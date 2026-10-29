//
// Vespertine — room measurement timing: finding the acoustic reference in a recording, estimating the clock
// mismatch between the output and the microphone input, and correcting for it before the sweep is deconvolved.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Room measurement timing reference and clock drift")
struct RoomClockDriftTests {
    private static let rate = 48_000.0
    // Playback layout, in seconds from the start of playback: reference, sweep, reference.
    private static let firstRef = 0.2, sweepAt = 1.0, secondRef = 5.0, captureLength = 5.6
    // The system: gain, a delay that isn't a whole number of samples, and one echo.
    private static let gain = 0.5, delay = 0.0123, echoDelay = 20.0 / 48_000, echoGain = 0.3

    private func makeSweep() throws -> LogSweep {
        try LogSweep(sampleRate: Self.rate, startHz: 20, endHz: 20_000, duration: 3, fadeSeconds: 0.1)
    }
    private func makeReference() throws -> TimingReference { try TimingReference(sampleRate: Self.rate) }

    /// What the speaker plays at time t (seconds from the start of playback).
    private func played(_ t: Double, sweep: LogSweep, ref: TimingReference) -> Double {
        ref.value(at: t - Self.firstRef) + sweep.value(at: t - Self.sweepAt) + ref.value(at: t - Self.secondRef)
    }

    /// The recording of that playback through the system when the input clock runs `ppm` parts per million fast
    /// relative to the output clock: sample n is taken at true time n / (rate · (1 + ppm·1e-6)).
    private func capture(ppm: Double, sweep: LogSweep, ref: TimingReference, noise: Double = 0, extra: ((Double) -> Double)? = nil) -> [Double] {
        let ratio = 1 + ppm * 1e-6
        var rng = SeededGenerator(seed: 11)
        return (0..<Int((Self.captureLength * Self.rate * ratio).rounded())).map { n in
            let t = Double(n) / (Self.rate * ratio) - Self.delay
            let direct = played(t, sweep: sweep, ref: ref) + Self.echoGain * played(t - Self.echoDelay, sweep: sweep, ref: ref)
            return Self.gain * direct + (extra?(t + Self.delay) ?? 0) + (noise > 0 ? noise * rng.gaussian() : 0)
        }
    }

    /// Truth for the sweep after alignment to the reference: the system's gain and echo, delay taken out because the
    /// reference arrives through the same delay.
    private func truth(at hz: Double) -> (db: Double, phase: Double) {
        let w = 2 * Double.pi * hz
        let re = 1 + Self.echoGain * cos(-w * Self.echoDelay), im = Self.echoGain * sin(-w * Self.echoDelay)
        return (20 * log10(Self.gain * hypot(re, im)), atan2(im, re))
    }

    private var spacing: Int { Int(((Self.secondRef - Self.firstRef) * Self.rate).rounded()) }
    private var sweepOffset: Int { Int(((Self.sweepAt - Self.firstRef) * Self.rate).rounded()) }

    private func wrapped(_ x: Double) -> Double { atan2(sin(x), cos(x)) }

    @Test("The reference is a short chirp with a sharp, unmistakable correlation")
    func referenceShape() throws {
        let ref = try makeReference()
        #expect(ref.samples.count == 4_800)
        #expect(ref.value(at: -0.01) == 0 && ref.value(at: 0.2) == 0)
        #expect(ref.samples.contains { abs($0) > 0.9 })
        #expect(throws: RoomSweepError.invalidBand) { try TimingReference(sampleRate: 48_000, lowHz: 1_000, highHz: 30_000) }
    }

    @Test("A reference at a fractional position is located to a tenth of a sample, in noise")
    func locatesFractionalPosition() throws {
        let ref = try makeReference()
        for offset in [0.0, 0.25, 0.5, 0.8] {
            let start = 10_000 + offset
            var rng = SeededGenerator(seed: 3)
            let recording = (0..<40_000).map { n in 0.4 * ref.value(at: (Double(n) - start) / Self.rate) + 0.01 * rng.gaussian() }
            let found = try ref.locate(in: recording, range: 0..<40_000)
            #expect(abs(found.position - start) < 0.1, "offset \(offset): found \(found.position)")
            #expect(found.score > 0.8)
        }
    }

    @Test("Clock drift of -100, 0 and +100 ppm is estimated to within 1 ppm and corrected so the response matches the truth")
    func driftRecovery() throws {
        let sweep = try makeSweep(), ref = try makeReference()
        for ppm in [-100.0, 0, 100] {
            let recording = capture(ppm: ppm, sweep: sweep, ref: ref, noise: 0.0005)
            let est = try ClockDriftEstimate.estimate(recording: recording, reference: ref, nominalSpacing: spacing)
            #expect(abs(est.ppm - ppm) < 1, "injected \(ppm), estimated \(est.ppm)")
            let start = est.position(afterFirst: sweepOffset)
            let aligned = est.resampled(recording, from: start, count: sweep.samples.count + 24_000)
            let ir = try sweep.recover(recording: aligned)
            #expect(abs(ir.delaySamples) <= 1, "delay \(ir.delaySamples) at \(ppm) ppm")
            var worstDB = 0.0, worstPhase = 0.0
            var hz = sweep.reliableBand.lowerBound
            while hz <= sweep.reliableBand.upperBound {
                let got = ir.response(at: hz), want = truth(at: hz)
                worstDB = max(worstDB, abs(got.magnitudeDB - want.db))
                worstPhase = max(worstPhase, abs(wrapped(got.phase - want.phase)))
                hz *= 2.0.squareRoot().squareRoot()
            }
            #expect(worstDB < 0.5, "\(ppm) ppm: magnitude error \(worstDB) dB")
            #expect(worstPhase < 0.1, "\(ppm) ppm: phase error \(worstPhase) rad")
        }
    }

    @Test("Without the correction the same 100 ppm of drift smears the phase by whole cycles, so the correction is doing the work")
    func uncorrectedIsWorse() throws {
        let sweep = try makeSweep(), ref = try makeReference()
        let recording = capture(ppm: 100, sweep: sweep, ref: ref)
        let start = Int((Self.sweepAt * Self.rate).rounded()) + Int((Self.delay * Self.rate).rounded())
        let ir = try sweep.recover(recording: Array(recording[start..<(start + sweep.samples.count + 24_000)]))
        // The delay is left in on purpose here (no reference to take it out), so compare to the same truth shifted by it.
        let errors = stride(from: 4_000.0, through: 15_000, by: 500).map { hz -> Double in
            let want = truth(at: hz).phase - 2 * Double.pi * hz * Self.delay
            return abs(wrapped(ir.response(at: hz).phase - want))
        }
        #expect((errors.max() ?? 0) > 1, "uncorrected worst \(errors.max() ?? 0) rad")
    }

    @Test("Two equal copies of the reference in one half make the position ambiguous, and it fails rather than guessing")
    func ambiguousReference() throws {
        let sweep = try makeSweep(), ref = try makeReference()
        let twin = capture(ppm: 0, sweep: sweep, ref: ref) { t in 0.5 * ref.value(at: t - 0.2 - 0.35) * 1 }
        // Same level as the real one: the system gain (0.5) applied to the twin's 1.0 amplitude is 0.5 as well.
        #expect(throws: TimingReferenceError.ambiguous) {
            try ClockDriftEstimate.estimate(recording: twin, reference: ref, nominalSpacing: spacing)
        }
        // A clearly weaker copy (a reflection) is not ambiguous and does not move the estimate.
        let reflection = capture(ppm: 50, sweep: sweep, ref: ref) { t in 0.15 * ref.value(at: t - 0.2 - 0.35) }
        let est = try ClockDriftEstimate.estimate(recording: reflection, reference: ref, nominalSpacing: spacing)
        #expect(abs(est.ppm - 50) < 1)
    }

    @Test("A missing reference, a too-short recording and implausible drift are refused with their own reasons")
    func refusals() throws {
        let sweep = try makeSweep(), ref = try makeReference()
        var rng = SeededGenerator(seed: 5)
        let hiss = (0..<Int(Self.captureLength * Self.rate)).map { _ in 0.01 * rng.gaussian() }
        #expect(throws: TimingReferenceError.notFound) {
            try ClockDriftEstimate.estimate(recording: hiss, reference: ref, nominalSpacing: spacing)
        }
        #expect(throws: TimingReferenceError.recordingTooShort) {
            try ClockDriftEstimate.estimate(recording: Array(hiss.prefix(3_000)), reference: ref, nominalSpacing: spacing)
        }
        // Only the first reference present: the second half has nothing to find.
        let first = capture(ppm: 0, sweep: sweep, ref: ref)
        let cut = first.enumerated().map { $0.offset > Int(4.5 * Self.rate) ? 0.0 : $0.element }
        #expect(throws: TimingReferenceError.notFound) {
            try ClockDriftEstimate.estimate(recording: cut, reference: ref, nominalSpacing: spacing)
        }
        // 1000 ppm is far beyond any real pair of crystals.
        let fast = capture(ppm: 1_000, sweep: sweep, ref: ref)
        do {
            _ = try ClockDriftEstimate.estimate(recording: fast, reference: ref, nominalSpacing: spacing)
            Issue.record("1000 ppm of drift was accepted")
        } catch TimingReferenceError.excessiveDrift(let ppm) {
            #expect(abs(ppm - 1_000) < 2)
        }
    }
}
