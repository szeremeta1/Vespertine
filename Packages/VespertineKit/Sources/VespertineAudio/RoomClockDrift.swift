//
// Vespertine — room measurement timing: the acoustic reference, and the clock mismatch between output and input.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The measurement plays a short chirp (the reference) before the sweep and again after it. Where the two arrive in
// the recording, against the spacing they were played at, is the ratio of the input clock to the output clock. The
// recording is then resampled by that ratio before the sweep is deconvolved, so every capture is on the output's time
// axis. Positions are relative to the reference's own arrival: the delay through the room and the audio chain is the
// same for the reference and the sweep, so it cancels, and the absolute latency is not recoverable from a recording.
//

import Accelerate
import Foundation

public enum TimingReferenceError: Error, Equatable, LocalizedError {
    case recordingTooShort
    case notFound
    case ambiguous
    case excessiveDrift(ppm: Double)

    public var errorDescription: String? {
        switch self {
        case .recordingTooShort: String(localized: "The recording is too short to contain the timing references.")
        case .notFound: String(localized: "The timing reference couldn't be found in the recording.")
        case .ambiguous: String(localized: "The timing reference arrived more than once at similar strength, so its position can't be trusted.")
        case .excessiveDrift(let ppm):
            String(localized: "The input and output clocks differ by \(Int(ppm.rounded())) parts per million, more than a measurement can correct.")
        }
    }
}

public struct TimingReference: Sendable {
    public let sampleRate: Double
    public let samples: [Double]
    public let lowHz: Double
    public let highHz: Double
    /// Samples into the reference at which a stretch of its time axis leaves the fitted start unmoved: the fit sees a
    /// clock-stretched copy as shifted by (ratio − 1) × this, which `ClockDriftEstimate` takes back out.
    public let stretchCentroid: Double
    private let chirp: LogSweep

    /// A 0.1 s exponential chirp with 10 ms fades: broadband, so its correlation peak is a few samples wide.
    public init(sampleRate: Double, lowHz: Double = 1_000, highHz: Double = 12_000) throws {
        let chirp = try LogSweep(sampleRate: sampleRate, startHz: lowHz, endHz: highHz, duration: 0.1, fadeSeconds: 0.01)
        self.chirp = chirp
        self.sampleRate = sampleRate
        self.lowHz = lowHz
        self.highHz = highHz
        self.samples = chirp.samples
        // Calibrate the centroid on the template itself: a copy stretched by ±0.01% (small enough that the phase fit does not wrap) and where the fit puts its start.
        var shifts: [Double] = []
        for stretch in [1.0001, 0.9999] {
            let m = chirp.samples.count
            let copy = (0..<(m + 300)).map { chirp.value(at: (Double($0) - 100) / (sampleRate * stretch)) }
            shifts.append(Self.refine(copy, nearestStart: 100, template: chirp.samples, rate: sampleRate, lowHz: lowHz, highHz: highHz) / (stretch - 1))
        }
        self.stretchCentroid = (shifts[0] + shifts[1]) / 2
    }

    /// The reference at any instant (seconds from its start); zero outside it.
    public func value(at t: Double) -> Double { chirp.value(at: t) }

    public struct Detection: Equatable, Sendable {
        /// Sample of the recording where the reference starts, to a fraction of a sample.
        public var position: Double
        /// Envelope of the normalised cross-correlation at the peak: 1 for an exact copy, near 0 for noise.
        public var score: Double
        /// The strongest other peak, as a fraction of this one.
        public var runnerUpRatio: Double
    }

    /// Weakest peak accepted as the reference, and how close another peak may come to it before the position is
    /// called ambiguous. Another peak within 2 ms is the same arrival (the chirp's own ringing), not a second one.
    public static let minimumScore = 0.3
    public static let ambiguityRatio = 0.8
    private static let sameArrivalSeconds = 0.002

    /// Find the reference starting within `range` (sample indices into `recording`).
    public func locate(in recording: [Double], range: Range<Int>) throws -> Detection {
        let m = samples.count
        let lo = max(range.lowerBound, 0), hi = min(range.upperBound, recording.count - m + 1)
        guard hi > lo else { throw TimingReferenceError.recordingTooShort }
        let segment = Array(recording[lo..<(hi + m - 1)])
        let envelope = RoomFFT.analyticCorrelation(segment, samples)
        // Normalise by the energy under the template so a loud sweep isn't mistaken for a reference, counting only the
        // reference's own band (an octave either side): a room's and a microphone's rumble sits far below it, and on the
        // first real run (UMIK-1, about -60 dBFS below 200 Hz) it alone held clearly audible tones under the minimum score.
        let inBand = RoomFFT.bandLimited(segment, rate: sampleRate, lowHz: lowHz / 2, highHz: min(highHz * 2, sampleRate / 2))
        var running = [Double](repeating: 0, count: hi - lo + m)
        for i in 0..<(hi - lo + m - 1) { running[i + 1] = running[i] + inBand[i] * inBand[i] }
        let templateEnergy = samples.reduce(0) { $0 + $1 * $1 }
        var score = [Double](repeating: 0, count: hi - lo)
        for k in 0..<(hi - lo) {
            let e = running[k + m] - running[k]
            score[k] = e > 0 ? min(envelope[k] / (e * templateEnergy).squareRoot(), 1) : 0
        }
        // Rank by the raw envelope, so a weak reflection of the reference doesn't look as good as the reference;
        // the normalised score only says whether what was found is shaped like the reference at all.
        guard let best = envelope.indices.max(by: { envelope[$0] < envelope[$1] }), envelope[best] > 0,
              score[best] >= Self.minimumScore else {
            throw TimingReferenceError.notFound
        }
        let guardBand = Int(Self.sameArrivalSeconds * sampleRate)
        var runnerUp = 0.0
        for k in 1..<max(envelope.count - 1, 1) where abs(k - best) > guardBand && envelope[k] >= envelope[k - 1] && envelope[k] >= envelope[k + 1] {
            runnerUp = max(runnerUp, envelope[k])
        }
        let ratio = runnerUp / envelope[best]
        guard ratio < Self.ambiguityRatio else { throw TimingReferenceError.ambiguous }
        let offset = Self.refine(recording, nearestStart: lo + best, template: samples, rate: sampleRate, lowHz: lowHz, highHz: highHz)
        return Detection(position: Double(lo + best) + offset, score: score[best], runnerUpRatio: ratio)
    }

    /// Fraction of a sample (within about ±1) by which the reference actually starts after `nearestStart`, from the
    /// slope of the cross-spectrum phase across the reference's band. Unlike the envelope's peak, that slope isn't
    /// pulled sideways by a nearby reflection, whose phase ripples around the true delay instead of shifting it.
    private static func refine(_ recording: [Double], nearestStart: Int, template samples: [Double], rate sampleRate: Double, lowHz: Double, highHz: Double) -> Double {
        let pad = 64, m = samples.count
        var log2n = 1
        while (1 << log2n) < m + 2 * pad { log2n += 1 }
        let n = 1 << log2n
        var xr = [Double](repeating: 0, count: n), xi = [Double](repeating: 0, count: n)
        var tr = [Double](repeating: 0, count: n), ti = [Double](repeating: 0, count: n)
        for i in 0..<(m + 2 * pad) {
            let j = nearestStart - pad + i
            if j >= 0, j < recording.count { xr[i] = recording[j] }
        }
        for i in 0..<m { tr[pad + i] = samples[i] }
        guard let setup = vDSP_create_fftsetupD(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return 0 }
        defer { vDSP_destroy_fftsetupD(setup) }
        RoomFFT.transform(&xr, &xi, setup, log2n, FFTDirection(FFT_FORWARD))
        RoomFFT.transform(&tr, &ti, setup, log2n, FFTDirection(FFT_FORWARD))
        var numerator = 0.0, denominator = 0.0
        for k in Int(lowHz / sampleRate * Double(n)).advanced(by: 1)..<Int(highHz / sampleRate * Double(n)) {
            let re = xr[k] * tr[k] + xi[k] * ti[k], im = xi[k] * tr[k] - xr[k] * ti[k]
            let omega = 2 * Double.pi * Double(k) / Double(n), weight = hypot(re, im)
            numerator += weight * omega * atan2(im, re)
            denominator += weight * omega * omega
        }
        return denominator > 0 ? -numerator / denominator : 0
    }
}

/// The input clock against the output clock, from two reference arrivals, and the resampling that removes it.
public struct ClockDriftEstimate: Equatable, Sendable {
    /// Positive when the input clock runs faster than the output clock (the recording holds more samples than were played).
    public let ppm: Double
    /// Recording samples per output sample.
    public let ratio: Double
    public let firstPosition: Double
    public let secondPosition: Double

    /// A real pair of audio clocks is within a few hundred ppm; beyond this the capture is refused.
    public static let defaultLimitPPM = 500.0

    /// `nominalSpacing` is the gap between the two references as played, in output samples. The first reference is
    /// looked for in the first half of the recording and the second in the second half.
    public static func estimate(
        recording: [Double], reference: TimingReference, nominalSpacing: Int, limitPPM: Double = defaultLimitPPM
    ) throws -> ClockDriftEstimate {
        let half = recording.count / 2
        guard nominalSpacing > 0, half > reference.samples.count else { throw TimingReferenceError.recordingTooShort }
        let first = try reference.locate(in: recording, range: 0..<half)
        let second = try reference.locate(in: recording, range: half..<recording.count)
        let ratio = (second.position - first.position) / Double(nominalSpacing)
        let ppm = (ratio - 1) * 1e6
        guard abs(ppm) <= limitPPM else { throw TimingReferenceError.excessiveDrift(ppm: ppm) }
        // Both fitted starts carry the same stretch bias, which cancels in the ratio but not in where the sweep is.
        let bias = (ratio - 1) * reference.stretchCentroid
        return ClockDriftEstimate(ppm: ppm, ratio: ratio, firstPosition: first.position - bias, secondPosition: second.position - bias)
    }

    /// Where, in the recording, something played `offset` output samples after the first reference starts.
    public func position(afterFirst offset: Int) -> Double { firstPosition + Double(offset) * ratio }

    /// `count` samples on the output's time axis starting at recording position `start` (windowed-sinc interpolation,
    /// zero beyond the recording).
    public func resampled(_ recording: [Double], from start: Double, count: Int) -> [Double] {
        let half = 24
        var out = [Double](repeating: 0, count: count)
        for n in 0..<count {
            let x = start + Double(n) * ratio
            let base = Int(x.rounded(.down))
            let frac = x - Double(base)
            if frac < 1e-9 {
                out[n] = base >= 0 && base < recording.count ? recording[base] : 0
                continue
            }
            // sin(π(frac − k)) = (−1)^k sin(π frac), so one sine serves every tap.
            let s = sin(Double.pi * frac)
            var acc = 0.0
            for k in (1 - half)...half {
                let j = base + k
                guard j >= 0, j < recording.count else { continue }
                let d = frac - Double(k)
                let u = d / Double(half)
                let window = 0.42 + 0.5 * cos(Double.pi * u) + 0.08 * cos(2 * Double.pi * u)
                acc += recording[j] * (k % 2 == 0 ? s : -s) / (Double.pi * d) * window
            }
            out[n] = acc
        }
        return out
    }
}

extension RoomFFT {
    /// `signal` with everything outside `lowHz...highHz` removed (zero-padded, so nothing wraps around).
    static func bandLimited(_ signal: [Double], rate: Double, lowHz: Double, highHz: Double) -> [Double] {
        var log2n = 1
        while (1 << log2n) < 2 * signal.count { log2n += 1 }
        let n = 1 << log2n
        var re = signal + [Double](repeating: 0, count: n - signal.count), im = [Double](repeating: 0, count: n)
        guard let setup = vDSP_create_fftsetupD(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return signal }
        defer { vDSP_destroy_fftsetupD(setup) }
        transform(&re, &im, setup, log2n, FFTDirection(FFT_FORWARD))
        for k in 0..<n {
            let hz = Double(min(k, n - k)) * rate / Double(n)
            if hz < lowHz || hz > highHz { re[k] = 0; im[k] = 0 }
        }
        transform(&re, &im, setup, log2n, FFTDirection(FFT_INVERSE))
        return (0..<signal.count).map { re[$0] / Double(n) }
    }

    /// Magnitude of the cross-correlation of `signal` with `template` against its quadrature (the envelope), indexed
    /// by the lag at which the template starts.
    static func analyticCorrelation(_ signal: [Double], _ template: [Double]) -> [Double] {
        let count = signal.count
        var log2n = 1
        while (1 << log2n) < count + template.count { log2n += 1 }
        let n = 1 << log2n
        var ar = signal + [Double](repeating: 0, count: n - signal.count), ai = [Double](repeating: 0, count: n)
        var br = template + [Double](repeating: 0, count: n - template.count), bi = [Double](repeating: 0, count: n)
        guard let setup = vDSP_create_fftsetupD(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetupD(setup) }
        transform(&ar, &ai, setup, log2n, FFTDirection(FFT_FORWARD))
        transform(&br, &bi, setup, log2n, FFTDirection(FFT_FORWARD))
        // A × conj(B), keeping only positive frequencies (doubled) so the inverse is the analytic correlation.
        var re = [Double](repeating: 0, count: n), im = [Double](repeating: 0, count: n)
        for i in 0...(n / 2) {
            let scale = (i == 0 || i == n / 2) ? 1.0 : 2.0
            re[i] = scale * (ar[i] * br[i] + ai[i] * bi[i])
            im[i] = scale * (ai[i] * br[i] - ar[i] * bi[i])
        }
        transform(&re, &im, setup, log2n, FFTDirection(FFT_INVERSE))
        return (0..<max(count - template.count + 1, 0)).map { hypot(re[$0], im[$0]) / Double(n) }
    }
}
