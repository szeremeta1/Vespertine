//
// Vespertine — BS.1770-4 loudness against EBU Tech 3341's test signals, and the transition profile against songs
// made to order: silences, exponential and linear fades, cold and segue ends, click tracks at known tempos.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAnalysisCore

enum Synth {
    /// `seconds` of a sine at `dbfs` (peak), in every channel.
    static func sine(_ seconds: Double, dbfs: Double, hz: Double = 1000, rate: Double = 48_000, channels: Int = 2, phase: Int = 0) -> [Float] {
        let a = pow(10, dbfs / 20)
        let n = Int((seconds * rate).rounded())
        var out = [Float](repeating: 0, count: n * channels)
        for i in 0..<n {
            let v = Float(a * sin(2 * .pi * hz * Double(i + phase) / rate))
            for c in 0..<channels { out[i * channels + c] = v }
        }
        return out
    }

    static func silence(_ seconds: Double, rate: Double = 48_000, channels: Int = 2) -> [Float] {
        [Float](repeating: 0, count: Int((seconds * rate).rounded()) * channels)
    }

    /// Deterministic white noise at `dbfs` RMS.
    static func noise(_ seconds: Double, dbfs: Double, rate: Double = 48_000, channels: Int = 2, seed: UInt64 = 1) -> [Float] {
        var state = seed
        let a = pow(10, dbfs / 20) * 3.0.squareRoot()     // uniform in ±a has RMS a/√3
        return (0..<(Int((seconds * rate).rounded()) * channels)).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(a * (Double(state >> 11) / Double(1 << 53) * 2 - 1))
        }
    }

    /// `x` with a gain envelope (dB, from `from` to `to` over its length, straight in dB: an exponential fade).
    static func exponentialRamp(_ x: [Float], channels: Int = 2, from: Double, to: Double) -> [Float] {
        let frames = x.count / channels
        var y = x
        for f in 0..<frames {
            let db = from + (to - from) * Double(f) / Double(max(1, frames - 1))
            let g = Float(pow(10, db / 20))
            for c in 0..<channels { y[f * channels + c] *= g }
        }
        return y
    }

    static func linearRamp(_ x: [Float], channels: Int = 2, from: Double, to: Double) -> [Float] {
        let frames = x.count / channels
        var y = x
        for f in 0..<frames {
            let g = Float(from + (to - from) * Double(f) / Double(max(1, frames - 1)))
            for c in 0..<channels { y[f * channels + c] *= g }
        }
        return y
    }

    /// A click track: a 5 ms 2 kHz burst on every beat, over quiet noise.
    static func clicks(bpm: Double, seconds: Double, rate: Double = 44_100, firstBeat: Double = 0.25) -> [Float] {
        var x = noise(seconds, dbfs: -50, rate: rate, channels: 1, seed: 9)
        let period = 60 / bpm * rate
        var t = firstBeat * rate
        while Int(t) < x.count {
            let start = Int(t.rounded())
            for i in 0..<Int(0.005 * rate) where start + i < x.count {
                x[start + i] += Float(0.8 * sin(2 * .pi * 2000 * Double(i) / rate))
            }
            t += period
        }
        return x
    }

    static func profile(_ x: [Float], rate: Double = 48_000, channels: Int = 2, chunk: Int = 4096) -> TransitionProfile {
        let analyzer = TransitionAnalyzer(sampleRate: rate, channels: channels)
        x.withUnsafeBufferPointer { b in
            var f = 0
            let frames = x.count / channels
            while f < frames {
                let n = min(chunk, frames - f)
                analyzer.add(b.baseAddress! + f * channels, frames: n)
                f += n
            }
        }
        return analyzer.finish(totalFrames: Int64(x.count / channels))
    }
}

@Suite("Loudness (BS.1770-4, EBU Tech 3341)")
struct LoudnessTests {
    func integrated(_ x: [Float], rate: Double = 48_000, channels: Int = 2) -> Double? {
        var meter = LoudnessMeter(sampleRate: rate, channels: channels)
        x.withUnsafeBufferPointer { meter.add($0.baseAddress!, frames: x.count / channels) }
        return meter.integratedLoudness
    }

    @Test("Tech 3341 case 1: stereo 1 kHz at −23 dBFS reads −23.0 LUFS", arguments: [44_100.0, 48_000, 96_000, 192_000])
    func case1(rate: Double) throws {
        let l = try #require(integrated(Synth.sine(20, dbfs: -23, rate: rate), rate: rate))
        #expect(abs(l - -23) <= 0.1, "\(l)")
    }

    @Test("Tech 3341 case 2: −33 dBFS reads −33.0 LUFS")
    func case2() throws {
        let l = try #require(integrated(Synth.sine(20, dbfs: -33)))
        #expect(abs(l - -33) <= 0.1, "\(l)")
    }

    @Test("Tech 3341 case 3: −36 / −23 / −36 dBFS (10, 60, 10 s) reads −23.0 (the relative gate)")
    func case3() throws {
        let x = Synth.sine(10, dbfs: -36) + Synth.sine(60, dbfs: -23) + Synth.sine(10, dbfs: -36)
        let l = try #require(integrated(x))
        #expect(abs(l - -23) <= 0.1, "\(l)")
    }

    @Test("Tech 3341 case 4: −72 / −36 / −23 / −36 / −72 dBFS reads −23.0 (both gates)")
    func case4() throws {
        let x = Synth.sine(10, dbfs: -72) + Synth.sine(10, dbfs: -36) + Synth.sine(60, dbfs: -23) + Synth.sine(10, dbfs: -36) + Synth.sine(10, dbfs: -72)
        let l = try #require(integrated(x))
        #expect(abs(l - -23) <= 0.1, "\(l)")
    }

    @Test("Tech 3341 case 5: −26 / −20 / −26 dBFS (20, 20.1, 20 s) reads −23.0")
    func case5() throws {
        let x = Synth.sine(20, dbfs: -26) + Synth.sine(20.1, dbfs: -20) + Synth.sine(20, dbfs: -26)
        let l = try #require(integrated(x))
        #expect(abs(l - -23) <= 0.1, "\(l)")
    }

    @Test("5.1: the LFE doesn't count, the surrounds count +1.5 dB")
    func surround() throws {
        // 1 kHz at −23 dBFS in L and R only reads −23; the same in the LFE alone reads nothing.
        func layout(_ active: [Int], dbfs: Double = -23) -> [Float] {
            let mono = Synth.sine(20, dbfs: dbfs, channels: 1)
            var x = [Float](repeating: 0, count: mono.count * 6)
            for (i, v) in mono.enumerated() { for c in active { x[i * 6 + c] = v } }
            return x
        }
        let front = try #require(integrated(layout([0, 1]), channels: 6))
        #expect(abs(front - -23) <= 0.1)
        #expect(integrated(layout([3]), channels: 6) == nil)
        let surrounds = try #require(integrated(layout([4, 5]), channels: 6))
        #expect(abs(surrounds - (-23 + 10 * log10(1.41))) <= 0.1, "\(surrounds)")
    }

    @Test("Silence and anything under 400 ms have no integrated loudness")
    func nothing() {
        #expect(integrated(Synth.silence(5)) == nil)
        #expect(integrated(Synth.sine(0.3, dbfs: -10)) == nil)
    }

    @Test("Chunk sizes don't change a single step")
    func chunking() {
        let x = Synth.noise(3, dbfs: -20) + Synth.sine(2, dbfs: -12)
        func steps(_ chunk: Int) -> [Double] {
            var meter = LoudnessMeter(sampleRate: 48_000, channels: 2)
            x.withUnsafeBufferPointer { b in
                var f = 0
                while f < x.count / 2 { let n = min(chunk, x.count / 2 - f); meter.add(b.baseAddress! + f * 2, frames: n); f += n }
            }
            return meter.steps
        }
        let whole = steps(1 << 20)
        #expect(whole.count == 50)
        for chunk in [1, 333, 4096] { #expect(steps(chunk) == whole) }
    }
}

@Suite("Transition profile")
struct TransitionProfileTests {
    let rate = 48_000.0

    @Test("Silence at both ends is measured to the frame")
    func silences() throws {
        let x = Synth.silence(1.5) + Synth.noise(20, dbfs: -18) + Synth.silence(2.25)
        let p = Synth.profile(x)
        let head = try #require(p.head), tail = try #require(p.tail)
        #expect(abs(head.silence - 1.5) < 0.0002)
        #expect(abs(tail.silence - 2.25) < 0.0002)
        #expect(head.type == .silence && tail.type == .silence)
        #expect(abs(p.seconds - 23.75) < 1e-9)
        let i = try #require(p.integratedLUFS)
        #expect(abs((head.loudness ?? 0) - i) < 0.5 && abs((tail.loudness ?? 0) - i) < 0.5)
    }

    @Test("An exponential fade-out is found where it starts", arguments: [4.0, 8.0, 15.0])
    func exponentialFadeOut(seconds: Double) throws {
        let body = Synth.noise(25, dbfs: -16, seed: 2)
        let fade = Synth.exponentialRamp(Synth.noise(seconds, dbfs: -16, seed: 3), from: 0, to: -50)
        let tail = try #require(Synth.profile(body + fade + Synth.silence(0.5)).tail)
        #expect(tail.type == .fade)
        let found = try #require(tail.fade)
        #expect(abs(found - seconds) <= 0.6, "fade \(found) s, made \(seconds) s")
        #expect(tail.fadeConfidence >= 0.8)
        // The level of the body, not of the fade.
        #expect(abs((tail.loudness ?? 0) - (Synth.profile(body).integratedLUFS ?? 99)) < 0.5)
    }

    @Test("A linear (amplitude) fade-out counts as a fade too")
    func linearFadeOut() throws {
        let x = Synth.noise(25, dbfs: -16) + Synth.linearRamp(Synth.noise(6, dbfs: -16, seed: 4), from: 1, to: 0)
        let tail = try #require(Synth.profile(x).tail)
        #expect(tail.type == .fade)
        #expect(abs((tail.fade ?? 0) - 6) <= 1.5, "\(tail.fade ?? -1)")
    }

    @Test("A fade-in is found where it ends")
    func fadeIn() throws {
        let x = Synth.exponentialRamp(Synth.noise(5, dbfs: -16, seed: 5), from: -45, to: 0) + Synth.noise(25, dbfs: -16, seed: 6)
        let head = try #require(Synth.profile(x).head)
        #expect(head.type == .fade)
        #expect(abs((head.fade ?? 0) - 5) <= 0.6, "\(head.fade ?? -1)")
    }

    @Test("Steady music that stops: a cold end, not a fade; a short dip in the middle doesn't fool it")
    func coldEnd() throws {
        let x = Synth.silence(0.2) + Synth.noise(12, dbfs: -14) + Synth.noise(2, dbfs: -30) + Synth.noise(12, dbfs: -14) + Synth.silence(0.4)
        let p = Synth.profile(x)
        let head = try #require(p.head), tail = try #require(p.tail)
        #expect(tail.type == .cold && head.type == .cold)
        #expect(tail.fadeConfidence < TransitionAnalyzer.fadeConfidenceNeeded)
    }

    @Test("Loud to the last sample: a segue")
    func segue() throws {
        let p = Synth.profile(Synth.noise(20, dbfs: -14))
        #expect(p.head?.type == .segue && p.tail?.type == .segue)
    }

    @Test("All silence: both ends are silence, no loudness")
    func allSilence() {
        let p = Synth.profile(Synth.silence(4))
        #expect(p.head?.type == .silence && p.tail?.type == .silence && p.integratedLUFS == nil)
        #expect(p.head?.silence == 4)
    }

    @Test("A tail alone, analysed from part-way, matches the whole song's tail")
    func tailOnly() throws {
        let x = Synth.noise(30, dbfs: -16) + Synth.exponentialRamp(Synth.noise(8, dbfs: -16, seed: 3), from: 0, to: -50) + Synth.silence(1.2)
        let whole = Synth.profile(x)
        let start = Int64(10 * rate)
        let analyzer = TransitionAnalyzer(sampleRate: rate, channels: 2, startFrame: start)
        x.withUnsafeBufferPointer { analyzer.add($0.baseAddress! + Int(start) * 2, frames: x.count / 2 - Int(start)) }
        let tail = analyzer.finish(totalFrames: Int64(x.count / 2))
        #expect(tail.head == nil && tail.integratedLUFS == nil)
        #expect(tail.tail?.silence == whole.tail?.silence)
        #expect(tail.tail?.type == .fade)
        #expect(abs((tail.tail?.fade ?? 0) - (whole.tail?.fade ?? 99)) <= 0.2)
        // A head alone has no tail, and the two merge into one profile.
        let head = TransitionAnalyzer(sampleRate: rate, channels: 2)
        x.withUnsafeBufferPointer { head.add($0.baseAddress!, frames: Int(20 * rate)) }
        let h = head.finish(totalFrames: Int64(x.count / 2))
        #expect(h.tail == nil && h.head != nil)
        let merged = h.merged(with: tail)
        #expect(merged.head == h.head && merged.tail == tail.tail)
    }

    @Test("Chunk sizes don't change the profile")
    func chunking() {
        let x = Synth.silence(0.7) + Synth.noise(12, dbfs: -16) + Synth.exponentialRamp(Synth.noise(5, dbfs: -16, seed: 8), from: 0, to: -40)
        let whole = Synth.profile(x, chunk: 1 << 22)
        for chunk in [1, 509, 4096] { #expect(Synth.profile(x, chunk: chunk) == whole) }
    }

    @Test("The profile survives JSON")
    func codable() throws {
        let p = Synth.profile(Synth.silence(0.5) + Synth.noise(15, dbfs: -16))
        let back = try JSONDecoder().decode(TransitionProfile.self, from: JSONEncoder().encode(p))
        #expect(back == p)
    }
}

@Suite("Beat")
struct BeatTests {
    @Test("Click tracks read at their tempo (not half or double)", arguments: [90.0, 120, 128, 174])
    func clickTrack(bpm: Double) throws {
        let rate = 44_100.0
        let x = Synth.clicks(bpm: bpm, seconds: 40, rate: rate)
        let p = Synth.profile(x, rate: rate, channels: 1)
        let head = try #require(p.head?.tempo), tail = try #require(p.tail?.tempo)
        #expect(abs(head.bpm - bpm) <= 0.5, "\(head.bpm)")
        #expect(abs(tail.bpm - bpm) <= 0.5, "\(tail.bpm) \(tail.confidence)")
        #expect(head.confidence >= 0.5)
        // The beat lands on a click (within 15 ms of one).
        let phase = (head.beat - 0.25).truncatingRemainder(dividingBy: 60 / bpm)
        #expect(min(abs(phase), abs(phase - 60 / bpm)) < 0.015, "beat at \(head.beat)")
        #expect(p.tempo != nil)
    }

    @Test("Noise has no beat; under ten seconds is too short to tell")
    func noBeat() {
        let p = Synth.profile(Synth.noise(40, dbfs: -16, channels: 1), channels: 1)
        #expect(p.head?.tempo == nil && p.tail?.tempo == nil && p.tempo == nil)
        let short = Synth.profile(Synth.clicks(bpm: 120, seconds: 8), rate: 44_100, channels: 1)
        #expect(short.head?.tempo == nil)
    }
}
