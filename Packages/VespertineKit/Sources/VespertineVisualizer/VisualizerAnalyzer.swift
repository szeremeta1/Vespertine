//
// Vespertine — the visualizer's analysis: spectrum, levels and beats from the newest samples, once per frame.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Accelerate
import Foundation

/// What the visualizer draws in one frame. Display values are 0…1.
public struct VisualizerFrame: Sendable, Equatable {
    /// Log-spaced from `lowHz` to `highHz`, lightly smoothed: the spectrogram's column and the circular spectra.
    public var fine: [Float]
    /// The bar spectrum, smoothed (fast rise, slower fall).
    public var bands: [Float]
    /// Each band's peak, held and then falling.
    public var peaks: [Float]
    /// The newest samples (mono), for waveforms: -1…1.
    public var waveform: [Float]
    /// dBFS of the newest ~45 ms, left and right (floor -100).
    public var rmsDB: SIMD2<Float>
    public var peakDB: SIMD2<Float>
    /// Energy in the lows (≈30–150 Hz), mids (150 Hz–2 kHz) and highs (2–16 kHz), each relative to its own recent
    /// loudest, so quiet and loud masters move the picture alike.
    public var bass: Float
    public var mid: Float
    public var treble: Float
    /// A beat started in this frame (an onset in the lows well above their recent average).
    public var beat: Bool
    /// 1 at a beat, falling to 0 over about a quarter second: drives pulses.
    public var beatPulse: Float
    /// Beats per minute from the recent beats, when they're regular enough to say.
    public var tempo: Double?
    /// Anything above about -80 dBFS in the last half second.
    public var hasSignal: Bool
    /// The analysis clock, in seconds.
    public var time: Double
    /// The newest samples, left and right (-1…1), oldest first: `stereoCount` of them, about 43 ms (every sample at
    /// 44.1 and 48 kHz, every other one at 88.2 and 96, every fourth above). For the scope.
    public var stereo: [SIMD2<Float>] = []
    /// The time between `stereo`'s samples, in seconds.
    public var stereoInterval: Double = 1.0 / 48_000
    /// How alike left and right are, -1…1: +1 mono, 0 unrelated, -1 out of phase (lightly smoothed).
    public var correlation: Float = 0
    /// The VU needles, as a fraction of their travel (see `VisualizerMeters`).
    public var vu = SIMD2<Float>(0, 0)
    /// The peak programme meters, in dB against the reference (0 is PPM 4).
    public var ppm = SIMD2<Float>(-40, -40)
    /// The level the meters read as 0 VU and PPM 4 (dBFS, sine RMS), after sensitivity.
    public var meterReferenceDB: Float = -18

    public static let stereoCount = 2048

    public static func silent(bands: Int, fine: Int, waveform: Int = VisualizerAnalyzer.waveformCount) -> VisualizerFrame {
        VisualizerFrame(fine: .init(repeating: 0, count: fine), bands: .init(repeating: 0, count: bands),
                        peaks: .init(repeating: 0, count: bands), waveform: .init(repeating: 0, count: waveform),
                        rmsDB: .init(-100, -100), peakDB: .init(-100, -100), bass: 0, mid: 0, treble: 0, beat: false,
                        beatPulse: 0, tempo: nil, hasSignal: false, time: 0,
                        stereo: .init(repeating: .zero, count: stereoCount))
    }
}

/// Turns the newest samples into a `VisualizerFrame`. One thread at a time; it allocates only when the sample rate or
/// the band count changes.
public final class VisualizerAnalyzer {
    public struct Configuration: Sendable, Equatable {
        public var bandCount = 64
        public var fineCount = 512
        public var lowHz: Double = 20
        public var highHz: Double = 20_000
        /// The bottom of the display, in dB below full scale.
        public var floorDB: Float = -72
        /// dB added per octave above 1 kHz (taken off below), so typical music, which falls with frequency, looks level.
        public var tiltDBPerOctave: Float = 3
        /// Display gain: 1 is as measured, 2 is +6 dB.
        public var sensitivity: Float = 1
        /// Bars in dB (the default) or in linear amplitude (full height at -12 dBFS).
        public var linear = false
        /// Seconds for a band to rise and fall most of the way.
        public var attack: Double = 0.015
        public var release: Double = 0.22
        /// Seconds a peak is held before it falls, and how fast it then falls (display units per second²).
        public var peakHold: Double = 0.7
        public var peakGravity: Float = 2.2
        /// The meters' reference (the sine RMS that reads 0 VU and PPM 4), in dBFS; nil follows the music's loudness.
        public var meterReferenceDB: Float?

        public init() {}
    }

    public static let waveformCount = 512

    public var configuration: Configuration {
        didSet { if configuration.bandCount != oldValue.bandCount || configuration.fineCount != oldValue.fineCount { resetBands() } }
    }

    // FFT
    private var size = 0
    private var fft: vDSP.FFT<DSPSplitComplex>?
    private var window: [Float] = []
    private var mono: [Float] = []
    private var real: [Float] = []
    private var imag: [Float] = []
    private var power: [Float] = []
    private var sampleRate: Double = 0

    // Fine bins: for each, the FFT bins it takes the largest of, or (narrower than a bin) where to interpolate.
    private var fineLow: [Int] = []
    private var fineHigh: [Int] = []
    private var fineAt: [Float] = []
    private var fineTilt: [Float] = []
    private var fineDB: [Float] = []

    // Display state
    private var fine: [Float] = []
    private var bands: [Float] = []
    private var peaks: [Float] = []
    private var peakVelocity: [Float] = []
    private var peakHeldUntil: [Double] = []
    private var waveform = [Float](repeating: 0, count: VisualizerAnalyzer.waveformCount)
    private var time: Double = 0
    private var lastSignal: Double = -.infinity

    // Beats
    private var bassRange = 0..<0
    private var midRange = 0..<0
    private var trebleRange = 0..<0
    private var previousBassDB: Float = -100
    private var flux: [Float] = []
    private var fluxTimes: [Double] = []
    private var lastBeat: Double = -.infinity
    private var beatPulse: Float = 0
    private var beatTimes: [Double] = []
    private var loudest = SIMD3<Float>(repeating: 1e-6)
    private var smoothedBands = SIMD3<Float>(repeating: 0)

    // Scope and meters
    private var stereo = [SIMD2<Float>](repeating: .zero, count: VisualizerFrame.stereoCount)
    private var correlation: Float = 0
    private var meters = VisualizerMeters()
    /// The music's recent loudness (mean square, full scale 1), for the meters' automatic reference.
    private var loudness: Double = pow(10, -19.0 / 10)

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        resetBands()
    }

    /// Frames of samples to pass in at `sampleRate`: one FFT, about 85 ms (finer in frequency at higher rates).
    public static func fftSize(for sampleRate: Double) -> Int {
        switch sampleRate {
        case ..<56_000: 4096
        case ..<112_000: 8192
        default: 16384
        }
    }

    private func resetBands() {
        let b = configuration.bandCount, f = configuration.fineCount
        fine = .init(repeating: 0, count: f)
        bands = .init(repeating: 0, count: b)
        peaks = .init(repeating: 0, count: b)
        peakVelocity = .init(repeating: 0, count: b)
        peakHeldUntil = .init(repeating: 0, count: b)
        sampleRate = 0   // re-map the fine bins
    }

    private func prepare(sampleRate rate: Double) {
        let n = Self.fftSize(for: rate)
        if n != size {
            size = n
            fft = vDSP.FFT(log2n: vDSP_Length(n.trailingZeroBitCount), radix: .radix2, ofType: DSPSplitComplex.self)
            window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
            mono = .init(repeating: 0, count: n)
            real = .init(repeating: 0, count: n / 2)
            imag = .init(repeating: 0, count: n / 2)
            power = .init(repeating: 0, count: n / 2)
        }
        guard rate != sampleRate else { return }
        sampleRate = rate
        let f = configuration.fineCount
        let binHz = rate / Double(n)
        let high = min(configuration.highHz, rate / 2 * 0.98), low = max(1, min(configuration.lowHz, high / 2))
        fineLow = .init(repeating: 0, count: f); fineHigh = fineLow
        fineAt = .init(repeating: 0, count: f); fineTilt = fineAt; fineDB = fineAt
        let ratio = high / low
        for j in 0..<f {
            let f0 = low * pow(ratio, Double(j) / Double(f)), f1 = low * pow(ratio, Double(j + 1) / Double(f))
            let lo = Int((f0 / binHz).rounded(.up)), hi = Int((f1 / binHz).rounded(.down))
            let center = (f0 * f1).squareRoot()
            fineLow[j] = max(1, lo)
            fineHigh[j] = min(n / 2 - 1, hi)
            fineAt[j] = Float(center / binHz)
            fineTilt[j] = configuration.tiltDBPerOctave * Float(log2(center / 1000))
        }
        func bins(_ a: Double, _ b: Double) -> Range<Int> {
            let lo = max(1, Int(a / binHz)), hi = min(n / 2, max(lo + 1, Int(b / binHz) + 1))
            return lo..<hi
        }
        bassRange = bins(30, 150)
        midRange = bins(150, 2000)
        trebleRange = bins(2000, min(16_000, rate / 2 * 0.98))
    }

    /// Analyzes the newest samples. `left` and `right` hold at least `fftSize(for: sampleRate)` frames, newest last
    /// (more are ignored). `fresh` is false when nothing new arrived since the last frame (paused, or nothing playing):
    /// everything then falls away as from silence. `dt` is the time since the last frame, in seconds.
    public func process(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>, sampleRate rate: Double,
                        fresh: Bool, dt: Double) -> VisualizerFrame {
        let dt = min(max(dt, 1.0 / 1000), 0.25)
        time += dt
        prepare(sampleRate: rate > 0 ? rate : 48_000)
        let n = size
        let have = min(left.count, right.count)
        let live = fresh && have >= n
        if live {
            let l = UnsafeBufferPointer(rebasing: left[(left.count - n)...])
            let r = UnsafeBufferPointer(rebasing: right[(right.count - n)...])
            mono.withUnsafeMutableBufferPointer { m in
                var half: Float = 0.5
                vDSP_vasm(l.baseAddress!, 1, r.baseAddress!, 1, &half, m.baseAddress!, 1, vDSP_Length(n))
            }
        } else {
            vDSP.fill(&mono, with: 0)
        }

        // Levels over the newest 2048 frames.
        var rms = SIMD2<Float>(-100, -100), peak = SIMD2<Float>(-100, -100)
        if live {
            let m = min(2048, n)
            let l = UnsafeBufferPointer(rebasing: left[(left.count - m)...])
            let r = UnsafeBufferPointer(rebasing: right[(right.count - m)...])
            rms = SIMD2(Self.decibels(vDSP.rootMeanSquare(l)), Self.decibels(vDSP.rootMeanSquare(r)))
            peak = SIMD2(Self.decibels(vDSP.maximumMagnitude(l)), Self.decibels(vDSP.maximumMagnitude(r)))
        }
        if max(rms.x, rms.y) > -80 { lastSignal = time }

        // Scope: the newest samples, thinned to about 48 kHz.
        let thin = Self.stereoStride(for: rate > 0 ? rate : 48_000)
        let stereoCount = VisualizerFrame.stereoCount
        if live {
            let from = left.count - stereoCount * thin, fromR = right.count - stereoCount * thin
            for i in 0..<stereoCount { stereo[i] = SIMD2(left[from + i * thin], right[fromR + i * thin]) }
        } else {
            for i in 0..<stereoCount { stereo[i] = .zero }
        }

        // Correlation over the newest ~40 ms: +1 mono, -1 out of phase. Nothing to compare (silence, or one side
        // silent) eases back to 0.
        var correlationTarget: Float = 0
        if live {
            let m = min(n, stereoCount * thin)
            let l = UnsafeBufferPointer(rebasing: left[(left.count - m)...])
            let r = UnsafeBufferPointer(rebasing: right[(right.count - m)...])
            let lr = vDSP.dot(l, r), ll = vDSP.sumOfSquares(l), rr = vDSP.sumOfSquares(r)
            let floor = Float(m) * 1e-8   // about -80 dBFS
            if ll > floor, rr > floor { correlationTarget = min(1, max(-1, lr / (ll * rr).squareRoot())) }
        }
        correlation += (correlationTarget - correlation) * Self.coefficient(dt, 0.2)

        // Meters: only the samples that are new since the last frame (about `dt` of them), so the needles see each
        // sample once.
        let currentRate = rate > 0 ? rate : 48_000
        let newFrames = min(n, max(1, Int((dt * currentRate).rounded())))
        if live {
            let l = UnsafeBufferPointer(rebasing: left[(left.count - newFrames)...])
            let r = UnsafeBufferPointer(rebasing: right[(right.count - newFrames)...])
            let power = Double(max(vDSP.meanSquare(l), vDSP.meanSquare(r)))
            // Loudness follows the music over a few seconds, ignoring silence between songs.
            if power > 1e-5 { loudness += (power - loudness) * Double(Self.coefficient(dt, 3)) }
        }
        let reference = meterReference
        if live {
            meters.process(left: UnsafeBufferPointer(rebasing: left[(left.count - newFrames)...]),
                           right: UnsafeBufferPointer(rebasing: right[(right.count - newFrames)...]),
                           sampleRate: currentRate, referenceDBFS: reference)
        } else {
            meters.process(left: UnsafeBufferPointer(start: nil, count: 0), right: UnsafeBufferPointer(start: nil, count: 0),
                           silentFrames: newFrames, sampleRate: currentRate, referenceDBFS: reference)
        }

        // Waveform: the newest samples, every other one.
        let stride = 2, count = Self.waveformCount
        let offset = n - count * stride
        for i in 0..<count { waveform[i] = mono[offset + i * stride] }

        // Spectrum, as power per bin, scaled so a full-scale sine reads 0 dB.
        let half = n / 2
        mono.withUnsafeMutableBufferPointer { m in
            window.withUnsafeBufferPointer { w in vDSP_vmul(m.baseAddress!, 1, w.baseAddress!, 1, m.baseAddress!, 1, vDSP_Length(n)) }
        }
        if let fft {
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    mono.withUnsafeBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                    }
                    fft.forward(input: split, output: &split)
                    ip[0] = 0   // the packed Nyquist bin
                    rp[0] = 0   // DC
                    power.withUnsafeMutableBufferPointer { p in vDSP.squareMagnitudes(split, result: &p) }
                }
            }
        }
        var scale = 4 / Float(n * n)
        power.withUnsafeMutableBufferPointer { p in vDSP_vsmul(p.baseAddress!, 1, &scale, p.baseAddress!, 1, vDSP_Length(half)) }

        // Fine bins in dB, then on the display scale.
        let floor = configuration.floorDB
        let gainDB = 20 * log10(max(configuration.sensitivity, 0.01))
        for j in 0..<configuration.fineCount {
            var p: Float
            if fineLow[j] <= fineHigh[j] {
                p = 0
                for k in fineLow[j]...fineHigh[j] where power[k] > p { p = power[k] }
            } else {
                let at = min(fineAt[j], Float(half - 2)), k = Int(at), t = at - Float(k)
                p = power[k] * (1 - t) + power[k + 1] * t
            }
            fineDB[j] = 10 * log10(max(p, 1e-14)) + fineTilt[j] + gainDB
        }
        let fineRelease = Self.coefficient(dt, 0.07)
        for j in 0..<configuration.fineCount {
            let target = Self.display(fineDB[j], floor: floor, linear: false)
            fine[j] = target > fine[j] ? target : fine[j] + (target - fine[j]) * fineRelease
        }

        // Bars: the loudest fine bin in each band, smoothed, with held peaks.
        let b = configuration.bandCount, f = configuration.fineCount
        let up = Self.coefficient(dt, configuration.attack), down = Self.coefficient(dt, configuration.release)
        for i in 0..<b {
            let from = i * f / b, to = max(from + 1, (i + 1) * f / b)
            var db: Float = -200
            for j in from..<to where fineDB[j] > db { db = fineDB[j] }
            let target = Self.display(db, floor: floor, linear: configuration.linear)
            bands[i] += (target - bands[i]) * (target > bands[i] ? up : down)
            if bands[i] >= peaks[i] {
                peaks[i] = bands[i]
                peakVelocity[i] = 0
                peakHeldUntil[i] = time + configuration.peakHold
            } else if time > peakHeldUntil[i] {
                peakVelocity[i] += configuration.peakGravity * Float(dt)
                peaks[i] = max(bands[i], peaks[i] - peakVelocity[i] * Float(dt))
            }
        }

        // Lows, mids and highs, against their own recent loudest (which falls back over a few seconds).
        func energy(_ range: Range<Int>) -> Float {
            guard !range.isEmpty, range.upperBound <= power.count else { return 0 }
            var sum: Float = 0
            for k in range { sum += power[k] }
            return sum
        }
        let raw = SIMD3<Float>(energy(bassRange), energy(midRange), energy(trebleRange))
        let fall = Float(exp(-dt / 4))
        loudest = SIMD3(max(loudest.x * fall, raw.x), max(loudest.y * fall, raw.y), max(loudest.z * fall, raw.z))
        loudest = SIMD3(max(loudest.x, 1e-6), max(loudest.y, 1e-6), max(loudest.z, 1e-6))
        let relative = SIMD3<Float>((raw.x / loudest.x).squareRoot(), (raw.y / loudest.y).squareRoot(), (raw.z / loudest.z).squareRoot())
        let bandUp = Self.coefficient(dt, 0.01), bandDown = Self.coefficient(dt, 0.12)
        for c in 0..<3 {
            let k = relative[c] > smoothedBands[c] ? bandUp : bandDown
            smoothedBands[c] += (relative[c] - smoothedBands[c]) * k
        }

        // Beats: a rise in the lows' level well above how they've been rising lately (spectral flux, adaptive
        // threshold), at most one every 0.28 s.
        let bassDB = 10 * log10(max(raw.x, 1e-12))
        let rise = live ? max(0, bassDB - previousBassDB) : 0
        previousBassDB = live ? bassDB : -100
        flux.append(rise); fluxTimes.append(time)
        while let first = fluxTimes.first, time - first > 1.5 { flux.removeFirst(); fluxTimes.removeFirst() }
        var beat = false
        if live, raw.x > 1e-7, flux.count > 8 {
            let mean = vDSP.mean(flux)
            let deviation = (vDSP.meanSquare(flux) - mean * mean).squareRoot()
            // The rise is per frame: at high frame rates each frame sees a smaller part of it, so the floor scales.
            let minimum = Float(max(dt, 1.0 / 240) * 60) * 1.5
            if rise > mean + 1.6 * deviation, rise > minimum, time - lastBeat > 0.28 {
                beat = true
                lastBeat = time
                beatTimes.append(time)
                if beatTimes.count > 16 { beatTimes.removeFirst() }
            }
        }
        beatPulse = beat ? 1 : beatPulse * Float(exp(-dt / 0.12))
        if let last = beatTimes.last, time - last > 3 { beatTimes.removeAll() }

        return VisualizerFrame(fine: fine, bands: bands, peaks: peaks, waveform: waveform, rmsDB: rms, peakDB: peak,
                               bass: smoothedBands.x, mid: smoothedBands.y, treble: smoothedBands.z, beat: beat,
                               beatPulse: beatPulse, tempo: Self.tempo(beatTimes), hasSignal: time - lastSignal < 0.5,
                               time: time, stereo: stereo, stereoInterval: Double(thin) / currentRate, correlation: correlation,
                               vu: SIMD2(Float(meters.vu.x), Float(meters.vu.y)),
                               ppm: SIMD2<Float>(meters.ppm(referenceDBFS: reference)), meterReferenceDB: Float(reference))
    }

    /// The meters' reference in dBFS: as set, or 1 dB over the music's recent loudness, so the needles swing around
    /// the top of the scale whatever the master's level; then raised or lowered by the sensitivity.
    var meterReference: Double {
        let base = configuration.meterReferenceDB.map(Double.init) ?? min(-6, max(-30, 10 * log10(loudness) + 1))
        return base - 20 * log10(Double(max(configuration.sensitivity, 0.01)))
    }

    /// Every how many samples the scope takes one, to keep about 48 kHz.
    public static func stereoStride(for sampleRate: Double) -> Int {
        switch sampleRate {
        case ..<56_000: 1
        case ..<112_000: 2
        default: 4
        }
    }

    /// Convenience for arrays.
    public func process(left: [Float], right: [Float], sampleRate: Double, fresh: Bool, dt: Double) -> VisualizerFrame {
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in process(left: l, right: r, sampleRate: sampleRate, fresh: fresh, dt: dt) }
        }
    }

    /// The median spacing of recent beats, folded into 70–180 BPM, once there are enough of them and they agree.
    static func tempo(_ times: [Double]) -> Double? {
        guard times.count >= 5 else { return nil }
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }.sorted()
        let median = gaps[gaps.count / 2]
        let agreeing = gaps.filter { abs($0 - median) < median * 0.12 }.count
        guard agreeing * 2 >= gaps.count, median > 0 else { return nil }
        var bpm = 60 / median
        while bpm < 70 { bpm *= 2 }
        while bpm > 180 { bpm /= 2 }
        return bpm
    }

    static func decibels(_ linear: Float) -> Float { linear > 1e-5 ? max(-100, 20 * log10(linear)) : -100 }

    /// dB → display height. In dB the floor is 0 and full scale 1; linear is amplitude, full height at -12 dBFS.
    static func display(_ db: Float, floor: Float, linear: Bool) -> Float {
        if linear { return min(1, max(0, pow(10, (db + 12) / 20))) }
        return min(1, max(0, (db - floor) / -floor))
    }

    /// The fraction of the way to a target to move in `dt` for a time constant `tau`.
    static func coefficient(_ dt: Double, _ tau: Double) -> Float { Float(1 - exp(-dt / max(tau, 1e-4))) }
}
