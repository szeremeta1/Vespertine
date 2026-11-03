//
// Vespertine — Live Set: its settings, the beat-matched blend's placement (LiveSetPlanner, pure) and the bass swap's
// filter.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Live Set: settings")
struct LiveSetSettingsTests {
    @Test("Off by default; its choices load from older settings with their defaults, and out-of-range rates are pulled in")
    func defaults() throws {
        let d = TransitionSettings()
        #expect(!d.enabled && d.liveSetRate == 48_000 && d.beatBlends && !d.bassSwap)
        let older = try JSONDecoder().decode(TransitionSettings.self, from: Data(#"{"enabled":true,"style":"liveSet"}"#.utf8))
        #expect(older.liveSetRate == 48_000 && older.beatBlends && !older.bassSwap)
        let odd = try JSONDecoder().decode(TransitionSettings.self, from: Data(#"{"liveSetRate":44100,"bassSwap":true,"beatBlends":false}"#.utf8))
        #expect(odd.liveSetRate == 48_000 && odd.bassSwap && !odd.beatBlends)
        var s = TransitionSettings()
        s.liveSetRate = 96_000
        s.bassSwap = true
        let back = try JSONDecoder().decode(TransitionSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test("The fixed rate and \"transitions first\" apply only with the switch on in Live Set")
    func fixedRate() {
        var s = TransitionSettings()
        s.style = .liveSet
        #expect(s.fixedRate == nil && !s.avoidsUnmixableModes)
        s.enabled = true
        #expect(s.fixedRate == 48_000 && s.avoidsUnmixableModes)
        s.liveSetRate = 96_000
        #expect(s.fixedRate == 96_000)
        s.style = .smartMix
        #expect(s.fixedRate == nil && !s.avoidsUnmixableModes)
    }

    @Test("Beat blends: only in Live Set with them on, a playlist's own Live Set included")
    func beatSettings() {
        let a = PlayableItem(url: URL(fileURLWithPath: "/a.flac")), b = PlayableItem(url: URL(fileURLWithPath: "/b.flac"))
        var s = TransitionSettings()
        s.style = .liveSet
        #expect(LiveSetPlanner.beatSettings(s, a: a, b: b) == nil, "switch off")
        s.enabled = true
        #expect(LiveSetPlanner.beatSettings(s, a: a, b: b) != nil)
        s.beatBlends = false
        #expect(LiveSetPlanner.beatSettings(s, a: a, b: b) == nil)
        s.beatBlends = true
        s.style = .smartMix
        #expect(LiveSetPlanner.beatSettings(s, a: a, b: b) == nil)
        let party = PlayableItem(url: URL(fileURLWithPath: "/c.flac"), context: TransitionContext(override: .liveSet))
        #expect(LiveSetPlanner.beatSettings(s, a: a, b: party)?.style == .liveSet)
        let quiet = PlayableItem(url: URL(fileURLWithPath: "/d.flac"), context: TransitionContext(override: .off))
        s.style = .liveSet
        #expect(LiveSetPlanner.beatSettings(s, a: a, b: quiet) == nil)
    }
}

@Suite("Live Set: beat-matched blends")
struct LiveSetPlannerTests {
    typealias Tempo = TransitionProfile.Tempo

    static func tempo(_ bpm: Double, beat: Double = 0.1, downbeat: Double? = 0.1, confidence: Double = 0.8, downbeatConfidence: Double = 0.7) -> Tempo {
        Tempo(bpm: bpm, confidence: confidence, beat: beat, downbeat: downbeat, downbeatConfidence: downbeatConfidence)
    }

    @Test("Same tempo: 16 beats, from the latest downbeat that lets the blend end with the music; B from its first downbeat")
    func sameTempo() throws {
        let a = Self.tempo(120, downbeat: 0.1), b = Self.tempo(120, beat: 0.05, downbeat: 0.55)
        let x = try #require(LiveSetPlanner.align(outgoing: a, incoming: b, aMusicEnd: 200, aEarliest: 170, bLead: 0.2, bMusicSeconds: 180, bassSwap: false))
        #expect(x.beats == 16 && x.seconds == 8 && x.drift == 0)
        // Bars of 2 s from 0.1: the latest bar start ≤ 192 is 190.1.
        #expect(abs(x.outgoingStart - 190.1) < 1e-9)
        #expect(abs(x.incomingStart - 0.55) < 1e-9)
        #expect(x.outgoingStart + x.seconds <= 200)
    }

    @Test("B's first downbeat after its silence, not before it")
    func downbeatAfterLead() throws {
        let a = Self.tempo(120), b = Self.tempo(120, beat: 0.05, downbeat: 0.05)
        let x = try #require(LiveSetPlanner.align(outgoing: a, incoming: b, aMusicEnd: 200, aEarliest: 0, bLead: 1.0, bMusicSeconds: 180, bassSwap: false))
        #expect(abs(x.incomingStart - 2.05) < 1e-9, "\(x.incomingStart)")
    }

    @Test("Slightly different tempos meet in the middle: B starts earlier by half the blend's difference in period")
    func smallDifference() throws {
        let a = Self.tempo(120), b = Self.tempo(120.5, beat: 0.3, downbeat: 0.3)
        let x = try #require(LiveSetPlanner.align(outgoing: a, incoming: b, aMusicEnd: 200, aEarliest: 0, bLead: 0.2, bMusicSeconds: 180, bassSwap: false))
        let pa = 0.5, pb = 60 / 120.5
        #expect(x.beats == 16)
        #expect(abs(x.drift - 8 * (pa - pb)) < 1e-12 && x.drift <= LiveSetPlanner.maximumDrift)
        #expect(abs(x.incomingStart - (0.3 + 8 * (pb - pa))) < 1e-12)
        // Beat 8 of each lands together: A's at start + 8 pa, B's at (its downbeat − incomingStart) + 8 pb into the blend.
        #expect(abs((0.3 - x.incomingStart + 8 * pb) - 8 * pa) < 1e-12)
    }

    @Test("A difference too big for 16 beats but fine for 8: 8 beats; too big for 8: no beat-matched blend")
    func drift() throws {
        // 16 beats would drift 8 × Δp, 8 beats 4 × Δp; the limit is 20 ms.
        let a = Self.tempo(120)
        let eight = try #require(LiveSetPlanner.align(outgoing: a, incoming: Self.tempo(121), aMusicEnd: 200, aEarliest: 0, bLead: 0, bMusicSeconds: 180, bassSwap: false))
        #expect(eight.beats == 8 && eight.drift <= 0.02 && 8 * (0.5 - 60 / 121.0) > 0.02)
        #expect(LiveSetPlanner.align(outgoing: a, incoming: Self.tempo(123), aMusicEnd: 200, aEarliest: 0, bLead: 0, bMusicSeconds: 180, bassSwap: false) == nil)
    }

    @Test("Half and double time line up beat for beat", arguments: [(140.0, 70.0), (70.0, 140.0), (128.0, 64.0)])
    func halfTime(_ c: (Double, Double)) throws {
        let x = try #require(LiveSetPlanner.align(outgoing: Self.tempo(c.0), incoming: Self.tempo(c.1), aMusicEnd: 200, aEarliest: 0, bLead: 0,
                                                  bMusicSeconds: 180, bassSwap: false))
        #expect(x.drift < 1e-9 && x.beats == 16 && abs(x.seconds - 16 * 60 / c.0) < 1e-9)
    }

    @Test("Not sure enough, too far apart, or no room: no beat-matched blend")
    func gates() {
        let a = Self.tempo(120)
        func align(_ a: Tempo, _ b: Tempo, end: Double = 200, earliest: Double = 0, bMusic: Double = 180) -> SmartMix.BeatAlignment? {
            LiveSetPlanner.align(outgoing: a, incoming: b, aMusicEnd: end, aEarliest: earliest, bLead: 0, bMusicSeconds: bMusic, bassSwap: false)
        }
        #expect(align(a, Self.tempo(120, confidence: 0.39)) == nil)
        #expect(align(Self.tempo(120, confidence: 0.35), Self.tempo(120)) == nil)
        #expect(align(a, Self.tempo(100)) == nil)
        #expect(align(a, Self.tempo(90)) == nil, "3:4 isn't a match")
        // Less than 8 beats (4 s) left after what's written: none.
        #expect(align(a, Self.tempo(120), end: 200, earliest: 196.5) == nil)
        // Room for 8 beats only.
        #expect(align(a, Self.tempo(120), end: 200, earliest: 190.5)?.beats == 8)
        // B too short to take a blend of twice its length.
        #expect(align(a, Self.tempo(120), bMusic: 12) == nil || align(a, Self.tempo(120), bMusic: 12)?.beats == 8)
        #expect(align(a, Self.tempo(120), bMusic: 6) == nil)
    }

    @Test("Without a sure downbeat the blend lines up beats, not bars")
    func beatsWithoutDownbeat() throws {
        let a = Self.tempo(120, beat: 0.1, downbeat: 0.1, downbeatConfidence: 0.1), b = Self.tempo(120, beat: 0.37, downbeat: 0.87, downbeatConfidence: 0.1)
        let x = try #require(LiveSetPlanner.align(outgoing: a, incoming: b, aMusicEnd: 200, aEarliest: 0, bLead: 0.2, bMusicSeconds: 180, bassSwap: false))
        // The latest beat (not bar) ≤ 192: 191.6; B's first beat after 0.19: 0.37.
        #expect(abs(x.outgoingStart - 191.6) < 1e-9 && abs(x.incomingStart - 0.37) < 1e-9)
    }

    @Test("A song's beat is used only when its start and end agree on it")
    func steadySongsOnly() {
        let steady = TransitionProfile(seconds: 200, head: .init(silence: 0, type: .cold, tempo: Self.tempo(120)),
                                       tail: .init(silence: 0, type: .cold, tempo: Self.tempo(120.5)))
        #expect(LiveSetPlanner.outgoingBeat(steady)?.bpm == 120.5 && LiveSetPlanner.incomingBeat(steady)?.bpm == 120)
        let changing = TransitionProfile(seconds: 200, head: .init(silence: 0, type: .cold, tempo: Self.tempo(100)),
                                         tail: .init(silence: 0, type: .cold, tempo: Self.tempo(128)))
        #expect(LiveSetPlanner.outgoingBeat(changing) == nil && LiveSetPlanner.incomingBeat(changing) == nil)
        #expect(LiveSetPlanner.outgoingBeat(nil) == nil)
    }

    @Test("A beat-matched mix: the curves over the whole blend, the loudness match kept; the signal path says so")
    func mixShape() throws {
        var s = TransitionSettings()
        s.curve = .sCurve
        let beat = SmartMix.BeatAlignment(beats: 16, bpm: 128, seconds: 7.5, outgoingStart: 100, incomingStart: 0.5, drift: 0, bassSwap: true)
        let mix = LiveSetPlanner.mix(s, beat: beat, matchDB: 2.5)
        #expect(mix.kind == .beatMatched && mix.seconds == 7.5 && mix.inSeconds == 7.5 && mix.outCurve == .sCurve && mix.inCurve == .sCurve)
        #expect(mix.matchDB == 2.5 && mix.beat == beat)
        #expect(mix.summary.contains("16") && mix.summary.contains("128"))
    }
}

@Suite("Live Set: the bass swap")
struct BassSwapTests {
    /// The level (dB) of a sine at `hz` with none of a song's lows: through the swap's high-pass, after it has settled.
    static func highPassGain(_ hz: Double, rate: Double = 48_000) -> Double {
        var swap = BassSwap(channels: 1, sampleRate: rate, beats: 16)
        // At the blend's end the incoming song plays whole and the outgoing one only above the crossover: feed the sine
        // as the outgoing song alone (ga 1, gb 0).
        var peakIn = 0.0, peakOut = 0.0
        let n = Int(rate)
        for i in 0..<n {
            let x = Float(sin(2 * .pi * hz * Double(i) / rate))
            var o = x
            swap.mix(&o, nil, t: 1, ga: 1, gb: 0)
            if i > n / 2 { peakIn = max(peakIn, abs(Double(x))); peakOut = max(peakOut, abs(Double(o))) }
        }
        return 20 * log10(peakOut / peakIn)
    }

    @Test("The crossover: a fourth-order high-pass at 150 Hz (−3 dB there, flat above, 24 dB an octave below)")
    func response() {
        #expect(abs(Self.highPassGain(150) + 3.01) < 0.1, "\(Self.highPassGain(150))")
        #expect(abs(Self.highPassGain(2400)) < 0.15)   // peaks of 20 samples a cycle: within 0.11 dB of the true one
        #expect(Self.highPassGain(37.5) < -46 && Self.highPassGain(37.5) > -50, "\(Self.highPassGain(37.5))")
    }

    @Test("While a song's lows are all there it plays exactly as itself")
    func transparent() {
        var swap = BassSwap(channels: 2, sampleRate: 48_000, beats: 8)
        for i in 0..<10_000 {
            var o: [Float] = [Float(sin(Double(i) * 0.01)), Float(cos(Double(i) * 0.003))]
            let before = o
            o.withUnsafeMutableBufferPointer { swap.mix($0.baseAddress!, nil, t: 0.2, ga: 1, gb: 0) }
            #expect(o == before)
            if o != before { break }
        }
    }

    @Test("The swap: all of A's lows until half a beat before the middle, none from half a beat after, smoothly between")
    func swapCurve() {
        let swap = BassSwap(channels: 1, sampleRate: 48_000, beats: 16)
        #expect(swap.outgoingLows(at: 0) == 1 && swap.outgoingLows(at: 0.5 - 1.0 / 32 - 1e-9) == 1)
        #expect(abs(swap.outgoingLows(at: 0.5) - 0.5) < 1e-6)
        #expect(swap.outgoingLows(at: 0.5 + 1.0 / 32) == 0 && swap.outgoingLows(at: 1) == 0)
        var last: Float = 1
        for k in 0...100 { let v = swap.outgoingLows(at: Double(k) / 100); #expect(v <= last); last = v }
    }

    @Test("Before the swap A's bass plays and B's doesn't; after it, the other way round; the highs of both throughout")
    func swapsTheLows() {
        let rate = 48_000.0
        var swap = BassSwap(channels: 1, sampleRate: rate, beats: 16)
        let n = Int(8 * rate)
        // A: 60 Hz, B: 50 Hz, both with 3 kHz on top at another level; equal gains so each is heard as itself.
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / rate
            var o = Float(sin(2 * .pi * 60 * t) + 0.5 * sin(2 * .pi * 3000 * t))
            let b = Float(sin(2 * .pi * 50 * t) + 0.25 * sin(2 * .pi * 3000 * t + 1))
            withUnsafePointer(to: b) { p in swap.mix(&o, p, t: Double(i) / Double(n), ga: 1, gb: 1) }
            out[i] = o
        }
        // The level of `hz` in a second of the output (a single-bin DFT).
        func level(_ hz: Double, from: Int) -> Double {
            var re = 0.0, im = 0.0
            for i in from..<(from + Int(rate)) {
                re += Double(out[i]) * cos(2 * .pi * hz * Double(i) / rate); im += Double(out[i]) * sin(2 * .pi * hz * Double(i) / rate)
            }
            return 2 * (re * re + im * im).squareRoot() / rate
        }
        let early = Int(1 * rate), late = Int(6 * rate)
        #expect(level(60, from: early) > 0.9 && level(50, from: early) < 0.1, "\(level(60, from: early)) \(level(50, from: early))")
        #expect(level(50, from: late) > 0.9 && level(60, from: late) < 0.1, "\(level(50, from: late)) \(level(60, from: late))")
        #expect(level(3000, from: early) > 0.5 && level(3000, from: late) > 0.5)
    }
}
