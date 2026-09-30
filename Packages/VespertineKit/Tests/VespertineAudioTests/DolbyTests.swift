//
// Vespertine — Dolby Digital and Dolby Digital Plus decode to their channels, each in its place.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import SFBAudioEngine
import Testing
@testable import VespertineAudio

@Suite("Dolby Digital")
struct DolbyTests {
    private func fixture(_ name: String) -> URL { Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")! }

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

    private func power(_ x: ArraySlice<Float>, _ f: Double) -> Double {
        var re = 0.0, im = 0.0
        for (i, v) in x.enumerated() { let p = 2 * .pi * f * Double(i) / 48_000; re += Double(v) * cos(p); im += Double(v) * sin(p) }
        return re * re + im * im
    }

    @Test("Dolby files are recognized and decode to 5.1 in the right order", arguments: [
        ("dolby-digital-tones.ac3", "Dolby Digital"), ("dolby-digital-plus-tones.ec3", "Dolby Digital Plus"),
        ("dolby-digital-plus-tones.m4a", "Dolby Digital Plus"),
    ])
    func decodes(name: String, codec: String) throws {
        let url = fixture(name)
        let probed = try SourceOpener.probe(url)
        #expect(probed.format.codec == codec)
        #expect(probed.format.encoding == .lossy)
        #expect(probed.format.channels == 6)
        #expect(probed.format.sampleRate == 48_000)
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: 48_000, decodedSampleRate: 48_000, physicalBitDepth: 32,
                              channels: 6, dsdConvertedToPCM: false, reason: "")
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: url))
        let audio = try decode(decoder, frames: 72_000)
        #expect(audio[0].count > 60_000)
        // Channels in Vespertine's order L R C LFE Ls Rs, whatever order the codec stores them in.
        let layout = decoder.processingFormat.channelLayout?.channelLabels ?? []
        let tones: [AudioChannelLabel: Double] = [kAudioChannelLabel_Left: 440, kAudioChannelLabel_Right: 550, kAudioChannelLabel_Center: 660,
                                                  kAudioChannelLabel_LFEScreen: 60, kAudioChannelLabel_LeftSurround: 770, kAudioChannelLabel_RightSurround: 880]
        #expect(layout.count == 6, "layout \(layout)")
        for (c, label) in layout.enumerated() {
            guard let expected = tones[label] else { Issue.record("unexpected channel label \(label)"); continue }
            let slice = audio[c][24_000..<28_096]
            let best = tones.values.max { power(slice, $0) < power(slice, $1) }!
            #expect(best == expected, "\(name) channel \(c) (label \(label)) has \(best), expected \(expected)")
        }
    }
}

@Suite("Dolby Digital modes macOS decodes wrongly")
struct DolbyModeTests {
    /// The start of an AC-3 frame: sync, crc1, fscod/frmsizecod, bsid 8 / bsmod 0, then acmod and the fields after it.
    func frame(_ modeByte: UInt8) -> [UInt8] { [0x0B, 0x77, 0, 0, 0, 0x40, modeByte, 0, 0, 0] + [UInt8](repeating: 0, count: 16) }

    @Test("2/1, 3/0+LFE and 3/1+LFE go to FFmpeg; the usual modes stay with macOS")
    func routing() throws {
        let twoOneLFE = try #require(DolbyModes.mode(in: frame(0b100_00_1_00)))   // acmod 4, surmixlev, lfeon
        #expect(twoOneLFE == .init(acmod: 4, lfe: true, enhanced: false, extended: false) && DolbyModes.needsFFmpeg(twoOneLFE))
        let threeLFE = try #require(DolbyModes.mode(in: frame(0b011_00_1_00)))    // acmod 3, cmixlev, lfeon
        #expect(threeLFE.acmod == 3 && threeLFE.lfe && DolbyModes.needsFFmpeg(threeLFE) && DolbyModes.name(threeLFE) == "3/0+LFE")
        let fiveOne = try #require(DolbyModes.mode(in: frame(0b111_00_00_1)))     // acmod 7, cmixlev, surmixlev, lfeon
        #expect(fiveOne.acmod == 7 && fiveOne.lfe && !DolbyModes.needsFFmpeg(fiveOne))
        let stereo = try #require(DolbyModes.mode(in: frame(0b010_00_0_00)))      // acmod 2, dsurmod, lfeon off
        #expect(stereo.acmod == 2 && !stereo.lfe && !DolbyModes.needsFFmpeg(stereo))
        #expect(!DolbyModes.needsFFmpeg(.init(acmod: 4, lfe: false, enhanced: true, extended: true)), "7.1 E-AC-3 stays with macOS")
    }
}
