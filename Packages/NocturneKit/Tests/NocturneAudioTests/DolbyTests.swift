//
// Nocturne — Dolby Digital and Dolby Digital Plus decode to their channels, each in its place.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import SFBAudioEngine
import Testing
@testable import NocturneAudio

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
        // Channels in Nocturne's order L R C LFE Ls Rs, whatever order the codec stores them in.
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
