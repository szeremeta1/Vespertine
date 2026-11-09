//
// Vespertine — DTS and Dolby TrueHD files (raw and in Matroska) decode through FFmpeg.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import SFBAudioEngine
import Testing
@testable import VespertineAudio

@Suite("DTS and TrueHD files")
struct FFmpegFormatTests {
    private func fixture(_ name: String) -> URL { Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")! }

    /// Decodes to Float32 per channel (integer formats converted exactly: ≤ 24 significant bits).
    private func decode(_ decoder: PCMDecoding, frames: Int = .max) throws -> [[Float]] {
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096)!
        let channels = Int(decoder.processingFormat.channelCount)
        let layout = decoder.processingFormat.channelLayout
            ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels))!
        let floatFormat = AVAudioFormat(standardFormatWithSampleRate: decoder.processingFormat.sampleRate, channelLayout: layout)
        let converter = decoder.processingFormat.commonFormat == .pcmFormatFloat32 && !decoder.processingFormat.isInterleaved
            ? nil : AVAudioConverter(from: decoder.processingFormat, to: floatFormat)
        var out = [[Float]](repeating: [], count: channels)
        while out[0].count < frames {
            try decoder.decode(into: buffer, length: AVAudioFrameCount(min(4096, frames - out[0].count)))
            if buffer.frameLength == 0 { break }
            var floats = buffer
            if let converter {
                floats = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: buffer.frameLength)!
                try converter.convert(to: floats, from: buffer)
            }
            for c in 0..<channels { out[c] += UnsafeBufferPointer(start: floats.floatChannelData![c], count: Int(floats.frameLength)) }
        }
        return out
    }

    private func open(_ name: String) throws -> (ProbedSource, PCMDecoding) {
        let probed = try SourceOpener.probe(fixture(name))
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: probed.format.sampleRate, decodedSampleRate: probed.format.sampleRate,
                              physicalBitDepth: 32, channels: probed.format.channels, dsdConvertedToPCM: false, reason: "")
        return (probed, try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: fixture(name))))
    }

    private func power(_ x: ArraySlice<Float>, _ f: Double) -> Double {
        var re = 0.0, im = 0.0
        for (i, v) in x.enumerated() { let p = 2 * .pi * f * Double(i) / 48_000; re += Double(v) * cos(p); im += Double(v) * sin(p) }
        return re * re + im * im
    }

    @Test("Each file is recognized, and every channel lands in its place", arguments: [
        ("dts-tones.dts", "DTS", false), ("dts-tones.mka", "DTS", false),
        ("truehd-tones.thd", "Dolby TrueHD", true), ("truehd-tones.mka", "Dolby TrueHD", true),
    ])
    func decodes(name: String, codec: String, lossless: Bool) throws {
        let (probed, decoder) = try open(name)
        #expect(probed.format.codec == codec)
        #expect((probed.format.encoding == .pcm) == lossless)
        #expect(probed.format.channels == 6 && probed.format.sampleRate == 48_000)
        if lossless { #expect(probed.format.bitDepth == 24) }
        let audio = try decode(decoder)
        #expect(abs(audio[0].count - 48_000) < 2_000, "\(audio[0].count) frames")
        let labels = decoder.processingFormat.channelLayout?.channelLabels ?? []
        let tones: [AudioChannelLabel: Double] = [kAudioChannelLabel_Left: 440, kAudioChannelLabel_Right: 550, kAudioChannelLabel_Center: 660,
                                                  kAudioChannelLabel_LFEScreen: 60, kAudioChannelLabel_LeftSurround: 770, kAudioChannelLabel_RightSurround: 880]
        #expect(labels.count == 6)
        for (c, label) in labels.enumerated() {
            let slice = audio[c][20_000..<24_096]
            let best = tones.values.max { power(slice, $0) < power(slice, $1) }!
            #expect(best == tones[label], "\(name) channel \(c): \(best)")
        }
    }

    @Test("Dolby TrueHD decodes to exactly the 24-bit audio it was made from", arguments: ["truehd-tones.thd", "truehd-tones.mka"])
    func trueHDIsLossless(name: String) throws {
        let (_, decoder) = try open(name)
        let decoded = try decode(decoder)
        let (_, reference) = try open("truehd-source.flac")
        let original = try decode(reference)
        // Channel order can differ between the two layouts: compare by label.
        let refLabels = reference.processingFormat.channelLayout?.channelLabels ?? []
        let labels = decoder.processingFormat.channelLayout?.channelLabels ?? []
        for (c, label) in labels.enumerated() {
            let r = try #require(refLabels.firstIndex(of: label))
            let n = min(decoded[c].count, original[r].count)
            #expect(n > 47_000)
            #expect(Array(decoded[c].prefix(n)) == Array(original[r].prefix(n)), "channel \(c) differs")
        }
    }

    @Test("Seeking lands on the same samples as playing through", arguments: ["truehd-tones.thd", "dts-tones.mka"])
    func seeks(name: String) throws {
        let (_, through) = try open(name)
        let all = try decode(through)
        let (_, seeking) = try open(name)
        for target in [0, 4_800, 20_000] {
            try seeking.seek(to: AVAudioFramePosition(target))
            #expect(seeking.position == AVAudioFramePosition(target))
            let got = try decode(seeking, frames: 2_048)
            for c in 0..<all.count {
                let diff = zip(got[c][512...], all[c][(target + 512)..<(target + 2_048)]).map { abs($0 - $1) }.max() ?? 1
                #expect(diff < (name.hasSuffix("thd") ? 1e-9 : 0.01), "\(name) channel \(c) at \(target): \(diff)")
            }
        }
    }

    @Test("Damaged frames in a lossless stream are counted, so the signal path can't call it bit-perfect", arguments: ["truehd-tones.thd", "truehd-tones.mka"])
    func damagedFramesCounted(name: String) throws {
        let (_, clean) = try open(name)
        let whole = try decode(clean)
        #expect((clean as? ConcealingDecoder)?.concealedFrames == 0)
        // 40 bytes in the middle of the stream scrambled, as a bad sector or a broken copy leaves them.
        var bytes = [UInt8](try Data(contentsOf: fixture(name)))
        for i in bytes.count / 2..<bytes.count / 2 + 40 { bytes[i] ^= 0x5A }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("damaged-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        let probed = try SourceOpener.probe(url)
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: 48_000, decodedSampleRate: 48_000, physicalBitDepth: 32,
                              channels: probed.format.channels, dsdConvertedToPCM: false, reason: "")
        let damaged = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: url))
        let audio = try decode(damaged)
        let concealed = (damaged as? ConcealingDecoder)?.concealedFrames ?? 0
        #expect(concealed > 0, "\(name): \(audio[0].count) of \(whole[0].count) frames, \(concealed) concealed")
    }

    /// The frames of dts-channel-change.dts (1,024 bytes each): ten stereo, then ten 5.1.
    private func channelChangeFrames() throws -> (stereo: [[UInt8]], surround: [[UInt8]]) {
        let bytes = [UInt8](try Data(contentsOf: fixture("dts-channel-change.dts")))
        let frames = stride(from: 0, to: bytes.count, by: 1024).map { Array(bytes[$0..<$0 + 1024]) }
        #expect(frames.count == 20 && frames.allSatisfy { $0.starts(with: [0x7F, 0xFE, 0x80, 0x01]) })
        return (Array(frames[..<10]), Array(frames[10...]))
    }

    /// Writes `frames` as a raw DTS file and opens it as playback does; then decodes until the end or an error.
    private func play(_ frames: [[UInt8]]) throws -> (format: SourceFormat, frames: Int, error: Error?, concealed: Int) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dts-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stream.dts")
        try Data(frames.flatMap { $0 }).write(to: url)
        let probed = try SourceOpener.probe(url)
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: probed.format.sampleRate, decodedSampleRate: probed.format.sampleRate,
                              physicalBitDepth: 32, channels: probed.format.channels, dsdConvertedToPCM: false, reason: "")
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: url))
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 1024)!
        var count = 0
        var failure: Error?
        do {
            while true {
                try decoder.decode(into: buffer, length: 1024)
                if buffer.frameLength == 0 { break }
                count += Int(buffer.frameLength)
            }
        } catch { failure = error }
        return (probed.format, count, failure, (decoder as? ConcealingDecoder)?.concealedFrames ?? 0)
    }

    @Test("A stream whose channel count changes for good plays its first part, then reports an error instead of just ending")
    func channelCountChange() throws {
        let (stereo, surround) = try channelChangeFrames()
        // Forty 5.1 frames: more than a run of damage, so the change has stuck.
        let result = try play(stereo + surround + surround + surround + surround)
        #expect(result.format.channels == 2)
        #expect(result.error is DTSError)
        #expect(result.frames > 3_000, "the stereo part plays first (\(result.frames) frames)")
    }

    @Test("One frame with another channel count in the middle is skipped and counted; the stream plays on to its end")
    func channelCountBlip() throws {
        let (stereo, surround) = try channelChangeFrames()
        let result = try play(stereo + [surround[0]] + stereo)
        #expect(result.error == nil)
        #expect(result.concealed > 0)
        #expect(result.frames >= 19 * 512, "\(result.frames) frames")
    }

    @Test("Matroska tags are read")
    func tags() {
        let tags = SourceInspector.containerTags(fixture("dts-tones.mka"))
        #expect(tags["title"] == "DTS Tones" && tags["artist"] == "Nocturne Test" && tags["album"] == "Fixtures")
    }
}
