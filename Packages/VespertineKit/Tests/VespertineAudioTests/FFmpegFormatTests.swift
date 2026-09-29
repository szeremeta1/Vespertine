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

    @Test("Matroska tags are read")
    func tags() {
        let tags = SourceInspector.containerTags(fixture("dts-tones.mka"))
        #expect(tags["title"] == "DTS Tones" && tags["artist"] == "Nocturne Test" && tags["album"] == "Fixtures")
    }
}
