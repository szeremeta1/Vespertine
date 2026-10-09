//
// Mutants of the integer-stream contract (INT-001 … INT-003): deliberately wrong decorators over a correct
// `IntegerOutput`. Each one forwards to the correct implementation it is given and changes exactly the behaviour
// its summary describes; `targets` names every requirement that change violates.
//
// None of them traps or loops without bound for input the contract allows: every index is derived from counts the
// decorator checked itself, and the base stage is only ever asked to render 1 … 4096 frames.
//

import Contracts
import SpecKit

public enum IntegerMutants {
    public static let all: [Mutant<any IntegerOutput>] = [
        // MARK: INT-001: every word comes out with all 32 bits unchanged.

        wordMutant("C-INT-001-a", ["INT-001"],
                   "signalling-NaN patterns come out quieted (bit 22 set), as if copied through a float register") {
            w, _, _, _ in
            isNaNPattern(w) && w & quietBit == 0 ? w | quietBit : w
        },
        wordMutant("C-INT-001-b", ["INT-001"],
                   "subnormal patterns (bits 30…23 clear, low 23 bits not all clear) are flushed to signed zero") {
            w, _, _, _ in
            w & exponentMask == 0 && w & mantissaMask != 0 ? w & signBit : w
        },
        wordMutant("C-INT-001-c", ["INT-001"],
                   "the negative-zero pattern 0x80000000 (Int32.min) comes out as 0x00000000") { w, _, _, _ in
            w == signBit ? 0 : w
        },
        wordMutant("C-INT-001-d", ["INT-001"],
                   "every NaN pattern comes out as the canonical quiet NaN 0x7FC00000 (sign and payload lost)") {
            w, _, _, _ in
            isNaNPattern(w) ? 0x7FC0_0000 : w
        },
        wordMutant("C-INT-001-e", ["INT-001"],
                   "the last channel loses its low 8 bits (bits 7…0 cleared, a 24-bit path)") {
            w, channel, channels, _ in
            channel == channels - 1 ? w & 0xFFFF_FF00 : w
        },
        stageMutant("C-INT-001-f", ["INT-001"],
                    "from the second write on, words go through Float: magnitudes above 2^24 lose their low bits") {
            core in
            var writes = 0
            return IHooks(write: { words in
                writes += 1
                guard writes >= 2 else { return core.write(words) }
                return core.write(words.map { w in
                    let f = Float(Int32(bitPattern: w))
                    let back: Int32 = f >= 2_147_483_648 ? .max : Int32(f)
                    return UInt32(bitPattern: back)
                })
            })
        },

        // MARK: INT-002: channel and order kept, nothing dropped or repeated, however writes and renders are sized.

        stageMutant("C-INT-002-a", ["INT-002"],
                    "with two or more channels, the channel order of every frame is reversed") { core in
            IHooks(write: { words in
                let ch = core.channels
                guard ch >= 2 else { return core.write(words) }
                var reversed = words
                var start = 0
                while start + ch <= reversed.count {
                    reversed[start ..< start + ch].reverse()
                    start += ch
                }
                return core.write(reversed)
            })
        },
        stageMutant("C-INT-002-b", ["INT-002"],
                    "holds capacityFrames; a write that only partly fits reports one frame fewer than it took (repeats)") {
            core in
            IHooks(write: { words in
                // Holds exactly `capacityFrames` (allowed: at least that many go into an empty stage), so the
                // partial write happens whatever room the base has.
                let ch = core.channels
                let offered = words.count / ch
                let wasEmpty = core.pending == 0
                let fits = min(offered, core.room)
                guard fits > 0 else { return 0 }
                let taken = core.write(Array(words.prefix(fits * ch)))
                // Never report fewer than `capacityFrames` for an empty stage, nor 0 for a stage that took frames.
                let mayUnderReport = taken >= 2 && taken < offered && (!wasEmpty || taken - 1 >= core.capacityFrames)
                return mayUnderReport ? taken - 1 : taken
            })
        },
        stageMutant("C-INT-002-c", ["INT-002"],
                    "a render of exactly 4096 frames skips its last written frame and plays the next one instead") {
            core in
            IHooks(render: { frameCount in
                guard frameCount == 4096 && !core.muted else { return core.render(frameCount).out }
                var (out, data) = core.render(frameCount)
                if data == frameCount {
                    let (next, _) = core.render(1)
                    let ch = core.channels
                    out.replaceSubrange(out.count - ch ..< out.count, with: next)
                }
                return out
            })
        },
        stageMutant("C-INT-002-d", ["INT-002"],
                    "the first two frames of the stream are played in swapped order") { core in
            var done = false
            return IHooks(write: { words in
                let ch = core.channels
                guard !done && core.accepted == 0 && words.count / ch >= 2 else { return core.write(words) }
                var swapped = words
                for c in 0 ..< ch { swapped.swapAt(c, ch + c) }
                let taken = core.write(swapped)
                if taken > 0 { done = true }
                return taken
            })
        },
        stageMutant("C-INT-002-e", ["INT-002"],
                    "once 65 536 frames have been played, every later frame comes out with its channels rotated by one") {
            core in
            IHooks(render: { frameCount in
                let before = core.played
                var (out, data) = core.render(frameCount)
                let ch = core.channels
                if ch >= 2 {
                    for frame in 0 ..< data where before + frame >= 65_536 {
                        let start = frame * ch
                        let first = out[start]
                        for c in 0 ..< ch - 1 { out[start + c] = out[start + c + 1] }
                        out[start + ch - 1] = first
                    }
                }
                return out
            })
        },

        // MARK: INT-003: muted or empty means silence (zero words), nothing consumed, and play resumes in order.

        stageMutant("C-INT-003-a", ["INT-003"],
                    "while muted the output words are 0x80000000 (−0.0 as Float32, not zero); nothing is consumed") {
            core in
            IHooks(render: { frameCount in
                let (out, _) = core.render(frameCount)
                return core.muted ? [UInt32](repeating: signBit, count: out.count) : out
            })
        },
        stageMutant("C-INT-003-b", ["INT-003"],
                    "when written frames run out, the padding has the word 1 on the last channel") { core in
            IHooks(render: { frameCount in
                var (out, data) = core.render(frameCount)
                if !core.muted {
                    let ch = core.channels
                    for frame in data ..< frameCount { out[frame * ch + ch - 1] = 1 }
                }
                return out
            })
        },
        stageMutant("C-INT-003-c", ["INT-003", "INT-002"],
                    "while muted, render outputs silence but consumes (discards) the frames it would have played") {
            core in
            IHooks(render: { frameCount in
                guard core.muted else { return core.render(frameCount).out }
                core.setMuted(false)
                _ = core.render(frameCount)
                core.setMuted(true)
                return core.silence(frameCount)
            })
        },
        stageMutant("C-INT-003-d", ["INT-003"],
                    "unmute takes effect one render late: the first render after setMuted(false) is still silent") {
            core in
            var lagging = false
            return IHooks(
                render: { frameCount in
                    let out = core.render(frameCount).out
                    if lagging {
                        lagging = false
                        core.setMuted(false)
                    }
                    return out
                },
                setMuted: { muted in
                    if muted {
                        lagging = false
                        core.setMuted(true)
                    } else if core.muted {
                        lagging = true
                    }
                })
        },
        stageMutant("C-INT-003-e", ["INT-003", "INT-002"],
                    "after a render runs out of written frames, the next frame written afterwards is skipped") {
            core in
            var owed = false
            return IHooks(render: { frameCount in
                if core.muted { return core.render(frameCount).out }
                if owed && core.pending > 0 {
                    _ = core.render(1)
                    owed = false
                }
                let (out, data) = core.render(frameCount)
                if data < frameCount { owed = true }
                return out
            })
        },
    ]
}

// MARK: - Bit patterns (read as Float32)

private let signBit: UInt32 = 0x8000_0000
private let exponentMask: UInt32 = 0x7F80_0000
private let mantissaMask: UInt32 = 0x007F_FFFF
private let quietBit: UInt32 = 0x0040_0000

private func isNaNPattern(_ w: UInt32) -> Bool {
    w & exponentMask == exponentMask && w & mantissaMask != 0
}

// MARK: - Plumbing

/// A mutant built from hooks around a correct stage.
private func stageMutant(_ id: String, _ targets: [String], _ summary: String,
                         _ hooks: @escaping @Sendable (ICore) -> IHooks) -> Mutant<any IntegerOutput> {
    Mutant(id, targets: targets, summary: summary) { base in IMutatedOutput(base: base, stage: hooks) }
}

/// A mutant that changes each written word on its way into the stage:
/// `change(word, channel, channels, frame)`, with `frame` counted from the stage's first written frame.
/// Every change used here keeps 0 as 0, so silence stays silence.
private func wordMutant(_ id: String, _ targets: [String], _ summary: String,
                        _ change: @escaping @Sendable (UInt32, Int, Int, Int) -> UInt32) -> Mutant<any IntegerOutput> {
    stageMutant(id, targets, summary) { core in
        IHooks(write: { words in
            let ch = core.channels
            let first = core.accepted
            var changed = words
            for i in changed.indices { changed[i] = change(changed[i], i % ch, ch, first + i / ch) }
            return core.write(changed)
        })
    }
}

/// Replacements for some of a stage's operations; the ones left nil forward to the base unchanged.
private struct IHooks {
    var write: (([UInt32]) -> Int)? = nil
    var render: ((Int) -> [UInt32])? = nil
    var setMuted: ((Bool) -> Void)? = nil
}

private struct IMutatedOutput: IntegerOutput {
    let base: any IntegerOutput
    let stage: @Sendable (ICore) -> IHooks

    func makeStage(channels: Int, capacityFrames: Int) -> any IntegerStage {
        let core = ICore(base: base.makeStage(channels: channels, capacityFrames: capacityFrames),
                         channels: channels, capacityFrames: capacityFrames)
        return IMutatedStage(core: core, hooks: stage(core))
    }
}

/// A correct stage plus a running account of what it holds (it is correct, so the account is exact).
private final class ICore {
    let base: any IntegerStage
    /// Words per frame (at least 1 for the decorator's own arithmetic).
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

    init(base: any IntegerStage, channels: Int, capacityFrames: Int) {
        self.base = base
        self.channels = max(1, channels)
        self.capacityFrames = capacityFrames
    }

    func write(_ words: [UInt32]) -> Int {
        let taken = base.write(words: words)
        let frames = max(0, min(taken, words.count / channels))
        pending += frames
        accepted += frames
        return taken
    }

    /// Renders from the base; `data` is how many of the returned frames are written frames (the rest is silence).
    func render(_ frameCount: Int) -> (out: [UInt32], data: Int) {
        let count = max(0, frameCount) * channels
        var out = base.render(frameCount: frameCount)
        if out.count != count {
            out = out.count > count ? Array(out.prefix(count))
                                    : out + [UInt32](repeating: 0, count: count - out.count)
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

    func silence(_ frames: Int) -> [UInt32] {
        [UInt32](repeating: 0, count: max(0, frames) * channels)
    }
}

private final class IMutatedStage: IntegerStage {
    let core: ICore
    let hooks: IHooks

    init(core: ICore, hooks: IHooks) {
        self.core = core
        self.hooks = hooks
    }

    func write(words: [UInt32]) -> Int {
        guard let write = hooks.write else { return core.write(words) }
        return write(words)
    }

    func render(frameCount: Int) -> [UInt32] {
        // Outside 1 … 4096 the contract says nothing; forward unchanged.
        guard (1 ... 4096).contains(frameCount), let render = hooks.render else { return core.render(frameCount).out }
        return render(frameCount)
    }

    func setMuted(_ muted: Bool) {
        guard let setMuted = hooks.setMuted else { return core.setMuted(muted) }
        setMuted(muted)
    }
}
