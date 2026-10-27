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

/// A float32 interleaved CAF written byte for byte from the converter's output, with its channel layout and true rate.
/// (AVAudioFile wrote a 192 kHz header for 352.8 kHz DSD-to-PCM output, which made the file 1.8 times too long.)
final class CAFWriter {
    let handle: FileHandle
    let dataSizeOffset: UInt64
    var bytes: UInt64 = 0

    init(_ url: URL, rate: Double, channels: Int, layout: AVAudioChannelLayout?) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        var d = Data()
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        func i64(_ v: Int64) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        func f64(_ v: Double) { u32(UInt32(v.bitPattern >> 32)); u32(UInt32(v.bitPattern & 0xFFFF_FFFF)) }
        func f32(_ v: Float) { u32(v.bitPattern) }
        func tag(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        tag("caff"); u16(1); u16(0)
        tag("desc"); i64(32)
        f64(rate); tag("lpcm"); u32(1 | 2)   // kCAFLinearPCMFormatFlagIsFloat | IsLittleEndian
        u32(UInt32(4 * channels)); u32(1); u32(UInt32(channels)); u32(32)
        let acl = layout?.layout.pointee
        let tagValue = acl?.mChannelLayoutTag ?? (channels == 1 ? kAudioChannelLayoutTag_Mono
                                                  : channels == 2 ? kAudioChannelLayoutTag_Stereo
                                                  : kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels))
        let count = tagValue == kAudioChannelLayoutTag_UseChannelDescriptions ? Int(acl?.mNumberChannelDescriptions ?? 0) : 0
        tag("chan"); i64(Int64(12 + 20 * count))
        u32(tagValue); u32(acl?.mChannelBitmap.rawValue ?? 0); u32(UInt32(count))
        if count > 0, let layout {
            // The descriptions run past the struct's one-element array: read them through the layout's own pointer.
            let descs = (UnsafeRawPointer(layout.layout) + MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!)
                .assumingMemoryBound(to: AudioChannelDescription.self)
            for i in 0..<count {
                u32(descs[i].mChannelLabel); u32(descs[i].mChannelFlags.rawValue)
                f32(descs[i].mCoordinates.0); f32(descs[i].mCoordinates.1); f32(descs[i].mCoordinates.2)
            }
        }
        tag("data")
        dataSizeOffset = UInt64(d.count)
        i64(-1); u32(0)   // size patched on close; edit count
        handle.write(d)
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard let first = list.first, let data = first.mData else { return }
        let n = Int(buffer.frameLength) * Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        handle.write(Data(bytes: data, count: n))
        bytes += UInt64(n)
    }

    func close() {
        try? handle.seek(toOffset: dataSizeOffset)
        withUnsafeBytes(of: Int64(bytes + 4).bigEndian) { handle.write(Data($0)) }
        try? handle.close()
    }
}

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
        // The engine's own converter (PlaybackEngine.Decoding); the decoder variant keeps the decoder's channels as they are.
        guard let outFormat = AudioFormats.float32(sampleRate: rate, channels: channels, interleaved: true, layout: layout),
              let converter = variant == .discrete ? OutputSession.converter(from: decoder.processingFormat, to: outFormat, plan: plan)
                                                   : AVAudioConverter(from: decoder.processingFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 8192),
              let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 8192) else {
            throw SourceOpenerError.unsupported(url)
        }
        if variant == .decoder {
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converter.sampleRateConverterQuality = .max
            converter.downmix = true
            converter.dither = false
        }
        let file = try CAFWriter(dest, rate: rate, channels: channels, layout: outFormat.channelLayout)
        defer { file.close() }
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
            if output.frameLength > 0 { file.write(output); frames += Int(output.frameLength) }
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
