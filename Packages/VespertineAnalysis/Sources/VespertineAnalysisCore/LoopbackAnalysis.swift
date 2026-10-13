//
// Vespertine — compares a loopback capture with the signal that was played, sample for sample, and says what went
// wrong when they differ.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lock: FFT cross-correlation of each captured channel with each channel's start sync (normalised peak above 0.9,
// the next peak below 0.2), which gives the latency, the channel mapping and the polarity. Then an exact compare of
// start sync through end sync, the end sync's drift, and a diagnosis for every difference: gain, dither, truncation,
// dropouts (silence inserted or frames lost, attributed to the recorder when it reported a discontinuity there),
// unlocked clocks. A missing signal, no lock, recorder discontinuities and unlocked clocks are test setup problems,
// not a fault in the player.
//

import Foundation

public struct LoopbackFinding: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable {
        case noSignal, noLock
        case channelsSwapped, polarityInverted, channelsDuplicated, channelMissing
        case gainChange, dither, truncation
        case dropout, framesLost, silencedRun, recorderDiscontinuity, unlockedClocks
        case samplesDiffer
    }
    public var kind: Kind
    /// Reference channel (0 = left), when it concerns one.
    public var channel: Int?
    /// Frame of the test signal where it happens.
    public var frame: Int?
    /// Frames affected, or bits for truncation.
    public var count: Int?
    /// dB for a gain change, LSB for dither.
    public var value: Double?
    public var summary: String
    /// The test setup, not the player, is at fault (or the result can't be trusted).
    public var isSetupProblem: Bool
}

public struct LoopbackChannelResult: Sendable, Hashable, Codable {
    /// Channel of the signal played (0 = left).
    public var channel: Int
    /// Captured channel it came back on; nil when it didn't.
    public var capturedChannel: Int?
    public var inverted = false
    /// Normalised correlation of the start sync, and of the next-highest peak.
    public var lock = 0.0
    public var nextPeak = 0.0
    public var latencyFrames: Int?
    public var driftFrames: Int?
    public var comparedFrames = 0
    public var mismatchedFrames = 0
    public var firstMismatch: Int?
    public var maxErrorLSB = 0.0
    public var bitExact: Bool { capturedChannel != nil && !inverted && comparedFrames > 0 && mismatchedFrames == 0 && (driftFrames ?? 0) == 0 }
}

public struct LoopbackResult: Sendable, Hashable, Codable {
    public enum Verdict: String, Sendable, Codable { case bitExact, failed, setupProblem }
    public var spec: LoopbackSignal.Spec
    public var channels: [LoopbackChannelResult]
    public var findings: [LoopbackFinding]
    public var verdict: Verdict {
        if findings.contains(where: \.isSetupProblem) { return .setupProblem }
        return findings.isEmpty && !channels.isEmpty && channels.allSatisfy(\.bitExact) ? .bitExact : .failed
    }
    /// One line: "bit-exact", or the first diagnosis.
    public var summary: String {
        switch verdict {
        case .bitExact: return "bit-exact"
        case .setupProblem: return "test setup problem: " + (findings.first(where: \.isSetupProblem)?.summary ?? "unknown")
        case .failed: return findings.first?.summary ?? "samples differ"
        }
    }
}

public enum LoopbackAnalyzer {
    public static let lockThreshold = 0.9
    public static let nextPeakLimit = 0.2

    /// `captured`: one array per input channel, Float32 as the input delivered it (±1.0 full scale).
    /// `discontinuities`: capture frames where the recorder saw its input's sample time jump.
    public static func analyze(captured: [[Float]], signal: LoopbackSignal, discontinuities: [Int] = []) -> LoopbackResult {
        let spec = signal.spec
        var findings: [LoopbackFinding] = []
        var results = (0..<spec.channels).map { LoopbackChannelResult(channel: $0) }
        let scale = signal.fullScale
        let live = captured.indices.filter { c in captured[c].contains { $0 != 0 } }
        guard !live.isEmpty else {
            findings.append(LoopbackFinding(kind: .noSignal, summary: "No signal reached the input", isSetupProblem: true))
            return LoopbackResult(spec: spec, channels: results, findings: findings)
        }

        // Lock every live captured channel onto the start sync it carries.
        let mlsLength = signal.startSync.count
        let starts = (0..<spec.channels).map { r in LoopbackSignal.mls(channel: r, syncSet: spec.syncSet, channels: spec.channels).map(Double.init) }
        struct Lock { var reference: Int; var lag: Int; var rho: Double; var next: Double }
        var locks: [Int: Lock] = [:]
        for c in live {
            let x = captured[c].map(Double.init)
            let spectrum = Correlator(signalLength: x.count, kernelLength: mlsLength)
            let X = spectrum.transform(x)
            var best: Lock?
            for r in 0..<spec.channels {
                let rho = spectrum.normalizedCorrelation(X, signal: x, kernel: starts[r])
                guard let peak = rho.indices.max(by: { abs(rho[$0]) < abs(rho[$1]) }) else { continue }
                if best == nil || abs(rho[peak]) > abs(best!.rho) {
                    var next = 0.0
                    for (i, v) in rho.enumerated() where abs(i - peak) > 8 { next = max(next, abs(v)) }
                    best = Lock(reference: r, lag: peak, rho: rho[peak], next: next)
                }
            }
            if let best, abs(best.rho) > lockThreshold, best.next < nextPeakLimit { locks[c] = best }
            if let best, results[best.reference].capturedChannel == nil {
                results[best.reference].lock = abs(best.rho)
                results[best.reference].nextPeak = best.next
            }
        }
        if locks.isEmpty {
            let r = results.map(\.lock).max() ?? 0
            findings.append(LoopbackFinding(kind: .noLock, value: r,
                                            summary: String(format: "Signal present but no lock on the sync (correlation %.2f)", r), isSetupProblem: true))
            return LoopbackResult(spec: spec, channels: results, findings: findings)
        }

        // Channel mapping.
        let byReference = Dictionary(grouping: locks.keys.sorted(), by: { locks[$0]!.reference })
        for r in 0..<spec.channels {
            guard let cs = byReference[r], let c = cs.first, let lock = locks[c] else {
                findings.append(LoopbackFinding(kind: .channelMissing, channel: r,
                                                summary: "\(name(r, of: spec.channels)) channel didn't come back on any input channel", isSetupProblem: false))
                continue
            }
            results[r].capturedChannel = c
            results[r].lock = abs(lock.rho)
            results[r].nextPeak = lock.next
            results[r].inverted = lock.rho < 0
            results[r].latencyFrames = lock.lag - signal.startSync.lowerBound
            if cs.count > 1 {
                findings.append(LoopbackFinding(kind: .channelsDuplicated, channel: r,
                                                summary: "\(name(r, of: spec.channels)) channel came back on \(cs.count) input channels (mono or duplicated)",
                                                isSetupProblem: false))
            }
            if lock.rho < 0 {
                findings.append(LoopbackFinding(kind: .polarityInverted, channel: r,
                                                summary: "\(name(r, of: spec.channels)) channel polarity inverted", isSetupProblem: false))
            }
        }
        let swapped = (0..<spec.channels).compactMap { r in results[r].capturedChannel.map { (r, $0) } }.filter { $0.0 != $0.1 }
        if !swapped.isEmpty {
            findings.append(LoopbackFinding(kind: .channelsSwapped,
                                            summary: "Channels swapped (" + swapped.map { "\(name($0.0, of: spec.channels)) → input \($0.1 + 1)" }.joined(separator: ", ") + ")",
                                            isSetupProblem: false))
        }

        // Compare each channel, sample for sample, and explain the differences.
        for r in 0..<spec.channels {
            guard let c = results[r].capturedChannel, let lock = locks[c] else { continue }
            let sign = lock.rho < 0 ? -1.0 : 1.0
            let x = captured[c].map { Double($0) * scale * sign }
            let ref = signal.samples[r].map(Double.init)
            let reversed = Array(starts[r].reversed())
            let spectrum = Correlator(signalLength: x.count, kernelLength: mlsLength)
            let endRho = spectrum.normalizedCorrelation(spectrum.transform(x), signal: x, kernel: reversed)
            let offset = lock.lag - signal.startSync.lowerBound
            if let endPeak = endRho.indices.max(by: { abs(endRho[$0]) < abs(endRho[$1]) }), abs(endRho[endPeak]) > lockThreshold {
                results[r].driftFrames = endPeak - (signal.endSync.lowerBound + offset)
            }
            var channel = results[r]
            findings += compare(x, ref, offset: offset, signal: signal, channel: r, result: &channel,
                                discontinuities: discontinuities)
            results[r] = channel
        }
        return LoopbackResult(spec: spec, channels: results, findings: findings)
    }

    static func name(_ channel: Int, of channels: Int) -> String {
        channels == 2 ? (channel == 0 ? "Left" : "Right") : "Channel \(channel + 1)"
    }

    /// Exact compare of the signal region; diagnoses what differs.
    static func compare(_ x: [Double], _ ref: [Double], offset: Int, signal: LoopbackSignal, channel r: Int,
                        result: inout LoopbackChannelResult, discontinuities: [Int]) -> [LoopbackFinding] {
        let range = signal.compared
        let label = name(r, of: signal.spec.channels)
        func captured(_ s: Int, _ shift: Int = 0) -> Double? {
            let i = s + offset + shift
            return i >= 0 && i < x.count ? x[i] : nil
        }
        var mismatches = 0
        var first: Int?
        var maxError = 0.0
        // Capture frames the recorder reported a skip at, and whether every mismatch lies next to one of them.
        let skips = discontinuities.sorted()
        var allNearSkips = !skips.isEmpty
        for s in range {
            let v = captured(s)
            if v != ref[s] {
                mismatches += 1
                if first == nil { first = s }
                maxError = max(maxError, abs((v ?? 0) - ref[s]))
                if allNearSkips, !skips.contains(where: { abs($0 - (s + offset)) <= 4096 }) { allNearSkips = false }
            }
        }
        result.comparedFrames = range.count
        result.mismatchedFrames = mismatches
        result.firstMismatch = first
        result.maxErrorLSB = maxError
        let drift = result.driftFrames
        guard let first, mismatches > 0 || (drift ?? 0) != 0 else { return [] }

        // Timing: anything that shifts the signal (inserted silence, lost frames, clock slips) is followed through it.
        if drift == nil || drift != 0 || mismatches < range.count / 100 {
            if let events = walk(x, ref, offset: offset, range: range, from: first) {
                var findings: [LoopbackFinding] = []
                let slips = events.filter { abs($0.shift) <= 2 && !$0.silence }
                if slips.count >= 3, slips.count == events.count {
                    let seconds = Double(range.count) / signal.spec.sampleRate
                    let net = events.reduce(0) { $0 + $1.shift }
                    let ppm = Double(net) / (seconds * signal.spec.sampleRate) * 1e6
                    return [LoopbackFinding(kind: .unlockedClocks, channel: r, frame: events[0].frame, count: events.count, value: ppm,
                                            summary: String(format: "\(label): %d clock slips (%.0f ppm); the output and input clocks aren't locked", events.count, ppm),
                                            isSetupProblem: true)]
                }
                for e in events {
                    let at = e.frame + offset   // capture frame
                    let recorder = discontinuities.contains { abs($0 - at) <= 4096 }
                    if recorder {
                        findings.append(LoopbackFinding(kind: .recorderDiscontinuity, channel: r, frame: e.frame, count: abs(e.shift),
                                                        summary: "\(label): the recorder skipped at frame \(e.frame) (\(abs(e.shift)) frames)", isSetupProblem: true))
                    } else if e.shift > 0 {
                        findings.append(LoopbackFinding(kind: e.silence ? .dropout : .samplesDiffer, channel: r, frame: e.frame, count: e.shift,
                                                        summary: e.silence ? "\(label): dropout at frame \(e.frame), \(e.shift) frames of silence inserted (engine underrun)"
                                                                           : "\(label): \(e.shift) extra frames at frame \(e.frame)",
                                                        isSetupProblem: false))
                    } else if e.shift < 0 {
                        findings.append(LoopbackFinding(kind: .framesLost, channel: r, frame: e.frame, count: -e.shift,
                                                        summary: "\(label): \(-e.shift) frames lost at frame \(e.frame)", isSetupProblem: false))
                    } else {
                        findings.append(LoopbackFinding(kind: .silencedRun, channel: r, frame: e.frame, count: e.length,
                                                        summary: "\(label): \(e.length) frames replaced by silence at frame \(e.frame)", isSetupProblem: false))
                    }
                }
                if !findings.isEmpty { return findings }
            }
        }

        // Wrong samples only where the recorder skipped, with no shift: the input missed an I/O cycle and recorded
        // whatever the virtual device held, so the playback path isn't what's at fault.
        if allNearSkips, (drift ?? 0) == 0 {
            return [LoopbackFinding(kind: .recorderDiscontinuity, channel: r, frame: first, count: mismatches,
                                    summary: "\(label): the recorder skipped near frame \(first); \(mismatches) samples there weren't recorded as played",
                                    isSetupProblem: true)]
        }

        // The same everywhere: truncation, dither, gain, or just different.
        let refAt = Array(ref[range])
        let capAt = range.map { captured($0) ?? 0 }
        if let kept = truncation(capAt, refAt, bits: signal.spec.bits) {
            return [LoopbackFinding(kind: .truncation, channel: r, frame: first, count: kept,
                                    summary: "\(label): truncated to \(kept) bits (the lowest \(signal.spec.bits - kept) bits lost)", isSetupProblem: false)]
        }
        let errors = zip(capAt, refAt).map { $0 - $1 }
        let worst = errors.map(abs).max() ?? 0
        if worst <= 2, capAt.allSatisfy({ $0 == $0.rounded() }) {
            let changed = errors.filter { $0 != 0 }.count
            return [LoopbackFinding(kind: .dither, channel: r, frame: first, count: changed, value: worst,
                                    summary: "\(label): dither or noise shaping, ±\(Int(worst)) LSB on \(changed) samples", isSetupProblem: false)]
        }
        let limit = signal.fullScale * 0.9
        var num = 0.0, den = 0.0
        for (c, s) in zip(capAt, refAt) where abs(s) < limit { num += c * s; den += s * s }
        if den > 0 {
            let g = num / den
            var residual = 0.0
            for (c, s) in zip(capAt, refAt) where abs(s) < limit { residual = max(residual, abs(c - g * s)) }
            if abs(g - 1) > 1e-9, g > 0, residual <= 2 {
                let db = 20 * log10(g)
                return [LoopbackFinding(kind: .gainChange, channel: r, frame: first, value: db,
                                        summary: String(format: "\(label): gain changed by %+.3f dB", db), isSetupProblem: false)]
            }
        }
        if capAt.contains(where: { $0 != $0.rounded() }) {
            return [LoopbackFinding(kind: .samplesDiffer, channel: r, frame: first, count: mismatches, value: maxError,
                                    summary: "\(label): samples aren't whole \(signal.spec.bits)-bit values (converted or resampled)", isSetupProblem: false)]
        }
        return [LoopbackFinding(kind: .samplesDiffer, channel: r, frame: first, count: mismatches, value: maxError,
                                summary: "\(label): \(mismatches) samples differ from frame \(first) (largest error \(Int(maxError)) LSB)", isSetupProblem: false)]
    }

    struct TimingEvent { var frame: Int; var shift: Int; var silence: Bool; var length: Int }

    /// Follows the capture through the signal: at each difference, finds the shift after which it matches again.
    /// nil when some difference isn't a timing event (the samples themselves are changed).
    static func walk(_ x: [Double], _ ref: [Double], offset: Int, range: Range<Int>, from start: Int) -> [TimingEvent]? {
        let window = 32
        let maxShift = 1 << 16
        var shift = 0
        var events: [TimingEvent] = []
        var s = start
        func at(_ s: Int, _ k: Int) -> Double? { let i = s + offset + k; return i >= 0 && i < x.count ? x[i] : nil }
        func matches(_ s: Int, _ k: Int) -> Bool {
            let end = min(range.upperBound, s + window)
            guard end > s else { return true }
            for j in s..<end where at(j, k) != ref[j] { return false }
            return true
        }
        while s < range.upperBound {
            if at(s, shift) == ref[s] { s += 1; continue }
            if events.count >= 64 { return nil }
            // Same timing, a run replaced (by silence or anything): resumes at the same shift.
            var resume: (frame: Int, shift: Int)?
            for skip in 1...min(maxShift, range.upperBound - s) {
                let t = s + skip
                if t < range.upperBound, matches(t, shift) { resume = (t, shift); break }
                if skip >= 8192 { break }
            }
            // Frames inserted at s (the capture matches again `d` frames later), or the next `d` frames of the
            // signal lost (the capture goes on with frame s + d).
            var inserted: Int?, lost: Int?
            for d in 1...maxShift {
                if matches(s, shift + d) { inserted = d; break }
                if s + d + window <= range.upperBound, matches(s + d, shift - d) { lost = d; break }
                if s + offset + shift + d >= x.count, s + d + window > range.upperBound { break }
            }
            if let d = inserted {
                let added = (0..<d).compactMap { at(s, shift + $0) }
                events.append(TimingEvent(frame: s, shift: d, silence: added.allSatisfy { $0 == 0 }, length: d))
                shift += d
                continue
            }
            if let d = lost {
                events.append(TimingEvent(frame: s, shift: -d, silence: false, length: d))
                shift -= d
                s += d
                continue
            }
            if let resume {
                let run = (s..<resume.frame).compactMap { at($0, shift) }
                guard run.allSatisfy({ $0 == 0 }) else { return nil }
                events.append(TimingEvent(frame: s, shift: 0, silence: true, length: resume.frame - s))
                s = resume.frame
                continue
            }
            return nil
        }
        return events
    }

    /// Bits kept when the capture is the reference with its lowest bits cut (floor, toward zero, or rounded); nil otherwise.
    static func truncation(_ cap: [Double], _ ref: [Double], bits: Int) -> Int? {
        guard cap.allSatisfy({ $0 == $0.rounded() && abs($0) < 0x1p40 }) else { return nil }
        let capInt = cap.map { Int64($0) }
        let refInt = ref.map { Int64($0) }
        for k in 1..<(bits - 1) {
            let step = Int64(1) << k
            let floorMatch = zip(capInt, refInt).allSatisfy { $0 == ($1 >> Int64(k)) << Int64(k) }
            let zeroMatch = zip(capInt, refInt).allSatisfy { $0 == ($1 / step) * step }
            let roundMatch = zip(capInt, refInt).allSatisfy { c, s in
                let rounded = ((s + step / 2) >> Int64(k)) << Int64(k)
                return c == min(rounded, (Int64(1) << (bits - 1)) - step)
            }
            if floorMatch || zeroMatch || roundMatch { return bits - k }
        }
        return nil
    }
}

/// FFT cross-correlation of a long signal with a short kernel, normalised by the signal's local energy, so a perfect
/// copy of the kernel at any level scores ±1 and noise or a different sequence scores near 0.
struct Correlator {
    let size: Int
    let signalLength: Int
    let kernelLength: Int
    private let fft: ComplexFFT

    init(signalLength: Int, kernelLength: Int) {
        var n = 1
        while n < signalLength + kernelLength { n <<= 1 }
        size = n
        self.signalLength = signalLength
        self.kernelLength = kernelLength
        fft = ComplexFFT(size: n)
    }

    func transform(_ x: [Double]) -> (re: [Double], im: [Double]) {
        var re = [Double](repeating: 0, count: size), im = [Double](repeating: 0, count: size)
        for (i, v) in x.prefix(size).enumerated() { re[i] = v }
        fft.forward(&re, &im)
        return (re, im)
    }

    /// ρ[lag] = Σ x[lag+k]·m[k] / (‖m‖·‖x[lag..<lag+L]‖), for every lag in the signal.
    func normalizedCorrelation(_ X: (re: [Double], im: [Double]), signal x: [Double], kernel m: [Double]) -> [Double] {
        var (kr, ki) = transform(m)
        // X · conj(M)
        for i in 0..<size {
            let a = X.re[i], b = X.im[i], c = kr[i], d = -ki[i]
            kr[i] = a * c - b * d
            ki[i] = a * d + b * c
        }
        fft.inverse(&kr, &ki)
        var energy = [Double](repeating: 0, count: x.count + 1)
        for (i, v) in x.enumerated() { energy[i + 1] = energy[i] + v * v }
        let peakEnergy = energy[x.count] / Double(max(1, x.count)) * 1e-9
        let norm = sqrt(m.reduce(0) { $0 + $1 * $1 })
        return (0..<x.count).map { lag in
            let e = energy[min(x.count, lag + kernelLength)] - energy[lag]
            return e > max(peakEnergy, 1e-30) ? kr[lag] / (norm * sqrt(e)) : 0
        }
    }
}

/// Iterative radix-2 complex FFT, double precision.
struct ComplexFFT {
    let size: Int
    private let cosTable: [Double]
    private let sinTable: [Double]

    init(size: Int) {
        precondition(size > 0 && size.nonzeroBitCount == 1)
        self.size = size
        cosTable = (0..<size / 2).map { cos(-2 * Double.pi * Double($0) / Double(size)) }
        sinTable = (0..<size / 2).map { sin(-2 * Double.pi * Double($0) / Double(size)) }
    }

    func forward(_ re: inout [Double], _ im: inout [Double]) { run(&re, &im, inverse: false) }

    /// Scaled by 1/N.
    func inverse(_ re: inout [Double], _ im: inout [Double]) {
        run(&re, &im, inverse: true)
        let s = 1 / Double(size)
        for i in 0..<size { re[i] *= s; im[i] *= s }
    }

    private func run(_ re: inout [Double], _ im: inout [Double], inverse: Bool) {
        let n = size
        var j = 0
        for i in 1..<max(n, 1) {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j |= bit
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= n {
            let step = n / len
            let half = len / 2
            var start = 0
            while start < n {
                for k in 0..<half {
                    let wr = cosTable[k * step]
                    let wi = inverse ? -sinTable[k * step] : sinTable[k * step]
                    let a = start + k, b = a + half
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                }
                start += len
            }
            len <<= 1
        }
    }
}
