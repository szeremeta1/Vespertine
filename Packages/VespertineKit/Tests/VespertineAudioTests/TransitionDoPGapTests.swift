//
// Vespertine — a gap between two native DSD songs (DoP): DSD silence between them, the markers alternating through the
// gap and into the next song, each song's words untouched; the album and SACD rules still come first.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Transitions: gaps on native DSD")
struct TransitionDoPGapTests {
    typealias T = TransitionGolden
    typealias R = GoldenRender

    static func plan(_ mode: OutputPlan.Mode, rate: Double = 176_400) -> OutputPlan {
        OutputPlan(mode: mode, deviceSampleRate: rate, decodedSampleRate: rate, physicalBitDepth: 24, channels: 2, dsdConvertedToPCM: false, reason: "")
    }

    static func gap(_ seconds: Double) -> TransitionSettings {
        var s = T.on
        s.gapSeconds = seconds
        return s
    }

    @Test("The planner: a gap between two DoP songs; still gapless in an album or an SACD, still a cut without a gap or to PCM")
    func planner() {
        let u = URL(fileURLWithPath: "/x.dsf"), v = URL(fileURLWithPath: "/y.dsf")
        let a = PlayableItem(url: u), b = PlayableItem(url: v)
        let dop = BoundaryFormat.plan(Self.plan(.dop))
        #expect(TransitionPlanner.decide(Self.gap(2), from: a, format: dop, to: b, format: dop) == .gap(seconds: 2))
        #expect(TransitionPlanner.decide(Self.gap(0), from: a, format: dop, to: b, format: dop) == .cut(.nativeDSD))
        #expect(TransitionPlanner.decide(T.on, from: a, format: dop, to: b, format: dop) == .cut(.nativeDSD))
        // Another DSD rate (not the same output): no gap, a cut.
        #expect(TransitionPlanner.decide(Self.gap(2), from: a, format: dop, to: b, format: .plan(Self.plan(.dop, rate: 352_800)), compatible: false)
            == .cut(.nativeDSD))
        // DoP to PCM, PCM to DoP: cuts.
        #expect(TransitionPlanner.decide(Self.gap(2), from: a, format: dop, to: b, format: .plan(Self.plan(.pcm, rate: 44_100)), compatible: false)
            == .cut(.nativeDSD))
        #expect(TransitionPlanner.decide(Self.gap(2), from: a, format: .plan(Self.plan(.pcm)), to: b, format: dop) == .cut(.nativeDSD))
        // Bitstream: never.
        #expect(TransitionPlanner.decide(Self.gap(2), from: a, format: .plan(Self.plan(.bitstream, rate: 48_000)), to: b,
                                         format: .plan(Self.plan(.bitstream, rate: 48_000))) == .cut(.bitstream))
        // Albums and SACDs first.
        let one = PlayableItem(url: u, context: TransitionContext(albumKey: "k", trackNumber: 1))
        let two = PlayableItem(url: v, context: TransitionContext(albumKey: "k", trackNumber: 2))
        #expect(TransitionPlanner.decide(Self.gap(2), from: one, format: dop, to: two, format: dop) == .gapless(.sameAlbum))
        let s1 = PlayableItem(url: u, regionStartFrame: 0, regionFrameLength: 2_822_400, sacdArea: .stereo)
        let s2 = PlayableItem(url: u, regionStartFrame: 2_822_400, regionFrameLength: 2_822_400, sacdArea: .stereo)
        #expect(TransitionPlanner.decide(Self.gap(2), from: s1, format: dop, to: s2, format: dop) == .gapless(.sacd))
        // An excluded genre: gapless, as for PCM.
        let classical = PlayableItem(url: v, context: TransitionContext(genre: "Classical"))
        #expect(TransitionPlanner.decide(Self.gap(2), from: a, format: dop, to: classical, format: dop) == .gapless(.excludedGenre))
    }

    /// Two DSD64 tracks (not of one album), the first an odd number of DoP frames, as the golden gapless pair.
    static func pair(_ name: String) throws -> [PlayableItem] {
        try (0..<2).map { i in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("vt-dopgap-\(name)-\(i).dsf")
            let bits = 846_720 + (i == 0 ? 16 : 0)
            try DSDFiles.writeDSF(GoldenFixtures.dsdPlanes(bits: bits, channels: 2, seed: i), rate: 2_822_400, to: url)
            return PlayableItem(url: url)
        }
    }

    /// The 24-bit DoP word in a device word (a float sample: the word as a 24-bit integer over 2²³, exact in a Float).
    static func dopWord(_ deviceWord: UInt32) -> UInt32 {
        UInt32(bitPattern: Int32(Float(bitPattern: deviceWord) * 2_147_483_648)) >> 8
    }

    /// The DoP marker of each frame (left channel), from the device's words.
    static func markers(_ words: [UInt32]) -> [UInt32] {
        stride(from: 0, to: words.count, by: 2).map { dopWord(words[$0]) >> 16 }
    }

    @Test("Golden: the first song's words, then DoP idle frames for the gap, then the second song's words, markers alternating throughout")
    func goldenGap() throws {
        let items = try Self.pair("golden")
        let off = try R.render(items, device: GoldenDevices.dopDAC)
        let run = try R.render(items, device: GoldenDevices.dopDAC, transitions: Self.gap(0.5), dither: true)
        #expect(run.decisions == [.gap(seconds: 0.5)])
        #expect(run.mixes.isEmpty)
        let offWords = try #require(off.sessions.first).words
        let words = try #require(run.output.sessions.first).words
        #expect(run.output.sessions.count == 1 && run.output.sessions.first?.plan.mode == .dop)
        let lengthA = 52_921, gap = 88_200   // DoP frames: the first song's, and half a second at 176.4 kHz
        #expect(words.count == offWords.count + gap * 2)
        // The first song exactly, then the gap, then the second song exactly as it joins gaplessly (the gap is an even
        // number of frames, so the second song's markers are where they'd be without it).
        #expect(Array(words.prefix(lengthA * 2)) == Array(offWords.prefix(lengthA * 2)))
        let idle = PlaybackEngine.dopIdle(frames: gap, channels: 2, from: UInt64(lengthA), integer: false).map(\.bitPattern)
        #expect(Array(words[(lengthA * 2)..<((lengthA + gap) * 2)]) == idle)
        #expect(Array(words.suffix(offWords.count - lengthA * 2)) == Array(offWords.suffix(offWords.count - lengthA * 2)))
        // The gap is DSD silence (0x69 0x69 behind each marker) and the markers never repeat, anywhere.
        let gapWords = words[(lengthA * 2)..<((lengthA + gap) * 2)]
        #expect(gapWords.allSatisfy { Self.dopWord($0) & 0xFFFF == 0x6969 })
        let m = Self.markers(words)
        #expect(m.allSatisfy { $0 == 0x05 || $0 == 0xFA })
        #expect(zip(m, m.dropFirst()).allSatisfy { $0 != $1 }, "a marker repeats")
    }

    @Test("In an album the gap isn't there: the off bytes")
    func albumHasNoGap() throws {
        let plain = try Self.pair("album")
        let items = plain.enumerated().map { PlayableItem(url: $1.url, context: GoldenCases.track($0 + 1)) }
        let run = try R.render(items, device: GoldenDevices.dopDAC, transitions: Self.gap(2), dither: true)
        #expect(run.decisions == [.gapless(.sameAlbum)])
        #expect(run.output.sha256 == (try R.render(items, device: GoldenDevices.dopDAC)).sha256)
    }

    @Test("The engine's idle frames: the marker by ring frame, the idle pattern, as the float word or the 32-bit word")
    func idleFrames() {
        let f = PlaybackEngine.dopIdle(frames: 3, channels: 2, from: 7, integer: false)
        #expect(f.count == 6 && f[0] == f[1] && f[2] == f[3])
        let words = f.map { UInt32(bitPattern: Int32(($0 * 2_147_483_648).rounded())) >> 8 }
        #expect(words[0] == 0xFA6969 && words[2] == 0x056969 && words[4] == 0xFA6969)
        let i = PlaybackEngine.dopIdle(frames: 2, channels: 1, from: 0, integer: true)
        #expect(i[0].bitPattern == 0x0569_6900 && i[1].bitPattern == 0xFA69_6900)
    }
}
