//
// Vespertine — the studio evidence run's offline routing render (verification/studio/). Each listed file goes through
// the app's own probe and decoder, and is written twice as a float CAF labelled with its channel layout, for
// verify_chid.py --coreaudio:
//   decoder   what the decoder delivers, in its own layout (is every channel labelled as the speaker it holds?)
//   discrete  converted the way the engine does for a discrete multichannel output with no speaker layout configured
//             (FormatPlanner plan, OutputSession.routeLayout, the engine's converter settings): what reaches the ring.
// The device I/O after the converter (ring buffer, IOProc, Core Audio) is not part of it; a capture covers that.
// Runs when VESPERTINE_STUDIO_RENDER=<file with one path per line> and VESPERTINE_STUDIO_RENDER_OUT=<folder> are set;
// writes <folder>/render.jsonl (one row per file and variant) next to the CAFs.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Studio routing render (opt-in)")
struct StudioRoutingTests {
    static let list = ProcessInfo.processInfo.environment["VESPERTINE_STUDIO_RENDER"]
    static let out = ProcessInfo.processInfo.environment["VESPERTINE_STUDIO_RENDER_OUT"]

    enum Variant: String, CaseIterable { case decoder, discrete }

    /// Renders `url` for `variant` into `dest`; returns the row for render.jsonl.
    static func render(_ url: URL, variant: Variant, to dest: URL) throws -> [String: Any] {
        let probed = try SourceOpener.probe(url)
        let f = probed.format
        let pcmRate = f.encoding == .dsd ? FormatPlanner.dsdToPCMRate(f.sampleRate) : f.sampleRate
        // A device with as many outputs as the file has channels, at its rate, no DoP, no bitstream, no speaker layout.
        var plan = FormatPlanner.plan(source: f, device: DeviceCapabilities(sampleRates: [pcmRate], physicalFormats: [],
                                                                           outputChannels: max(f.channels, 2), supportsDoP: false))
        plan.integerSamples = false
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: url))
        let own = decoder.processingFormat.channelLayout
        let layout = variant == .decoder ? own : OutputSession.routeLayout(plan: plan, speakers: nil)
        let channels = variant == .decoder ? Int(decoder.processingFormat.channelCount) : plan.channels
        let rate = variant == .decoder ? decoder.processingFormat.sampleRate : plan.deviceSampleRate
        guard let outFormat = AudioFormats.float32(sampleRate: rate, channels: channels, interleaved: true, layout: layout),
              let converter = AVAudioConverter(from: decoder.processingFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 8192),
              let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 8192) else {
            throw SourceOpenerError.unsupported(url)
        }
        // The engine's converter settings (PlaybackEngine.Decoding).
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = .max
        converter.downmix = true
        converter.dither = false
        let file = try AVAudioFile(forWriting: dest, settings: outFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        var ended = false, frames = 0
        while true {
            output.frameLength = 0
            let status = converter.convert(to: output, error: nil) { _, s in
                if ended { s.pointee = .endOfStream; return nil }
                do { try decoder.decode(into: input, length: input.frameCapacity) } catch { ended = true }
                if input.frameLength == 0 { ended = true; s.pointee = .endOfStream; return nil }
                s.pointee = .haveData
                return input
            }
            if output.frameLength > 0 { try file.write(from: output); frames += Int(output.frameLength) }
            if status == .error || status == .endOfStream || (output.frameLength == 0 && ended) { break }
        }
        return ["file": url.path, "variant": variant.rawValue, "out": dest.path, "frames": frames,
                "decoder": probed.decoderName, "source_channels": f.channels, "source_rate": f.sampleRate,
                "decoder_layout": own?.shortNames ?? [], "route_layout": outFormat.channelLayout?.shortNames ?? [],
                "plan": ["mode": plan.mode.rawValue, "rate": plan.deviceSampleRate, "channels": plan.channels,
                         "device_channels": plan.deviceChannels, "reason": plan.reason]]
    }

    @Test(.enabled(if: list != nil && out != nil))
    func renderListedFiles() throws {
        let paths = try String(contentsOfFile: Self.list!, encoding: .utf8).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let dir = URL(fileURLWithPath: Self.out!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines: [String] = [], failed = 0
        for (i, path) in paths.enumerated() {
            for variant in Variant.allCases {
                let dest = dir.appendingPathComponent(String(format: "%04d-%@.caf", i + 1, variant.rawValue))
                var row: [String: Any]
                do { row = try Self.render(URL(fileURLWithPath: path), variant: variant, to: dest) } catch {
                    row = ["file": path, "variant": variant.rawValue, "error": "\(error)"]; failed += 1
                }
                let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
                lines.append(String(decoding: data, as: UTF8.self))
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("render.jsonl"), atomically: true, encoding: .utf8)
        print("studio render: \(paths.count) files, \(lines.count - failed) renders, \(failed) could not be rendered -> \(dir.path)")
        #expect(!paths.isEmpty)
    }
}
