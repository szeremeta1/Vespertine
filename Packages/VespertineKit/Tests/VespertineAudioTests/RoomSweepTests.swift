//
// Vespertine — room measurement sweep: the faded exponential sweep, its matched inverse and impulse recovery,
// checked against filters whose response is known exactly.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Room measurement sweep")
struct RoomSweepTests {
    private static let rate = 48_000.0
    private func makeSweep(duration: Double = 3) throws -> LogSweep {
        try LogSweep(sampleRate: Self.rate, startHz: 20, endHz: 20_000, duration: duration, fadeSeconds: 0.1)
    }

    /// The system under test: `gain` × (delay of `delay` samples, one-pole low-pass `a`, and an echo of 0.3 after 20
    /// samples). Response in closed form: H(ω) = gain e^{-jωD} (1 + 0.3 e^{-j20ω}) a / (1 - (1-a) e^{-jω}).
    private struct Known {
        var delay = 48
        var gain = 0.5
        var a = 0.4
        func apply(_ x: [Double], tail: Int) -> [Double] {
            var y = [Double](repeating: 0, count: x.count + tail)
            var lp = 0.0
            var lpOut = [Double](repeating: 0, count: y.count)
            for n in 0..<y.count {
                lp = a * (n < x.count ? x[n] : 0) + (1 - a) * lp
                lpOut[n] = lp
            }
            for n in 0..<y.count {
                let d = n - delay
                y[n] = gain * ((d >= 0 ? lpOut[d] : 0) + (d >= 20 ? 0.3 * lpOut[d - 20] : 0))
            }
            return y
        }
        func response(at hz: Double) -> (db: Double, phase: Double) {
            let w = 2 * Double.pi * hz / RoomSweepTests.rate
            func e(_ k: Double) -> (Double, Double) { (cos(-w * k), sin(-w * k)) }
            func mul(_ p: (Double, Double), _ q: (Double, Double)) -> (Double, Double) { (p.0 * q.0 - p.1 * q.1, p.0 * q.1 + p.1 * q.0) }
            let echo = (1 + 0.3 * e(20).0, 0.3 * e(20).1)
            let den = (1 - (1 - a) * e(1).0, -(1 - a) * e(1).1)
            let dd = den.0 * den.0 + den.1 * den.1
            let inv = (den.0 / dd, -den.1 / dd)
            let h = mul(mul(mul((gain * a, 0), e(Double(delay))), echo), inv)
            return (20 * log10(hypot(h.0, h.1)), atan2(h.1, h.0))
        }
    }

    private func wrapped(_ x: Double) -> Double { atan2(sin(x), cos(x)) }

    private func logGrid(_ lo: Double, _ hi: Double, perOctave: Double = 6) -> [Double] {
        let n = Int(log2(hi / lo) * perOctave)
        return (0...n).map { lo * pow(2, Double($0) / perOctave) }
    }

    @Test("The sweep covers its band, ends faded, and reports the band that can be trusted")
    func sweepShape() throws {
        let sweep = try makeSweep()
        #expect(sweep.samples.count == 144_000)
        #expect(abs(sweep.samples[0]) < 1e-6 && abs(sweep.samples[sweep.samples.count - 1]) < 1e-3)
        #expect((sweep.samples.map { abs($0) }.max() ?? 0) <= 1.0 + 1e-12)
        #expect(sweep.inverse.count == sweep.samples.count)
        // Frequency reached at the end of the fade-in (plus a quarter) and at the start of the fade-out.
        #expect(abs(sweep.reliableBand.lowerBound - 1.25 * 20 * exp(0.1 / 3 * log(1000))) < 0.01)
        #expect(abs(sweep.reliableBand.upperBound - 20_000 / exp(0.1 / 3 * log(1000))) < 1)
        // The k-th harmonic arrives T·ln(k)/ln(f2/f1) before the linear impulse.
        #expect(sweep.harmonicOffset(order: 2) == Int((3 * log(2.0) / log(1000) * Self.rate).rounded()))
        #expect(sweep.harmonicOffset(order: 3) > sweep.harmonicOffset(order: 2))
    }

    @Test("Bad sweep parameters are refused")
    func badParameters() {
        #expect(throws: RoomSweepError.invalidSampleRate) { try LogSweep(sampleRate: 0, startHz: 20, endHz: 20_000, duration: 3, fadeSeconds: 0.05) }
        #expect(throws: RoomSweepError.invalidBand) { try LogSweep(sampleRate: 48_000, startHz: 20, endHz: 24_000, duration: 3, fadeSeconds: 0.05) }
        #expect(throws: RoomSweepError.invalidBand) { try LogSweep(sampleRate: 48_000, startHz: 200, endHz: 100, duration: 3, fadeSeconds: 0.05) }
        #expect(throws: RoomSweepError.invalidDuration) { try LogSweep(sampleRate: 48_000, startHz: 20, endHz: 20_000, duration: 0.01, fadeSeconds: 0.05) }
        #expect(throws: RoomSweepError.invalidFade) { try LogSweep(sampleRate: 48_000, startHz: 20, endHz: 20_000, duration: 3, fadeSeconds: 1) }
    }

    @Test("A known filter is recovered within 0.5 dB over the reliable band, and its timing within one sample")
    func recoversKnownFilter() throws {
        let sweep = try makeSweep()
        let known = Known()
        let recording = known.apply(sweep.samples, tail: 24_000)
        let ir = try sweep.recover(recording: recording)
        #expect(abs(ir.delaySamples - known.delay) <= 1)
        var worst = 0.0
        var worstPhase = 0.0
        for hz in logGrid(sweep.reliableBand.lowerBound, sweep.reliableBand.upperBound) {
            let got = ir.response(at: hz)
            let want = known.response(at: hz)
            worst = max(worst, abs(got.magnitudeDB - want.db))
            worstPhase = max(worstPhase, abs(wrapped(got.phase - want.phase)))
        }
        #expect(worst < 0.5, "worst magnitude error \(worst) dB")
        #expect(worstPhase < 0.1, "worst phase error \(worstPhase) rad")
    }

    @Test("A 5 s sweep (the length a real measurement uses) recovers the same response with the default window")
    func longSweepDefaultWindow() throws {
        let sweep = try makeSweep(duration: 5)
        let known = Known()
        let ir = try sweep.recover(recording: known.apply(sweep.samples, tail: 24_000))
        var worst = 0.0
        // The very first point of the band is still in the onset ripple at this length (about 1 dB there), so the check
        // starts a tenth above it.
        for hz in logGrid(sweep.reliableBand.lowerBound * 1.1, sweep.reliableBand.upperBound) {
            worst = max(worst, abs(ir.response(at: hz).magnitudeDB - known.response(at: hz).db))
        }
        #expect(worst < 0.5, "worst magnitude error \(worst) dB")
        // The window reaches past the impulse, however far back it starts.
        #expect(ir.linearWindow().count > 16_384)
    }

    @Test("A pure delay moves the recovered impulse by that many samples")
    func timingFollowsDelay() throws {
        let sweep = try makeSweep(duration: 2)
        for delay in [0, 1, 333, 2_400] {
            let known = Known(delay: delay, gain: 1, a: 1)
            let ir = try sweep.recover(recording: known.apply(sweep.samples, tail: 12_000))
            #expect(abs(ir.delaySamples - delay) <= 1, "delay \(delay) read back as \(ir.delaySamples)")
        }
    }

    @Test("Noise leaves the response intact where the signal is well above it, and the reported margin follows the noise level")
    func noise() throws {
        let sweep = try makeSweep()
        let known = Known()
        let clean = known.apply(sweep.samples, tail: 48_000)
        var margins: [Double] = []
        for sigma in [0.001, 0.01] {
            var rng = SeededGenerator(seed: 7)
            let noisy = clean.map { $0 + sigma * rng.gaussian() }
            let ir = try sweep.recover(recording: noisy)
            if sigma == 0.001 {
                for hz in logGrid(40, 12_000) {
                    #expect(abs(ir.response(at: hz).magnitudeDB - known.response(at: hz).db) < 0.5, "\(hz) Hz")
                }
            }
            margins.append(try #require(ir.peakToNoiseDB))
        }
        // Ten times the noise amplitude is 20 dB less margin.
        #expect(abs((margins[0] - margins[1]) - 20) < 3, "margins \(margins)")
        #expect(margins[0] > 60)
    }

    @Test("Harmonic distortion lands before the linear impulse at the predicted lags and does not touch the linear window")
    func distortion() throws {
        let sweep = try makeSweep()
        let known = Known()
        let amp = 0.5
        let x = sweep.samples.map { amp * $0 }
        let linear = known.apply(x, tail: 48_000)
        // Memoryless nonlinearity ahead of the system: 2nd and 3rd harmonics.
        let bent = known.apply(x.map { $0 + 0.05 * $0 * $0 + 0.1 * $0 * $0 * $0 }, tail: 48_000)
        let clean = try sweep.recover(recording: linear)
        let dirty = try sweep.recover(recording: bent)
        #expect(abs(dirty.delaySamples - known.delay) <= 1)
        // Fundamental gain is only changed by the cubic's 3/4·0.1·A² compression term (about +0.6 dB at this level).
        for hz in logGrid(40, 12_000) {
            let d = dirty.response(at: hz).magnitudeDB - clean.response(at: hz).magnitudeDB
            #expect(abs(d - 20 * log10(1 + 0.1 * 0.75 * amp * amp)) < 0.3, "\(hz) Hz: \(d)")
        }
        // Expected levels relative to the fundamental: A·0.05/2 for 2nd, A²·0.1/4 for 3rd.
        let h2 = try #require(dirty.harmonicLevelDB(order: 2, sweep: sweep))
        let h3 = try #require(dirty.harmonicLevelDB(order: 3, sweep: sweep))
        let want2 = 20 * log10(0.05 * amp / 2)
        let want3 = 20 * log10(0.1 * amp * amp / 4)
        #expect(abs(h2 - want2) < 4, "2nd \(h2) vs \(want2)")
        #expect(abs(h3 - want3) < 4, "3rd \(h3) vs \(want3)")
        // The undistorted recording has nothing there.
        let c2 = try #require(clean.harmonicLevelDB(order: 2, sweep: sweep))
        #expect(c2 < h2 - 25, "clean \(c2) vs distorted \(h2)")
        // The linear window starts only a short way before the peak, so those arrivals are excluded from it.
        let window = dirty.linearWindow()
        let early = dirty.samples[(dirty.origin + dirty.delaySamples - sweep.harmonicOffset(order: 2) - 16)...(dirty.origin + dirty.delaySamples - sweep.harmonicOffset(order: 2) + 16)]
        #expect((early.map { abs($0) }.max() ?? 0) > 20 * (window.prefix(32).map { abs($0) }.max() ?? 1))
    }

    @Test("A recording shorter than the sweep, or silent, is refused rather than analysed")
    func refusals() throws {
        let sweep = try makeSweep(duration: 1)
        #expect(throws: RoomSweepError.recordingTooShort) { try sweep.recover(recording: [Double](repeating: 0.1, count: 100)) }
        #expect(throws: RoomSweepError.silentRecording) { try sweep.recover(recording: [Double](repeating: 0, count: 80_000)) }
        #expect(throws: RoomSweepError.notFinite) { try sweep.recover(recording: [Double](repeating: .nan, count: 80_000)) }
    }
}

/// Deterministic noise so the tests don't flake.
struct SeededGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func gaussian() -> Double {
        let u = max(next(), 1e-300), v = next()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}
