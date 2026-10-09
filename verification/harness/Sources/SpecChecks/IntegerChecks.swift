//
// Spec-traced checks for the integer-mode output stream contract (INT-001 … INT-003).
//
// Conventions used throughout:
// - The value check (INT-001) writes every word to every channel of a frame, so that a mix-up of channels cannot
//   look like a changed word; it only ever renders frames that are already written, and compares all 32 bits.
// - Order and silence checks (INT-002, INT-003) write words that identify them: bits 31…8 encode the interleaved
//   sample index as an ordinary normal-float pattern (never zero, NaN, infinity or denormal); bits 7…0 vary but are
//   ignored when decoding, so that a change of low bits cannot look like a misplaced word. Silence is a frame whose
//   words all equal zero.
// - While at least `frameCount` written frames are waiting and the stage is not muted, `render` must return
//   exactly the next `frameCount` frames. When fewer are waiting, a render may return any of them in order mixed
//   with silent frames (the records leave open how a short render is filled).
//

import Contracts
import SpecKit

public enum IntegerChecks {
    public static let all: [SpecCheck<any IntegerOutput>] = [
        // REQ: INT-001
        SpecCheck("INT-001: special words (NaN, infinity, ±0, denormal, extremes, single bits) on every channel of 1…8-channel stages",
                  requirements: ["INT-001"]) { subject, checker in
            istCheckSpecialWords(subject, checker)
        },
        // REQ: INT-001
        SpecCheck("INT-001: sweeps over every float exponent, every byte value in every byte, on every channel",
                  requirements: ["INT-001"]) { subject, checker in
            istCheckSweeps(subject, checker)
        },
        // REQ: INT-001
        SpecCheck("INT-001: all 2^16 high halves, and all 2^16 low halves under NaN, infinity, denormal and other high halves",
                  requirements: ["INT-001"]) { subject, checker in
            istCheckHalves(subject, checker)
        },
        // REQ: INT-001
        SpecCheck("INT-001: pseudo-random words",
                  requirements: ["INT-001"]) { subject, checker in
            istCheckRandomWords(subject, checker)
        },
        // REQ: INT-002
        SpecCheck("INT-002: fixed write/render size patterns on 1…8-channel stages",
                  requirements: ["INT-002"]) { subject, checker in
            istCheckOrderPatterns(subject, checker)
        },
        // REQ: INT-002
        SpecCheck("INT-002: pseudo-random write and render sizes on 1…4-channel stages",
                  requirements: ["INT-002"]) { subject, checker in
            istCheckOrderRandom(subject, checker, channels: 1...4, seed: 0x1A7_0002_0001)
        },
        // REQ: INT-002
        SpecCheck("INT-002: pseudo-random write and render sizes on 5…8-channel stages",
                  requirements: ["INT-002"]) { subject, checker in
            istCheckOrderRandom(subject, checker, channels: 5...8, seed: 0x1A7_0002_0002)
        },
        // REQ: INT-003
        SpecCheck("INT-003: no written words left: silence, nothing consumed, then the next written frame",
                  requirements: ["INT-003"]) { subject, checker in
            istCheckSilenceWhenEmpty(subject, checker)
        },
        // REQ: INT-003
        SpecCheck("INT-003: muted: zero words on every channel, nothing consumed, then the next frame not yet played",
                  requirements: ["INT-003"]) { subject, checker in
            istCheckSilenceWhenMuted(subject, checker)
        },
        // REQ: INT-003
        SpecCheck("INT-003: pseudo-random schedules with mute toggles and underruns",
                  requirements: ["INT-003"]) { subject, checker in
            istCheckSilenceRandom(subject, checker)
        },
    ]
}

// MARK: - Deterministic pseudo-random numbers (SplitMix64)

fileprivate struct IstRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 ..< n (0 when n <= 1).
    mutating func below(_ n: Int) -> Int {
        n <= 1 ? 0 : Int(truncatingIfNeeded: next() % UInt64(n))
    }

    /// lo ... hi (lo when hi <= lo).
    mutating func inRange(_ lo: Int, _ hi: Int) -> Int {
        hi <= lo ? lo : lo + below(hi - lo + 1)
    }

    mutating func percent(_ p: Int) -> Bool { below(100) < p }

    mutating func word() -> UInt32 { UInt32(truncatingIfNeeded: next() >> 17) }
}

fileprivate func istHex(_ w: UInt32) -> String {
    let s = String(w, radix: 16)
    return "0x" + String(repeating: "0", count: max(0, 8 - s.count)) + s
}

/// `words` in a pseudo-random order (Fisher–Yates), so that neighbouring words are unrelated.
fileprivate func istShuffled(_ words: [UInt32], seed: UInt64) -> [UInt32] {
    var v = words
    var rng = IstRandom(seed: seed)
    var i = v.count - 1
    while i > 0 {
        v.swapAt(i, rng.below(i + 1))
        i -= 1
    }
    return v
}

// MARK: - Words

/// Words that would be special if read as Float32, or are extremes as Int32, or simple bit patterns.
fileprivate let istSpecialWords: [UInt32] = {
    var w: [UInt32] = [
        0x0000_0000, 0x8000_0000,                                      // +0, −0 (also Int32.min)
        0x0000_0001, 0x8000_0001, 0x007F_FFFF, 0x807F_FFFF,            // denormals
        0x0040_0000, 0x8040_0000, 0x0000_00FF, 0x0000_FFFF, 0x0012_3456, 0x8012_3456, 0x0000_0100,
        0x0080_0000, 0x8080_0000, 0x0080_0001,                         // smallest normals
        0x7F7F_FFFF, 0xFF7F_FFFF,                                      // largest finite
        0x7F80_0000, 0xFF80_0000,                                      // ±infinity
        0x7F80_0001, 0xFF80_0001, 0x7FBF_FFFF, 0xFFBF_FFFF, 0x7FA0_0000, 0xFFA0_0000,  // signalling NaNs
        0x7F80_0100, 0x7FA5_A5A5, 0xFF80_00FF, 0x7F81_2345, 0xFF9A_BCDE,
        0x7FC0_0000, 0xFFC0_0000, 0x7FC0_0001, 0xFFC0_0001, 0x7FFF_FFFF, 0xFFFF_FFFF,  // quiet NaNs
        0x7FE0_0000, 0xFFD5_5555, 0x7FC1_2345,
        0x3F80_0000, 0xBF80_0000, 0x3F7F_FFFF, 0x4B00_0000, 0x4B7F_FFFF, 0xCB00_0000,  // ordinary floats
        0x7FFF_FFFE, 0x8000_0002, 0x0000_0002, 0xFFFF_FFFE,           // Int32 extremes and neighbours
        0x00FF_FFFF, 0xFF00_0000, 0x7FFF_FF00, 0x8000_0100, 0xFFFF_FF00, 0x0100_0000, 0xFEFF_FFFF,
        0x0080_0000, 0xFF80_0000, 0x007F_FF00, 0xFF7F_FF00,           // 24-bit boundaries in the high bits
        0x1234_5678, 0x8765_4321, 0xDEAD_BEEF, 0x5555_5555, 0xAAAA_AAAA, 0x0F0F_0F0F, 0xF0F0_F0F0,
        0x3333_3333, 0xCCCC_CCCC, 0x0101_0101, 0x8080_8080, 0x7F7F_7F7F, 0xFEFE_FEFE,
    ]
    for b in 0..<32 {
        let bit = UInt32(1) << UInt32(b)
        w.append(bit)
        w.append(~bit)
        w.append(bit | 0x7F80_0000)  // infinity or NaN with one more bit
    }
    return w
}()

/// Every float exponent with assorted significands, both signs; and every byte value in every byte position.
fileprivate let istSweepWords: [UInt32] = {
    var w: [UInt32] = []
    let significands: [UInt32] = [0, 1, 2, 0x3F_FFFF, 0x40_0000, 0x40_0001, 0x7F_FFFE, 0x7F_FFFF,
                                  0x2A_AAAA, 0x55_5555, 0x00_0100, 0x7F_FF00]
    for e in UInt32(0)...255 {
        for m in significands {
            w.append(e << 23 | m)
            w.append(0x8000_0000 | e << 23 | m)
        }
    }
    let bases: [UInt32] = [0x0000_0000, 0xFFFF_FFFF, 0x7F80_0000, 0x8000_0000, 0x7FC0_0000]
    for b in 0..<4 {
        let shift = UInt32(8 * b)
        for v in UInt32(0)...255 {
            for base in bases {
                w.append((base & ~(0xFF << shift)) | v << shift)
            }
        }
    }
    return w
}()

// MARK: - Value runs (INT-001)

/// Writes `values` through a fresh stage, one word per frame on every channel, and checks that every word comes
/// out with all 32 bits unchanged. Only renders frames that are already written. The first frame is a substantial
/// leader word, so that a stage that is silent at first is seen to be late, not to change bits.
fileprivate func istValueRun(_ subject: any IntegerOutput, _ checker: Checker, values body: [UInt32], channels: Int,
                             capacity: Int, writeSizes: [Int], renderSizes: [Int], label: String) {
    guard !body.isEmpty, !writeSizes.isEmpty, !renderSizes.isEmpty, channels >= 1, capacity >= 1 else { return }
    let values = [0x3F81_2345] + body
    let stage = subject.makeStage(channels: channels, capacityFrames: capacity)
    let where_ = "\(label) [\(channels) ch, capacity \(capacity)]"
    let total = values.count
    var written = 0
    var played = 0
    var step = 0
    var asserted = false
    let maxSteps = 3 * total + 1000
    while played < total && step < maxSteps {
        let ws = max(1, writeSizes[step % writeSizes.count])
        let rs = max(1, renderSizes[step % renderSizes.count])
        step += 1
        if written < total && written - played < capacity {
            // Never more than the free space, so that how a stage takes part of a write (INT-002) stays out of it.
            let n = min(ws, total - written, capacity - (written - played))
            let buf: [UInt32]
            if channels == 1 {
                buf = Array(values[written..<(written + n)])
            } else {
                var b = [UInt32]()
                b.reserveCapacity(n * channels)
                for f in 0..<n {
                    let v = values[written + f]
                    for _ in 0..<channels { b.append(v) }
                }
                buf = b
            }
            let accepted = max(0, min(stage.write(words: buf), n))
            // An empty stage that takes nothing leaves no word to check (not a matter of bits).
            if accepted == 0 && written == played { break }
            written += accepted
        }
        let pending = written - played
        guard pending > 0 else { continue }
        let n = min(rs, pending, 4096)
        let out = stage.render(frameCount: n)
        // A render of the wrong length cannot be lined up with frames (not a matter of bits).
        guard out.count == n * channels else { break }
        var bad = 0
        var firstBad = -1
        if channels != 1 || out != Array(values[played..<(played + n)]) {
            var i = 0
            for f in 0..<n {
                let v = values[played + f]
                for _ in 0..<channels {
                    if out[i] != v {
                        bad += 1
                        if firstBad < 0 { firstBad = i }
                    }
                    i += 1
                }
            }
        }
        if bad > 0 && istOnlyMoved(out, values: values, played: played, written: written, channels: channels) {
            // The written words all came out, only not where they belong, or nothing came out at all: a matter
            // of order or timing (INT-002, INT-003) that leaves this run unable to say more about bits.
            break
        }
        asserted = true
        checker.expect(bad == 0, "INT-001", {
            let f = firstBad / channels
            let c = firstBad % channels
            return "\(where_): \(bad) of \(n * channels) words changed in render(frameCount: \(n)); "
                + "first: frame \(played + f) channel \(c) wrote \(istHex(values[played + f])), "
                + "got \(istHex(out[firstBad]))"
        }())
        played += n
    }
    if !asserted {
        checker.expect(true, "INT-001", "\(where_): no frame could be compared in place")
    }
}

/// A word no plausible change of bits turns into zero: every byte non-zero and an ordinary float exponent.
fileprivate func istSubstantial(_ w: UInt32) -> Bool {
    let e = (w >> 23) & 0xFF
    return e != 0 && e != 0xFF && w & 0xFF != 0 && w & 0xFF00 != 0 && w & 0xFF_0000 != 0 && w & 0xFF00_0000 != 0
}

/// Whether a render that differs from frames `played…` holds only written words that were moved: every
/// differing word equals a word written within two frames of its place, or the render holds exactly the expected
/// words in another order; or whether nothing came out: the whole render is zero although a substantial word was
/// due. Any other word means changed bits.
fileprivate func istOnlyMoved(_ out: [UInt32], values: [UInt32], played: Int, written: Int, channels: Int) -> Bool {
    let n = out.count / channels
    var allZero = true
    for x in out where x != 0 {
        allZero = false
        break
    }
    if allZero {
        for f in 0..<n where istSubstantial(values[played + f]) { return true }
        return false
    }
    var neighbours = true
    var i = 0
    for f in 0..<n {
        let here = played + f
        for _ in 0..<channels {
            let x = out[i]
            i += 1
            if x == values[here] { continue }
            var found = false
            for j in max(0, here - 2)...min(written - 1, here + 2) where values[j] == x {
                found = true
                break
            }
            if !found { neighbours = false }
        }
    }
    if neighbours { return true }
    var expected = [UInt32]()
    expected.reserveCapacity(out.count)
    for f in 0..<n {
        for _ in 0..<channels { expected.append(values[played + f]) }
    }
    return out.sorted() == expected.sorted()
}

fileprivate let istValueConfigs: [(capacity: Int, writes: [Int], renders: [Int])] = [
    (4096, [4096], [4096]),
    (1, [1, 2], [1]),
    (5, [3, 5], [2, 5, 1]),
    (64, [64, 13], [64, 1, 30]),
    (1000, [999, 2, 1000], [4096, 3, 600]),
    (5000, [4096, 5000, 17], [4096, 13, 4095]),
]

fileprivate func istCheckSpecialWords(_ subject: any IntegerOutput, _ checker: Checker) {
    let words = istShuffled(istSpecialWords, seed: 0x1A7_0001_0001)
    // Several copies in different orders, so that every word meets every position of a short render.
    var values = words
    values += istShuffled(words, seed: 0x1A7_0001_0002)
    values += words.reversed()
    for channels in 1...8 {
        for cfg in istValueConfigs {
            istValueRun(subject, checker, values: values, channels: channels, capacity: cfg.capacity,
                        writeSizes: cfg.writes, renderSizes: cfg.renders, label: "special words")
        }
    }
}

fileprivate func istCheckSweeps(_ subject: any IntegerOutput, _ checker: Checker) {
    let values = istShuffled(istSweepWords, seed: 0x1A7_0001_0003)
    for channels in 1...8 {
        for (j, cfg) in istValueConfigs.enumerated() where (j + channels) % 2 == 0 || j == 0 {
            istValueRun(subject, checker, values: values, channels: channels, capacity: cfg.capacity,
                        writeSizes: cfg.writes, renderSizes: cfg.renders, label: "exponent and byte sweeps")
        }
    }
}

fileprivate func istCheckHalves(_ subject: any IntegerOutput, _ checker: Checker) {
    // Every high half (sign, exponent and top of significand), with a varying low half.
    var high = [UInt32](repeating: 0, count: 1 << 16)
    for h in 0..<(1 << 16) {
        let hi = UInt32(h)
        high[h] = hi << 16 | ((hi &* 0x9E37) ^ 0x5A5A) & 0xFFFF
    }
    istValueRun(subject, checker, values: istShuffled(high, seed: 0x1A7_0001_0004), channels: 1, capacity: 4096,
                writeSizes: [4096, 4093, 7], renderSizes: [4096, 1, 4095, 512], label: "every high half")
    istValueRun(subject, checker, values: high, channels: 2, capacity: 3000,
                writeSizes: [3000, 1], renderSizes: [2999, 4096, 2], label: "every high half, in order")
    // Every low half (bottom of significand) under high halves that make NaNs, infinities, denormals, ±0 and
    // Int32 extremes.
    let tops: [UInt32] = [0x0000, 0x8000, 0x7F80, 0xFF80, 0x7FC0, 0xFFC0, 0x007F, 0x807F, 0x7FBF, 0xFFBF,
                          0x7FFF, 0xFFFF]
    var low = [UInt32](repeating: 0, count: tops.count << 16)
    var i = 0
    for top in tops {
        for l in 0..<(1 << 16) {
            low[i] = top << 16 | UInt32(l)
            i += 1
        }
    }
    istValueRun(subject, checker, values: istShuffled(low, seed: 0x1A7_0001_0005), channels: 1, capacity: 4096,
                writeSizes: [4096, 2048, 3], renderSizes: [4096, 4096, 1, 1000], label: "every low half")
}

fileprivate func istCheckRandomWords(_ subject: any IntegerOutput, _ checker: Checker) {
    var rng = IstRandom(seed: 0x1A7_0001_0006)
    var mono = [UInt32](repeating: 0, count: 500_000)
    for i in 0..<mono.count { mono[i] = rng.word() }
    istValueRun(subject, checker, values: mono, channels: 1, capacity: 4096,
                writeSizes: [4096, 1, 4000, 77], renderSizes: [4096, 4096, 3, 1000], label: "pseudo-random words")
    for (channels, count) in [(2, 100_000), (3, 50_000), (6, 20_000), (8, 20_000)] {
        var vs = [UInt32](repeating: 0, count: count)
        for i in 0..<count { vs[i] = rng.word() }
        istValueRun(subject, checker, values: vs, channels: channels, capacity: 2048,
                    writeSizes: [2048, 999, 5], renderSizes: [1024, 2047, 1, 4096], label: "pseudo-random words")
    }
}

// MARK: - Identity streams (INT-002, INT-003)

/// Identities: interleaved sample index modulo 2^23.
fileprivate let istIdPeriod = 1 << 23

/// The word written for interleaved sample index `index`: bit 31 and bits 22…8 carry the identity, bits 30…23
/// hold an exponent from 0x40 to 0xBF (an ordinary float, never zero), bits 7…0 vary and are ignored.
fileprivate func istIdWord(_ index: Int) -> UInt32 {
    let j = UInt32(truncatingIfNeeded: index % istIdPeriod)
    let low15 = j & 0x7FFF
    let high7 = (j >> 15) & 0x7F
    let sign = (j >> 22) & 1
    let lowByte = (j &* 0x9D &+ 0x5B) & 0xFF
    return sign << 31 | (0x40 + high7) << 23 | low15 << 8 | lowByte
}

/// The identity a word decodes to, or −1. Bits 7…0 are ignored, so a change of low bits does not change it.
fileprivate func istIdOf(_ w: UInt32) -> Int {
    let e: UInt32 = (w >> 23) & 0xFF
    guard e >= 0x40 && e <= 0xBF else { return -1 }
    let sign: UInt32 = (w >> 31) << 22
    let high: UInt32 = (e - 0x40) << 15
    let low: UInt32 = (w >> 8) & 0x7FFF
    return Int(sign | high | low)
}

fileprivate enum IstOp {
    case write(Int)
    case render(Int)
    /// Render exactly the frames still waiting (at most 4096), or one frame when none wait.
    case renderPending
    case mute
    case unmute
}

/// Drives one fresh stage with identity words and follows what must come out.
///
/// With `order`, asserts INT-002: while at least `frameCount` written frames wait, render returns exactly the next
/// ones; in a shorter render every non-silent frame is the next written frame; nothing played comes out again.
/// With `silence`, asserts INT-003: muted renders and renders with nothing waiting are all zero words, and so is
/// the rest of a render once the last waiting frame has come out; after such silence the next frame out is the
/// next one not yet played; frames waiting while muted all still come out. Anything else that goes wrong only
/// ends the scenario.
fileprivate final class IstStream {
    let stage: any IntegerStage
    let channels: Int
    let checker: Checker
    let order: Bool
    let silence: Bool
    let label: String
    private(set) var written = 0
    private(set) var played = 0
    private(set) var muted = false
    private(set) var aborted = false
    /// Silence came out (or the stage is fresh) since a frame was last played.
    private var resume = true
    /// Frames below this index were waiting during a muted render.
    private var protectedUpTo = 0
    private var renders = 0
    /// Every word accepted so far, interleaved, in the order written.
    private var sent: [UInt32] = []

    init(_ subject: any IntegerOutput, _ checker: Checker, channels: Int, capacity: Int,
         order: Bool, silence: Bool, label: String) {
        self.stage = subject.makeStage(channels: channels, capacityFrames: capacity)
        self.channels = channels
        self.checker = checker
        self.order = order
        self.silence = silence
        self.label = "\(label) [\(channels) ch, capacity \(capacity)]"
    }

    var pending: Int { written - played }

    private func expectedId(_ frame: Int, _ c: Int) -> Int { (frame * channels + c) % istIdPeriod }

    private func at(_ n: Int) -> String { "\(label), render #\(renders) (frameCount \(n))" }

    /// Output frame `f` is written frame `src`, channel for channel.
    private func frameMatches(_ out: [UInt32], _ f: Int, _ src: Int) -> Bool {
        let base = f * channels
        for c in 0..<channels where istIdOf(out[base + c]) != expectedId(src, c) { return false }
        return true
    }

    /// Output frame `f` holds only words of written frame `src`, in whatever channel. Silence checks follow frames
    /// this way, so that a channel mix-up (an INT-002 matter) does not look like a wrong frame.
    private func frameIs(_ out: [UInt32], _ f: Int, _ src: Int) -> Bool {
        let base = f * channels
        let first = expectedId(src, 0)
        for c in 0..<channels {
            let id = istIdOf(out[base + c])
            guard id >= first && id < first + channels else { return false }
        }
        return true
    }

    /// The matching rule for this stream: exact channels when it checks order, frame identity otherwise.
    private func matches(_ out: [UInt32], _ f: Int, _ src: Int) -> Bool {
        order ? frameMatches(out, f, src) : frameIs(out, f, src)
    }

    private func frameSilent(_ out: [UInt32], _ f: Int) -> Bool {
        let base = f * channels
        for c in 0..<channels where out[base + c] != 0 { return false }
        return true
    }

    /// Index of the first word in `out[from...]` that is not zero, or −1.
    private func firstNonZero(_ out: [UInt32], from: Int = 0) -> Int {
        var i = from
        while i < out.count {
            if out[i] != 0 { return i }
            i += 1
        }
        return -1
    }

    /// Whether `out[0 ..< frames × channels]` holds exactly the words written for frames `src ..< src + frames`
    /// (fast path; a mismatch is then examined word by word).
    private func exactlyWritten(_ out: [UInt32], src: Int, frames: Int) -> Bool {
        let count = frames * channels
        let a = src * channels
        guard a >= 0, a + count <= sent.count, count <= out.count else { return false }
        if count == out.count { return out == Array(sent[a..<(a + count)]) }
        return Array(out[0..<count]) == Array(sent[a..<(a + count)])
    }

    /// The already played frame (below `playedSoFar`) that output frame `f` repeats, if it is one.
    private func repeatedFrame(_ out: [UInt32], _ f: Int, playedSoFar: Int) -> Int? {
        guard written * channels <= istIdPeriod else { return nil }
        let j = istIdOf(out[f * channels])
        guard j >= 0, j % channels == 0 else { return nil }
        let src = j / channels
        guard src < playedSoFar, frameMatches(out, f, src) else { return nil }
        return src
    }

    private func show(_ out: [UInt32], _ f: Int) -> String {
        let base = f * channels
        let shown = (0..<min(channels, 4)).map { istHex(out[base + $0]) }
        return "[" + shown.joined(separator: ", ") + (channels > 4 ? ", …]" : "]")
    }

    private func showWritten(_ src: Int) -> String {
        let shown = (0..<min(channels, 4)).map { istHex(istIdWord(src * channels + $0)) }
        return "[" + shown.joined(separator: ", ") + (channels > 4 ? ", …]" : "]")
    }

    @discardableResult
    func write(_ frames: Int) -> Int {
        guard !aborted, frames > 0 else { return 0 }
        let base = written * channels
        let count = frames * channels
        var buf = [UInt32](repeating: 0, count: count)
        for s in 0..<count { buf[s] = istIdWord(base + s) }
        let accepted = max(0, min(stage.write(words: buf), frames))
        written += accepted
        sent.append(contentsOf: buf[0..<(accepted * channels)])
        return accepted
    }

    func setMuted(_ m: Bool) {
        guard !aborted else { return }
        stage.setMuted(m)
        muted = m
    }

    func render(_ n: Int) {
        guard !aborted, n >= 1, n <= 4096 else { return }
        renders += 1
        let out = stage.render(frameCount: n)
        guard out.count == n * channels else {
            if order {
                checker.expect(false, "INT-002",
                               "\(at(n)): returned \(out.count) words instead of \(n * channels)")
            }
            if silence {
                checker.expect(false, "INT-003",
                               "\(at(n)): returned \(out.count) words instead of \(n * channels)")
            }
            aborted = true
            return
        }
        if muted {
            renderSilent(out, n, why: "muted")
            protectedUpTo = written
            return
        }
        let p = pending
        if p == 0 {
            renderSilent(out, n, why: "no written frames remain")
        } else if p >= n {
            renderFull(out, n)
        } else {
            renderShort(out, n, p)
        }
    }

    private func renderSilent(_ out: [UInt32], _ n: Int, why: String) {
        let firstLoud = firstNonZero(out)
        if silence {
            checker.expect(firstLoud < 0, "INT-003",
                           "\(at(n)), \(why): word \(firstLoud) (frame \(firstLoud / channels), channel "
                           + "\(firstLoud % channels)) is \(firstLoud >= 0 ? istHex(out[firstLoud]) : ""), "
                           + "expected zero")
            if firstLoud >= 0 {
                aborted = true
                return
            }
        }
        if order && firstLoud >= 0 {
            for f in (firstLoud / channels)..<n where !frameSilent(out, f) {
                if let src = repeatedFrame(out, f, playedSoFar: played) {
                    checker.expect(false, "INT-002",
                                   "\(at(n)), \(why): output frame \(f) repeats frame \(src), played already")
                    aborted = true
                    return
                }
            }
        }
        resume = true
    }

    private func renderFull(_ out: [UInt32], _ n: Int) {
        var bad = -1
        if !exactlyWritten(out, src: played, frames: n) {
            for f in 0..<n where !matches(out, f, played + f) {
                bad = f
                break
            }
        }
        if silence {
            var reported = false
            if resume {
                checker.expect(bad != 0, "INT-003",
                               "\(at(n)): after silence the next frame out must be frame \(played), the next not yet "
                               + "played, \(showWritten(played)); got \(bad == 0 ? show(out, 0) : "")")
                reported = bad == 0
            }
            if played < protectedUpTo && !reported {
                let ok = bad < 0 || played + bad >= protectedUpTo
                checker.expect(ok, "INT-003",
                               "\(at(n)): frame \(played + max(bad, 0)) was waiting while muted, so it must still come "
                               + "out next, \(showWritten(played + max(bad, 0))); got "
                               + "\(bad >= 0 ? show(out, bad) : "")")
            }
        }
        if bad < 0 {
            if order { checker.expect(true, "INT-002", "\(at(n)): frames \(played)… in order") }
            played += n
            resume = false
            return
        }
        if order {
            checker.expect(false, "INT-002",
                           "\(at(n)) with \(pending) frames waiting: output frame \(bad) should be written frame "
                           + "\(played + bad) \(showWritten(played + bad)); got \(show(out, bad))")
        }
        aborted = true
    }

    private func renderShort(_ out: [UInt32], _ n: Int, _ p: Int) {
        var consumed = 0
        var silentTail = false
        if firstNonZero(out) < 0 {
            // All silence: nothing came out.
        } else if exactlyWritten(out, src: played, frames: p) && firstNonZero(out, from: p * channels) < 0 {
            consumed = p  // every waiting frame, then silence
            silentTail = true
        } else {
            scanShort(out, n, p, &consumed, &silentTail)
            if aborted { return }
        }
        if silence && consumed > 0 && resume {
            checker.expect(true, "INT-003", "\(at(n)): resumed at frame \(played)")
        }
        if silence && consumed == p && silentTail {
            checker.expect(true, "INT-003", "\(at(n)): silence after the last waiting frame")
        }
        if silence && played < protectedUpTo && consumed > 0 {
            checker.expect(true, "INT-003", "\(at(n)): frames waiting while muted came out")
        }
        if order && consumed > 0 {
            checker.expect(true, "INT-002", "\(at(n)): frames \(played)… in order")
        }
        played += consumed
        if consumed > 0 { resume = false }
        if consumed == p && silentTail { resume = true }
    }

    /// Frame-by-frame reading of a short render: silent frames are skipped, every other frame must be the next
    /// waiting frame, and once none wait, the rest must be zero (INT-003) and must not repeat (INT-002).
    private func scanShort(_ out: [UInt32], _ n: Int, _ p: Int, _ consumed: inout Int, _ silentTail: inout Bool) {
        for f in 0..<n {
            let silent = frameSilent(out, f)
            if consumed < p {
                if silent { continue }
                if matches(out, f, played + consumed) {
                    consumed += 1
                    continue
                }
                let src = played + consumed
                if silence && consumed == 0 && resume {
                    checker.expect(false, "INT-003",
                                   "\(at(n)): after silence the next frame out must be frame \(src), the next not "
                                   + "yet played, \(showWritten(src)); output frame \(f) is \(show(out, f))")
                } else if silence && src < protectedUpTo {
                    checker.expect(false, "INT-003",
                                   "\(at(n)): frame \(src) was waiting while muted, so it must still come out next, "
                                   + "\(showWritten(src)); output frame \(f) is \(show(out, f))")
                }
                if order {
                    checker.expect(false, "INT-002",
                                   "\(at(n)) with \(p) frames waiting: output frame \(f) is neither silence nor the "
                                   + "next written frame \(src) \(showWritten(src)); got \(show(out, f))")
                }
                aborted = true
                return
            }
            if silent {
                silentTail = true
                continue
            }
            if silence {
                checker.expect(false, "INT-003",
                               "\(at(n)): all \(p) waiting frames came out, so output frame \(f) must be zero words; "
                               + "got \(show(out, f))")
                aborted = true
                return
            }
            if order, let src = repeatedFrame(out, f, playedSoFar: played + consumed) {
                checker.expect(false, "INT-002",
                               "\(at(n)): output frame \(f) repeats frame \(src), played already")
                aborted = true
                return
            }
        }
    }

    func run(_ op: IstOp) {
        switch op {
        case .write(let n): write(n)
        case .render(let n): render(n)
        case .renderPending: render(max(1, min(pending, 4096)))
        case .mute: setMuted(true)
        case .unmute: setMuted(false)
        }
    }

    /// Unmutes, plays every waiting frame with renders that are never short, then renders once more on the
    /// empty stage. For order streams, also requires that some frames were accepted at all.
    func finish() {
        if muted { setMuted(false) }
        var guardCount = 0
        while !aborted && pending > 0 && guardCount < 20_000 {
            render(min(pending, 4096))
            guardCount += 1
        }
        render(64)
        if order && !aborted {
            checker.expect(written > 0 && played == written, "INT-002",
                           "\(label): \(played) of \(written) written frames came out (the stage must accept frames)")
        }
    }
}

// MARK: - INT-002

fileprivate let istOrderPatterns: [(capacity: Int, ops: [IstOp], times: Int)] = [
    (1, [.write(1), .render(1)], 12),
    (1, [.write(3), .render(1), .render(1), .render(2), .renderPending], 6),
    (2, [.write(2), .render(1), .write(1), .render(2), .write(2), .render(2)], 8),
    (3, [.write(2), .render(2), .write(3), .render(1), .render(2)], 8),
    (7, [.write(5), .render(3), .write(5), .render(3), .write(5), .render(4), .write(7), .renderPending], 6),
    (64, [.write(64)] + Array(repeating: IstOp.render(1), count: 64), 2),
    (64, Array(repeating: IstOp.write(1), count: 64) + [.render(64)], 3),
    (100, [.write(150), .render(64), .write(100), .render(64), .render(64)], 5),
    (300, [.write(150)]
        + Array(repeating: [IstOp.write(37), .render(37)], count: 40).flatMap { $0 }
        + Array(repeating: [IstOp.write(64), .render(50)], count: 15).flatMap { $0 }
        + Array(repeating: [IstOp.write(50), .render(64)], count: 20).flatMap { $0 }, 1),
    (4096, [.write(4096), .render(4096)], 4),
    (4096, [.write(4096), .render(4095), .write(4096), .render(4096), .render(1)], 2),
    (5000, [.write(5000), .render(4096), .write(4096), .render(4096), .render(4096)], 2),
    (1000, [.write(3000), .render(1000), .write(3000), .render(999), .render(1)], 3),
    (64, [.write(10), .render(16), .write(10), .render(16), .write(20), .render(4096), .write(64), .render(100),
          .renderPending], 3),
    (4097, [.write(4097), .render(4096), .render(1), .write(1), .render(4096), .write(4097), .render(4096),
            .write(3), .render(4)], 2),
    (13, [.write(13), .render(5), .write(5), .render(13), .write(13), .render(2), .render(11), .write(1),
          .render(3)], 7),
]

fileprivate func istCheckOrderPatterns(_ subject: any IntegerOutput, _ checker: Checker) {
    for channels in 1...8 {
        for (i, pattern) in istOrderPatterns.enumerated() {
            let s = IstStream(subject, checker, channels: channels, capacity: pattern.capacity,
                              order: true, silence: false, label: "pattern \(i)")
            for _ in 0..<pattern.times {
                for op in pattern.ops { s.run(op) }
            }
            s.finish()
        }
    }
}

fileprivate func istRandomWriteSize(_ rng: inout IstRandom, capacity: Int) -> Int {
    switch rng.below(100) {
    case ..<25: return rng.inRange(1, 4)
    case ..<45: return rng.inRange(1, capacity)
    case ..<57: return capacity
    case ..<65: return max(1, capacity + rng.inRange(-1, 1))
    case ..<80: return rng.inRange(1, min(2 * capacity + 8, 5000))
    default: return rng.inRange(1, 64)
    }
}

fileprivate func istRandomRenderSize(_ rng: inout IstRandom, pending: Int) -> Int {
    let n: Int
    switch rng.below(100) {
    case ..<20: n = rng.inRange(1, 4)
    case ..<40: n = rng.inRange(1, 64)
    case ..<55: n = pending
    case ..<65: n = pending + rng.inRange(-1, 1)
    case ..<72: n = 4096
    default: n = rng.inRange(1, 4096)
    }
    return min(max(n, 1), 4096)
}

fileprivate func istCheckOrderRandom(_ subject: any IntegerOutput, _ checker: Checker,
                                     channels: ClosedRange<Int>, seed: UInt64) {
    var rng = IstRandom(seed: seed)
    let capacities = [1, 3, 16, 100, 1000, 4096, 6000]
    for ch in channels {
        for capacity in capacities {
            let s = IstStream(subject, checker, channels: ch, capacity: capacity,
                              order: true, silence: false, label: "random schedule")
            for _ in 0..<160 {
                if s.aborted { break }
                if rng.percent(50) {
                    s.write(istRandomWriteSize(&rng, capacity: capacity))
                } else {
                    s.render(istRandomRenderSize(&rng, pending: s.pending))
                }
            }
            s.finish()
        }
    }
}

// MARK: - INT-003

fileprivate let istEmptyScenarios: [(capacity: Int, ops: [IstOp])] = [
    (64, [.render(1), .render(3), .render(4096), .render(2), .write(10), .render(4), .render(6), .render(5),
          .write(20), .render(20), .render(1), .write(3), .render(3)]),
    (64, [.write(10), .render(25), .render(25), .write(30), .render(30), .render(1), .write(5), .render(4096),
          .render(4096), .write(64), .render(64)]),
    (8, Array(repeating: [IstOp.write(1), .render(2), .write(3), .render(3), .render(1), .write(2), .render(1),
                          .write(8), .render(5), .render(5), .write(4), .render(4096), .write(8), .render(8)],
              count: 4).flatMap { $0 }),
    (1, [.render(1), .write(1), .render(1), .render(1), .write(1), .render(2), .write(2), .render(1), .render(1),
         .render(4096), .write(1), .render(1)]),
    (4096, [.write(4096), .render(4096), .render(1), .write(1), .render(1), .render(4096), .write(4096),
            .render(4095), .render(2), .write(100), .render(100)]),
    (100, [.write(12), .render(12), .render(1), .write(12), .render(12), .render(4096), .write(100), .render(99),
           .render(1), .render(7), .write(1), .render(4096), .write(50), .render(50)]),
]

fileprivate let istMuteScenarios: [(capacity: Int, ops: [IstOp])] = [
    (100, [.write(100), .render(30), .mute, .render(1), .render(70), .render(71), .render(4096), .write(50),
           .render(10), .unmute, .render(1), .renderPending, .render(1)]),
    (32, [.mute, .render(8), .write(16), .render(16), .render(4096), .unmute, .render(16), .render(4), .write(5),
          .render(5)]),
    (50, [.write(40), .render(5), .mute, .mute, .render(7), .unmute, .render(5), .unmute, .render(5), .mute,
          .unmute, .mute, .render(9), .unmute, .render(3), .renderPending, .render(2)]),
    (5, [.write(5), .render(3), .write(3), .mute, .render(4096), .render(4096), .render(1), .render(4096),
         .render(5), .render(4096), .unmute, .render(5), .render(1), .write(5), .mute, .render(1), .unmute, .render(4),
         .render(4096)]),
    (16, [.write(4), .mute, .render(10), .unmute, .render(10), .render(4), .write(16), .mute, .render(16), .unmute,
          .render(17), .render(1)]),
    (4096, [.write(4096), .mute, .render(4096), .render(4096), .unmute, .render(4096), .render(1), .write(4096),
            .render(1000), .mute, .render(4096), .unmute, .render(3096), .render(4096)]),
    (300, [.write(300), .render(100), .mute, .write(300), .render(100), .render(4096), .unmute, .render(100), .mute,
           .render(50), .unmute, .renderPending, .render(10)]),
    (1, [.mute, .render(1), .write(1), .render(1), .unmute, .render(1), .render(1), .write(1), .mute, .render(2),
         .unmute, .render(2), .write(1), .render(1)]),
    (64, Array(repeating: [IstOp.write(9), .render(4), .mute, .render(3), .render(64), .unmute, .render(2), .mute,
                           .unmute, .render(1)], count: 12).flatMap { $0 }),
]

fileprivate func istRunScenarios(_ subject: any IntegerOutput, _ checker: Checker,
                                 _ scenarios: [(capacity: Int, ops: [IstOp])], label: String) {
    for channels in 1...8 {
        for (i, scenario) in scenarios.enumerated() {
            let s = IstStream(subject, checker, channels: channels, capacity: scenario.capacity,
                              order: false, silence: true, label: "\(label) \(i)")
            for op in scenario.ops { s.run(op) }
            s.finish()
        }
    }
}

fileprivate func istCheckSilenceWhenEmpty(_ subject: any IntegerOutput, _ checker: Checker) {
    istRunScenarios(subject, checker, istEmptyScenarios, label: "underrun scenario")
}

fileprivate func istCheckSilenceWhenMuted(_ subject: any IntegerOutput, _ checker: Checker) {
    istRunScenarios(subject, checker, istMuteScenarios, label: "mute scenario")
}

fileprivate func istCheckSilenceRandom(_ subject: any IntegerOutput, _ checker: Checker) {
    var rng = IstRandom(seed: 0x1A7_0003_0001)
    for channels in 1...8 {
        for capacity in [1, 5, 64, 1000, 4096] {
            let s = IstStream(subject, checker, channels: channels, capacity: capacity,
                              order: false, silence: true, label: "random schedule with mutes")
            for _ in 0..<120 {
                if s.aborted { break }
                let roll = rng.below(100)
                if roll < 12 {
                    s.setMuted(!s.muted)
                } else if roll < 15 {
                    s.setMuted(s.muted)  // repeating the current state changes nothing
                } else if roll < 55 {
                    s.write(istRandomWriteSize(&rng, capacity: capacity))
                } else {
                    s.render(istRandomRenderSize(&rng, pending: s.pending))
                }
            }
            s.finish()
        }
    }
}
