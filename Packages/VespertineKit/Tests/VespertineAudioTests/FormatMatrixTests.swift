//
// Vespertine — every file in a folder of format samples (VESPERTINE_FORMAT_DIR) opens, decodes, seeks and
// sounds like audio (not silence, not full-scale noise). Prints a table.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import SFBAudioEngine
import Testing
@testable import VespertineAudio

@Test(.enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_FORMAT_DIR"] != nil))
func formatMatrix() throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VESPERTINE_FORMAT_DIR"]!)
    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
        .filter { SourceInspector.supportedExtensions.contains($0.pathExtension.lowercased()) && $0.pathExtension.lowercased() != "cue" }
        .sorted { $0.path < $1.path }
    var failures = 0
    for url in files {
        let name = url.path.replacingOccurrences(of: root.path + "/", with: "")
        do {
            let probed = try SourceOpener.probe(url)
            let f = probed.format
            let pcmRate = f.encoding == .dsd ? FormatPlanner.dsdToPCMRate(f.sampleRate) : f.sampleRate
            let plan = OutputPlan(mode: .pcm, deviceSampleRate: pcmRate, decodedSampleRate: pcmRate, physicalBitDepth: 32,
                                  channels: f.channels, dsdConvertedToPCM: f.encoding == .dsd, reason: "")
            let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: url))
            let floatFormat = AVAudioFormat(standardFormatWithSampleRate: decoder.processingFormat.sampleRate,
                                            channelLayout: decoder.processingFormat.channelLayout
                                                ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(f.channels))!)
            let converter = decoder.processingFormat == floatFormat ? nil : AVAudioConverter(from: decoder.processingFormat, to: floatFormat)
            func measure(frames: Int) throws -> (Int, Float, Double) {
                let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 8192)!
                var got = 0, peak: Float = 0, sum = 0.0, n = 0
                while got < frames {
                    try decoder.decode(into: buffer, length: 8192)
                    if buffer.frameLength == 0 { break }
                    var fb = buffer
                    if let converter { fb = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: buffer.frameLength)!; try converter.convert(to: fb, from: buffer) }
                    for c in 0..<Int(fb.format.channelCount) { for i in 0..<Int(fb.frameLength) { let v = fb.floatChannelData![c][i]; peak = max(peak, abs(v)); sum += Double(v * v); n += 1 } }
                    got += Int(buffer.frameLength)
                }
                return (got, peak, n > 0 ? 10 * log10(max(sum / Double(n), 1e-20)) : -200)
            }
            let (frames, peak, rms) = try measure(frames: Int(pcmRate * 3))
            try decoder.seek(to: max(0, decoder.length / 2))
            let (afterSeek, _, _) = try measure(frames: 4096)
            var extras: [String] = []
            if f.codec == DolbyAtmos.codecName { extras.append("objects up to \(DolbyAtmos.maximumLayout(url).map(DolbyAtmos.layoutName) ?? "?")") }
            if SourceInspector.canBitstream(url, codec: f.codec), f.codec != "DTS" {
                let b = try BitstreamDecoder.open(url: url)
                extras.append("bitstream \(Int(b.processingFormat.sampleRate / 1000)) kHz carrier")
            }
            if f.encoding == .dsd {
                let dop = OutputPlan(mode: .dop, deviceSampleRate: FormatPlanner.dopCarrierRate(f.sampleRate), decodedSampleRate: FormatPlanner.dopCarrierRate(f.sampleRate),
                                     physicalBitDepth: 24, channels: f.channels, dsdConvertedToPCM: false, reason: "")
                let d = try SourceOpener.decoder(for: try SourceOpener.probe(url), plan: dop, item: PlayableItem(url: url))
                extras.append("DoP \(Int(d.processingFormat.sampleRate / 1000)) kHz")
            }
            let noise = peak > 0.99 && rms > -6          // full-scale noise (a bitstream played as PCM)
            let silent = rms < -90
            let ok = frames > 0 && afterSeek > 0 && !noise && !silent
            if !ok { failures += 1 }
            let bits = f.bitDepth.map { "\($0)-bit" } ?? (f.encoding == .dsd ? "1-bit" : "lossy")
            print(String(format: "%@ %-58@ %-22@ %@ ch  %@ %@  %@ Hz  rms %6.1f dB  peak %.2f  %@", ok ? "✓" : "✗", name as NSString, f.codec as NSString,
                         "\(f.channels)", bits as NSString, f.encoding.rawValue as NSString, "\(Int(f.sampleRate))" as NSString, rms, peak, extras.joined(separator: ", ") as NSString))
        } catch {
            failures += 1
            print("✗ \(name): \(error.localizedDescription)")
        }
    }
    #expect(failures == 0)
}
