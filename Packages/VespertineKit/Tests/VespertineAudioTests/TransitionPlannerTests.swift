//
// Vespertine — song transitions, the pure parts: the gain curves, the album rule, and the planner's decision for
// every kind of boundary.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Transition curves")
struct TransitionCurveTests {
    private let steps = (0...1000).map { Double($0) / 1000 }

    @Test("Exactly all of the outgoing song at the start and all of the incoming one at the end", arguments: TransitionCurve.allCases)
    func endpoints(_ curve: TransitionCurve) {
        #expect(curve.gains(at: 0) == (1, 0))
        #expect(curve.gains(at: 1) == (0, 1))
        // Outside 0…1 (rounding at the ends of a ramp) it holds the end values.
        #expect(curve.gains(at: -0.5) == (1, 0))
        #expect(curve.gains(at: 1.5) == (0, 1))
    }

    @Test("Equal-power keeps out² + in² = 1")
    func equalPower() {
        for t in steps {
            let g = TransitionCurve.equalPower.gains(at: t)
            #expect(abs(g.out * g.out + g.in * g.in - 1) < 1e-12, "t = \(t)")
        }
        // Halfway, each is at −3 dB.
        let mid = TransitionCurve.equalPower.gains(at: 0.5)
        #expect(abs(mid.out - 0.5.squareRoot()) < 1e-12 && abs(mid.in - 0.5.squareRoot()) < 1e-12)
    }

    @Test("Linear and the S-curve keep out + in = 1", arguments: [TransitionCurve.linear, .sCurve])
    func constantAmplitude(_ curve: TransitionCurve) {
        for t in steps {
            let g = curve.gains(at: t)
            #expect(abs(g.out + g.in - 1) < 1e-12, "t = \(t)")
        }
    }

    @Test("Every curve moves one way only, and is the same played backwards", arguments: TransitionCurve.allCases)
    func monotoneAndSymmetric(_ curve: TransitionCurve) {
        for (a, b) in zip(steps, steps.dropFirst()) {
            #expect(curve.gains(at: b).in >= curve.gains(at: a).in && curve.gains(at: b).out <= curve.gains(at: a).out)
        }
        for t in steps {
            #expect(abs(curve.gains(at: t).in - curve.gains(at: 1 - t).out) < 1e-12)
        }
    }

    @Test("The S-curve is gentle at both ends and quick in the middle")
    func sCurveShape() {
        let s = TransitionCurve.sCurve, l = TransitionCurve.linear
        #expect(s.gains(at: 0.1).in < l.gains(at: 0.1).in)
        #expect(s.gains(at: 0.9).in > l.gains(at: 0.9).in)
        #expect(abs(s.gains(at: 0.5).in - 0.5) < 1e-12)
        // Its slope at the middle is π/2 (linear's is 1).
        let slope = (s.gains(at: 0.501).in - s.gains(at: 0.499).in) / 0.002
        #expect(abs(slope - .pi / 2) < 1e-4)
    }
}

/// Every format nothing may touch, on either side of the boundary (PLAN §2).
enum PlannerCuts {
    static let all: [(BoundaryFormat, TransitionDecision.CutReason)] = [
        (.plan(TransitionPlannerTests.plan(.dop, rate: 176_400)), .nativeDSD),
        (.plan(TransitionPlannerTests.plan(.bitstream, rate: 48_000)), .bitstream),
        (.systemRenderer, .atmos),
        (.plan(TransitionPlannerTests.plan(integer: true)), .integerMode),
        (.plan(TransitionPlannerTests.plan(sixteen: .requested)), .sixteenBit),
    ]

}

@Suite("Transition planner")
struct TransitionPlannerTests {
    static let url = URL(fileURLWithPath: "/music/a.flac")
    static let other = URL(fileURLWithPath: "/music/b.flac")

    static func plan(_ mode: OutputPlan.Mode = .pcm, rate: Double = 44_100, channels: Int = 2, integer: Bool = false,
                     sixteen: SixteenBitMatch? = nil) -> OutputPlan {
        var p = OutputPlan(mode: mode, deviceSampleRate: rate, decodedSampleRate: rate, physicalBitDepth: 24, channels: channels,
                           dsdConvertedToPCM: false, reason: "")
        p.integerSamples = integer
        p.sixteenBit = sixteen
        return p
    }

    static func item(_ url: URL = other, album: String? = nil, disc: Int? = nil, track: Int? = nil, genre: String? = nil,
                     region: (Int64, Int64)? = nil, sacd: SACDArea? = nil) -> PlayableItem {
        let context = album == nil && track == nil && genre == nil ? nil
            : TransitionContext(albumKey: album, discNumber: disc, trackNumber: track, genre: genre)
        return PlayableItem(url: url, regionStartFrame: region?.0, regionFrameLength: region?.1, sacdArea: sacd, context: context)
    }

    static var on: TransitionSettings {
        var s = TransitionSettings()
        s.enabled = true
        return s
    }

    private func decide(_ a: PlayableItem = item(url), _ fa: BoundaryFormat = .plan(plan()), _ b: PlayableItem = item(),
                        _ fb: BoundaryFormat = .plan(plan()), settings: TransitionSettings = on, compatible: Bool = true,
                        lengthKnown: Bool = true, streams: Bool = false) -> TransitionDecision {
        TransitionPlanner.decide(settings, from: a, format: fa, to: b, format: fb, compatible: compatible, lengthKnown: lengthKnown,
                                 nextStreams: streams)
    }

    @Test("Unrelated songs on the same output format crossfade, at the chosen length and curve")
    func crossfade() {
        #expect(decide() == .overlap(seconds: 6, curve: .equalPower))
        var s = Self.on
        s.crossfadeSeconds = 2.5
        s.curve = .sCurve
        #expect(decide(settings: s) == .overlap(seconds: 2.5, curve: .sCurve))
    }

    @Test("Master switch off: every boundary is today's, whatever else is set")
    func off() {
        var s = Self.on
        s.enabled = false
        for fb in [BoundaryFormat.plan(Self.plan()), .plan(Self.plan(.dop)), .systemRenderer, .unknown] {
            #expect(decide(Self.item(Self.url), .plan(Self.plan(.bitstream)), settings: s) == .gapless(.off))
            #expect(decide(Self.item(Self.url), .plan(Self.plan()), Self.item(), fb, settings: s, compatible: false) == .gapless(.off))
        }
    }

    @Test("Native DSD, bitstream, Atmos, integer and 16-bit words are never mixed or faded, on either side",
          arguments: 0..<PlannerCuts.all.count)
    func cuts(_ index: Int) {
        let (format, reason) = PlannerCuts.all[index]
        #expect(decide(Self.item(Self.url), format, Self.item(), .plan(Self.plan())) == .cut(reason))
        #expect(decide(Self.item(Self.url), .plan(Self.plan()), Self.item(), format) == .cut(reason))
        // Even where the format changes anyway (no dip either).
        #expect(decide(Self.item(Self.url), format, Self.item(), .plan(Self.plan(rate: 96_000)), compatible: false) == .cut(reason))
        // And when the next song's format isn't known yet, the outgoing side still decides.
        #expect(decide(Self.item(Self.url), format, Self.item(), .unknown) == .cut(reason))
    }

    @Test("16-bit sent zero-padded (no 16-bit mode) mixes like any PCM")
    func sixteenBitPadded() {
        #expect(decide(Self.item(Self.url), .plan(Self.plan(sixteen: .noMode)), Self.item(), .plan(Self.plan())) == .overlap(seconds: 6, curve: .equalPower))
    }

    @Test("Another rate or channel count: a dip, faded out and in around the reconfigure gap")
    func dip() {
        #expect(decide(compatible: false) == .dip(seconds: TransitionPlanner.dipSeconds, curve: .equalPower))
        var s = Self.on
        s.curve = .linear
        #expect(decide(settings: s, compatible: false) == .dip(seconds: 1, curve: .linear))
    }

    @Test("Consecutive album tracks always play gaplessly, playlists included")
    func album() {
        let a = Self.item(Self.url, album: "k", disc: 1, track: 3)
        #expect(decide(a, .plan(Self.plan()), Self.item(album: "k", disc: 1, track: 4)) == .gapless(.sameAlbum))
        // Disc 1's last track into disc 2's first.
        #expect(decide(a, .plan(Self.plan()), Self.item(album: "k", disc: 2, track: 1)) == .gapless(.sameAlbum))
        // No disc numbers: disc 1.
        #expect(decide(Self.item(Self.url, album: "k", track: 3), .plan(Self.plan()), Self.item(album: "k", track: 4)) == .gapless(.sameAlbum))
        // Even when the next one needs another format: it isn't faded.
        #expect(decide(a, .plan(Self.plan()), Self.item(album: "k", disc: 1, track: 4), compatible: false) == .gapless(.sameAlbum))
        // Same album out of order (shuffle, a playlist that jumps), another album, or no album: a crossfade.
        #expect(decide(a, .plan(Self.plan()), Self.item(album: "k", disc: 1, track: 7)).changesSamples)
        #expect(decide(a, .plan(Self.plan()), Self.item(album: "k", disc: 1, track: 2)).changesSamples)
        #expect(decide(a, .plan(Self.plan()), Self.item(album: "other", disc: 1, track: 4)).changesSamples)
        #expect(decide(Self.item(Self.url, album: "", track: 1), .plan(Self.plan()), Self.item(album: "", track: 2)).changesSamples)
    }

    @Test("The album rule", arguments: [
        (TransitionContext(albumKey: "k", discNumber: 1, trackNumber: 1), TransitionContext(albumKey: "k", discNumber: 1, trackNumber: 2), true),
        (TransitionContext(albumKey: "k", discNumber: 1, trackNumber: 9), TransitionContext(albumKey: "k", discNumber: 2, trackNumber: 1), true),
        (TransitionContext(albumKey: "k", discNumber: 1, trackNumber: 9), TransitionContext(albumKey: "k", discNumber: 2, trackNumber: 2), false),
        (TransitionContext(albumKey: "k", discNumber: 2, trackNumber: 1), TransitionContext(albumKey: "k", discNumber: 1, trackNumber: 2), false),
        (TransitionContext(albumKey: "k", trackNumber: 4), TransitionContext(albumKey: "k", trackNumber: 4), false),
        (TransitionContext(albumKey: "k"), TransitionContext(albumKey: "k"), true),
        (TransitionContext(albumKey: "k", trackNumber: 0), TransitionContext(albumKey: "k", trackNumber: 5), true),
        (TransitionContext(albumKey: nil, trackNumber: 1), TransitionContext(albumKey: nil, trackNumber: 2), false),
        (TransitionContext(albumKey: "a", trackNumber: 1), TransitionContext(albumKey: "b", trackNumber: 2), false),
    ])
    func albumRule(_ a: TransitionContext, _ b: TransitionContext, _ consecutive: Bool) {
        #expect(a.isFollowed(onAlbumBy: b) == consecutive)
    }

    @Test("Adjacent tracks of one CUE sheet or one SACD image play gaplessly; the same file out of order crossfades")
    func cueAndSACD() {
        let one = Self.item(Self.url, region: (0, 1_000)), two = Self.item(Self.url, region: (1_000, 500)), three = Self.item(Self.url, region: (1_500, 500))
        #expect(decide(one, .plan(Self.plan()), two) == .gapless(.cueSheet))
        #expect(decide(two, .plan(Self.plan()), three) == .gapless(.cueSheet))
        #expect(decide(one, .plan(Self.plan()), three).changesSamples)
        #expect(decide(three, .plan(Self.plan()), one).changesSamples)
        // Another file with the same numbers isn't adjacent.
        #expect(decide(one, .plan(Self.plan()), Self.item(Self.other, region: (1_000, 500))).changesSamples)
        // SACD: adjacent regions of one area (converted to PCM here; as DoP it's a cut anyway).
        let s1 = Self.item(Self.url, region: (0, 2_822_400), sacd: .stereo), s2 = Self.item(Self.url, region: (2_822_400, 2_822_400), sacd: .stereo)
        #expect(decide(s1, .plan(Self.plan()), s2) == .gapless(.sacd))
        #expect(decide(s1, .plan(Self.plan(.dop, rate: 176_400)), s2, .plan(Self.plan(.dop, rate: 176_400))) == .cut(.nativeDSD))
        // The other area of the same disc isn't the next track.
        #expect(decide(s1, .plan(Self.plan()), Self.item(Self.url, region: (2_822_400, 2_822_400), sacd: .multichannel)).changesSamples)
    }

    @Test("Excluded genres play without transitions, on either side, in a list of several")
    func genres() {
        #expect(decide(Self.item(Self.url, genre: "Classical"), .plan(Self.plan()), Self.item(genre: "Rock")) == .gapless(.excludedGenre))
        #expect(decide(Self.item(Self.url, genre: "Rock"), .plan(Self.plan()), Self.item(genre: "spoken word")) == .gapless(.excludedGenre))
        #expect(decide(Self.item(Self.url, genre: "Rock; Opera"), .plan(Self.plan()), Self.item(genre: "Pop")) == .gapless(.excludedGenre))
        #expect(decide(Self.item(Self.url, genre: "Soundtrack"), .plan(Self.plan()), Self.item(), compatible: false) == .gapless(.excludedGenre))
        #expect(decide(Self.item(Self.url, genre: "Rock"), .plan(Self.plan()), Self.item(genre: "Jazz")).changesSamples)
        var s = Self.on
        s.excludedGenres = []
        #expect(decide(Self.item(Self.url, genre: "Classical"), .plan(Self.plan()), Self.item(genre: "Opera"), settings: s).changesSamples)
        s.excludedGenres = ["Jazz"]
        #expect(decide(Self.item(Self.url, genre: "Rock"), .plan(Self.plan()), Self.item(genre: "jazz"), settings: s) == .gapless(.excludedGenre))
    }

    @Test("Formats outrank the album rule; the album rule outranks genres; nothing is mixed with a song on a share")
    func order() {
        let a = Self.item(Self.url, album: "k", track: 1, genre: "Classical"), b = Self.item(album: "k", track: 2, genre: "Classical")
        #expect(decide(a, .plan(Self.plan(.dop)), b) == .cut(.nativeDSD))
        #expect(decide(a, .plan(Self.plan()), b) == .gapless(.sameAlbum))
        #expect(decide(Self.item(Self.url, genre: "Opera"), .plan(Self.plan()), Self.item(), streams: true) == .gapless(.excludedGenre))
        #expect(decide(streams: true) == .gapless(.network))
        #expect(decide(Self.item(Self.url), .plan(Self.plan()), Self.item(), .unknown, streams: true) == .gapless(.network))
        #expect(decide(lengthKnown: false) == .cut(.unknownLength))
        // Not known yet (the signal path's preview): a crossfade unless a rule says otherwise.
        #expect(decide(Self.item(Self.url), .plan(Self.plan()), Self.item(), .unknown) == .overlap(seconds: 6, curve: .equalPower))
    }

    @Test("Smart Mix and Live Set crossfade for now (their analysis comes later)", arguments: [TransitionStyle.smartMix, .liveSet])
    func otherStyles(_ style: TransitionStyle) {
        var s = Self.on
        s.style = style
        #expect(decide(settings: s) == .overlap(seconds: 6, curve: .equalPower))
    }

    @Test("Only dips and overlaps change samples")
    func changesSamples() {
        #expect(TransitionDecision.overlap(seconds: 1, curve: .linear).changesSamples)
        #expect(TransitionDecision.dip(seconds: 1, curve: .linear).changesSamples)
        for r in TransitionDecision.GaplessReason.allCases { #expect(!TransitionDecision.gapless(r).changesSamples) }
        for r in TransitionDecision.CutReason.allCases { #expect(!TransitionDecision.cut(r).changesSamples) }
    }

    @Test("Every decision has a line for the signal path")
    func summaries() {
        var all: [TransitionDecision] = [.overlap(seconds: 6, curve: .equalPower), .overlap(seconds: 2.5, curve: .sCurve), .dip(seconds: 1, curve: .linear)]
        all += TransitionDecision.GaplessReason.allCases.map { .gapless($0) } + TransitionDecision.CutReason.allCases.map { .cut($0) }
        let lines = all.map(\.summary)
        #expect(lines.allSatisfy { !$0.isEmpty })
        #expect(Set(lines).count == lines.count)
        #expect(lines[0] == "Crossfade, 6 s, equal-power")
        #expect(lines[1] == "Crossfade, 2.5 s, S-curve")
    }
}
