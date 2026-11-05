//
// Vespertine — Spatialize stereo: a stereo or mono song upmixed to 5.1 (L R C LFE Ls Rs), for Spatial Audio on headphones
// and for multichannel speakers. Opt-in per output; the original stays the default.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A frequency-domain primary/ambient decomposition after Avendano & Jot ("A frequency-domain approach to multichannel
// upmix", JAES 52(7/8), 2004), made downmix-safe. Per STFT bin, from cross- and auto-spectra smoothed over ~40 ms:
//   · the centre is what L and R share in phase: m = φ⁺·√min(Φll, Φrr), taken from each side by the mask m/√Φ (never
//     more than the side has, never phase-inverted); C = √2·(the two removed parts)/2. Folded back with the ITU-R BS.775
//     coefficient (L′ + 0.707·C) the original L returns for coherent material, and a phantom centre becomes a real one at
//     the same power.
//   · the ambience is the part present in both channels but not coherent between them, a = √(min(Φll, Φrr)·(1 − φ²)):
//     reverb and room sound, never a dry hard-panned instrument. It feeds the surrounds (−6 dB, delayed 12 and 15 ms so
//     the pair is decorrelated and the front image stays in front); the fronts keep theirs.
//   · LFE: off by default (receivers bass-manage the mains, as with Pro Logic II and Neo:6); optionally a 120 Hz 4th-order
//     low-pass of the mono sum.
// Mono is taken as L = R: it all lands on the centre. Runs on the decode thread, never on the I/O thread. Its latency is
// compensated inside: output frame n is input frame n, and a song comes out exactly as long as it went in.
//

import Accelerate
import CoreAudio
import Foundation

public struct UpmixSettings: Sendable, Hashable, Codable {
    /// Linear gain of the ambience sent to the surrounds.
    public var ambienceGain: Float = 0.5
    /// How much of the shared, in-phase part moves to the centre (1: all of it; 0: no centre).
    public var centreAmount: Float = 1
    /// Linear gain of the extracted LFE (0: the LFE channel stays silent).
    public var lfeGain: Float = 0
    /// Surround delays in milliseconds (left, right).
    public var surroundDelayMS: (left: Double, right: Double) { (12, 15) }

    public init(ambienceGain: Float = 0.5, centreAmount: Float = 1, lfeGain: Float = 0) {
        self.ambienceGain = ambienceGain
        self.centreAmount = centreAmount
        self.lfeGain = lfeGain
    }
}

final class StereoUpmixer {
    /// The channels it produces, in order: standard 5.1 (the Spatial Audio bed kAudioChannelLayoutTag_MPEG_5_1_A).
    static let outputLabels: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                                                    kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]
    static let outputChannels = 6

    let inputChannels: Int
    let sampleRate: Double
    let settings: UpmixSettings
    /// Frame length and hop of the STFT.
    let size: Int
    let hop: Int
    private let bins: Int
    private let window: [Float]
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup
    /// Undoes the DFT pair's own scale and the windows' overlap (√Hann × √Hann at 75 % overlap sums to 2).
    private let scale: Float
    private let alpha: Float

    // Analysis: the last `size` input samples of each side.
    private var frameL: [Float], frameR: [Float]
    private var filled = 0
    // Smoothed spectra per bin.
    private var pLL: [Float], pRR: [Float], pLRre: [Float], pLRim: [Float]
    // Overlap-add of the five STFT outputs (L′ R′ C Ls Rs).
    private var ola: [[Float]]
    // Scratch.
    private var evenIn: [Float], oddIn: [Float], reL: [Float], imL: [Float], reR: [Float], imR: [Float]
    private var outRe: [[Float]], outIm: [[Float]], timeBuffer: [Float]
    // Time-domain stages after the STFT.
    private var delayLs: DelayLine, delayRs: DelayLine
    private var lfe: LFEPath?
    /// Output frames still to drop (the STFT's latency), and input frames taken in and frames handed out.
    private var toDrop: Int
    private(set) var framesIn = 0
    private(set) var framesOut = 0

    init?(inputChannels: Int, sampleRate: Double, settings: UpmixSettings = UpmixSettings()) {
        guard inputChannels == 1 || inputChannels == 2, sampleRate.isFinite, sampleRate > 0 else { return nil }
        self.inputChannels = inputChannels
        self.sampleRate = sampleRate
        self.settings = settings
        // About 43 ms whatever the rate: 2048 at 44.1/48 kHz, 4096 at 88.2/96, … 16384 at 352.8/384.
        var n = 2048
        while Double(n) / sampleRate < 0.03 && n < 32_768 { n *= 2 }
        size = n
        hop = n / 4
        bins = n / 2 + 1
        guard let f = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD),
              let i = vDSP_DFT_zrop_CreateSetup(f, vDSP_Length(n), .INVERSE) else { return nil }
        forward = f
        inverse = i
        window = (0..<n).map { Float((0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))).squareRoot()) }
        alpha = Float(exp(-Double(n / 4) / (0.04 * sampleRate)))
        frameL = [Float](repeating: 0, count: n)
        frameR = [Float](repeating: 0, count: n)
        pLL = [Float](repeating: 0, count: n / 2 + 1)
        pRR = pLL; pLRre = pLL; pLRim = pLL
        ola = [[Float]](repeating: [Float](repeating: 0, count: n), count: 5)
        evenIn = [Float](repeating: 0, count: n / 2)
        oddIn = evenIn; reL = evenIn; imL = evenIn; reR = evenIn; imR = evenIn; timeBuffer = [Float](repeating: 0, count: n)
        outRe = [[Float]](repeating: evenIn, count: 5)
        outIm = outRe
        delayLs = DelayLine(frames: Int((settings.surroundDelayMS.left / 1000 * sampleRate).rounded()))
        delayRs = DelayLine(frames: Int((settings.surroundDelayMS.right / 1000 * sampleRate).rounded()))
        lfe = settings.lfeGain > 0 ? LFEPath(sampleRate: sampleRate, gain: settings.lfeGain, delay: n - n / 4) : nil
        toDrop = n - n / 4
        // The pair's own scale, measured once: a forward and inverse transform of an impulse.
        scale = Self.roundTripScale(forward: f, inverse: i, size: n) / 2
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
    }

    /// The STFT's latency in frames (compensated: callers never see it).
    var latency: Int { size - hop }

    /// Takes `frames` interleaved frames of `inputChannels` and appends the 5.1 frames now ready, interleaved, to `output`.
    func process(_ input: UnsafePointer<Float>, frames: Int, into output: inout [Float]) {
        var f = 0
        while f < frames {
            let take = min(hop - filled, frames - f)
            let at = size - hop + filled
            for j in 0..<take {
                let l = input[(f + j) * inputChannels]
                frameL[at + j] = l
                frameR[at + j] = inputChannels == 2 ? input[(f + j) * 2 + 1] : l
            }
            lfe?.push(frameL, frameR, from: at, count: take)
            filled += take
            f += take
            framesIn += take
            if filled == hop {
                runFrame(into: &output)
                filled = 0
            }
        }
    }

    /// Flushes what the STFT still holds: after this, exactly as many frames have come out as went in.
    func finish(into output: inout [Float]) {
        var zeros = [Float](repeating: 0, count: hop * inputChannels)
        let target = framesIn
        // At most the latency and one partial hop of padding are needed.
        for _ in 0...(size / hop + 1) where framesOut < target {
            zeros.withUnsafeBufferPointer { process($0.baseAddress!, frames: hop, into: &output) }
        }
        framesIn = target   // the padding isn't input
        let extra = framesOut - target
        if extra > 0 {
            output.removeLast(extra * Self.outputChannels)
            framesOut = target
        }
    }

    // MARK: One STFT frame

    private func runFrame(into output: inout [Float]) {
        analyse(frameL, re: &reL, im: &imL)
        analyse(frameR, re: &reR, im: &imR)
        let half = size / 2
        let a = alpha, b = 1 - alpha
        let centre = settings.centreAmount, ambience = settings.ambienceGain
        let eps: Float = 1e-20
        // Bin k's value: k = 0 is DC (re[0]) and k = half is Nyquist (im[0]); 1..<half are re[k] + i·im[k].
        for k in 0..<bins {
            let (lr, li): (Float, Float) = k == 0 ? (reL[0], 0) : k == half ? (imL[0], 0) : (reL[k], imL[k])
            let (rr, ri): (Float, Float) = k == 0 ? (reR[0], 0) : k == half ? (imR[0], 0) : (reR[k], imR[k])
            pLL[k] = a * pLL[k] + b * (lr * lr + li * li)
            pRR[k] = a * pRR[k] + b * (rr * rr + ri * ri)
            pLRre[k] = a * pLRre[k] + b * (lr * rr + li * ri)     // L · conj(R)
            pLRim[k] = a * pLRim[k] + b * (li * rr - lr * ri)
            let ll = pLL[k], rrP = pRR[k]
            let norm = (ll * rrP).squareRoot() + eps
            let coherence = min(1, (pLRre[k] * pLRre[k] + pLRim[k] * pLRim[k]).squareRoot() / norm)
            let inPhase = max(0, pLRre[k]) / norm
            let shared = min(ll, rrP)
            let m = centre * min(1, inPhase) * shared.squareRoot()
            let wL = min(1, m / (ll.squareRoot() + eps)), wR = min(1, m / (rrP.squareRoot() + eps))
            let amb = (shared * max(0, 1 - coherence * coherence)).squareRoot()
            let aL = ambience * min(1, amb / (ll.squareRoot() + eps)), aR = ambience * min(1, amb / (rrP.squareRoot() + eps))
            // L′, R′, C (√2 × the mean of the two removed parts), Ls, Rs.
            let cr = Float(0.5.squareRoot()) * (wL * lr + wR * rr), ci = Float(0.5.squareRoot()) * (wL * li + wR * ri)
            let values: [(Float, Float)] = [((1 - wL) * lr, (1 - wL) * li), ((1 - wR) * rr, (1 - wR) * ri), (cr, ci),
                                            (aL * lr, aL * li), (aR * rr, aR * ri)]
            for (o, v) in values.enumerated() {
                if k == 0 { outRe[o][0] = v.0 } else if k == half { outIm[o][0] = v.0 } else { outRe[o][k] = v.0; outIm[o][k] = v.1 }
            }
        }
        for o in 0..<5 {
            synthesise(re: outRe[o], im: outIm[o])
            for j in 0..<size { ola[o][j] += timeBuffer[j] * window[j] * scale }
        }
        // The first hop of the overlap-add is complete: hand it out (past the latency), then shift everything by a hop.
        let skip = min(toDrop, hop)
        toDrop -= skip
        if skip < hop {
            let count = hop - skip
            let lfeOut = lfe?.take(count: hop).suffix(count)
            output.reserveCapacity(output.count + count * Self.outputChannels)
            for j in skip..<hop {
                let ls = delayLs.run(ola[3][j]), rs = delayRs.run(ola[4][j])
                let low = lfeOut.map { $0[$0.startIndex + (j - skip)] } ?? 0
                output.append(contentsOf: [ola[0][j], ola[1][j], ola[2][j], low, ls, rs])
            }
            framesOut += count
        } else {
            _ = lfe?.take(count: hop)
            for j in 0..<hop { _ = delayLs.run(ola[3][j]); _ = delayRs.run(ola[4][j]) }
        }
        for o in 0..<5 {
            ola[o].withUnsafeMutableBufferPointer { p in
                p.baseAddress!.update(from: p.baseAddress! + hop, count: size - hop)
                (p.baseAddress! + size - hop).update(repeating: 0, count: hop)
            }
        }
        for buffer in [\StereoUpmixer.frameL, \StereoUpmixer.frameR] {
            self[keyPath: buffer].withUnsafeMutableBufferPointer { p in
                p.baseAddress!.update(from: p.baseAddress! + hop, count: size - hop)
            }
        }
    }

    /// Windowed forward transform of `frame` into packed bins (re[0] DC, im[0] Nyquist).
    private func analyse(_ frame: [Float], re: inout [Float], im: inout [Float]) {
        let half = size / 2
        for j in 0..<half {
            evenIn[j] = frame[2 * j] * window[2 * j]
            oddIn[j] = frame[2 * j + 1] * window[2 * j + 1]
        }
        vDSP_DFT_Execute(forward, evenIn, oddIn, &re, &im)
    }

    /// Inverse transform of packed bins into `timeBuffer` (unwindowed, unscaled).
    private func synthesise(re: [Float], im: [Float]) {
        let half = size / 2
        vDSP_DFT_Execute(inverse, re, im, &evenIn, &oddIn)
        for j in 0..<half {
            timeBuffer[2 * j] = evenIn[j]
            timeBuffer[2 * j + 1] = oddIn[j]
        }
    }

    private static func roundTripScale(forward: vDSP_DFT_Setup, inverse: vDSP_DFT_Setup, size: Int) -> Float {
        let half = size / 2
        var even = [Float](repeating: 0, count: half), odd = even, re = even, im = even
        even[0] = 1
        vDSP_DFT_Execute(forward, even, odd, &re, &im)
        vDSP_DFT_Execute(inverse, re, im, &even, &odd)
        return even[0] != 0 ? 1 / even[0] : 1
    }
}

/// A fixed delay, sample by sample.
private struct DelayLine {
    private var buffer: [Float]
    private var index = 0
    init(frames: Int) { buffer = [Float](repeating: 0, count: max(frames, 0)) }
    mutating func run(_ x: Float) -> Float {
        guard !buffer.isEmpty else { return x }
        let y = buffer[index]
        buffer[index] = x
        index = (index + 1) % buffer.count
        return y
    }
}

/// The LFE: the mono sum through a 4th-order Butterworth low-pass at 120 Hz, delayed to line up with the STFT's outputs.
private final class LFEPath {
    private var sections: [(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double, z1: Double, z2: Double)]
    private var pending: [Float] = []
    private var delay: DelayLine
    private let gain: Float

    init(sampleRate: Double, gain: Float, delay frames: Int) {
        self.gain = gain
        delay = DelayLine(frames: frames)
        let w = tan(Double.pi * 120 / sampleRate)
        sections = [0.5412, 1.3066].map { q in
            let k = w * w, norm = 1 / (1 + w / q + k)
            return (k * norm, 2 * k * norm, k * norm, 2 * (k - 1) * norm, (1 - w / q + k) * norm, 0, 0)
        }
    }

    func push(_ l: [Float], _ r: [Float], from: Int, count: Int) {
        for j in from..<(from + count) {
            var x = Double(l[j] + r[j]) * 0.5
            for s in sections.indices {
                let y = sections[s].b0 * x + sections[s].z1
                sections[s].z1 = sections[s].b1 * x - sections[s].a1 * y + sections[s].z2
                sections[s].z2 = sections[s].b2 * x - sections[s].a2 * y
                x = y
            }
            pending.append(delay.run(Float(x) * gain))
        }
    }

    /// The next `count` LFE samples (silence where none were pushed).
    func take(count: Int) -> [Float] {
        let n = min(count, pending.count)
        var out = Array(pending.prefix(n))
        pending.removeFirst(n)
        if out.count < count { out += [Float](repeating: 0, count: count - out.count) }
        return out
    }
}
