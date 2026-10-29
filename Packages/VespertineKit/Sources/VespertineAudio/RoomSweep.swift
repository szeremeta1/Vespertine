//
// Vespertine — room measurement sweep (Farina): a faded exponential sweep, its matched inverse, and impulse recovery.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Offline and hardware-independent. Convolving a recording of the sweep with the inverse gives the system's impulse
// response at the sweep's time zero; harmonic distortion collapses into separate impulses *before* it, at
// T·ln(k)/ln(f2/f1) per harmonic order k, so the linear response can be windowed out cleanly. The sweep carries no
// level of its own (peak 1.0); the caller scales it.
//

import Accelerate
import Foundation

public enum RoomSweepError: Error, Equatable, LocalizedError {
    case invalidSampleRate
    case invalidBand
    case invalidDuration
    case invalidFade
    case recordingTooShort
    case silentRecording
    case notFinite

    public var errorDescription: String? {
        switch self {
        case .invalidSampleRate: String(localized: "The sweep needs a positive sample rate.")
        case .invalidBand: String(localized: "The sweep's start and end frequencies must rise and stay below half the sample rate.")
        case .invalidDuration: String(localized: "The sweep is too short to measure with.")
        case .invalidFade: String(localized: "The sweep's fade must be short compared with the sweep.")
        case .recordingTooShort: String(localized: "The recording is shorter than the sweep.")
        case .silentRecording: String(localized: "The recording is silent.")
        case .notFinite: String(localized: "The recording contains values that aren't numbers.")
        }
    }
}

public struct LogSweep: Equatable, Sendable {
    public let sampleRate: Double
    public let startHz: Double
    public let endHz: Double
    public let duration: Double
    public let fadeSeconds: Double
    /// The sweep, peak 1.0, with raised-cosine fades at both ends.
    public let samples: [Double]
    /// Time-reversed sweep with a 6 dB/octave falling envelope, scaled so the sweep convolved with it has unit gain
    /// at the geometric centre of the band.
    public let inverse: [Double]

    public init(sampleRate: Double, startHz: Double, endHz: Double, duration: Double, fadeSeconds: Double) throws {
        guard sampleRate.isFinite, sampleRate > 0 else { throw RoomSweepError.invalidSampleRate }
        guard startHz.isFinite, endHz.isFinite, startHz > 0, endHz > startHz, endHz < sampleRate / 2 else {
            throw RoomSweepError.invalidBand
        }
        guard duration.isFinite, duration >= 0.1, duration * sampleRate >= 16 else { throw RoomSweepError.invalidDuration }
        guard fadeSeconds.isFinite, fadeSeconds >= 0, fadeSeconds * 4 <= duration else { throw RoomSweepError.invalidFade }
        self.sampleRate = sampleRate
        self.startHz = startHz
        self.endHz = endHz
        self.duration = duration
        self.fadeSeconds = fadeSeconds

        let n = Int((duration * sampleRate).rounded())
        var s = [Double](repeating: 0, count: n)
        for i in 0..<n { s[i] = Self.value(at: Double(i) / sampleRate, startHz: startHz, endHz: endHz, duration: duration, fadeSeconds: fadeSeconds) }
        let l = Foundation.log(endHz / startHz)
        var inv = [Double](repeating: 0, count: n)
        for i in 0..<n { inv[i] = s[n - 1 - i] * exp(-Double(i) / sampleRate * l / duration) }
        // Unit gain at the band's centre: |S(fc)·I(fc)| is what the convolution does to a tone there.
        let fc = (startHz * endHz).squareRoot()
        let gain = Self.magnitude(s, at: fc, rate: sampleRate) * Self.magnitude(inv, at: fc, rate: sampleRate)
        self.samples = s
        self.inverse = inv.map { $0 / gain }
    }

    /// The sweep at any instant (seconds from its start); zero outside it. The samples are this, taken at the rate.
    public func value(at t: Double) -> Double {
        Self.value(at: t, startHz: startHz, endHz: endHz, duration: duration, fadeSeconds: fadeSeconds)
    }

    private static func value(at t: Double, startHz: Double, endHz: Double, duration: Double, fadeSeconds: Double) -> Double {
        guard t >= 0, t < duration else { return 0 }
        let l = Foundation.log(endHz / startHz)
        var g = 1.0
        if t < fadeSeconds { g = 0.5 - 0.5 * cos(Double.pi * t / fadeSeconds) }
        if duration - t < fadeSeconds { g = min(g, 0.5 - 0.5 * cos(Double.pi * (duration - t) / fadeSeconds)) }
        return g * sin(2 * Double.pi * startHz * duration / l * (exp(t / duration * l) - 1))
    }

    /// Frequencies between the end of the fade-in and the start of the fade-out; outside this the recovered response
    /// is shaped by the fades rather than the system. The low edge sits a quarter above the end of the fade-in because
    /// the sweep's onset ripples the response (about ±2 dB) for a little way above it; measured with a known filter.
    public var reliableBand: ClosedRange<Double> {
        let l = Foundation.log(endHz / startHz)
        return startHz * exp(fadeSeconds / duration * l) * 1.25...endHz / exp(fadeSeconds / duration * l)
    }

    /// Samples by which the k-th harmonic's impulse precedes the linear one.
    public func harmonicOffset(order k: Int) -> Int {
        Int((duration * Foundation.log(Double(k)) / Foundation.log(endHz / startHz) * sampleRate).rounded())
    }

    /// Deconvolve a recording of this sweep (played at the amplitude `samples` has; scale the result if it wasn't).
    public func recover(recording: [Double]) throws -> ImpulseResponse {
        guard recording.count >= samples.count else { throw RoomSweepError.recordingTooShort }
        guard recording.allSatisfy(\.isFinite) else { throw RoomSweepError.notFinite }
        guard recording.contains(where: { $0 != 0 }) else { throw RoomSweepError.silentRecording }
        return ImpulseResponse(
            samples: RoomFFT.convolve(recording, inverse), sampleRate: sampleRate, origin: inverse.count - 1,
            sweepCount: samples.count, recordingCount: recording.count, clearLead: harmonicOffset(order: 2) * 3 / 4)
    }

    private static func magnitude(_ x: [Double], at hz: Double, rate: Double) -> Double {
        let w = 2 * Double.pi * hz / rate
        var re = 0.0, im = 0.0
        for (i, v) in x.enumerated() {
            re += v * cos(w * Double(i))
            im -= v * sin(w * Double(i))
        }
        return hypot(re, im)
    }
}

/// The deconvolved recording. `samples[origin]` is the sweep's time zero: a system with delay D puts its impulse at
/// `origin + D`; distortion arrives at negative lags.
public struct ImpulseResponse: Sendable {
    public let samples: [Double]
    public let sampleRate: Double
    public let origin: Int
    let sweepCount: Int
    let recordingCount: Int
    /// How far before the peak the linear window may start without reaching the 2nd harmonic's arrival.
    let clearLead: Int

    /// Where the linear impulse is: the largest sample after the origin, in samples from the origin.
    public var delaySamples: Int {
        var best = origin, bestValue = 0.0
        for i in origin..<samples.count where abs(samples[i]) > bestValue {
            bestValue = abs(samples[i])
            best = i
        }
        return best - origin
    }

    /// The linear impulse from `preSamples` before the peak (default: as far as the 2nd harmonic allows, since the
    /// low end of a band-limited impulse rings for a long time), `length` samples long, ending in a short half-cosine
    /// taper.
    /// The default length is 16384 samples after the start point plus the lead, so a long sweep (whose lead is longer
    /// than 16384 samples) still reaches past the impulse.
    public func linearWindow(preSamples: Int? = nil, length: Int? = nil) -> [Double] {
        let pre = preSamples ?? clearLead
        return window(startLag: delaySamples - pre, length: length ?? Self.tailSamples + max(pre, 0))
    }

    /// Samples kept after the lead in the default window.
    static let tailSamples = 16_384

    func window(startLag: Int, length: Int) -> [Double] {
        let taper = max(1, length / 10)
        return (0..<length).map { i in
            let j = origin + startLag + i
            guard j >= 0, j < samples.count else { return 0 }
            let t = length - 1 - i
            return samples[j] * (t < taper ? 0.5 - 0.5 * cos(Double.pi * Double(t) / Double(taper)) : 1)
        }
    }

    /// Magnitude (dB) and phase (radians) of the linear window at one frequency, with phase referred to the sweep's
    /// time zero so the system's delay is part of it.
    public func response(at hz: Double, preSamples: Int? = nil, length: Int? = nil) -> (magnitudeDB: Double, phase: Double) {
        let pre = preSamples ?? clearLead
        let start = delaySamples - pre
        let w = 2 * Double.pi * hz / sampleRate
        var re = 0.0, im = 0.0
        for (i, v) in window(startLag: start, length: length ?? Self.tailSamples + max(pre, 0)).enumerated() {
            let lag = Double(start + i)
            re += v * cos(w * lag)
            im -= v * sin(w * lag)
        }
        return (20 * log10(max(hypot(re, im), 1e-300)), atan2(im, re))
    }

    /// Linear impulse peak over the noise floor, in dB. The floor is the RMS of the later half of the recording's
    /// tail after the sweep, where no impulse is left; nil when the tail is too short to measure it.
    public var peakToNoiseDB: Double? {
        let tail = recordingCount - sweepCount
        guard tail >= 2_000 else { return nil }
        let lo = origin + delaySamples + tail / 2, hi = origin + tail
        guard hi - lo >= 1_000, hi <= samples.count else { return nil }
        let rms = (samples[lo..<hi].reduce(0) { $0 + $1 * $1 } / Double(hi - lo)).squareRoot()
        guard rms > 0 else { return nil }
        return 20 * log10(abs(samples[origin + delaySamples]) / rms)
    }

    /// Level of the k-th harmonic's impulse relative to the linear one (dB), from the largest sample within
    /// `halfWidth` of its predicted place; nil if that place lies outside the recovered data.
    public func harmonicLevelDB(order k: Int, sweep: LogSweep, halfWidth: Int = 48) -> Double? {
        let centre = origin + delaySamples - sweep.harmonicOffset(order: k)
        guard centre - halfWidth >= 0, centre + halfWidth < samples.count else { return nil }
        let peak = samples[(centre - halfWidth)...(centre + halfWidth)].map { abs($0) }.max() ?? 0
        let linear = abs(samples[origin + delaySamples])
        guard linear > 0 else { return nil }
        return 20 * log10(max(peak, 1e-300) / linear)
    }
}

/// Power-of-two FFT convolution on Accelerate.
enum RoomFFT {
    static func convolve(_ a: [Double], _ b: [Double]) -> [Double] {
        let count = a.count + b.count - 1
        var log2n = 1
        while (1 << log2n) < count { log2n += 1 }
        let n = 1 << log2n
        var ar = a + [Double](repeating: 0, count: n - a.count), ai = [Double](repeating: 0, count: n)
        var br = b + [Double](repeating: 0, count: n - b.count), bi = [Double](repeating: 0, count: n)
        guard let setup = vDSP_create_fftsetupD(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetupD(setup) }
        transform(&ar, &ai, setup, log2n, FFTDirection(FFT_FORWARD))
        transform(&br, &bi, setup, log2n, FFTDirection(FFT_FORWARD))
        for i in 0..<n {
            let re = ar[i] * br[i] - ai[i] * bi[i]
            ai[i] = ar[i] * bi[i] + ai[i] * br[i]
            ar[i] = re
        }
        transform(&ar, &ai, setup, log2n, FFTDirection(FFT_INVERSE))
        return (0..<count).map { ar[$0] / Double(n) }
    }

    static func transform(_ re: inout [Double], _ im: inout [Double], _ setup: FFTSetupD, _ log2n: Int, _ direction: FFTDirection) {
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPDoubleSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zipD(setup, &split, 1, vDSP_Length(log2n), direction)
            }
        }
    }
}
