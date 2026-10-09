//
// Spec-traced checks for the float output stream contract (FLT-001 … FLT-005).
//
// Conventions used throughout:
// - Value checks (FLT-001, FLT-002) write every value to every channel of a frame, so that a mix-up of channels
//   cannot look like a changed value; they only ever render frames that are already written.
// - Order and silence checks (FLT-003, FLT-005) write samples whose values identify them (sample index n maps
//   to ±m / 2^20, never zero), and decode what comes out by rounding to that grid, so that a tiny change of value
//   cannot look like a misplaced sample. Silence is a frame whose samples all equal zero.
// - While at least `frameCount` written frames are waiting and the stage is not muted, `render` must return
//   exactly the next `frameCount` frames. When fewer are waiting, a render may return any of them in order mixed
//   with silent frames (the records leave open how a short render is filled).
//

import Contracts
import SpecKit

public enum FloatChecks {
    public static let all: [SpecCheck<any FloatOutput>] = [
        // REQ: FLT-001
        SpecCheck("FLT-001: every value k/2^23 with k < 0 (2^23 values) comes out of a mono stage unchanged",
                  requirements: ["FLT-001"]) { subject, checker in
            fltCheckEveryGridValueMono(subject, checker, negative: true)
        },
        // REQ: FLT-001
        SpecCheck("FLT-001: every value k/2^23 with k ≥ 0 (2^23 values) comes out of a mono stage unchanged",
                  requirements: ["FLT-001"]) { subject, checker in
            fltCheckEveryGridValueMono(subject, checker, negative: false)
        },
        // REQ: FLT-001
        SpecCheck("FLT-001: edge, strided and pseudo-random k/2^23 on every channel of 1…8-channel stages",
                  requirements: ["FLT-001"]) { subject, checker in
            fltCheckGridValuesAllChannels(subject, checker)
        },
        // REQ: FLT-002
        SpecCheck("FLT-002: special finite values in −1…+1 (±1, ±0, subnormals, powers of two, off-grid) on every channel",
                  requirements: ["FLT-002"]) { subject, checker in
            fltCheckSpecialValues(subject, checker)
        },
        // REQ: FLT-002
        SpecCheck("FLT-002: pseudo-random finite values in −1…+1 needing up to full Float32 precision",
                  requirements: ["FLT-002"]) { subject, checker in
            fltCheckRandomValues(subject, checker)
        },
        // REQ: FLT-003
        SpecCheck("FLT-003: fixed write/render size patterns on 1…8-channel stages",
                  requirements: ["FLT-003"]) { subject, checker in
            fltCheckOrderPatterns(subject, checker)
        },
        // REQ: FLT-003
        SpecCheck("FLT-003: pseudo-random write and render sizes on 1…4-channel stages",
                  requirements: ["FLT-003"]) { subject, checker in
            fltCheckOrderRandom(subject, checker, channels: 1...4, seed: 0xF1_7003_0001)
        },
        // REQ: FLT-003
        SpecCheck("FLT-003: pseudo-random write and render sizes on 5…8-channel stages",
                  requirements: ["FLT-003"]) { subject, checker in
            fltCheckOrderRandom(subject, checker, channels: 5...8, seed: 0xF1_7003_0002)
        },
        // REQ: FLT-004
        SpecCheck("FLT-004: all 2^24 samples in one call, ascending",
                  requirements: ["FLT-004"]) { subject, checker in
            fltCheckConvertAllAscending(subject, checker)
        },
        // REQ: FLT-004
        SpecCheck("FLT-004: all 2^24 samples, scrambled, spread over calls of many sizes",
                  requirements: ["FLT-004"]) { subject, checker in
            fltCheckConvertChunked(subject, checker)
        },
        // REQ: FLT-004
        SpecCheck("FLT-004: edge samples at every position of short calls, duplicates and repeated calls",
                  requirements: ["FLT-004"]) { subject, checker in
            fltCheckConvertShortCalls(subject, checker)
        },
        // REQ: FLT-005
        SpecCheck("FLT-005: no written samples left: silence, nothing consumed, then the next written frame",
                  requirements: ["FLT-005"]) { subject, checker in
            fltCheckSilenceWhenEmpty(subject, checker)
        },
        // REQ: FLT-005
        SpecCheck("FLT-005: muted: silence on every channel, nothing consumed, then the next frame not yet played",
                  requirements: ["FLT-005"]) { subject, checker in
            fltCheckSilenceWhenMuted(subject, checker)
        },
        // REQ: FLT-005
        SpecCheck("FLT-005: pseudo-random schedules with mute toggles and underruns",
                  requirements: ["FLT-005"]) { subject, checker in
            fltCheckSilenceRandom(subject, checker)
        },
    ]
}

// MARK: - Deterministic pseudo-random numbers (SplitMix64)

fileprivate struct FltRandom {
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
}

// MARK: - Values

/// 2^23, full scale for 24-bit samples.
fileprivate let fltFullScale: Float = 8_388_608

/// k ÷ 2^23: exact for every 24-bit k (k is exact in Float32 and the division is by a power of two).
fileprivate func fltGrid(_ k: Int32) -> Float { Float(k) / fltFullScale }

fileprivate func fltShow(_ v: Float) -> String {
    "\(v) (bits 0x\(String(v.bitPattern, radix: 16)))"
}

fileprivate let fltMinK: Int32 = -8_388_608
fileprivate let fltMaxK: Int32 = 8_388_607

/// Edge 24-bit samples: both ends of the range, around zero, powers of two and their neighbours, bit patterns.
fileprivate let fltEdgeK: [Int32] = {
    var ks: [Int32] = [
        -8_388_608, -8_388_607, -8_388_606, -8_388_605, -2, -1, 0, 1, 2,
        8_388_604, 8_388_605, 8_388_606, 8_388_607,
        5_592_405, -5_592_406, 2_796_202, -2_796_203, 1_193_046, -1_193_046, 7_456_540, -7_456_541,
        8_388_352, -8_388_352, 255, -255, 256, -256, 4_194_303, -4_194_305, 65_535, -65_536,
    ]
    for b in 0...22 {
        let p = Int32(1) << Int32(b)
        ks += [p, -p, p - 1, -(p - 1), p + 1, -(p + 1)]
    }
    var seen = Set<Int32>()
    return ks.filter { $0 >= fltMinK && $0 <= fltMaxK && seen.insert($0).inserted }
}()

/// Special finite values from −1.0 to +1.0, many needing more than 24 significant bits as fixed point.
fileprivate let fltSpecialValues: [Float] = {
    let one: Float = 1
    var v: [Float] = [
        0, -0.0, 1, -1, 0.5, -0.5, 0.25, -0.25, 0.75, -0.75,
        0.1, -0.1, 0.2, -0.3, 1.0 / 3, -1.0 / 3, 2.0 / 3, -2.0 / 3, 0.70710677, -0.70710677,
        Float.pi / 4, -Float.pi / 4, 0.999, -0.999, 0.001, -0.001, 1e-7, -1e-7, 1e-10, -1e-10,
        1e-20, -1e-20, 1e-30, -1e-30, 1e-38, -1e-38,
        Float(bitPattern: 0x0001_16C2), -Float(bitPattern: 0x0001_16C2),  // ≈ 1e-40 (subnormal)
        Float(bitPattern: 0x0000_0007), -Float(bitPattern: 0x0000_0007),  // ≈ 1e-44 (subnormal)
        one.nextDown, -one.nextDown, one.nextDown.nextDown, -one.nextDown.nextDown,
        Float.leastNonzeroMagnitude, -Float.leastNonzeroMagnitude,
        Float.leastNonzeroMagnitude * 2, -Float.leastNonzeroMagnitude * 3,
        Float.leastNormalMagnitude, -Float.leastNormalMagnitude,
        Float.leastNormalMagnitude.nextDown, -Float.leastNormalMagnitude.nextDown,
        Float.leastNormalMagnitude.nextUp, -Float.leastNormalMagnitude.nextUp,
    ]
    // Every power of two in range, with its neighbours.
    for e in -149...0 {
        let p = Float(sign: .plus, exponent: e, significand: 1)
        for x in [p, p.nextUp, p.nextDown, p * 1.5, p * 1.75] {
            v.append(x)
            v.append(-x)
        }
    }
    // Neighbours of the 2^-23 grid: one ulp off every edge grid value.
    for k in fltEdgeK {
        let x = fltGrid(k)
        v.append(x.nextUp)
        v.append(x.nextDown)
    }
    // Every exponent (subnormal included) with assorted significands, both signs.
    let significands: [UInt32] = [0, 1, 2, 0x7F_FFFF, 0x7F_FFFE, 0x40_0000, 0x40_0001, 0x3F_FFFF,
                                  0x2A_AAAA, 0x55_5555, 0x00_0FFF, 0x7F_F000, 0x12_3457]
    for exponentField in UInt32(0)...126 {
        for m in significands {
            let x = Float(bitPattern: exponentField << 23 | m)
            v.append(x)
            v.append(-x)
        }
    }
    return v.filter { $0.isFinite && $0.magnitude <= 1 }
}()

/// A pseudo-random finite value from −1.0 to +1.0, drawn from several distributions.
fileprivate func fltRandomUnitValue(_ rng: inout FltRandom) -> Float {
    var x: Float
    switch rng.below(5) {
    case 0:  // any bit pattern from 0 to 1.0
        x = Float(bitPattern: UInt32(truncatingIfNeeded: rng.next() % 0x3F80_0001))
    case 1:  // every exponent equally likely (subnormals included)
        let e = UInt32(rng.below(127))
        let m = UInt32(truncatingIfNeeded: rng.next()) & 0x7F_FFFF
        x = Float(bitPattern: e << 23 | m)
    case 2:  // 24 significant fractional bits, scaled down by a power of two
        x = Float(rng.below(1 << 24)) / 16_777_216
        x *= Float(sign: .plus, exponent: -rng.below(12), significand: 1)
    case 3:  // full 24-bit significand in [2^-(e+1), 2^-e), e = 0 … 20
        let e = UInt32(rng.below(21))
        let m = UInt32(truncatingIfNeeded: rng.next()) & 0x7F_FFFF
        x = Float(bitPattern: (0x3F00_0000 - (e << 23)) | m)
    default:  // one ulp off the 2^-23 grid
        let g = fltGrid(Int32(rng.inRange(Int(fltMinK), Int(fltMaxK))))
        x = rng.percent(50) ? g.nextUp : g.nextDown
        if !(x.magnitude <= 1) { x = g }
        return x
    }
    return rng.percent(50) ? -x : x
}

// MARK: - Value runs (FLT-001, FLT-002)

fileprivate enum FltValueRequirement { case grid, straightCopy }

fileprivate func fltReport(_ checker: Checker, _ req: FltValueRequirement, _ ok: Bool,
                           _ message: @autoclosure () -> String) {
    switch req {
    case .grid: checker.expect(ok, "FLT-001", message())
    case .straightCopy: checker.expect(ok, "FLT-002", message())
    }
}

/// Writes `values` through a fresh stage, one value per frame on every channel, and checks that every sample
/// comes out with exactly the value written. Only renders frames that are already written. The first frame is a
/// leader of magnitude 0.5 (k = −2^22 for FLT-001), so that a stage that is silent at first is seen to be late,
/// not to change values.
fileprivate func fltValueRun(_ subject: any FloatOutput, _ checker: Checker, _ req: FltValueRequirement,
                             values body: [Float], channels: Int, capacity: Int,
                             writeSizes: [Int], renderSizes: [Int], label: String) {
    guard !body.isEmpty, !writeSizes.isEmpty, !renderSizes.isEmpty, channels >= 1, capacity >= 1 else { return }
    let values = [req == .grid ? -0.5 : 0.5] + body
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
            // Never more than the free space, so that how a stage takes part of a write (FLT-003) stays out of it.
            let n = min(ws, total - written, capacity - (written - played))
            let buf: [Float]
            if channels == 1 {
                buf = Array(values[written..<(written + n)])
            } else {
                var b = [Float]()
                b.reserveCapacity(n * channels)
                for f in 0..<n {
                    let v = values[written + f]
                    for _ in 0..<channels { b.append(v) }
                }
                buf = b
            }
            let accepted = max(0, min(stage.write(samples: buf), n))
            // An empty stage that takes nothing leaves no value to check (not a matter of values).
            if accepted == 0 && written == played { break }
            written += accepted
        }
        let pending = written - played
        guard pending > 0 else { continue }
        let n = min(rs, pending, 4096)
        let out = stage.render(frameCount: n)
        // A render of the wrong length cannot be lined up with frames (not a matter of values).
        guard out.count == n * channels else { break }
        var bad = 0
        var firstBad = -1
        // Fast path for mono: Array == compares Float values (−0 equals +0, NaN equals nothing).
        if channels != 1 || out != Array(values[played..<(played + n)]) {
            var i = 0
            for f in 0..<n {
                let v = values[played + f]
                for _ in 0..<channels {
                    if !(out[i] == v) {
                        bad += 1
                        if firstBad < 0 { firstBad = i }
                    }
                    i += 1
                }
            }
        }
        if bad > 0 && fltOnlyMoved(out, values: values, played: played, written: written, channels: channels) {
            // The written values all came out, only not where they belong, or nothing came out at all: a matter
            // of order or timing (FLT-003, FLT-005) that leaves this run unable to say more about values.
            break
        }
        asserted = true
        fltReport(checker, req, bad == 0, {
            let f = firstBad / channels
            let c = firstBad % channels
            return "\(where_): \(bad) of \(n * channels) samples changed in render(frameCount: \(n)); "
                + "first: frame \(played + f) channel \(c) wrote \(fltShow(values[played + f])), "
                + "got \(fltShow(out[firstBad]))"
        }())
        played += n
    }
    if !asserted {
        fltReport(checker, req, true, "\(where_): no frame could be compared in place")
    }
}

/// Whether a render that differs from frames `played…` holds only written values that were moved: every
/// differing sample equals a value written within two frames of its place, or the render holds exactly the
/// expected samples in another order; or whether nothing came out: the whole render is zero although a value of
/// at least 2^-10 in magnitude was due (no plausible change of value turns such a value into zero). NaN or any
/// other value means a changed value.
fileprivate func fltOnlyMoved(_ out: [Float], values: [Float], played: Int, written: Int, channels: Int) -> Bool {
    let n = out.count / channels
    var allZero = true
    for x in out where !(x == 0) {
        allZero = false
        break
    }
    if allZero {
        for f in 0..<n where values[played + f].magnitude >= 0.000_976_562_5 { return true }
        return false
    }
    var neighbours = true
    var i = 0
    for f in 0..<n {
        let here = played + f
        for _ in 0..<channels {
            let x = out[i]
            i += 1
            if x.isNaN { return false }
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
    var expected = [Float]()
    expected.reserveCapacity(out.count)
    for f in 0..<n {
        for _ in 0..<channels { expected.append(values[played + f]) }
    }
    return out.sorted() == expected.sorted()
}

/// `values` in a pseudo-random order (Fisher–Yates), so that neighbouring values are unrelated.
fileprivate func fltShuffled(_ values: [Float], seed: UInt64) -> [Float] {
    var v = values
    var rng = FltRandom(seed: seed)
    var i = v.count - 1
    while i > 0 {
        v.swapAt(i, rng.below(i + 1))
        i -= 1
    }
    return v
}

/// Every k/2^23 with k < 0 (`negative`) or k ≥ 0, in scrambled order, through one mono stage.
fileprivate func fltCheckEveryGridValueMono(_ subject: any FloatOutput, _ checker: Checker, negative: Bool) {
    let half = 1 << 23
    var values = [Float](repeating: 0, count: half)
    for i in 0..<half {
        // A bijection on 23 bits (odd multiplier, xorshift, offset), written out because it runs 2^23 times.
        var x = UInt32(truncatingIfNeeded: i) & 0x7F_FFFF
        x = (x &* 0x2F_5AB7) & 0x7F_FFFF
        x ^= x >> 11
        x = (x &+ 0x5B_3C1D) & 0x7F_FFFF
        let k = negative ? -Int32(bitPattern: x) - 1 : Int32(bitPattern: x)
        values[i] = Float(k) / 8_388_608
    }
    fltValueRun(subject, checker, .grid, values: values, channels: 1, capacity: 4096,
                writeSizes: [4096, 4093, 1, 4096, 2048, 3, 4096, 1000],
                renderSizes: [4096, 4096, 1, 4095, 2, 4096, 512, 7],
                label: negative ? "every k/2^23 with k < 0, scrambled" : "every k/2^23 with k ≥ 0, scrambled")
}

fileprivate func fltCheckGridValuesAllChannels(_ subject: any FloatOutput, _ checker: Checker) {
    var rng = FltRandom(seed: 0xF1_7001_0001)
    var ks = fltEdgeK
    var k = Int(fltMinK)
    while k <= Int(fltMaxK) {
        ks.append(Int32(k))
        k += 32_771
    }
    for _ in 0..<3000 { ks.append(Int32(rng.inRange(Int(fltMinK), Int(fltMaxK)))) }
    ks += fltEdgeK
    let values = fltShuffled(ks.map(fltGrid), seed: 0xF1_7001_0002)
    let configs: [(capacity: Int, writes: [Int], renders: [Int])] = [
        (4096, [4096], [4096]),
        (1, [1, 3], [1]),
        (7, [5, 7, 2], [3, 4, 1, 7]),
        (100, [64, 37, 100, 1], [50, 37, 1, 64]),
        (1000, [999, 2, 1000], [4096, 3, 600]),
        (5000, [4096, 5000, 17], [4096, 13, 4095]),
    ]
    for channels in 1...8 {
        for (j, cfg) in configs.enumerated() where (j + channels) % 2 == 0 || j == 0 {
            fltValueRun(subject, checker, .grid, values: values, channels: channels, capacity: cfg.capacity,
                        writeSizes: cfg.writes, renderSizes: cfg.renders, label: "edge and sampled k/2^23")
        }
    }
}

fileprivate func fltCheckSpecialValues(_ subject: any FloatOutput, _ checker: Checker) {
    let values = fltShuffled(fltSpecialValues, seed: 0xF1_7002_0002)
    let reversed = Array(values.reversed())
    let configs: [(capacity: Int, writes: [Int], renders: [Int])] = [
        (4096, [4096], [4096]),
        (1, [1, 2], [1]),
        (5, [3, 5], [2, 5, 1]),
        (64, [64, 13], [64, 1, 30]),
        (3000, [2999, 7], [4096, 101]),
    ]
    for channels in 1...8 {
        for (j, cfg) in configs.enumerated() where (j + channels) % 2 == 1 || j == 0 {
            fltValueRun(subject, checker, .straightCopy, values: values, channels: channels, capacity: cfg.capacity,
                        writeSizes: cfg.writes, renderSizes: cfg.renders, label: "special values")
        }
        fltValueRun(subject, checker, .straightCopy, values: reversed, channels: channels, capacity: 512,
                    writeSizes: [500, 12], renderSizes: [256, 3], label: "special values, reversed")
    }
}

fileprivate func fltCheckRandomValues(_ subject: any FloatOutput, _ checker: Checker) {
    var rng = FltRandom(seed: 0xF1_7002_0001)
    var mono = [Float]()
    mono.reserveCapacity(600_000)
    for _ in 0..<600_000 { mono.append(fltRandomUnitValue(&rng)) }
    fltValueRun(subject, checker, .straightCopy, values: mono, channels: 1, capacity: 4096,
                writeSizes: [4096, 1, 4000, 77], renderSizes: [4096, 4096, 3, 1000],
                label: "pseudo-random values")
    for (channels, count) in [(2, 120_000), (3, 60_000), (5, 30_000), (8, 30_000)] {
        var vs = [Float]()
        vs.reserveCapacity(count)
        for _ in 0..<count { vs.append(fltRandomUnitValue(&rng)) }
        fltValueRun(subject, checker, .straightCopy, values: vs, channels: channels, capacity: 2048,
                    writeSizes: [2048, 999, 5], renderSizes: [1024, 2047, 1, 4096],
                    label: "pseudo-random values")
    }
}

// MARK: - Identity streams (FLT-003, FLT-005)

/// Identities per sign: sample index n is written as ±(m) / 2^20 with m in 1 ... 2^20 − 1.
fileprivate let fltIdHalf = 1_048_575
fileprivate let fltIdPeriod = 2 * 1_048_575

/// The value written for interleaved sample index `index` (never zero, always inside −1 … +1).
fileprivate func fltIdValue(_ index: Int) -> Float {
    let j = index % fltIdPeriod
    return j < fltIdHalf ? Float(j + 1) / 1_048_576 : -Float(j - fltIdHalf + 1) / 1_048_576
}

/// The identity (index modulo the period) a value decodes to, or −1. Rounds to the 2^-20 grid, so a change of
/// a few ulps does not change the identity.
fileprivate func fltIdOf(_ v: Float) -> Int {
    guard v.isFinite, v.magnitude <= 1 else { return -1 }
    let d = Double(v) * 1_048_576
    // Round half away from zero (Int(_:) truncates toward zero).
    let m = d >= 0 ? Int(d + 0.5) : -Int(-d + 0.5)
    if m >= 1 && m <= 1_048_575 { return m - 1 }
    if m <= -1 && m >= -1_048_575 { return fltIdHalf - m - 1 }
    return -1
}

fileprivate enum FltOp {
    case write(Int)
    case render(Int)
    /// Render exactly the frames still waiting (at most 4096), or one frame when none wait.
    case renderPending
    case mute
    case unmute
}

/// Drives one fresh stage with identity samples and follows what must come out.
///
/// With `order`, asserts FLT-003: while at least `frameCount` written frames wait, render returns exactly the next
/// ones; in a shorter render every non-silent frame is the next written frame; nothing played comes out again.
/// With `silence`, asserts FLT-005: muted renders and renders with nothing waiting are all zero, and so is the
/// rest of a render once the last waiting frame has come out; after such silence the next frame out is the next
/// one not yet played; frames waiting while muted all still come out. Anything else that goes wrong only ends
/// the scenario.
fileprivate final class FltStream {
    let stage: any FloatStage
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

    init(_ subject: any FloatOutput, _ checker: Checker, channels: Int, capacity: Int,
         order: Bool, silence: Bool, label: String) {
        self.stage = subject.makeStage(channels: channels, capacityFrames: capacity)
        self.channels = channels
        self.checker = checker
        self.order = order
        self.silence = silence
        self.label = "\(label) [\(channels) ch, capacity \(capacity)]"
    }

    var pending: Int { written - played }

    private func expectedId(_ frame: Int, _ c: Int) -> Int { (frame * channels + c) % fltIdPeriod }

    private func at(_ n: Int) -> String { "\(label), render #\(renders) (frameCount \(n))" }

    /// Output frame `f` is written frame `src`, channel for channel.
    private func frameMatches(_ out: [Float], _ f: Int, _ src: Int) -> Bool {
        let base = f * channels
        for c in 0..<channels where fltIdOf(out[base + c]) != expectedId(src, c) { return false }
        return true
    }

    /// Output frame `f` holds only samples of written frame `src`, in whatever channel. Silence checks follow
    /// frames this way, so that a channel mix-up (an FLT-003 matter) does not look like a wrong frame.
    private func frameIs(_ out: [Float], _ f: Int, _ src: Int) -> Bool {
        let base = f * channels
        let first = expectedId(src, 0)
        for c in 0..<channels {
            let id = fltIdOf(out[base + c])
            guard id >= first && id < first + channels else { return false }
        }
        return true
    }

    /// The matching rule for this stream: exact channels when it checks order, frame identity otherwise.
    private func matches(_ out: [Float], _ f: Int, _ src: Int) -> Bool {
        order ? frameMatches(out, f, src) : frameIs(out, f, src)
    }

    private func frameSilent(_ out: [Float], _ f: Int) -> Bool {
        let base = f * channels
        for c in 0..<channels where !(out[base + c] == 0) { return false }
        return true
    }

    /// The already played frame (below `playedSoFar`) that output frame `f` repeats, if it is one.
    private func repeatedFrame(_ out: [Float], _ f: Int, playedSoFar: Int) -> Int? {
        guard written * channels <= fltIdPeriod else { return nil }
        let j = fltIdOf(out[f * channels])
        guard j >= 0, j % channels == 0 else { return nil }
        let src = j / channels
        guard src < playedSoFar, frameMatches(out, f, src) else { return nil }
        return src
    }

    private func show(_ out: [Float], _ f: Int) -> String {
        let base = f * channels
        let shown = (0..<min(channels, 4)).map { "\(out[base + $0])" }
        return "[" + shown.joined(separator: ", ") + (channels > 4 ? ", …]" : "]")
    }

    private func showWritten(_ src: Int) -> String {
        let shown = (0..<min(channels, 4)).map { "\(fltIdValue(src * channels + $0))" }
        return "[" + shown.joined(separator: ", ") + (channels > 4 ? ", …]" : "]")
    }

    /// Index of the first sample in `out[from...]` that is not zero, or −1.
    private func firstNonZero(_ out: [Float], from: Int = 0) -> Int {
        var i = from
        while i < out.count {
            if !(out[i] == 0) { return i }
            i += 1
        }
        return -1
    }

    /// Whether `out[outStart ..< outStart + frames × channels]` holds exactly the samples written for frames
    /// `src ..< src + frames` (fast path; a mismatch is then examined sample by sample).
    private func exactlyWritten(_ out: [Float], outStart: Int, src: Int, frames: Int) -> Bool {
        let count = frames * channels
        let a = src * channels
        guard a >= 0, a + count <= sent.count, outStart + count <= out.count else { return false }
        if outStart == 0 && count == out.count { return out == Array(sent[a..<(a + count)]) }
        return Array(out[outStart..<(outStart + count)]) == Array(sent[a..<(a + count)])
    }

    /// Every sample accepted so far, interleaved, in the order written.
    private var sent: [Float] = []

    @discardableResult
    func write(_ frames: Int) -> Int {
        guard !aborted, frames > 0 else { return 0 }
        let base = written * channels
        let count = frames * channels
        var buf = [Float](repeating: 0, count: count)
        for s in 0..<count { buf[s] = fltIdValue(base + s) }
        let accepted = max(0, min(stage.write(samples: buf), frames))
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
                checker.expect(false, "FLT-003",
                               "\(at(n)): returned \(out.count) samples instead of \(n * channels)")
            }
            if silence {
                checker.expect(false, "FLT-005",
                               "\(at(n)): returned \(out.count) samples instead of \(n * channels)")
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

    private func renderSilent(_ out: [Float], _ n: Int, why: String) {
        let firstLoud = firstNonZero(out)
        if silence {
            checker.expect(firstLoud < 0, "FLT-005",
                           "\(at(n)), \(why): sample \(firstLoud) (frame \(firstLoud / channels), channel "
                           + "\(firstLoud % channels)) is \(firstLoud >= 0 ? fltShow(out[firstLoud]) : ""), "
                           + "expected silence")
            if firstLoud >= 0 {
                aborted = true
                return
            }
        }
        if order && firstLoud >= 0 {
            for f in (firstLoud / channels)..<n where !frameSilent(out, f) {
                if let src = repeatedFrame(out, f, playedSoFar: played) {
                    checker.expect(false, "FLT-003",
                                   "\(at(n)), \(why): output frame \(f) repeats frame \(src), played already")
                    aborted = true
                    return
                }
            }
        }
        resume = true
    }

    private func renderFull(_ out: [Float], _ n: Int) {
        var bad = -1
        if !exactlyWritten(out, outStart: 0, src: played, frames: n) {
            for f in 0..<n where !matches(out, f, played + f) {
                bad = f
                break
            }
        }
        if silence {
            var reported = false
            if resume {
                checker.expect(bad != 0, "FLT-005",
                               "\(at(n)): after silence the next frame out must be frame \(played), the next not yet "
                               + "played, \(showWritten(played)); got \(bad == 0 ? show(out, 0) : "")")
                reported = bad == 0
            }
            if played < protectedUpTo && !reported {
                let ok = bad < 0 || played + bad >= protectedUpTo
                checker.expect(ok, "FLT-005",
                               "\(at(n)): frame \(played + max(bad, 0)) was waiting while muted, so it must still come "
                               + "out next, \(showWritten(played + max(bad, 0))); got "
                               + "\(bad >= 0 ? show(out, bad) : "")")
            }
        }
        if bad < 0 {
            if order { checker.expect(true, "FLT-003", "\(at(n)): frames \(played)… in order") }
            played += n
            resume = false
            return
        }
        if order {
            checker.expect(false, "FLT-003",
                           "\(at(n)) with \(pending) frames waiting: output frame \(bad) should be written frame "
                           + "\(played + bad) \(showWritten(played + bad)); got \(show(out, bad))")
        }
        aborted = true
    }

    private func renderShort(_ out: [Float], _ n: Int, _ p: Int) {
        var consumed = 0
        var silentTail = false
        if firstNonZero(out) < 0 {
            // All silence: nothing came out.
        } else if exactlyWritten(out, outStart: 0, src: played, frames: p)
                    && firstNonZero(out, from: p * channels) < 0 {
            consumed = p  // every waiting frame, then silence
            silentTail = true
        } else {
            scanShort(out, n, p, &consumed, &silentTail)
            if aborted { return }
        }
        if silence && consumed > 0 && resume {
            checker.expect(true, "FLT-005", "\(at(n)): resumed at frame \(played)")
        }
        if silence && consumed == p && silentTail {
            checker.expect(true, "FLT-005", "\(at(n)): silence after the last waiting frame")
        }
        if silence && played < protectedUpTo && consumed > 0 {
            checker.expect(true, "FLT-005", "\(at(n)): frames waiting while muted came out")
        }
        if order && consumed > 0 {
            checker.expect(true, "FLT-003", "\(at(n)): frames \(played)… in order")
        }
        played += consumed
        if consumed > 0 { resume = false }
        if consumed == p && silentTail { resume = true }
    }

    /// Frame-by-frame reading of a short render: silent frames are skipped, every other frame must be the next
    /// waiting frame, and once none wait, the rest must be silence (FLT-005) and must not repeat (FLT-003).
    private func scanShort(_ out: [Float], _ n: Int, _ p: Int, _ consumed: inout Int, _ silentTail: inout Bool) {
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
                    checker.expect(false, "FLT-005",
                                   "\(at(n)): after silence the next frame out must be frame \(src), the next not "
                                   + "yet played, \(showWritten(src)); output frame \(f) is \(show(out, f))")
                } else if silence && src < protectedUpTo {
                    checker.expect(false, "FLT-005",
                                   "\(at(n)): frame \(src) was waiting while muted, so it must still come out next, "
                                   + "\(showWritten(src)); output frame \(f) is \(show(out, f))")
                }
                if order {
                    checker.expect(false, "FLT-003",
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
                checker.expect(false, "FLT-005",
                               "\(at(n)): all \(p) waiting frames came out, so output frame \(f) must be silence; got "
                               + "\(show(out, f))")
                aborted = true
                return
            }
            if order, let src = repeatedFrame(out, f, playedSoFar: played + consumed) {
                checker.expect(false, "FLT-003",
                               "\(at(n)): output frame \(f) repeats frame \(src), played already")
                aborted = true
                return
            }
        }
    }

    func run(_ op: FltOp) {
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
            checker.expect(written > 0 && played == written, "FLT-003",
                           "\(label): \(played) of \(written) written frames came out (the stage must accept frames)")
        }
    }
}

// MARK: - FLT-003

fileprivate let fltOrderPatterns: [(capacity: Int, ops: [FltOp], times: Int)] = [
    (1, [.write(1), .render(1)], 12),
    (1, [.write(3), .render(1), .render(1), .render(2), .renderPending], 6),
    (2, [.write(2), .render(1), .write(1), .render(2), .write(2), .render(2)], 8),
    (3, [.write(2), .render(2), .write(3), .render(1), .render(2)], 8),
    (7, [.write(5), .render(3), .write(5), .render(3), .write(5), .render(4), .write(7), .renderPending], 6),
    (64, [.write(64)] + Array(repeating: FltOp.render(1), count: 64), 2),
    (64, Array(repeating: FltOp.write(1), count: 64) + [.render(64)], 3),
    (100, [.write(150), .render(64), .write(100), .render(64), .render(64)], 5),
    (300, [.write(150)]
        + Array(repeating: [FltOp.write(37), .render(37)], count: 40).flatMap { $0 }
        + Array(repeating: [FltOp.write(64), .render(50)], count: 15).flatMap { $0 }
        + Array(repeating: [FltOp.write(50), .render(64)], count: 20).flatMap { $0 }, 1),
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

fileprivate func fltCheckOrderPatterns(_ subject: any FloatOutput, _ checker: Checker) {
    for channels in 1...8 {
        for (i, pattern) in fltOrderPatterns.enumerated() {
            let s = FltStream(subject, checker, channels: channels, capacity: pattern.capacity,
                              order: true, silence: false, label: "pattern \(i)")
            for _ in 0..<pattern.times {
                for op in pattern.ops { s.run(op) }
            }
            s.finish()
        }
    }
}

fileprivate func fltRandomWriteSize(_ rng: inout FltRandom, capacity: Int) -> Int {
    switch rng.below(100) {
    case ..<25: return rng.inRange(1, 4)
    case ..<45: return rng.inRange(1, capacity)
    case ..<57: return capacity
    case ..<65: return max(1, capacity + rng.inRange(-1, 1))
    case ..<80: return rng.inRange(1, min(2 * capacity + 8, 5000))
    default: return rng.inRange(1, 64)
    }
}

fileprivate func fltRandomRenderSize(_ rng: inout FltRandom, pending: Int) -> Int {
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

fileprivate func fltCheckOrderRandom(_ subject: any FloatOutput, _ checker: Checker,
                                     channels: ClosedRange<Int>, seed: UInt64) {
    var rng = FltRandom(seed: seed)
    let capacities = [1, 3, 16, 100, 1000, 4096, 6000]
    for ch in channels {
        for capacity in capacities {
            let s = FltStream(subject, checker, channels: ch, capacity: capacity,
                              order: true, silence: false, label: "random schedule")
            for _ in 0..<160 {
                if s.aborted { break }
                if rng.percent(50) {
                    s.write(fltRandomWriteSize(&rng, capacity: capacity))
                } else {
                    s.render(fltRandomRenderSize(&rng, pending: s.pending))
                }
            }
            s.finish()
        }
    }
}

// MARK: - FLT-004

fileprivate func fltCheckConversion(_ checker: Checker, input: [Int32], output: [Float], label: String) {
    checker.expect(output.count == input.count, "FLT-004",
                   "\(label): \(input.count) samples in, \(output.count) values out")
    let n = min(input.count, output.count)
    var bad = 0
    var firstBad = -1
    for i in 0..<n where !(output[i] == Float(input[i]) / 8_388_608) {
        bad += 1
        if firstBad < 0 { firstBad = i }
    }
    checker.expect(bad == 0, "FLT-004", {
        guard firstBad >= 0 else { return "" }
        let k = input[firstBad]
        return "\(label): \(bad) of \(n) values differ from k ÷ 2^23; first at index \(firstBad): k = \(k), "
            + "expected \(fltShow(fltGrid(k))), got \(fltShow(output[firstBad]))"
    }())
}

fileprivate func fltCheckConvertAllAscending(_ subject: any FloatOutput, _ checker: Checker) {
    var input = [Int32](repeating: 0, count: 1 << 24)
    for i in 0..<(1 << 24) { input[i] = Int32(i - 8_388_608) }
    let output = subject.int24ToFloat(samples: input)
    fltCheckConversion(checker, input: input, output: output, label: "one call, all 2^24 samples ascending")
}

fileprivate func fltCheckConvertChunked(_ subject: any FloatOutput, _ checker: Checker) {
    let sizes = [1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 100, 127, 128, 129, 255, 256, 257,
                 1000, 1023, 1024, 1025, 4095, 4096, 4097, 65_535, 65_536, 65_537, 300_001]
    var start = 0
    var call = 0
    let total = 1 << 24
    while start < total {
        let n = min(sizes[call % sizes.count], total - start)
        var input = [Int32](repeating: 0, count: n)
        // Every sample exactly once over all calls, in scrambled order: a bijection on 24 bits (odd multiplier,
        // xorshift, offset), shifted to −2^23 … 2^23 − 1.
        for i in 0..<n {
            var x = UInt32(truncatingIfNeeded: start + i) & 0xFF_FFFF
            x = (x &* 0x2F_5AB7) & 0xFF_FFFF
            x ^= x >> 12
            x = (x &+ 0x5B_3C1D) & 0xFF_FFFF
            input[i] = Int32(bitPattern: x) - 8_388_608
        }
        let output = subject.int24ToFloat(samples: input)
        fltCheckConversion(checker, input: input, output: output, label: "call \(call) (\(n) samples)")
        start += n
        call += 1
    }
}

fileprivate func fltCheckConvertShortCalls(_ subject: any FloatOutput, _ checker: Checker) {
    var rng = FltRandom(seed: 0xF1_7004_0001)
    let edges = fltEdgeK
    // Every edge sample at the first, last and a middle position of short calls of every length 1 … 40.
    for n in 1...40 {
        for (e, k) in edges.enumerated() {
            var input = [Int32]()
            input.reserveCapacity(n)
            for _ in 0..<n { input.append(Int32(rng.inRange(Int(fltMinK), Int(fltMaxK)))) }
            let pos = [0, n - 1, n / 2][e % 3]
            input[pos] = k
            if n > 1 { input[n - 1 - pos] = edges[(e + 7) % edges.count] }
            fltCheckConversion(checker, input: input, output: subject.int24ToFloat(samples: input),
                               label: "\(n) samples, edge \(k) at \(pos)")
        }
    }
    // All edges in one call, forwards and backwards, called twice each.
    for input in [edges, Array(edges.reversed())] {
        fltCheckConversion(checker, input: input, output: subject.int24ToFloat(samples: input), label: "edges, first call")
        fltCheckConversion(checker, input: input, output: subject.int24ToFloat(samples: input), label: "edges, again")
    }
    // Runs of one value (duplicates must convert alike).
    for k in [fltMinK, -1, 0, 1, fltMaxK, 4_194_304, -4_194_304] {
        for n in [1, 2, 3, 8, 1000, 4097] {
            let input = [Int32](repeating: k, count: n)
            fltCheckConversion(checker, input: input, output: subject.int24ToFloat(samples: input),
                               label: "\(n) copies of \(k)")
        }
    }
    // Sizes around powers of two, pseudo-random content.
    for n in [127, 128, 129, 255, 256, 257, 511, 512, 513, 4095, 4096, 4097, 8191, 8192, 8193] {
        var input = [Int32]()
        input.reserveCapacity(n)
        for _ in 0..<n { input.append(Int32(rng.inRange(Int(fltMinK), Int(fltMaxK)))) }
        fltCheckConversion(checker, input: input, output: subject.int24ToFloat(samples: input),
                           label: "\(n) pseudo-random samples")
    }
}

// MARK: - FLT-005

fileprivate let fltEmptyScenarios: [(capacity: Int, ops: [FltOp])] = [
    (64, [.render(1), .render(3), .render(4096), .render(2), .write(10), .render(4), .render(6), .render(5),
          .write(20), .render(20), .render(1), .write(3), .render(3)]),
    (64, [.write(10), .render(25), .render(25), .write(30), .render(30), .render(1), .write(5), .render(4096),
          .render(4096), .write(64), .render(64)]),
    (8, Array(repeating: [FltOp.write(1), .render(2), .write(3), .render(3), .render(1), .write(2), .render(1),
                          .write(8), .render(5), .render(5), .write(4), .render(4096), .write(8), .render(8)],
              count: 4).flatMap { $0 }),
    (1, [.render(1), .write(1), .render(1), .render(1), .write(1), .render(2), .write(2), .render(1), .render(1),
         .render(4096), .write(1), .render(1)]),
    (4096, [.write(4096), .render(4096), .render(1), .write(1), .render(1), .render(4096), .write(4096),
            .render(4095), .render(2), .write(100), .render(100)]),
    (100, [.write(12), .render(12), .render(1), .write(12), .render(12), .render(4096), .write(100), .render(99),
           .render(1), .render(7), .write(1), .render(4096), .write(50), .render(50)]),
]

fileprivate let fltMuteScenarios: [(capacity: Int, ops: [FltOp])] = [
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
    (64, Array(repeating: [FltOp.write(9), .render(4), .mute, .render(3), .render(64), .unmute, .render(2), .mute,
                           .unmute, .render(1)], count: 12).flatMap { $0 }),
]

fileprivate func fltRunScenarios(_ subject: any FloatOutput, _ checker: Checker,
                                 _ scenarios: [(capacity: Int, ops: [FltOp])], label: String) {
    for channels in 1...8 {
        for (i, scenario) in scenarios.enumerated() {
            let s = FltStream(subject, checker, channels: channels, capacity: scenario.capacity,
                              order: false, silence: true, label: "\(label) \(i)")
            for op in scenario.ops { s.run(op) }
            s.finish()
        }
    }
}

fileprivate func fltCheckSilenceWhenEmpty(_ subject: any FloatOutput, _ checker: Checker) {
    fltRunScenarios(subject, checker, fltEmptyScenarios, label: "underrun scenario")
}

fileprivate func fltCheckSilenceWhenMuted(_ subject: any FloatOutput, _ checker: Checker) {
    fltRunScenarios(subject, checker, fltMuteScenarios, label: "mute scenario")
}

fileprivate func fltCheckSilenceRandom(_ subject: any FloatOutput, _ checker: Checker) {
    var rng = FltRandom(seed: 0xF1_7005_0001)
    for channels in 1...8 {
        for capacity in [1, 5, 64, 1000, 4096] {
            let s = FltStream(subject, checker, channels: channels, capacity: capacity,
                              order: false, silence: true, label: "random schedule with mutes")
            for _ in 0..<120 {
                if s.aborted { break }
                let roll = rng.below(100)
                if roll < 12 {
                    s.setMuted(!s.muted)
                } else if roll < 15 {
                    s.setMuted(s.muted)  // repeating the current state changes nothing
                } else if roll < 55 {
                    s.write(fltRandomWriteSize(&rng, capacity: capacity))
                } else {
                    s.render(fltRandomRenderSize(&rng, pending: s.pending))
                }
            }
            s.finish()
        }
    }
}
