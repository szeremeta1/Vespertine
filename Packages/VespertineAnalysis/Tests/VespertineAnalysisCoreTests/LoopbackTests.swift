//
// Vespertine — the loopback analyzer finds every fault injected into a perfect capture, and calls a perfect one exact.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAnalysisCore

@Suite("Loopback signal and analyzer")
struct LoopbackTests {
    static let spec16 = LoopbackSignal.Spec(sampleRate: 44_100, bits: 16, payloadSeconds: 0.25)
    static let spec24 = LoopbackSignal.Spec(sampleRate: 48_000, bits: 24, payloadSeconds: 0.25)

    /// What a perfect loop records: `latency` frames of silence, the signal as Float32, more silence.
    static func capture(_ signal: LoopbackSignal, latency: Int = 1234, tail: Int = 2000) -> [[Float]] {
        (0..<signal.spec.channels).map { c in
            [Float](repeating: 0, count: latency) + signal.floatSamples(channel: c) + [Float](repeating: 0, count: tail)
        }
    }

    static func analyze(_ captured: [[Float]], _ signal: LoopbackSignal, discontinuities: [Int] = []) -> LoopbackResult {
        LoopbackAnalyzer.analyze(captured: captured, signal: signal, discontinuities: discontinuities)
    }

    // MARK: Signal

    @Test("Every sync polynomial is maximal length, and no two are the same sequence")
    func polynomials() {
        let n = (1 << LoopbackSignal.mlsDegree) - 1
        var seen = Set<[Int8]>()
        for taps in LoopbackSignal.mlsTaps {
            let m = LoopbackSignal.mls(taps: taps)
            #expect(m.count == n)
            // Maximal length: 2^(n-1) ones and 2^(n-1) - 1 minus-ones, and the LFSR returns to its start only after n steps.
            #expect(m.filter { $0 == 1 }.count == (n + 1) / 2)
            var state: UInt32 = 1, period = 0
            repeat {
                let bit = state & 1
                state >>= 1
                if bit == 1 { state ^= taps }
                period += 1
            } while state != 1 && period <= n
            #expect(period == n, "taps \(String(taps, radix: 16))")
            seen.insert(m)
        }
        #expect(seen.count == LoopbackSignal.mlsTaps.count)
    }

    @Test("The signal uses the whole range at each bit depth, and is the same every time", arguments: [16, 24, 32])
    func signalRange(bits: Int) {
        let spec = LoopbackSignal.Spec(sampleRate: 44_100, bits: bits, payloadSeconds: 0.1)
        let a = LoopbackSignal(spec), b = LoopbackSignal(spec)
        #expect(a.samples == b.samples)
        let maxV = Int64(1) << (bits - 1) - 1, minV = -(Int64(1) << (bits - 1))
        for c in 0..<2 {
            let values = a.samples[c].map(Int64.init)
            #expect(values.max() == maxV && values.min() == minV)
            #expect(values.contains(1) && values.contains(-1))
            // Start sync at ±0.5 FS.
            #expect(a.samples[c][a.startSync].allSatisfy { abs(Int64($0)) == Int64(1) << (bits - 2) })
            #expect(a.samples[c][..<a.startSync.lowerBound].allSatisfy { $0 == 0 })
            #expect(a.samples[c][a.endSync.upperBound...].allSatisfy { $0 == 0 })
        }
        #expect(a.samples[0] != a.samples[1])
        #expect(a.payload.contains(a.splitFrame))
    }

    // MARK: Exact

    @Test("A perfect loop is bit-exact, with its latency", arguments: [LoopbackTests.spec16, LoopbackTests.spec24])
    func perfect(spec: LoopbackSignal.Spec) {
        let signal = LoopbackSignal(spec)
        let result = Self.analyze(Self.capture(signal, latency: 777), signal)
        #expect(result.verdict == .bitExact, "\(result.findings.map(\.summary))")
        #expect(result.summary == "bit-exact")
        for c in result.channels {
            #expect(c.bitExact && c.latencyFrames == 777 && c.driftFrames == 0 && c.lock > 0.99 && c.nextPeak < 0.2)
            #expect(c.comparedFrames == signal.compared.count)
        }
    }

    @Test("The gapless pair: the two halves played back to back are the whole signal")
    func gaplessSplit() {
        let signal = LoopbackSignal(Self.spec16)
        let full = Self.capture(signal)
        let split = signal.splitFrame
        let joined = (0..<2).map { c in
            [Float](repeating: 0, count: 1234) + signal.floatSamples(channel: c, range: 0..<split)
                + signal.floatSamples(channel: c, range: split..<signal.frames) + [Float](repeating: 0, count: 2000)
        }
        #expect(joined == full)
        #expect(Self.analyze(joined, signal).verdict == .bitExact)
    }

    @Test("Extra silent input channels (a 16-channel loopback) don't matter")
    func extraInputs() {
        let signal = LoopbackSignal(Self.spec16)
        var captured = Self.capture(signal)
        captured += Array(repeating: [Float](repeating: 0, count: captured[0].count), count: 14)
        #expect(Self.analyze(captured, signal).verdict == .bitExact)
    }

    @Test("Two signals back to back (16-bit, then 24-bit) are each found on their own")
    func twoSignals() {
        let a = LoopbackSignal(Self.spec16)
        var spec = Self.spec16; spec.bits = 24; spec.syncSet = 1
        let b = LoopbackSignal(spec)
        let captured = (0..<2).map { c in
            [Float](repeating: 0, count: 500) + a.floatSamples(channel: c) + b.floatSamples(channel: c) + [Float](repeating: 0, count: 500)
        }
        let ra = Self.analyze(captured, a), rb = Self.analyze(captured, b)
        #expect(ra.verdict == .bitExact && rb.verdict == .bitExact)
        #expect(rb.channels[0].latencyFrames == 500 + a.frames)
    }

    // MARK: Faults

    @Test("Left and right swapped")
    func swap() {
        let signal = LoopbackSignal(Self.spec16)
        let c = Self.capture(signal)
        let result = Self.analyze([c[1], c[0]], signal)
        #expect(result.verdict == .failed)
        #expect(result.findings.map(\.kind) == [.channelsSwapped])
        #expect(result.channels[0].capturedChannel == 1 && result.channels[1].capturedChannel == 0)
    }

    @Test("Polarity inverted on one channel")
    func polarity() {
        let signal = LoopbackSignal(Self.spec24)
        var c = Self.capture(signal)
        c[1] = c[1].map { -$0 }
        let result = Self.analyze(c, signal)
        #expect(result.verdict == .failed)
        #expect(result.findings.map(\.kind) == [.polarityInverted])
        #expect(result.findings[0].channel == 1 && result.channels[1].inverted && !result.channels[0].inverted)
    }

    @Test("Mono: the left channel on both inputs")
    func mono() {
        let signal = LoopbackSignal(Self.spec16)
        let c = Self.capture(signal)
        let kinds = Set(Self.analyze([c[0], c[0]], signal).findings.map(\.kind))
        #expect(kinds.contains(.channelsDuplicated) && kinds.contains(.channelMissing))
    }

    @Test("Truncation to fewer bits", arguments: [8, 4, 1])
    func truncation(dropped: Int) {
        let signal = LoopbackSignal(Self.spec24)
        let c = (0..<2).map { ch in
            [Float](repeating: 0, count: 300) + signal.samples[ch].map { Float(Double(($0 >> Int32(dropped)) << Int32(dropped)) / signal.fullScale) }
        }
        let result = Self.analyze(c, signal)
        #expect(result.verdict == .failed)
        #expect(result.findings.count == 2 && result.findings.allSatisfy { $0.kind == .truncation && $0.count == 24 - dropped })
    }

    @Test("Dither: ±1 LSB on a third of the samples")
    func dither() {
        let signal = LoopbackSignal(Self.spec16)
        var rng = SplitMix64(seed: 9)
        let c = (0..<2).map { ch in
            [Float](repeating: 0, count: 300) + signal.samples[ch].enumerated().map { i, v -> Float in
                var w = Int64(v)
                if signal.compared.contains(i), rng.next() % 3 == 0 { w = max(-32768, min(32767, w + (rng.next() & 1 == 0 ? 1 : -1))) }
                return Float(Double(w) / signal.fullScale)
            }
        }
        let result = Self.analyze(c, signal)
        #expect(result.verdict == .failed)
        #expect(result.findings.count == 2 && result.findings.allSatisfy { $0.kind == .dither && ($0.value ?? 0) <= 2 })
    }

    @Test("A gain change", arguments: [-0.5, -6.0, -0.01])
    func gain(db: Double) {
        let signal = LoopbackSignal(Self.spec24)
        let g = Float(pow(10, db / 20))
        let c = Self.capture(signal).map { $0.map { $0 * g } }
        let result = Self.analyze(c, signal)
        #expect(result.verdict == .failed)
        #expect(result.findings.count == 2)
        for f in result.findings {
            #expect(f.kind == .gainChange)
            #expect(abs((f.value ?? 0) - db) < 0.001, "\(f.summary)")
        }
    }

    @Test("A dropout: an engine underrun inserts silence")
    func dropout() {
        let signal = LoopbackSignal(Self.spec16)
        let at = signal.payload.lowerBound + 3000
        let c = (0..<2).map { ch in
            [Float](repeating: 0, count: 1000) + signal.floatSamples(channel: ch, range: 0..<at) + [Float](repeating: 0, count: 512)
                + signal.floatSamples(channel: ch, range: at..<signal.frames)
        }
        let result = Self.analyze(c, signal)
        #expect(result.verdict == .failed)
        #expect(result.channels.allSatisfy { $0.driftFrames == 512 })
        #expect(result.findings.count == 2)
        for f in result.findings { #expect(f.kind == .dropout && f.frame == at && f.count == 512 && !f.isSetupProblem, "\(f.summary)") }
    }

    @Test("Frames lost, and the same loss where the recorder reported a discontinuity (a test setup problem)")
    func framesLost() {
        let signal = LoopbackSignal(Self.spec16)
        let at = signal.payload.lowerBound + 5000
        let c = (0..<2).map { ch in
            [Float](repeating: 0, count: 1000) + signal.floatSamples(channel: ch, range: 0..<at) + signal.floatSamples(channel: ch, range: (at + 300)..<signal.frames)
        }
        let lost = Self.analyze(c, signal)
        #expect(lost.verdict == .failed)
        #expect(lost.channels.allSatisfy { $0.driftFrames == -300 })
        #expect(lost.findings.allSatisfy { $0.kind == .framesLost && $0.count == 300 && $0.frame == at })
        let recorder = Self.analyze(c, signal, discontinuities: [1000 + at])
        #expect(recorder.verdict == .setupProblem)
        #expect(recorder.findings.allSatisfy { $0.kind == .recorderDiscontinuity && $0.isSetupProblem })
        #expect(recorder.summary.hasPrefix("test setup problem"))
    }

    @Test("A buffer of wrong samples where the recorder skipped an I/O cycle is a test setup problem, and elsewhere a failure")
    func recorderSkipInPlace() {
        let signal = LoopbackSignal(Self.spec16)
        var c = Self.capture(signal, latency: 100)
        let at = signal.payload.lowerBound + 3000
        for ch in 0..<2 { for i in (at + 100)..<(at + 100 + 1024) { c[ch][i] = -c[ch][i] * 0.5 + 0.25 } }
        let failed = Self.analyze(c, signal)
        #expect(failed.verdict == .failed)
        let skipped = Self.analyze(c, signal, discontinuities: [at + 100])
        #expect(skipped.verdict == .setupProblem)
        #expect(skipped.findings.count == 2 && skipped.findings.allSatisfy { $0.kind == .recorderDiscontinuity && $0.isSetupProblem && $0.count == 1024 })
        let elsewhere = Self.analyze(c, signal, discontinuities: [at + 100 + 50_000])
        #expect(elsewhere.verdict == .failed)
    }

    @Test("A run replaced by silence with no timing change")
    func silencedRun() {
        let signal = LoopbackSignal(Self.spec16)
        var c = Self.capture(signal, latency: 100)
        let at = signal.payload.lowerBound + 2000
        for ch in 0..<2 { for i in (at + 100)..<(at + 100 + 256) { c[ch][i] = 0 } }
        let result = Self.analyze(c, signal)
        #expect(result.verdict == .failed)
        #expect(result.findings.allSatisfy { $0.kind == .silencedRun && $0.count == 256 && $0.frame == at })
    }

    @Test("Drift from unlocked clocks: a frame repeated every so often")
    func unlockedClocks() {
        let signal = LoopbackSignal(Self.spec16)
        let c = (0..<2).map { ch -> [Float] in
            let x = signal.floatSamples(channel: ch)
            var out = [Float](repeating: 0, count: 600)
            for (i, v) in x.enumerated() {
                out.append(v)
                // Slips in the payload only: real clock drift slips rarely enough that the syncs still lock.
                if signal.payload.contains(i), (i - signal.payload.lowerBound) % 2500 == 2499 { out.append(v) }
            }
            return out + [Float](repeating: 0, count: 600)
        }
        let result = Self.analyze(c, signal)
        #expect(result.verdict == .setupProblem)
        #expect(result.findings.count == 2 && result.findings.allSatisfy { $0.kind == .unlockedClocks && ($0.count ?? 0) >= 3 })
        #expect(result.channels.allSatisfy { ($0.driftFrames ?? 0) > 0 })
    }

    @Test("Samples that aren't whole values (converted on the way)")
    func notIntegers() {
        let signal = LoopbackSignal(Self.spec16)
        var rng = SplitMix64(seed: 3)
        let c = Self.capture(signal).map { $0.map { $0 == 0 ? 0 : $0 + Float(Int64(rng.next() % 200) - 100) / 3 / 32768 } }
        let result = Self.analyze(c, signal)
        #expect(result.verdict == .failed)
        #expect(result.findings.allSatisfy { $0.kind == .samplesDiffer })
    }

    // MARK: Setup

    @Test("Nothing recorded: no signal reached the input")
    func noSignal() {
        let signal = LoopbackSignal(Self.spec16)
        let result = Self.analyze([[Float](repeating: 0, count: 50_000), [Float](repeating: 0, count: 50_000)], signal)
        #expect(result.verdict == .setupProblem)
        #expect(result.findings.map(\.kind) == [.noSignal])
        #expect(result.summary == "test setup problem: No signal reached the input")
    }

    @Test("Something else on the input: no lock")
    func noLock() {
        let signal = LoopbackSignal(Self.spec16)
        var rng = SplitMix64(seed: 4)
        let noise = (0..<2).map { _ in (0..<signal.frames).map { _ in Float(Int64(rng.next() % 20_000) - 10_000) / 32768 } }
        let result = Self.analyze(noise, signal)
        #expect(result.verdict == .setupProblem)
        #expect(result.findings.map(\.kind) == [.noLock])
    }
}
