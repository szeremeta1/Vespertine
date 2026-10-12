//
// Mutants of the float-stream contract (FLT-001 … FLT-005): deliberately wrong decorators over a correct
// `FloatOutput`. Each one forwards to the correct implementation it is given and changes exactly the behaviour its
// summary describes; `targets` names every requirement that change violates.
//
// None of them traps or loops without bound for input the contract allows: every index is derived from counts the
// decorator checked itself, and the base stage is only ever asked to render 1 … 4096 frames.
//

import Contracts
import SpecKit

public enum FloatMutants {
    public static let all: [Mutant<any FloatOutput>] = [
        // MARK: FLT-001: k ÷ 2^23 written to the stage comes out unchanged.
        // Every 24-bit value is also a finite value in −1.0 … +1.0, so each of these breaks FLT-002 as well.

        sampleMutant("C-FLT-001-a", ["FLT-001", "FLT-002"],
                     "clips symmetrically at ±(2^23−1)/2^23: −1.0 (k = −2^23) comes out as −(2^23−1)/2^23") {
            x, _, _, _ in
            x < -largest24 ? -largest24 : (x > largest24 ? largest24 : x)
        },
        sampleMutant("C-FLT-001-b", ["FLT-001", "FLT-002"],
                     "noise gate: samples below 2^−15 in magnitude (24-bit |k| < 256) come out as 0") {
            x, _, _, _ in
            abs(x) < gate ? 0 : x
        },
        sampleMutant("C-FLT-001-c", ["FLT-001", "FLT-002"],
                     "the last channel is rescaled for a 2^23−1 full scale: k/2^23 comes out as k/(2^23−1)") {
            x, channel, channels, _ in
            channel == channels - 1 ? Float(nearestInteger(Double(x) * 8_388_608) / 8_388_607) : x
        },
        sampleMutant("C-FLT-001-d", ["FLT-001", "FLT-002"],
                     "only 23 bits kept from 0.5 up: odd k with |k| ≥ 2^22 come out one 24-bit step nearer zero") {
            x, _, _, _ in
            let m = abs(x)
            return m >= 0.5 && m < 1 ? Float(integerPart(Double(x) * 4_194_304) / 4_194_304) : x
        },
        sampleMutant("C-FLT-001-e", ["FLT-001", "FLT-002"],
                     "from the 1 048 576th frame written on, every sample is scaled by (1 − 2^−23)") {
            x, _, _, frame in
            frame >= 1 << 20 ? x * largest24 : x
        },

        // MARK: FLT-002: any finite sample in −1.0 … +1.0 comes out unchanged.
        // These leave every k ÷ 2^23 value alone, so FLT-001 still holds.

        sampleMutant("C-FLT-002-a", ["FLT-002"],
                     "requantizes to the 24-bit grid: values finer than 2^−23 are rounded to the nearest k/2^23") {
            x, _, _, _ in
            Float(nearestInteger(Double(x) * 8_388_608) / 8_388_608)
        },
        sampleMutant("C-FLT-002-b", ["FLT-002"],
                     "clips the top at (2^23−1)/2^23: +1.0 comes out as 0.99999988 (−1.0 and every k/2^23 exact)") {
            x, _, _, _ in
            x > largest24 ? largest24 : x
        },
        sampleMutant("C-FLT-002-c", ["FLT-002"],
                     "goes through 32-bit fixed point: anything finer than 2^−31 (tiny samples) is rounded away") {
            x, _, _, _ in
            let scaled = nearestInteger(Double(x) * 2_147_483_648)
            let clamped = min(max(scaled, -2_147_483_648), 2_147_483_647)
            return Float(clamped / 2_147_483_648)
        },
        sampleMutant("C-FLT-002-d", ["FLT-002"],
                     "flushes subnormal samples (magnitude below 2^−126) to zero") {
            x, _, _, _ in
            x.isSubnormal ? 0 : x
        },

        // MARK: FLT-003: channel and order kept, nothing dropped or repeated, however writes and renders are sized.

        stageMutant("C-FLT-003-a", ["FLT-003"],
                    "with two or more channels, the first and last channel of every frame are swapped") { core in
            FHooks(write: { samples in
                let ch = core.channels
                guard ch >= 2 else { return core.write(samples) }
                var swapped = samples
                var start = 0
                while start + ch <= swapped.count {
                    swapped.swapAt(start, start + ch - 1)
                    start += ch
                }
                return core.write(swapped)
            })
        },
        stageMutant("C-FLT-003-b", ["FLT-003"],
                    "holds capacityFrames; a write that only partly fits reports one frame more than it took (lost)") {
            core in
            FHooks(write: { samples in
                // Holds exactly `capacityFrames` (allowed: at least that many go into an empty stage), so the
                // partial write happens whatever room the base has.
                let ch = core.channels
                let offered = samples.count / ch
                let fits = min(offered, core.room)
                guard fits > 0 else { return 0 }
                let taken = core.write(Array(samples.prefix(fits * ch)))
                return taken >= 1 && taken < offered ? taken + 1 : taken
            })
        },
        stageMutant("C-FLT-003-c", ["FLT-003"],
                    "the frame with index 1000 (the 1001st played) comes out twice in a row") { core in
            let target = 1000
            var copy: [Float]? = nil
            var done = false
            return FHooks(render: { frameCount in
                if core.muted { return core.render(frameCount).out }
                var out: [Float] = []
                out.reserveCapacity(frameCount * core.channels)
                var left = frameCount
                while left > 0 {
                    if let again = copy {
                        out += again
                        copy = nil
                        left -= 1
                        continue
                    }
                    let before = core.played
                    let chunk = !done && before <= target ? min(left, target + 1 - before) : left
                    let (o, data) = core.render(chunk)
                    out += o
                    left -= chunk
                    if !done && data >= 1 && before + data == target + 1 {
                        // Frame `target` is the last data frame of this chunk.
                        let start = (data - 1) * core.channels
                        copy = Array(o[start ..< start + core.channels])
                        done = true
                    }
                }
                return out
            })
        },
        stageMutant("C-FLT-003-d", ["FLT-003"],
                    "a render of an odd frame count ≥ 3 returns its first two frames in swapped order") { core in
            FHooks(render: { frameCount in
                var (out, data) = core.render(frameCount)
                if frameCount >= 3 && frameCount % 2 == 1 && data >= 2 {
                    let ch = core.channels
                    for c in 0 ..< ch { out.swapAt(c, ch + c) }
                }
                return out
            })
        },

        // MARK: FLT-004: int24ToFloat(k) is exactly k ÷ 2^23.

        convertMutant("C-FLT-004-a", ["FLT-004"],
                      "converts with a 2^23−1 full scale: k comes out as k/(2^23−1)") { _, correct in
            correct.map { Float(Double($0) * 8_388_608 / 8_388_607) }
        },
        convertMutant("C-FLT-004-b", ["FLT-004"],
                      "asymmetric scale: positive k come out as k/(2^23−1), zero and negative k are exact") {
            input, correct in
            var result = correct
            for i in 0 ..< min(result.count, input.count) where input[i] > 0 {
                result[i] = Float(Double(input[i]) / 8_388_607)
            }
            return result
        },
        convertMutant("C-FLT-004-c", ["FLT-004"],
                      "k = −2^23 comes out as −(2^23−1)/2^23, the same as k = −2^23+1") { input, correct in
            var result = correct
            for i in 0 ..< min(result.count, input.count) where input[i] == -8_388_608 { result[i] = -largest24 }
            return result
        },
        convertMutant("C-FLT-004-d", ["FLT-004"],
                      "in calls of more than 65 536 samples, every result from index 65 536 on is the previous input's") {
            _, correct in
            let chunk = 65_536
            guard correct.count > chunk else { return correct }
            var result = correct
            var i = result.count - 1
            while i >= chunk {
                result[i] = result[i - 1]
                i -= 1
            }
            return result
        },
        convertMutant("C-FLT-004-e", ["FLT-004"],
                      "k = 2^23−1 comes out as 1.0 instead of (2^23−1)/2^23") { input, correct in
            var result = correct
            for i in 0 ..< min(result.count, input.count) where input[i] == 8_388_607 { result[i] = 1 }
            return result
        },

        // MARK: FLT-005: muted or empty means silence (exact zeros), nothing consumed, and play resumes in order.

        stageMutant("C-FLT-005-a", ["FLT-005"],
                    "while muted the output is the smallest subnormal (not zero); nothing is consumed") { core in
            FHooks(render: { frameCount in
                let (out, _) = core.render(frameCount)
                return core.muted ? [Float](repeating: .leastNonzeroMagnitude, count: out.count) : out
            })
        },
        stageMutant("C-FLT-005-b", ["FLT-005"],
                    "when written frames run out, the padding has 2^−23 (one 24-bit step) on the last channel") {
            core in
            FHooks(render: { frameCount in
                var (out, data) = core.render(frameCount)
                if !core.muted {
                    let ch = core.channels
                    for frame in data ..< frameCount { out[frame * ch + ch - 1] = lsb24 }
                }
                return out
            })
        },
        stageMutant("C-FLT-005-c", ["FLT-005"],
                    "mute takes effect one render late: the first render after setMuted(true) still plays frames") {
            core in
            var lagging = false
            return FHooks(
                render: { frameCount in
                    let out = core.render(frameCount).out
                    if lagging {
                        lagging = false
                        core.setMuted(true)
                    }
                    return out
                },
                setMuted: { muted in
                    if muted {
                        if !core.muted { lagging = true }
                    } else {
                        lagging = false
                        core.setMuted(false)
                    }
                })
        },
        stageMutant("C-FLT-005-d", ["FLT-005", "FLT-003"],
                    "while muted, render outputs silence but consumes (discards) the frames it would have played") {
            core in
            FHooks(render: { frameCount in
                guard core.muted else { return core.render(frameCount).out }
                core.setMuted(false)
                _ = core.render(frameCount)
                core.setMuted(true)
                return core.silence(frameCount)
            })
        },
        stageMutant("C-FLT-005-e", ["FLT-005", "FLT-003"],
                    "every frame of silence played on underrun is made up later by skipping that many written frames") {
            core in
            var debt = 0
            return FHooks(render: { frameCount in
                if core.muted { return core.render(frameCount).out }
                while debt > 0 && core.pending > 0 {
                    let skipped = core.render(min(debt, core.pending, 4096)).data
                    if skipped == 0 { break }
                    debt -= skipped
                }
                let (out, data) = core.render(frameCount)
                debt = min(debt + frameCount - data, 1 << 24)
                return out
            })
        },
        stageMutant("C-FLT-005-f", ["FLT-005"],
                    "after setMuted(false) the first render starts with one extra frame of silence") { core in
            var gap = false
            return FHooks(
                render: { frameCount in
                    guard gap && !core.muted else { return core.render(frameCount).out }
                    gap = false
                    var out = core.silence(1)
                    if frameCount > 1 { out += core.render(frameCount - 1).out }
                    return out
                },
                setMuted: { muted in
                    gap = !muted && (core.muted || gap)
                    core.setMuted(muted)
                })
        },
    ]
}

// MARK: - Constants

/// 2^−23, one 24-bit step.
private let lsb24: Float = 1 / 8_388_608
/// (2^23 − 1) / 2^23 = 1 − 2^−23, the largest 24-bit value.
private let largest24: Float = 8_388_607 / 8_388_608
/// 2^−15 (256 24-bit steps).
private let gate: Float = 256 / 8_388_608

// Rounding without the C math library (`rounded()` needs libm, which the package does not link).

/// `v` rounded toward zero. Values of magnitude 2^52 or more are already integers and come back unchanged, as do
/// infinities and NaN.
private func integerPart(_ v: Double) -> Double {
    abs(v) < 4_503_599_627_370_496 ? Double(Int64(v)) : v
}

/// `v` rounded to the nearest integer, halves away from zero.
private func nearestInteger(_ v: Double) -> Double {
    let whole = integerPart(v)
    let fraction = v - whole
    if fraction >= 0.5 { return whole + 1 }
    if fraction <= -0.5 { return whole - 1 }
    return whole
}

// MARK: - Plumbing

/// A mutant built from hooks around a correct stage.
private func stageMutant(_ id: String, _ targets: [String], _ summary: String,
                         _ hooks: @escaping @Sendable (FCore) -> FHooks) -> Mutant<any FloatOutput> {
    Mutant(id, targets: targets, summary: summary) { base in FMutatedOutput(base: base, convert: nil, stage: hooks) }
}

/// A mutant that changes `int24ToFloat`: `change(input, correctResult)` returns what the mutant returns.
private func convertMutant(_ id: String, _ targets: [String], _ summary: String,
                           _ change: @escaping @Sendable ([Int32], [Float]) -> [Float]) -> Mutant<any FloatOutput> {
    Mutant(id, targets: targets, summary: summary) { base in FMutatedOutput(base: base, convert: change, stage: nil) }
}

/// A mutant that changes each written sample on its way into the stage:
/// `change(sample, channel, channels, frame)`, with `frame` counted from the stage's first written frame.
/// Every change used here keeps 0 as 0, so silence stays silence.
private func sampleMutant(_ id: String, _ targets: [String], _ summary: String,
                          _ change: @escaping @Sendable (Float, Int, Int, Int) -> Float) -> Mutant<any FloatOutput> {
    stageMutant(id, targets, summary) { core in
        FHooks(write: { samples in
            let ch = core.channels
            let first = core.accepted
            var changed = samples
            for i in changed.indices { changed[i] = change(changed[i], i % ch, ch, first + i / ch) }
            return core.write(changed)
        })
    }
}

/// Replacements for some of a stage's operations; the ones left nil forward to the base unchanged.
private struct FHooks {
    var write: (([Float]) -> Int)? = nil
    var render: ((Int) -> [Float])? = nil
    var setMuted: ((Bool) -> Void)? = nil
}

private struct FMutatedOutput: FloatOutput {
    let base: any FloatOutput
    let convert: (@Sendable ([Int32], [Float]) -> [Float])?
    let stage: (@Sendable (FCore) -> FHooks)?

    func int24ToFloat(samples: [Int32]) -> [Float] {
        let correct = base.int24ToFloat(samples: samples)
        guard let convert else { return correct }
        return convert(samples, correct)
    }

    func makeStage(channels: Int, capacityFrames: Int) -> any FloatStage {
        let stage = base.makeStage(channels: channels, capacityFrames: capacityFrames)
        guard let hooks = self.stage else { return stage }
        let core = FCore(base: stage, channels: channels, capacityFrames: capacityFrames)
        return FMutatedStage(core: core, hooks: hooks(core))
    }
}

/// A correct stage plus a running account of what it holds (it is correct, so the account is exact).
private final class FCore {
    let base: any FloatStage
    /// Samples per frame (at least 1 for the decorator's own arithmetic).
    let channels: Int
    let capacityFrames: Int
    /// Frames written and not yet played.
    private(set) var pending = 0
    /// Whether the base stage is muted.
    private(set) var muted = false
    /// Frames the base accepted since it was made.
    private(set) var accepted = 0
    /// Written frames the base has played since it was made.
    private(set) var played = 0

    init(base: any FloatStage, channels: Int, capacityFrames: Int) {
        self.base = base
        self.channels = max(1, channels)
        self.capacityFrames = capacityFrames
    }

    func write(_ samples: [Float]) -> Int {
        let taken = base.write(samples: samples)
        let frames = max(0, min(taken, samples.count / channels))
        pending += frames
        accepted += frames
        return taken
    }

    /// Renders from the base; `data` is how many of the returned frames are written frames (the rest is silence).
    func render(_ frameCount: Int) -> (out: [Float], data: Int) {
        let count = max(0, frameCount) * channels
        var out = base.render(frameCount: frameCount)
        if out.count != count {
            out = out.count > count ? Array(out.prefix(count))
                                    : out + [Float](repeating: 0, count: count - out.count)
        }
        let data = muted ? 0 : max(0, min(pending, frameCount))
        pending -= data
        played += data
        return (out, data)
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        base.setMuted(muted)
    }

    /// Frames that still fit if the stage held exactly `capacityFrames` (at least 1).
    var room: Int { max(0, max(1, capacityFrames) - pending) }

    func silence(_ frames: Int) -> [Float] {
        [Float](repeating: 0, count: max(0, frames) * channels)
    }
}

private final class FMutatedStage: FloatStage {
    let core: FCore
    let hooks: FHooks

    init(core: FCore, hooks: FHooks) {
        self.core = core
        self.hooks = hooks
    }

    func write(samples: [Float]) -> Int {
        guard let write = hooks.write else { return core.write(samples) }
        return write(samples)
    }

    func render(frameCount: Int) -> [Float] {
        // Outside 1 … 4096 the contract says nothing; forward unchanged.
        guard (1 ... 4096).contains(frameCount), let render = hooks.render else { return core.render(frameCount).out }
        return render(frameCount)
    }

    func setMuted(_ muted: Bool) {
        guard let setMuted = hooks.setMuted else { return core.setMuted(muted) }
        setMuted(muted)
    }
}
