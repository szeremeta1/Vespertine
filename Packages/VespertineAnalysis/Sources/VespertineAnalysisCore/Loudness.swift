//
// Vespertine — loudness as ITU-R BS.1770-4 measures it: K-weighting, 400 ms blocks every 100 ms, gating.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plain Swift (no Accelerate) so the same numbers come out in the app and on a Linux server. Used by the transition
// analysis (`TransitionAnalyzer`): integrated loudness for a whole song, and the loudness of each 100 ms step for its
// head and tail. Checked against EBU Tech 3341's test signals (LoudnessTests).
//

import Foundation

/// One second-order section, direct form I, in Double (the K-weighting's low shelf needs the precision at 192 kHz+).
struct Biquad: Sendable {
    var b0, b1, b2, a1, a2: Double
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }

    /// BS.1770's first stage: a high shelf (+4 dB above about 1.5 kHz, the head's effect), for any sample rate. The
    /// filter's analog prototype is the one libebur128 derives from the standard's 48 kHz coefficients.
    static func kShelf(sampleRate: Double) -> Biquad {
        let f0 = 1681.974450955533, gain = 3.999843853973347, q = 0.7071752369554196
        let k = tan(Double.pi * f0 / sampleRate)
        let vh = pow(10, gain / 20), vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        return Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                      a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
    }

    /// BS.1770's second stage: the RLB high-pass (about 38 Hz).
    static func kHighPass(sampleRate: Double) -> Biquad {
        let f0 = 38.13547087602444, q = 0.5003270373238773
        let k = tan(Double.pi * f0 / sampleRate)
        let a0 = 1 + k / q + k * k
        return Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
    }
}

/// Measures loudness per BS.1770-4 from interleaved samples fed in chunks of any size: the mean square of each
/// 100 ms step after K-weighting, summed over the channels with their weights. Blocks of four steps (400 ms, 75%
/// overlap) give momentary loudness; gating them gives integrated loudness.
public struct LoudnessMeter: Sendable {
    public let sampleRate: Double
    public let channels: Int
    /// Each channel's weight: 1 for left, right and centre, 1.41 for the surrounds, 0 for LFE.
    public let weights: [Double]
    /// Frames in one 100 ms step.
    public let stepFrames: Int

    private var shelves: [Biquad]
    private var highPasses: [Biquad]
    private var energy: [Double] = []
    private var sum = 0.0
    private var inStep = 0
    /// The weighted mean square of each complete 100 ms step.
    public private(set) var steps: [Double] = []

    public init(sampleRate: Double, channels: Int, weights: [Double]? = nil) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        self.weights = weights ?? Self.defaultWeights(channels: max(1, channels))
        stepFrames = max(1, Int((sampleRate / 10).rounded()))
        shelves = Array(repeating: .kShelf(sampleRate: sampleRate), count: max(1, channels))
        highPasses = Array(repeating: .kHighPass(sampleRate: sampleRate), count: max(1, channels))
    }

    /// The weights for an interleaved layout in WAVE / SMPTE order (L R C LFE Ls Rs …): 5.1 and 7.1 have their LFE
    /// fourth and their surrounds after it; mono, stereo and 3.0 count every channel once.
    public static func defaultWeights(channels: Int) -> [Double] {
        guard channels >= 4 else { return Array(repeating: 1, count: channels) }
        return (0..<channels).map { c in
            if c < 3 { return 1 }
            if c == 3 && (channels == 6 || channels == 8) { return 0 }
            return 1.41
        }
    }

    /// Adds `frames` interleaved frames.
    public mutating func add(_ samples: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        // Each channel through its two filters over the whole chunk (state in locals), into one weighted energy per
        // frame; then the frames into 100 ms steps. Same arithmetic, in the same order per frame, as frame by frame.
        if energy.count < frames { energy = [Double](repeating: 0, count: frames) }
        let ch = channels
        energy.withUnsafeMutableBufferPointer { e in
            for f in 0..<frames { e[f] = 0 }
            for c in 0..<ch where weights[c] != 0 {
                let w = weights[c]
                var a = shelves[c], b = highPasses[c]
                var p = samples + c
                for f in 0..<frames {
                    let y = b.process(a.process(Double(p.pointee)))
                    e[f] += w * y * y
                    p += ch
                }
                shelves[c] = a
                highPasses[c] = b
            }
            var f = 0
            while f < frames {
                let n = min(frames - f, stepFrames - inStep)
                for i in f..<(f + n) { sum += e[i] }
                inStep += n
                f += n
                if inStep == stepFrames {
                    steps.append(sum / Double(stepFrames))
                    sum = 0
                    inStep = 0
                }
            }
        }
    }

    /// Loudness (LUFS) of a weighted mean square: −0.691 + 10·log10(z). −∞ for silence.
    public static func lufs(_ meanSquare: Double) -> Double {
        meanSquare > 0 ? -0.691 + 10 * log10(meanSquare) : -.infinity
    }

    /// The mean square of each 400 ms block (four steps), one per step from the fourth on.
    public static func blocks(_ steps: [Double]) -> [Double] {
        guard steps.count >= 4 else { return [] }
        return (3..<steps.count).map { (steps[$0 - 3] + steps[$0 - 2] + steps[$0 - 1] + steps[$0]) / 4 }
    }

    /// Integrated loudness of the steps in `range` (all by default): blocks below −70 LUFS are left out, then those
    /// more than 10 LU under the mean of the rest. nil when no block is left (silence, or under 400 ms).
    public static func integrated(_ steps: [Double], range: Range<Int>? = nil) -> Double? {
        let r = range ?? 0..<steps.count
        guard r.count >= 4 else { return nil }
        let blocks = Self.blocks(Array(steps[r]))
        let absolute = blocks.filter { lufs($0) > -70 }
        guard !absolute.isEmpty else { return nil }
        let threshold = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { lufs($0) > threshold }
        guard !gated.isEmpty else { return nil }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }

    /// Loudness of the steps in `range` without the relative gate (only blocks under −70 LUFS left out): the level of
    /// a short stretch such as a song's last ten seconds.
    public static func shortTerm(_ steps: [Double], range: Range<Int>) -> Double? {
        let r = range.clamped(to: 0..<steps.count)
        guard r.count >= 4 else { return nil }
        let blocks = Self.blocks(Array(steps[r])).filter { lufs($0) > -70 }
        guard !blocks.isEmpty else { return nil }
        return lufs(blocks.reduce(0, +) / Double(blocks.count))
    }

    /// Integrated loudness of everything added so far.
    public var integratedLoudness: Double? { Self.integrated(steps) }
}
