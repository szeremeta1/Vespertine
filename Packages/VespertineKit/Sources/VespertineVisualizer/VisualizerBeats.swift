//
// Vespertine: finds the beats the visualizer moves to. It listens to the samples as a stream, at its own steady
// pace, whatever the display's frame rate: short spectra a few milliseconds apart, how much each rose since the one
// before (in the lows, the mids and the highs), and the peaks of that which stand out from what the music has been
// doing.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Accelerate
import Foundation

/// What the beat detector knows after the newest samples.
public struct VisualizerBeatState: Sendable, Equatable {
    /// Beats found so far. It only ever goes up (and wraps), so a reader that compares it with the count it saw last
    /// misses no beat and counts none twice, however its own clock runs against the analysis.
    public var count: UInt32 = 0
    /// How hard the newest beat was, 0…1, against the hardest of the last few seconds.
    public var strength: Float = 0
    /// Jumps to the beat's strength (at least 0.4) on a beat and falls to nothing in about a third of a second.
    public var pulse: Float = 0
    /// Sudden sounds in the lows (kicks), the mids (snares, claps, plucked notes) and the highs (hi-hats, cymbals),
    /// each 0…1 against its own recent hardest, falling away in about a tenth of a second. Quicker and finer than
    /// `pulse`: every hit shows, not only the beat.
    public var transients = SIMD3<Float>(0, 0, 0)
    /// Beats per minute, when the music has kept a tempo for a few seconds.
    public var tempo: Double?
    /// Seconds since the newest beat (a large number before the first).
    public var sinceBeat: Double = 1e6
}

/// Finds beats in a stream of samples. One thread at a time; it allocates only when the sample rate changes.
///
/// How: a Hann-windowed FFT of about 23 ms every 5.8 ms (a quarter of the window) for the mids (180 Hz to 2.5 kHz)
/// and the highs (to 12 kHz). The lows (32 to 180 Hz) get a spectrum of their own, of the same samples averaged down
/// to about 5.5 kHz and four times as long (93 ms): in a 23 ms window a bass note is under two cycles, and its bins
/// swell and shrink with its phase from one spectrum to the next, which reads as a beat on every held note. Each
/// spectrum is compressed (log of 1 + 100 × magnitude, against the loudest partial of late, so a quiet master and a loud one read alike, and a kick over
/// a held bass note still shows) and compared with the one before: the rise in each bin above the largest of its
/// neighbours there (so a note that only wobbles in pitch isn't a rise), summed over each band. A beat is a peak of
/// the lows' and mids' rise that stands out from the last second and a half (mean + 1.6 standard deviations), is at
/// least a third of the hardest peak of the last few seconds (so the hi-hats between the kicks aren't beats, but are
/// when nothing else plays), and comes at least 0.18 s after the last. A kick's click shows in the mids a few
/// hundredths of a second before its body shows in the lows: the later, larger peak makes the same beat stronger
/// rather than a second one. The tempo is the lag at which the last eight seconds of that rise best repeat.
public struct VisualizerBeatDetector {
    public private(set) var state = VisualizerBeatState()

    // The spectra
    private var sampleRate: Double = 0
    private var size = 0
    private var hop = 0
    private var fft: vDSP.FFT<DSPSplitComplex>?
    private var window: [Float] = []
    private var pending: [Float] = []
    private var filled = 0
    private var work: [Float] = []
    private var real: [Float] = []
    private var imag: [Float] = []
    private var magnitude: [Float] = []
    private var compressed: [Float] = []
    private var previous: [Float] = []
    private var havePrevious = false
    private var bands: [Range<Int>] = [0..<0, 0..<0, 0..<0]

    // The lows' own spectra: the same samples averaged down by `lowStride`, `lowSize` of them a spectrum.
    static let lowSize = 512
    private var lowStride = 8
    private var lowFFT: vDSP.FFT<DSPSplitComplex>?
    private var lowWindow: [Float] = []
    private var lowPending = [Float](repeating: 0, count: VisualizerBeatDetector.lowSize)
    private var lowFilled = 0
    private var lowWork = [Float](repeating: 0, count: VisualizerBeatDetector.lowSize)
    private var lowReal = [Float](repeating: 0, count: VisualizerBeatDetector.lowSize / 2)
    private var lowImag = [Float](repeating: 0, count: VisualizerBeatDetector.lowSize / 2)
    private var lowMagnitude = [Float](repeating: 0, count: VisualizerBeatDetector.lowSize / 2)
    private var lowCompressed = [Float](repeating: 0, count: VisualizerBeatDetector.lowSize / 2)
    private var lowPrevious = [Float](repeating: 0, count: VisualizerBeatDetector.lowSize / 2)
    private var haveLowPrevious = false
    private var lowBand = 0..<0
    /// The newest beat's own measure and how many hops ago it was (a larger peak just after it is the same beat).
    private var beatValue: Float = 0

    // The rise from spectrum to spectrum: the last few values (for picking peaks), a second and a half (for what
    // stands out) and eight seconds (for the tempo), each a ring.
    private var novelty = SIMD3<Float>(0, 0, 0)     // two hops ago, one hop ago, now
    private var recent: [Float] = []
    private var recentAt = 0
    private var recentFilled = 0
    private var history: [Float] = []
    private var historyAt = 0
    private var historyFilled = 0
    private var hopsSinceTempo = 0
    private var acf: [Float] = []
    private var ordered: [Float] = []

    // What loud has been lately
    private var hardest: Float = 0
    private var bandHardest = SIMD3<Float>(repeating: 0)
    private var bandPrevious = SIMD3<Float>(repeating: 0)
    private var hopsSinceBeat = Int.max / 2
    private var level: Float = 0
    /// The largest bin of late (a full-scale sine is 1): the spectra are read against it, so a quiet master and a
    /// loud one give the same rises.
    private var loudest: Float = 0
    /// The newest rise (tests).
    var newestRise: Float { novelty.z }

    static let pulseFall = 0.11       // seconds for the pulse to fall to 1/e
    static let transientFall = 0.07
    static let minimumGap = 0.18      // seconds between beats
    static let sameBeat = 0.07        // a larger peak this soon after a beat is the same beat
    static let standOut: Float = 1.6  // standard deviations above the recent mean
    static let share: Float = 0.33    // of the hardest recent peak
    static let memory = 5.0           // seconds for "the hardest lately" to fall to 1/e
    static let compression: Float = 100
    /// The least rise that can be a beat at all: the ripple of held notes stays under it.
    static let floor: Float = 0.5

    public init() {}

    /// Samples in one spectrum at `rate`: about 23 ms.
    static func windowSize(for rate: Double) -> Int {
        switch rate {
        case ..<56_000: 1024
        case ..<112_000: 2048
        default: 4096
        }
    }

    private mutating func prepare(rate: Double) {
        guard rate != sampleRate else { return }
        sampleRate = rate
        size = Self.windowSize(for: rate)
        hop = size / 4
        fft = vDSP.FFT(log2n: vDSP_Length(size.trailingZeroBitCount), radix: .radix2, ofType: DSPSplitComplex.self)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        pending = .init(repeating: 0, count: size * 2)
        filled = 0
        work = .init(repeating: 0, count: size)
        real = .init(repeating: 0, count: size / 2)
        imag = real
        magnitude = real
        compressed = real
        previous = real
        let binHz = rate / Double(size)
        func bins(_ a: Double, _ b: Double) -> Range<Int> {
            let lo = max(1, Int((a / binHz).rounded(.up))), hi = min(size / 2 - 1, max(lo + 1, Int((b / binHz).rounded(.up))))
            return lo..<hi
        }
        bands = [0..<0, bins(180, 2500), bins(2500, min(12_000, rate / 2 * 0.9))]
        lowStride = size / 128
        lowFFT = vDSP.FFT(log2n: vDSP_Length(Self.lowSize.trailingZeroBitCount), radix: .radix2, ofType: DSPSplitComplex.self)
        lowWindow = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.lowSize, isHalfWindow: false)
        let lowBinHz = rate / Double(lowStride) / Double(Self.lowSize)
        // From the third bin: the first two swell and shrink with a note's phase (they overlap their own mirror image).
        lowBand = max(3, Int((32 / lowBinHz).rounded(.up)))..<min(Self.lowSize / 2 - 1, Int((180 / lowBinHz).rounded(.up)))
        let perSecond = rate / Double(hop)
        recent = .init(repeating: 0, count: max(8, Int(1.5 * perSecond)))
        history = .init(repeating: 0, count: max(16, Int(8 * perSecond)))
        ordered = history
        acf = .init(repeating: 0, count: history.count)
        forget()
    }

    /// Forgets what came before (the music stopped, or samples were lost): the next spectrum is compared with nothing,
    /// so the join isn't a beat. What loud has been is kept.
    private mutating func forget() {
        filled = 0
        havePrevious = false
        lowFilled = 0
        haveLowPrevious = false
        novelty = .zero
        bandPrevious = .zero
        recentAt = 0; recentFilled = 0
        historyAt = 0; historyFilled = 0
        hopsSinceTempo = 0
        state.tempo = nil
    }

    /// The newest samples (mono, in playing order), every one exactly once. `continuous` is false when they don't
    /// follow on from the last ones given (the first after a pause, or after some were lost).
    public mutating func process(_ samples: UnsafeBufferPointer<Float>, sampleRate rate: Double, continuous: Bool = true) {
        prepare(rate: rate > 0 ? rate : 48_000)
        if !continuous { forget() }
        let seconds = Double(samples.count) / sampleRate
        decay(seconds)
        var offset = 0
        while offset < samples.count {
            let take = min(samples.count - offset, pending.count - filled)
            pending.withUnsafeMutableBufferPointer { p in
                (p.baseAddress! + filled).update(from: samples.baseAddress! + offset, count: take)
            }
            filled += take
            offset += take
            while filled >= size {
                step()
                pending.withUnsafeMutableBufferPointer { p in
                    p.baseAddress!.update(from: p.baseAddress! + hop, count: filled - hop)
                }
                filled -= hop
            }
        }
    }

    /// Nothing is playing (paused, stopped, or the window just opened): the pulse falls away and the stream is
    /// forgotten, so playing again starts afresh.
    public mutating func idle(_ seconds: Double) {
        if havePrevious || haveLowPrevious || filled > 0 || lowFilled > 0 || state.tempo != nil { forget() }
        decay(seconds)
    }

    private mutating func decay(_ seconds: Double) {
        guard seconds > 0 else { return }
        state.pulse *= Float(exp(-seconds / Self.pulseFall))
        if state.pulse < 1e-4 { state.pulse = 0 }
        let fall = Float(exp(-seconds / Self.transientFall))
        state.transients *= fall
        state.sinceBeat = min(state.sinceBeat + seconds, 1e6)
    }

    /// One spectrum: the oldest `size` pending samples.
    private mutating func step() {
        guard let fft else { return }
        let half = size / 2
        vDSP.multiply(pending[0..<size], window, result: &work)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                work.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                fft.forward(input: split, output: &split)
                rp[0] = 0; ip[0] = 0
                magnitude.withUnsafeMutableBufferPointer { m in vDSP.absolute(split, result: &m) }
            }
        }
        // A full-scale sine reads 1. Against the loudest bin of late, then log(1 + c m): what is 40 dB under the
        // music's loudest partial hardly counts.
        var largest: Float = 0
        vDSP_maxv(magnitude, 1, &largest, vDSP_Length(half))
        largest *= 2 / Float(size)
        loudest = max(loudest * Float(exp(-Double(hop) / sampleRate / Self.memory)), largest, 1e-4)
        level = largest
        var scale = Self.compression * 2 / Float(size) / loudest, one: Float = 1
        vDSP_vsmsa(magnitude, 1, &scale, &one, &compressed, 1, vDSP_Length(half))
        var count = Int32(half)
        vvlogf(&compressed, compressed, &count)

        var rise = SIMD3<Float>(repeating: 0)
        if havePrevious {
            for b in 1..<3 { rise[b] = Self.rise(compressed, over: previous, in: bands[b]) }
        }
        swap(&previous, &compressed)
        havePrevious = true
        rise.x = lowRise()

        let perSecond = sampleRate / Double(hop)
        let hopSeconds = 1 / perSecond

        // Each band's own hits, against its own recent hardest: for sparkle and ripples.
        let fall = Float(exp(-hopSeconds / Self.memory))
        for b in 0..<3 {
            bandHardest[b] = max(bandHardest[b] * fall, rise[b], 1e-3)
            // A hit is a local peak of the band's rise that is a good part of its hardest.
            let relative = rise[b] / bandHardest[b]
            if rise[b] > bandPrevious[b], relative > 0.3 { state.transients[b] = max(state.transients[b], min(1, relative)) }
            bandPrevious[b] = rise[b]
        }

        // The beat's own measure: the lows and the mids together (a kick is both; a snare mostly the second), the
        // highs only a little.
        let value = rise.x + 0.7 * rise.y + 0.15 * rise.z
        novelty = SIMD3(novelty.y, novelty.z, value)
        history[historyAt] = value
        historyAt = (historyAt + 1) % history.count
        historyFilled = min(historyFilled + 1, history.count)

        // Was the hop before this one a peak that stands out?
        hopsSinceBeat = min(hopsSinceBeat + 1, Int.max / 2)
        let candidate = novelty.y
        if recentFilled >= recent.count / 3, candidate > novelty.x, candidate >= novelty.z, level > 0.0015, candidate > Self.floor {
            var mean: Float = 0, meanSquare: Float = 0
            let n = vDSP_Length(recentFilled)
            vDSP_meanv(recent, 1, &mean, n)
            vDSP_measqv(recent, 1, &meanSquare, n)
            let deviation = max(0, meanSquare - mean * mean).squareRoot()
            let threshold = mean + Self.standOut * deviation
            let gap = Double(hopsSinceBeat) * hopSeconds
            if candidate > threshold {
                let beat = candidate > Self.share * hardest && gap >= Self.minimumGap
                hardest = max(hardest, candidate)
                if beat {
                    state.count &+= 1
                    beatValue = candidate
                    state.sinceBeat = 0
                    hopsSinceBeat = 0
                } else if gap < Self.sameBeat, candidate > beatValue {
                    beatValue = candidate   // the same beat's body, after its click
                }
                if beat || gap < Self.sameBeat {
                    state.strength = min(1, beatValue / max(hardest, 1e-6))
                    state.pulse = max(state.pulse, max(0.4, state.strength))
                }
            }
        }
        hardest *= fall
        recent[recentAt] = candidate
        recentAt = (recentAt + 1) % recent.count
        recentFilled = min(recentFilled + 1, recent.count)

        // The tempo, twice a second once there's enough to go on.
        hopsSinceTempo += 1
        if hopsSinceTempo >= Int(perSecond / 2) {
            hopsSinceTempo = 0
            state.tempo = tempo(perSecond: perSecond)
        }
    }

    /// How much a compressed spectrum rose over the one before, in a band: each bin above the largest of its
    /// neighbours before, summed, over the root of the band's width (so a wide band's many small rises don't outweigh
    /// a narrow band's few large ones).
    private static func rise(_ now: [Float], over before: [Float], in range: Range<Int>) -> Float {
        guard !range.isEmpty else { return 0 }
        var total: Float = 0
        let last = now.count - 1
        for k in range {
            let d = now[k] - max(before[max(k - 1, 0)], before[k], before[min(k + 1, last)])
            if d > 0 { total += d }
        }
        return total / Float(range.count).squareRoot()
    }

    /// The lows' rise for this hop: the hop's samples averaged down and added to the lows' own stream, and the newest
    /// `lowSize` of that as a spectrum. Nothing until a full spectrum's worth has arrived since the stream began, so
    /// the stream filling up isn't a rise.
    private mutating func lowRise() -> Float {
        guard let lowFFT else { return 0 }
        let n = Self.lowSize, new = hop / lowStride, half = n / 2
        lowPending.withUnsafeMutableBufferPointer { p in
            p.baseAddress!.update(from: p.baseAddress! + new, count: n - new)
            pending.withUnsafeBufferPointer { x in
                for j in 0..<new {
                    var mean: Float = 0
                    vDSP_meanv(x.baseAddress! + size - hop + j * lowStride, 1, &mean, vDSP_Length(lowStride))
                    p[n - new + j] = mean
                }
            }
        }
        lowFilled = min(lowFilled + new, n + new)
        // The very first hop of a stream brings a whole window of samples, of which only the last hop is taken here:
        // it's a few milliseconds short, which the wait for a full spectrum covers.
        guard lowFilled >= n else { return 0 }
        vDSP.multiply(lowPending, lowWindow, result: &lowWork)
        lowReal.withUnsafeMutableBufferPointer { rp in
            lowImag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                lowWork.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                lowFFT.forward(input: split, output: &split)
                rp[0] = 0; ip[0] = 0
                lowMagnitude.withUnsafeMutableBufferPointer { m in vDSP.absolute(split, result: &m) }
            }
        }
        var scale = Self.compression * 2 / Float(n) / loudest, one: Float = 1
        vDSP_vsmsa(lowMagnitude, 1, &scale, &one, &lowCompressed, 1, vDSP_Length(half))
        var count = Int32(half)
        vvlogf(&lowCompressed, lowCompressed, &count)
        let rise = haveLowPrevious ? Self.rise(lowCompressed, over: lowPrevious, in: lowBand) : 0
        swap(&lowPrevious, &lowCompressed)
        haveLowPrevious = true
        return rise
    }

    /// The tempo the last seconds of rises repeat at, 60 to 200 BPM, or nil when they don't repeat clearly (or there
    /// aren't four seconds of them yet). Autocorrelation; a lag also has to be backed by twice itself, and of two
    /// that are an octave apart the one nearer 120 BPM is taken.
    private mutating func tempo(perSecond: Double) -> Double? {
        let n = historyFilled
        guard n >= Int(4 * perSecond), hardest > 0 else { return nil }
        // Oldest first, without its mean.
        let start = historyFilled == history.count ? historyAt : 0
        for i in 0..<n { ordered[i] = history[(start + i) % history.count] }
        var mean: Float = 0
        vDSP_meanv(ordered, 1, &mean, vDSP_Length(n))
        var negative = -mean
        vDSP_vsadd(ordered, 1, &negative, &ordered, 1, vDSP_Length(n))
        var energy: Float = 0
        vDSP_svesq(ordered, 1, &energy, vDSP_Length(n))
        guard energy > 1e-6 else { return nil }
        let shortest = max(2, Int(perSecond * 60 / 200)), longest = min(n / 2 - 1, Int(perSecond * 60 / 60) + 1)
        guard longest > shortest + 2 else { return nil }
        // Up to twice the longest lag, for the check against the octave.
        let reach = min(n - 2, longest * 2 + 2)
        ordered.withUnsafeBufferPointer { x in
            for lag in (shortest - 1)...reach {
                var dot: Float = 0
                vDSP_dotpr(x.baseAddress!, 1, x.baseAddress! + lag, 1, &dot, vDSP_Length(n - lag))
                // Normalized for the shorter overlap, so long lags aren't at a disadvantage.
                acf[lag] = dot / energy * Float(n) / Float(n - lag)
            }
        }
        var best = -1, bestScore: Float = 0
        for lag in shortest...longest {
            let a = acf[lag]
            guard a > acf[lag - 1], a >= acf[lag + 1], a > 0.12 else { continue }
            let double = 2 * lag <= reach ? max(acf[2 * lag - 1], acf[2 * lag], acf[min(2 * lag + 1, reach)]) : a
            let bpm = 60 * perSecond / Double(lag)
            let octaves = log2(bpm / 126)
            let prior = Float(exp(-0.5 * octaves * octaves / (0.9 * 0.9)))
            let score = (a + 0.5 * max(0, double)) * prior
            if score > bestScore { best = lag; bestScore = score }
        }
        guard best > 0 else { return nil }
        // Between the lags: a parabola through the peak and its neighbours.
        let a = acf[best - 1], b = acf[best], c = acf[best + 1]
        let denominator = a - 2 * b + c
        let shift = abs(denominator) > 1e-9 ? 0.5 * (a - c) / denominator : 0
        let lag = Double(best) + Double(min(max(shift, -0.5), 0.5))
        return 60 * perSecond / lag
    }
}
