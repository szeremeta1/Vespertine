//
// Vespertine — DTS CDs / DTS-in-WAV decode to 5.1 instead of playing as full-scale noise.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Accelerate
import AVFAudio
import Foundation
import SFBAudioEngine
import Testing
@testable import VespertineAudio

@Suite("DTS CDs")
struct DTSTests {
    private var fixture: URL { Bundle.module.url(forResource: "dts-cd-tones", withExtension: "wav", subdirectory: "Fixtures")! }

    private func decode(_ decoder: PCMDecoding, frames: Int) throws -> [[Float]] {
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096)!
        let channels = Int(decoder.processingFormat.channelCount)
        var out = [[Float]](repeating: [], count: channels)
        while out[0].count < frames {
            try decoder.decode(into: buffer, length: AVAudioFrameCount(min(4096, frames - out[0].count)))
            if buffer.frameLength == 0 { break }
            for c in 0..<channels { out[c] += UnsafeBufferPointer(start: buffer.floatChannelData![c], count: Int(buffer.frameLength)) }
        }
        return out
    }

    /// The strongest frequency in a signal (Hz), by a plain DFT scan over candidate tones.
    private func dominant(_ x: [Float], rate: Double, candidates: [Double]) -> Double {
        candidates.max { a, b in power(x, a, rate) < power(x, b, rate) }!
    }
    private func power(_ x: [Float], _ f: Double, _ rate: Double) -> Double {
        var re = 0.0, im = 0.0
        for (i, v) in x.enumerated() { let p = 2 * .pi * f * Double(i) / rate; re += Double(v) * cos(p); im += Double(v) * sin(p) }
        return re * re + im * im
    }

    @Test("A DTS CD is recognized and decoded as 5.1, each channel in its place")
    func decodesToSurround() throws {
        let probed = try SourceOpener.probe(fixture)
        #expect(probed.format.codec == "DTS")
        #expect(probed.format.encoding == .lossy)
        #expect(probed.format.channels == 6)
        #expect(probed.format.sampleRate == 44_100)
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: 44_100, decodedSampleRate: 44_100, physicalBitDepth: 32,
                              channels: 6, dsdConvertedToPCM: false, reason: "")
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: fixture))
        #expect(decoder.length == 110_592)                         // the WAV's own timeline
        let audio = try decode(decoder, frames: 110_592)
        #expect(audio[0].count == 110_592)
        let tones: [Double] = [440, 550, 660, 60, 770, 880]
        let layout = decoder.processingFormat.channelLayout
        #expect(layout != nil)
        let window = Array(audio[0][44_100..<48_196])
        _ = window
        for (c, expected) in tones.enumerated() {
            let slice = Array(audio[c][44_100..<48_196])
            #expect(dominant(slice, rate: 44_100, candidates: tones) == expected, "channel \(c): \(dominant(slice, rate: 44_100, candidates: tones)) layout \(String(describing: layout?.layoutTag)) mask")
            let peak = slice.map(abs).max() ?? 0
            #expect(peak > 0.05 && peak < 1.01, "channel \(c) level \(peak)")   // a tone, not full-scale noise
        }
    }

    @Test("Seeking lands on the same audio as playing through, within the codec's precision")
    func seeks() throws {
        let probed = try SourceOpener.probe(fixture)
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: 44_100, decodedSampleRate: 44_100, physicalBitDepth: 32,
                              channels: 6, dsdConvertedToPCM: false, reason: "")
        let through = try decode(try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: fixture)), frames: 110_592)
        let seeking = try SourceOpener.decoder(for: try SourceOpener.probe(fixture), plan: plan, item: PlayableItem(url: fixture))
        for target in [0, 1, 511, 512, 30_000, 77_777] {
            try seeking.seek(to: AVAudioFramePosition(target))
            #expect(seeking.position == AVAudioFramePosition(target))
            let got = try decode(seeking, frames: 2048)
            // Skip the first DTS frame after a seek (the filter bank's history restarts), then compare.
            let from = 1024
            for c in 0..<6 {
                let a = Array(got[c][from..<2048]), b = Array(through[c][(target + from)..<(target + 2048)])
                let diff = zip(a, b).map { abs($0 - $1) }.max() ?? 1
                #expect(diff < 0.01, "channel \(c) at \(target): \(diff) first8 \(a.prefix(4)) vs \(b.prefix(4))")
            }
        }
    }

    @Test("A CUE track inside a DTS CD starts where its index says")
    func cueRegion() throws {
        let probed = try SourceOpener.probe(fixture)
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: 44_100, decodedSampleRate: 44_100, physicalBitDepth: 32,
                              channels: 6, dsdConvertedToPCM: false, reason: "")
        let region = try SourceOpener.decoder(for: probed, plan: plan,
                                              item: PlayableItem(url: fixture, regionStartFrame: 44_100, regionFrameLength: 22_050))
        #expect(region.length == 22_050)
        let audio = try decode(region, frames: 30_000)
        #expect(audio[0].count == 22_050)
        #expect(dominant(Array(audio[2][4096..<8192]), rate: 44_100, candidates: [440, 550, 660, 60, 770, 880]) == 660)
    }

    @Test("A CUE track that runs a few frames past the end of the file still opens (clamped)")
    func overlongLastTrack() throws {
        let probed = try SourceOpener.probe(fixture)
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: 44_100, decodedSampleRate: 44_100, physicalBitDepth: 32,
                              channels: 6, dsdConvertedToPCM: false, reason: "")
        let region = try SourceOpener.decoder(for: probed, plan: plan,
                                              item: PlayableItem(url: fixture, regionStartFrame: 100_000, regionFrameLength: 10_609))
        #expect(region.length == 10_592)
        #expect(try decode(region, frames: 20_000)[0].count == 10_592)
    }

    @Test("Ordinary 16-bit stereo PCM is left alone")
    func plainPCM() throws {
        let url = try writeWAV("not-dts", rate: 44_100, bits: 16, seconds: 1) { c, i in Float(sin(Double(i) * 0.05 + Double(c))) * 0.5 }
        defer { try? FileManager.default.removeItem(at: url) }
        let probed = try SourceOpener.probe(url)
        #expect(probed.format.codec == "WAV")
        #expect(probed.format.channels == 2)
        #expect(probed.format.encoding == .pcm)
    }
}

/// Compares Vespertine's decode of a real DTS CD with FFmpeg's (set VESPERTINE_DTS_FILE and VESPERTINE_DTS_REFERENCE,
/// the latter being `ffmpeg -i FILE -t 30 -f f32le -c:a pcm_f32le`).
@Test(.enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_DTS_FILE"] != nil))
func realDTSMatchesFFmpeg() throws {
    let env = ProcessInfo.processInfo.environment
    let url = URL(fileURLWithPath: env["VESPERTINE_DTS_FILE"]!)
    let reference = try Data(contentsOf: URL(fileURLWithPath: env["VESPERTINE_DTS_REFERENCE"]!))
    let probed = try SourceOpener.probe(url)
    let channels = probed.format.channels
    let plan = OutputPlan(mode: .pcm, deviceSampleRate: probed.format.sampleRate, decodedSampleRate: probed.format.sampleRate,
                          physicalBitDepth: 32, channels: channels, dsdConvertedToPCM: false, reason: "")
    let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: url))
    let frames = reference.count / (4 * channels)
    let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096)!
    var done = 0, worst: Float = 0, peak: Float = 0
    reference.withUnsafeBytes { raw in
        let ref = raw.bindMemory(to: Float.self)
        while done < frames {
            try? decoder.decode(into: buffer, length: AVAudioFrameCount(min(4096, frames - done)))
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            for i in 0..<n { for c in 0..<channels {
                let v = buffer.floatChannelData![c][i]
                worst = max(worst, abs(v - ref[(done + i) * channels + c])); peak = max(peak, abs(v))
            } }
            done += n
        }
    }
    print("real DTS: \(probed.format.codec) \(channels) ch, \(done) of \(frames) frames, max difference \(worst), peak \(peak)")
    #expect(done == frames)
    #expect(worst == 0)
}

/// Diagnostic: opens CUE regions of a real DTS CD (VESPERTINE_DTS_CUE_FILE, VESPERTINE_DTS_REGIONS="start:length,…").
@Test(.enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_DTS_CUE_FILE"] != nil))
func realDTSRegions() throws {
    let env = ProcessInfo.processInfo.environment
    let url = URL(fileURLWithPath: env["VESPERTINE_DTS_CUE_FILE"]!)
    for region in env["VESPERTINE_DTS_REGIONS"]!.split(separator: ",") {
        let parts = region.split(separator: ":").compactMap { Int64($0) }
        do {
            let probed = try SourceOpener.probe(url)
            let plan = OutputPlan(mode: .pcm, deviceSampleRate: 44_100, decodedSampleRate: 44_100, physicalBitDepth: 32,
                                  channels: probed.format.channels, dsdConvertedToPCM: false, reason: "")
            let decoder = try SourceOpener.decoder(for: probed, plan: plan,
                                                   item: PlayableItem(url: url, regionStartFrame: parts[0], regionFrameLength: parts[1]))
            let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096)!
            var n = 0
            for _ in 0..<20 { try decoder.decode(into: buffer, length: 4096); n += Int(buffer.frameLength) }
            try decoder.seek(to: parts[1] / 2)
            try decoder.decode(into: buffer, length: 4096)
            print("region \(parts[0]) ok: decoded \(n), after seek \(buffer.frameLength), length \(decoder.length)")
        } catch {
            print("region \(parts[0]) FAILED: \(error) / \((error as NSError).domain) \((error as NSError).code)")
        }
    }
}
