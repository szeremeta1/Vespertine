//
// Vespertine — what Smart Mix knows about a song's two ends: silence, fades, how loud, how it starts and stops, and
// its beat where the beat is steady.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plain Swift, so `vespertine-analyze` computes the same profile on a Linux server. Fed decoded audio in chunks of any
// size (`TransitionAnalyzer`), either a whole song (the library's analysis pass) or only its head or tail (the engine,
// just in time, when a song has no profile yet).
//

import Foundation

/// A song's ends, as Smart Mix sees them.
public struct TransitionProfile: Sendable, Hashable, Codable {
    /// Bumped when the analysis learns something new, so older profiles are made again.
    public static let currentVersion = 1

    public var version = TransitionProfile.currentVersion
    /// The song's length in seconds.
    public var seconds: Double
    /// Its start (nil when the start wasn't analysed).
    public var head: Edge?
    /// Its end (nil when the end wasn't analysed).
    public var tail: Edge?
    /// BS.1770-4 integrated loudness of the whole song, LUFS (nil unless all of it was analysed, or it's silent).
    public var integratedLUFS: Double?

    /// How a song starts or ends.
    public enum EdgeType: String, Sendable, Hashable, Codable, CaseIterable {
        /// The music starts or stops at once, after or before a moment of near-silence.
        case cold
        /// The music fades in or out over seconds.
        case fade
        /// A second or more of silence before the music starts or after it ends.
        case silence
        /// Loud right to the first or last sample: the song continues from or into its neighbour.
        case segue
    }

    /// One end of a song. Times are seconds from that end (the start for the head, the end for the tail).
    public struct Edge: Sendable, Hashable, Codable {
        /// Silence (below about −60 dBFS) between the song's end and its music.
        public var silence: Double
        /// The fade-in from the music's start, or the fade-out to the music's end, in seconds; nil when none was found.
        public var fade: Double?
        /// How sure the fade is, 0…1 (0 when none was found).
        public var fadeConfidence: Double
        /// The loudness of the ten seconds of music next to this end (the fade left out), LUFS.
        public var loudness: Double?
        /// The loudness of the music's first or last second, LUFS.
        public var edgeLoudness: Double?
        public var type: EdgeType
        /// The beat of up to 60 s of music at this end, when it's steady enough to measure.
        public var tempo: Tempo?

        public init(silence: Double, fade: Double? = nil, fadeConfidence: Double = 0, loudness: Double? = nil,
                    edgeLoudness: Double? = nil, type: EdgeType, tempo: Tempo? = nil) {
            self.silence = silence
            self.fade = fade
            self.fadeConfidence = fadeConfidence
            self.loudness = loudness
            self.edgeLoudness = edgeLoudness
            self.type = type
            self.tempo = tempo
        }
    }

    /// A steady beat: beats per minute, how sure, and where one beat falls (seconds from the song's start).
    public struct Tempo: Sendable, Hashable, Codable {
        public var bpm: Double
        public var confidence: Double
        public var beat: Double

        public init(bpm: Double, confidence: Double, beat: Double) {
            self.bpm = bpm
            self.confidence = confidence
            self.beat = beat
        }

        /// Seconds between beats.
        public var period: Double { 60 / bpm }
    }

    public init(seconds: Double, head: Edge? = nil, tail: Edge? = nil, integratedLUFS: Double? = nil) {
        self.seconds = seconds
        self.head = head
        self.tail = tail
        self.integratedLUFS = integratedLUFS
    }

    /// The song's beat, when its head and tail agree on it (within 2%).
    public var tempo: Tempo? {
        guard let a = head?.tempo, let b = tail?.tempo, abs(a.bpm - b.bpm) <= 0.02 * a.bpm else { return nil }
        return a.confidence >= b.confidence ? a : b
    }

    /// A profile with this one's head and `other`'s tail, or whichever is known (for a song analysed in two parts).
    public func merged(with other: TransitionProfile) -> TransitionProfile {
        var p = self
        p.head = head ?? other.head
        p.tail = other.tail ?? tail
        p.integratedLUFS = integratedLUFS ?? other.integratedLUFS
        p.seconds = max(seconds, other.seconds)
        return p
    }
}

/// Builds a `TransitionProfile` from decoded audio fed in chunks of any size. The result doesn't depend on the
/// chunking: loudness is measured in 100 ms steps and onsets in 10 ms hops, both counted from `startFrame`.
public final class TransitionAnalyzer {
    public let sampleRate: Double
    public let channels: Int
    /// The song frame the first sample added is (0 for a head or a whole song; later for a tail).
    public let startFrame: Int64
    /// The level below which a sample counts as silence (−60 dBFS by default).
    public let silenceThreshold: Float

    private var meter: LoudnessMeter
    private let hop: Int
    private var hopSum = 0.0
    private var inHop = 0
    private var lastLogEnergy: Double?
    /// Onset strength per 10 ms hop: how much the level rose since the hop before (log energy, rises only).
    private var onsets: [Float] = []
    public private(set) var framesAdded: Int64 = 0
    /// The first and last frame above `silenceThreshold`, as song frames.
    public private(set) var firstLoudFrame: Int64?
    public private(set) var lastLoudFrame: Int64?

    /// Music below this many seconds of fade isn't a fade.
    static let minimumFadeOut = 3.0
    static let minimumFadeIn = 2.0
    /// A fade lowers (or raises) the level by at least this much.
    static let minimumFadeDrop = 10.0
    /// The span at each end looked at for a fade, and the music measured for the edge's loudness.
    public static let fadeWindow = 30.0
    public static let loudnessWindow = 10.0
    /// The span at each end measured for the beat.
    static let tempoWindow = 60.0
    /// Edges with at least this much silence are `.silence`; with less than `segueSilence`, and loud, `.segue`.
    static let silenceEdge = 1.0
    static let segueSilence = 0.05
    /// A fade counts (`.fade`) from this confidence on.
    public static let fadeConfidenceNeeded = 0.6
    /// The beat is kept from this confidence on.
    public static let tempoConfidenceNeeded = 0.3

    public init(sampleRate: Double, channels: Int, startFrame: Int64 = 0, silenceThreshold: Float = 0.001, weights: [Double]? = nil) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        self.startFrame = max(0, startFrame)
        self.silenceThreshold = silenceThreshold
        meter = LoudnessMeter(sampleRate: sampleRate, channels: channels, weights: weights)
        hop = max(1, Int((sampleRate / 100).rounded()))
    }

    /// Adds `frames` interleaved frames.
    public func add(_ samples: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        meter.add(samples, frames: frames)
        let ch = channels, count = frames * ch, limit = silenceThreshold
        // The first and last sample above the threshold, as frames.
        var first = -1, last = -1
        for i in 0..<count where abs(samples[i]) > limit { first = i; break }
        if first >= 0 {
            var i = count - 1
            while i >= first { if abs(samples[i]) > limit { last = i; break }; i -= 1 }
            let base = startFrame + framesAdded
            if firstLoudFrame == nil { firstLoudFrame = base + Int64(first / ch) }
            lastLoudFrame = base + Int64(last / ch)
        }
        // Energy per 10 ms hop, for the onsets.
        var f = 0
        while f < frames {
            let n = min(frames - f, hop - inHop)
            var e = 0.0
            for i in (f * ch)..<((f + n) * ch) { let x = Double(samples[i]); e += x * x }
            hopSum += e
            inHop += n
            f += n
            if inHop == hop {
                let logEnergy = log10(hopSum / Double(hop * ch) + 1e-10)
                onsets.append(Float(max(0, logEnergy - (lastLogEnergy ?? logEnergy))))
                lastLogEnergy = logEnergy
                hopSum = 0
                inHop = 0
            }
        }
        framesAdded += Int64(frames)
    }

    private var interleaved: [Float] = []

    /// Adds `frames` frames given as one buffer per channel.
    public func add(planar planes: [UnsafePointer<Float>], frames: Int) {
        guard frames > 0, planes.count >= channels else { return }
        if interleaved.count < frames * channels { interleaved = [Float](repeating: 0, count: frames * channels) }
        interleaved.withUnsafeMutableBufferPointer { b in
            for c in 0..<channels {
                let plane = planes[c]
                for f in 0..<frames { b[f * channels + c] = plane[f] }
            }
            add(UnsafePointer(b.baseAddress!), frames: frames)
        }
    }

    public func add(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { add($0.baseAddress!, frames: $0.count / channels) }
    }

    /// The profile of what was added. `totalFrames`: the song's length, when known (the tail is only described when
    /// the audio added reaches it).
    public func finish(totalFrames: Int64? = nil) -> TransitionProfile {
        let end = startFrame + framesAdded
        let total = max(totalFrames ?? end, end)
        let hasHead = startFrame == 0 && framesAdded > 0
        let hasTail = end >= total && framesAdded > 0
        let steps = meter.steps
        var profile = TransitionProfile(seconds: Double(total) / sampleRate)
        if hasHead { profile.head = headEdge(steps) }
        if hasTail { profile.tail = tailEdge(steps, end: end) }
        if hasHead && hasTail { profile.integratedLUFS = LoudnessMeter.integrated(steps).map(Self.rounded) }
        return profile
    }

    // MARK: Edges

    /// Steps (100 ms) from the analysis start to a song frame, rounded down / up.
    private func stepFloor(_ frame: Int64) -> Int { Int(max(0, frame - startFrame) / Int64(meter.stepFrames)) }
    private func stepCeil(_ frame: Int64) -> Int {
        let s = Int64(meter.stepFrames)
        return Int((max(0, frame - startFrame) + s - 1) / s)
    }

    private func headEdge(_ steps: [Double]) -> TransitionProfile.Edge {
        let analysed = Double(framesAdded) / sampleRate
        guard let first = firstLoudFrame else { return .init(silence: analysed, type: .silence) }
        let silence = Double(first) / sampleRate
        // The music: whole steps from its first loud frame on.
        let from = stepCeil(first)
        let music = Array(steps.suffix(from: min(from, steps.count)))
        let window = min(music.count, Int(Self.fadeWindow * 10))
        let fade = Self.fade(levels: Self.levels(Array(music.prefix(window))).reversed(), minimumSeconds: Self.minimumFadeIn)
        let fadeSteps = fade.map { Int(($0.seconds * 10).rounded()) } ?? 0
        let body = fade.map { $0.confidence >= Self.fadeConfidenceNeeded } == true ? fadeSteps : 0
        let loudness = LoudnessMeter.shortTerm(music, range: body ..< body + Int(Self.loudnessWindow * 10))
        let edgeLoudness = LoudnessMeter.shortTerm(music, range: 0..<10)
        let type = Self.type(silence: silence, fadeConfidence: fade?.confidence ?? 0, loudness: loudness, edgeLoudness: edgeLoudness)
        let tempoHops = Int(Self.tempoWindow * 100)
        let firstHop = Int((first - startFrame) / Int64(hop))
        let tempo = Self.tempo(onsets, range: firstHop ..< min(onsets.count, firstHop + tempoHops), hopSeconds: Double(hop) / sampleRate,
                               offset: Double(startFrame) / sampleRate)
        return .init(silence: Self.rounded(silence, places: 4), fade: fade.map { Self.rounded($0.seconds) }, fadeConfidence: Self.rounded(fade?.confidence ?? 0),
                     loudness: loudness.map(Self.rounded), edgeLoudness: edgeLoudness.map(Self.rounded), type: type, tempo: tempo)
    }

    private func tailEdge(_ steps: [Double], end: Int64) -> TransitionProfile.Edge {
        let analysed = Double(framesAdded) / sampleRate
        guard let last = lastLoudFrame else { return .init(silence: analysed, type: .silence) }
        let silence = Double(end - (last + 1)) / sampleRate
        // The music: whole steps up to its last loud frame.
        let to = min(stepFloor(last + 1), steps.count)
        let music = Array(steps.prefix(to))
        let window = min(music.count, Int(Self.fadeWindow * 10))
        let fade = Self.fade(levels: Self.levels(Array(music.suffix(window))), minimumSeconds: Self.minimumFadeOut)
        let fadeSteps = fade.map { Int(($0.seconds * 10).rounded()) } ?? 0
        let body = fade.map { $0.confidence >= Self.fadeConfidenceNeeded } == true ? fadeSteps : 0
        let bodyEnd = music.count - body
        let loudness = LoudnessMeter.shortTerm(music, range: max(0, bodyEnd - Int(Self.loudnessWindow * 10)) ..< bodyEnd)
        let edgeLoudness = LoudnessMeter.shortTerm(music, range: max(0, music.count - 10) ..< music.count)
        let type = Self.type(silence: silence, fadeConfidence: fade?.confidence ?? 0, loudness: loudness, edgeLoudness: edgeLoudness)
        let tempoHops = Int(Self.tempoWindow * 100)
        let lastHop = min(onsets.count, Int((last + 1 - startFrame) / Int64(hop)))
        let tempo = Self.tempo(onsets, range: max(0, lastHop - tempoHops) ..< lastHop, hopSeconds: Double(hop) / sampleRate,
                               offset: Double(startFrame) / sampleRate)
        return .init(silence: Self.rounded(silence, places: 4), fade: fade.map { Self.rounded($0.seconds) }, fadeConfidence: Self.rounded(fade?.confidence ?? 0),
                     loudness: loudness.map(Self.rounded), edgeLoudness: edgeLoudness.map(Self.rounded), type: type, tempo: tempo)
    }

    static func type(silence: Double, fadeConfidence: Double, loudness: Double?, edgeLoudness: Double?) -> TransitionProfile.EdgeType {
        if fadeConfidence >= fadeConfidenceNeeded { return .fade }
        if silence >= silenceEdge { return .silence }
        if silence < segueSilence, let loudness, let edgeLoudness, edgeLoudness >= loudness - 6 { return .segue }
        return .cold
    }

    /// The momentary loudness (400 ms) starting at each step whose block lies within `steps`, floored at −70 LUFS.
    static func levels(_ steps: [Double]) -> [Double] {
        guard steps.count >= 4 else { return [] }
        return (0...(steps.count - 4)).map { k in
            max(-70, LoudnessMeter.lufs((steps[k] + steps[k + 1] + steps[k + 2] + steps[k + 3]) / 4))
        }
    }

    /// A fade at the end of `levels` (one per 100 ms, the music's end last): the split that best fits "steady, then a
    /// straight line in dB down to the end", when that line falls by `minimumFadeDrop` or more over `minimumSeconds`
    /// or more. Its confidence is how straight the line is (R²) and how far it falls. nil when there's no such fade.
    static func fade(levels: some Collection<Double>, minimumSeconds: Double) -> (seconds: Double, confidence: Double)? {
        let y = Array(levels)
        let n = y.count
        let minimum = Int((minimumSeconds * 10).rounded())
        guard n >= minimum + 1 else { return nil }
        // Prefix sums for O(1) fits of any range.
        var s = [0.0], ss = [0.0], sx = [0.0], sxy = [0.0], sxx = [0.0]
        for (i, v) in y.enumerated() {
            let x = Double(i)
            s.append(s[i] + v); ss.append(ss[i] + v * v); sx.append(sx[i] + x); sxy.append(sxy[i] + x * v); sxx.append(sxx[i] + x * x)
        }
        func flatError(_ a: Int, _ b: Int) -> Double {      // a constant over [a, b)
            let m = Double(b - a)
            guard m > 0 else { return 0 }
            let sum = s[b] - s[a]
            return (ss[b] - ss[a]) - sum * sum / m
        }
        func line(_ a: Int, _ b: Int) -> (slope: Double, intercept: Double, error: Double, r2: Double) {
            let m = Double(b - a)
            let mx = (sx[b] - sx[a]) / m, my = (s[b] - s[a]) / m
            let varX = (sxx[b] - sxx[a]) / m - mx * mx
            let covXY = (sxy[b] - sxy[a]) / m - mx * my
            let varY = max(0, (ss[b] - ss[a]) / m - my * my)
            let slope = varX > 0 ? covXY / varX : 0
            let error = max(0, (varY - slope * covXY) * m)
            let r2 = varY > 1e-12 ? min(1, covXY * covXY / (varX * varY)) : 0
            return (slope, my - slope * mx, error, r2)
        }
        var best: (split: Int, error: Double)?
        for split in 0...(n - minimum - 1) {
            let fit = line(split, n)
            guard fit.slope < 0 else { continue }
            let error = flatError(0, split) + fit.error
            if best == nil || error < best!.error { best = (split, error) }
        }
        guard let split = best?.split else { return nil }
        let fit = line(split, n)
        let drop = -fit.slope * Double(n - 1 - split)
        guard drop >= minimumFadeDrop else { return nil }
        let confidence = max(0, min(1, (fit.r2 - 0.5) / 0.4)) * min(1, drop / 15)
        // A block starting at the last level ends 400 ms later, at the music's edge: the fade spans the levels plus that.
        return (Double(n - split + 3) / 10, confidence)
    }

    // MARK: Beat

    /// The beat of the onsets in `range` (10 ms hops): the period whose multiples line up best (autocorrelation over
    /// 70–180 BPM, each candidate scored with its 2nd–4th multiples so half time doesn't win), refined by fitting a
    /// line through the strongest onset near each beat. nil when under 10 s, or the beat isn't steady.
    static func tempo(_ onsets: [Float], range: Range<Int>, hopSeconds: Double, offset: Double) -> TransitionProfile.Tempo? {
        let r = range.clamped(to: 0..<onsets.count)
        guard r.count >= 1000 else { return nil }
        let x = onsets[r].map(Double.init)
        let mean = x.reduce(0, +) / Double(x.count)
        // Smoothed a little ([1 2 1]), so a beat that falls between two hops still lines up with itself.
        let d = x.indices.map { i in (2 * x[i] + x[max(i - 1, 0)] + x[min(i + 1, x.count - 1)]) / 4 - mean }
        let minLag = Int((60 / 180 / hopSeconds).rounded(.down)), maxLag = Int((60 / 70 / hopSeconds).rounded(.up))
        let lags = 4 * maxLag + 1
        guard lags < d.count / 2 else { return nil }
        var ac = [Double](repeating: 0, count: lags + 1)
        for lag in 0...lags {
            var sum = 0.0
            for i in 0..<(d.count - lag) { sum += d[i] * d[i + lag] }
            ac[lag] = sum
        }
        guard ac[0] > 0 else { return nil }
        var bestLag = 0, bestScore = -Double.infinity
        for lag in minLag...maxLag {
            let score = (1...4).reduce(0.0) { $0 + ac[lag * $1] / Double($1) }
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        // The best lag, allowing a hop either side of a fractional one.
        func near(_ lag: Double) -> Int {
            let lo = max(1, Int(lag.rounded(.down)) - 1), hi = min(ac.count - 1, Int(lag.rounded(.up)) + 1)
            return (lo...hi).max { ac[$0] < ac[$1] }!
        }
        // Twice the tempo when half the period lines up nearly as well: every beat, not every other one.
        let half = near(Double(bestLag) / 2)
        if Double(half) >= Double(minLag) - 0.5, ac[half] >= 0.8 * ac[bestLag] { bestLag = half }
        let confidence = max(0, min(1, ac[bestLag] / ac[0]))
        guard confidence >= tempoConfidenceNeeded else { return nil }
        // A fractional period from the peak's neighbours.
        var period = Double(bestLag)
        let l = ac[bestLag - 1], c = ac[bestLag], rr = ac[bestLag + 1]
        let denominator = l - 2 * c + rr
        if denominator < 0 { period += 0.5 * (l - rr) / denominator }
        // The phase that lands most onsets on beats, then a line through the strongest onset near each beat.
        let whole = max(1, Int(period.rounded()))
        var bestPhase = 0, bestSum = -Double.infinity
        for phase in 0..<whole {
            var sum = 0.0, t = Double(phase)
            while Int(t.rounded()) < x.count { sum += x[Int(t.rounded())]; t += period }
            if sum > bestSum { bestSum = sum; bestPhase = phase }
        }
        var beats: [(n: Double, at: Double)] = []
        var n = 0.0
        while true {
            let predicted = Double(bestPhase) + n * period
            let lo = Int((predicted - period / 4).rounded()), hi = Int((predicted + period / 4).rounded())
            if lo >= x.count { break }
            let window = max(0, lo)..<min(x.count, hi + 1)
            if let k = window.max(by: { x[$0] < x[$1] }), x[k] > mean { beats.append((n, Double(k))) }
            n += 1
        }
        if beats.count >= 8 {
            let m = Double(beats.count)
            let mn = beats.reduce(0) { $0 + $1.n } / m, ma = beats.reduce(0) { $0 + $1.at } / m
            let cov = beats.reduce(0) { $0 + ($1.n - mn) * ($1.at - ma) }, varN = beats.reduce(0) { $0 + ($1.n - mn) * ($1.n - mn) }
            if varN > 0 {
                let fitted = cov / varN
                if abs(fitted - period) < period * 0.03 { period = fitted; bestPhase = Int((ma - mn * fitted).rounded()) }
            }
        }
        let bpm = 60 / (period * hopSeconds)
        let beat = offset + (Double(r.lowerBound) + Double(max(0, bestPhase))) * hopSeconds
        return .init(bpm: rounded(bpm, places: 2), confidence: rounded(confidence), beat: rounded(beat, places: 3))
    }

    static func rounded(_ x: Double) -> Double { rounded(x, places: 2) }
    static func rounded(_ x: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (x * scale).rounded() / scale
    }
}
