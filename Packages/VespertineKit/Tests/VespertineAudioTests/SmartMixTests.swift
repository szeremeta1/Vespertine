//
// Vespertine — Smart Mix, the pure parts: the choice for every pair of song ends, the gains with their loudness match,
// the limiter, a playlist's own transitions, gaps and the "transitions first" policy in the settings.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Smart Mix planner")
struct SmartMixPlannerTests {
    typealias E = TransitionProfile.Edge
    static var smart: TransitionSettings {
        var s = TransitionSettings()
        s.enabled = true
        s.style = .smartMix
        return s
    }

    static func edge(_ type: TransitionProfile.EdgeType, fade: Double? = nil, confidence: Double = 0, loudness: Double? = -14) -> E {
        E(silence: type == .silence ? 2 : 0.1, fade: fade, fadeConfidence: confidence, loudness: loudness, edgeLoudness: loudness, type: type)
    }

    /// Every pair of end types: (A's end, B's start) → the kind (nil: gapless, a segue).
    static let table: [(TransitionProfile.EdgeType, TransitionProfile.EdgeType, SmartMix.Kind?)] = [
        (.fade, .cold, .insideFade), (.fade, .fade, .insideFade), (.fade, .silence, .insideFade), (.fade, .segue, .insideFade),
        (.segue, .segue, nil), (.segue, .cold, .coldCut), (.cold, .segue, .coldCut), (.cold, .cold, .coldCut),
        (.silence, .cold, .trimmed), (.silence, .segue, .trimmed), (.silence, .fade, .trimmed), (.silence, .silence, .trimmed),
        (.cold, .silence, .trimmed), (.segue, .silence, .trimmed), (.cold, .fade, .trimmed), (.segue, .fade, .trimmed),
    ]

    @Test("Every pair of ends gets its transition", arguments: SmartMixPlannerTests.table.indices)
    func pairs(_ i: Int) {
        let (a, b, kind) = Self.table[i]
        let tail = Self.edge(a, fade: a == .fade ? 7 : nil, confidence: a == .fade ? 0.9 : 0)
        let head = Self.edge(b, fade: b == .fade ? 3 : nil, confidence: b == .fade ? 0.9 : 0)
        let mix = SmartMixPlanner.plan(Self.smart, tail: tail, head: head)
        #expect(mix?.kind == kind, "\(a) → \(b)")
        guard let mix else { return }
        switch mix.kind {
        case .insideFade:
            #expect(mix.seconds == 7 && mix.outCurve == nil)
            // B rises over half the overlap, unless it starts quiet (its own fade-in, or silence before it).
            #expect(mix.inSeconds == (b == .fade || b == .silence ? 0 : 3.5))
        case .coldCut:
            #expect(mix.seconds == 0.5 && mix.inSeconds == 0.1 && mix.outCurve == .equalPower)
        case .trimmed:
            #expect(mix.seconds == 1 && mix.outCurve == .equalPower)
            #expect(mix.inSeconds == (b == .fade || b == .silence ? 0 : 1))
        case .crossfade:
            Issue.record("no plain crossfade expected")
        }
    }

    @Test("A fade's overlap is its length within 2…12 s", arguments: [(0.5, 2.0), (3, 3), (9.5, 9.5), (20, 12)])
    func fadeLength(_ c: (Double, Double)) {
        let mix = SmartMixPlanner.plan(Self.smart, tail: Self.edge(.fade, fade: c.0, confidence: 1), head: Self.edge(.cold))
        #expect(mix?.seconds == c.1)
        #expect(mix?.inSeconds == max(1, c.1 / 2))
    }

    @Test("Unsure (no profile, or a fade it can't be sure of): a plain crossfade at the chosen length and curve")
    func unsure() {
        var s = Self.smart
        s.crossfadeSeconds = 4.5
        s.curve = .sCurve
        let plain = SmartMix(kind: .crossfade, seconds: 4.5, outCurve: .sCurve, inSeconds: 4.5, inCurve: .sCurve, matchDB: 0)
        #expect(SmartMixPlanner.plan(s, tail: nil, head: Self.edge(.cold)) == plain)
        #expect(SmartMixPlanner.plan(s, tail: Self.edge(.cold), head: nil) == plain)
        for c in [0.3, 0.45, 0.59] {
            let mix = SmartMixPlanner.plan(s, tail: Self.edge(.cold, fade: 5, confidence: c), head: Self.edge(.cold, loudness: -20))
            #expect(mix?.kind == .crossfade && mix?.matchDB == 6, "confidence \(c)")
        }
        // Under 0.3 the fade is no fade: the ends decide.
        #expect(SmartMixPlanner.plan(s, tail: Self.edge(.cold, fade: 5, confidence: 0.2), head: Self.edge(.cold))?.kind == .coldCut)
    }

    @Test("Loudness match: A's level minus B's (ReplayGain included), within ±6 dB, to 0.1 dB")
    func match() {
        func m(_ a: Double?, _ b: Double?, gainA: Double = 0, gainB: Double = 0) -> Double? {
            SmartMixPlanner.plan(Self.smart, tail: Self.edge(.cold, loudness: a), head: Self.edge(.cold, loudness: b), gainA: gainA, gainB: gainB)?.matchDB
        }
        #expect(m(-10, -14) == 4)
        #expect(m(-14, -10) == -4)
        #expect(m(-5, -20) == 6)
        #expect(m(-25, -9) == -6)
        #expect(m(-10, -14, gainA: -3) == 1)
        #expect(m(-10, -14, gainA: -3, gainB: 2) == -1)
        #expect(m(-10.04, -14) == 4)
        #expect(m(nil, -14) == 0)
        #expect(m(-.infinity, -14) == 0)
    }

    @Test("The planner: Smart Mix measured into a mix or a segue; unmeasured, it plans the mix the engine then measures")
    func planner() {
        let a = PlayableItem(url: URL(fileURLWithPath: "/a.flac")), b = PlayableItem(url: URL(fileURLWithPath: "/b.flac"))
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: 48_000, decodedSampleRate: 48_000, physicalBitDepth: 24, channels: 2,
                              dsdConvertedToPCM: false, reason: "")
        let s = Self.smart
        if case .mix(let m) = TransitionPlanner.decide(s, from: a, format: .plan(plan), to: b, format: .plan(plan)) {
            #expect(m.kind == .crossfade)
        } else { Issue.record("expected a mix") }
        #expect(TransitionPlanner.decide(s, from: a, format: .plan(plan), to: b, format: .plan(plan),
                                         profiles: (Self.edge(.segue), Self.edge(.segue))) == .gapless(.segue))
        // Live Set plans as Smart Mix.
        var live = s
        live.style = .liveSet
        #expect(TransitionPlanner.decide(live, from: a, format: .plan(plan), to: b, format: .plan(plan),
                                         profiles: (Self.edge(.segue), Self.edge(.segue))) == .gapless(.segue))
        // A cut or a gapless rule comes first: native DSD stays a cut.
        var dop = plan
        dop.mode = .dop
        #expect(TransitionPlanner.decide(s, from: a, format: .plan(dop), to: b, format: .plan(plan),
                                         profiles: (Self.edge(.fade, fade: 6, confidence: 1), Self.edge(.cold))) == .cut(.nativeDSD))
        // Another rate is still a dip.
        #expect(TransitionPlanner.decide(s, from: a, format: .plan(plan), to: b, format: .plan(plan), compatible: false) == .dip(seconds: 1, curve: .equalPower))
    }

    @Test("Summaries name the choice")
    func summaries() {
        let kinds = SmartMix.Kind.allCases.map {
            TransitionDecision.mix(SmartMix(kind: $0, seconds: 6, outCurve: nil, inSeconds: 1, inCurve: .linear, matchDB: 0)).summary
        }
        #expect(Set(kinds).count == SmartMix.Kind.allCases.count)
        #expect(kinds.allSatisfy { $0.hasPrefix("Smart Mix") })
        #expect(TransitionDecision.gap(seconds: 2.5).summary.contains("2.5"))
        #expect(TransitionDecision.gapless(.segue).summary != TransitionDecision.gapless(.playlist).summary)
        #expect(!TransitionDecision.gap(seconds: 2).changesSamples && TransitionDecision.mix(SmartMixPlanner.plan(Self.smart, tail: nil, head: nil)!).changesSamples)
    }
}

@Suite("Smart Mix gains")
struct SmartMixGainTests {
    private let steps = (0...1000).map { Double($0) / 1000 }

    @Test("With no match, the curves: out over the whole overlap, in over its rise, then 1")
    func curves() {
        let m = SmartMix(kind: .trimmed, seconds: 1, outCurve: .equalPower, inSeconds: 0.25, inCurve: .linear, matchDB: 0)
        for t in steps {
            let g = m.gains(at: t, inFraction: 0.25)
            #expect(g.out == TransitionCurve.equalPower.gains(at: t).out)
            #expect(g.in == (t >= 0.25 ? 1 : TransitionCurve.linear.gains(at: t / 0.25).in))
        }
        // No out curve: the outgoing song at its own level; no rise: the incoming one at its own.
        let fade = SmartMix(kind: .insideFade, seconds: 8, outCurve: nil, inSeconds: 0, inCurve: .equalPower, matchDB: 0)
        #expect(steps.allSatisfy { fade.gains(at: $0, inFraction: 0) == (1, 1) })
    }

    @Test("The match: A from 0 dB down to −m, B from +m back to 0 dB; halfway each is m/2 from its own, and always m apart", arguments: [-6.0, -2.5, 3, 6])
    func match(_ db: Double) {
        let m = SmartMix(kind: .insideFade, seconds: 8, outCurve: nil, inSeconds: 0, inCurve: .equalPower, matchDB: db)
        func dB(_ x: Double) -> Double { 20 * log10(x) }
        #expect(abs(dB(m.gains(at: 0, inFraction: 0).out)) < 1e-12)
        #expect(abs(dB(m.gains(at: 1, inFraction: 0).in)) < 1e-12)
        #expect(abs(dB(m.gains(at: 0, inFraction: 0).in) - db) < 1e-9)
        #expect(abs(dB(m.gains(at: 1, inFraction: 0).out) + db) < 1e-9)
        let mid = m.gains(at: 0.5, inFraction: 0)
        #expect(abs(dB(mid.out) + db / 2) < 1e-9 && abs(dB(mid.in) - db / 2) < 1e-9)
        // B's gain over A's stays `db` throughout: with `db` A's level less B's, both sound at one level all through.
        for t in steps { #expect(abs(dB(m.gains(at: t, inFraction: 0).in) - dB(m.gains(at: t, inFraction: 0).out) - db) < 1e-9) }
    }
}

@Suite("Overlap limiter")
struct OverlapLimiterTests {
    static func run(_ x: [Float], channels: Int = 2, rate: Double = 48_000, chunk: Int = 4096) -> (out: [Float], limiter: OverlapLimiter) {
        let limiter = OverlapLimiter(channels: channels, sampleRate: rate)
        var out: [Float] = []
        x.withUnsafeBufferPointer { b in
            var f = 0
            let frames = x.count / channels
            while f < frames {
                let n = min(chunk, frames - f)
                limiter.process(b.baseAddress! + f * channels, frames: n) { out += UnsafeBufferPointer(start: $0, count: $1 * channels) }
                f += n
            }
        }
        limiter.flush { out += UnsafeBufferPointer(start: $0, count: $1 * channels) }
        return (out, limiter)
    }

    static func noise(_ frames: Int, amplitude: Float, seed: UInt64 = 3) -> [Float] {
        var state = seed
        return (0..<(frames * 2)).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return amplitude * (Float(state >> 40) / Float(1 << 24) * 2 - 1)
        }
    }

    @Test("Under the ceiling: every frame comes out as it went in, bit for bit, none lost")
    func transparent() {
        let x = Self.noise(50_000, amplitude: OverlapLimiter.ceiling)
        let (out, limiter) = Self.run(x)
        #expect(out.map(\.bitPattern) == x.map(\.bitPattern))
        #expect(limiter.lowestGain == 1)
    }

    @Test("Over it: nothing comes out above the ceiling, the gain moves smoothly, and comes back", arguments: [1, 333, 4096])
    func limits(chunk: Int) {
        var x = Self.noise(48_000, amplitude: 0.5)
        // A burst at 2× full scale in the middle, a single-sample spike later.
        for f in 20_000..<20_480 { for c in 0..<2 { x[f * 2 + c] = 2 * sin(Float(f) * 0.05) } }
        x[40_000 * 2] = 1.7
        let (out, limiter) = Self.run(x, chunk: chunk)
        #expect(out.count == x.count)
        #expect(out.map(abs).max()! <= OverlapLimiter.ceiling)
        #expect(limiter.lowestGain < 0.5)
        // The gain (out/in where the input isn't tiny) never jumps by more than one lookahead's step.
        var last: Float = 1, biggest: Float = 0
        for f in 0..<48_000 where abs(x[f * 2]) > 0.05 {
            let g = out[f * 2] / x[f * 2]
            biggest = max(biggest, abs(g - last))
            last = g
        }
        #expect(biggest < 0.25, "\(biggest)")
        // Well after the burst and the spike (release 50 ms), frames are untouched again.
        #expect(Array(out[(46_000 * 2)...]).map(\.bitPattern) == Array(x[(46_000 * 2)...]).map(\.bitPattern))
        #expect(Array(out[..<(19_000 * 2)]).map(\.bitPattern) == Array(x[..<(19_000 * 2)]).map(\.bitPattern))
        // The same input in any chunking gives the same bytes.
        #expect(Self.run(x, chunk: 1).out.map(\.bitPattern) == out.map(\.bitPattern))
    }
}

@Suite("Smart Mix settings")
struct SmartMixSettingsTests {
    @Test("A playlist's own transitions survive the library's text, and apply only while the switch is on")
    func override() {
        let all: [TransitionOverride] = [.off, .crossfade(seconds: 4), .crossfade(seconds: 0.5), .crossfade(seconds: 7.5), .smartMix, .liveSet]
        for o in all {
            let back = TransitionOverride(storedValue: o.storedValue)
            if case .crossfade(let s) = o { #expect(back == .crossfade(seconds: TransitionSettings.crossfadeLength(s))) } else { #expect(back == o) }
        }
        #expect(TransitionOverride.crossfade(seconds: 7.5).storedValue == "crossfade:7.5")
        #expect(TransitionOverride.crossfade(seconds: 6).storedValue == "crossfade:6")
        for bad in [nil, "", "crossfade:", "crossfade:x", "crossfade:nan", "smart", "Off"] { #expect(TransitionOverride(storedValue: bad) == nil, "\(bad ?? "nil")") }
        var on = TransitionSettings()
        on.enabled = true
        #expect(TransitionOverride.off.applied(to: on) == nil)
        #expect(TransitionOverride.smartMix.applied(to: on)?.style == .smartMix)
        #expect(TransitionOverride.crossfade(seconds: 3).applied(to: on)?.crossfadeSeconds == 3)
        // Off is off: the playlist's choice changes nothing.
        #expect(TransitionOverride.smartMix.applied(to: TransitionSettings()) == TransitionSettings())
        #expect(TransitionOverride.off.applied(to: TransitionSettings()) == TransitionSettings())
    }

    @Test("Gap, policy and Live Set's skip: stored, read back, pulled into range")
    func settings() throws {
        var s = TransitionSettings()
        #expect(s.gapSeconds == 0 && s.policy == .bitPerfectFirst && !s.avoidsUnmixableModes)
        s.enabled = true
        s.gapSeconds = 3.3
        s.policy = .transitionsFirst
        let back = try JSONDecoder().decode(TransitionSettings.self, from: JSONEncoder().encode(s))
        #expect(back.gapSeconds == 3.5 && back.policy == .transitionsFirst && back.avoidsUnmixableModes)
        for (v, want) in [(-1.0, 0.0), (0.2, 0.0), (0.3, 0.5), (11, 10), (Double.nan, 0)] { #expect(TransitionSettings.gapLength(v) == want) }
        let old = try JSONDecoder().decode(TransitionSettings.self, from: Data(#"{"enabled":true,"policy":"nonsense","gapSeconds":"x"}"#.utf8))
        #expect(old.policy == .bitPerfectFirst && old.gapSeconds == 0)
        // Off, "transitions first" changes nothing.
        s.enabled = false
        #expect(!s.avoidsUnmixableModes)
        // Live Set always blends a skip.
        var live = TransitionSettings()
        live.style = .liveSet
        live.skip = .instant
        #expect(live.effectiveSkip == .crossfade && live.isSmart)
        live.style = .crossfade
        #expect(live.effectiveSkip == .instant && !live.isSmart)
    }
}
