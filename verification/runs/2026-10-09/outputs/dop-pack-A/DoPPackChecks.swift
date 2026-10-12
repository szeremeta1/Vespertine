//
// Spec-traced checks for the DoP packing contract (contracts/dop-pack.md), requirements DOP-001 ... DOP-007.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Every check works only through `DoPPacker.dopPack(dsd:firstMarker:)`. Checks never trap (counts are checked
// before indexing, no force unwraps, every range is built from non-negative bounds), are deterministic (a seeded
// SplitMix64, no clock or system randomness) and do a bounded amount of work.
//
// How the checks keep the requirements apart:
// - Only the DOP-007 checks compare data bits with absolute expected values. The other data checks compare two
//   outputs whose inputs differ in a chosen way, so that a fault another requirement is about (inverted bits,
//   swapped channels, bytes in the wrong order, ...) cannot show up as a failure of the requirement under test.
// - Checks other than DOP-007's look only at the samples the output does have for the input given; a wrong
//   number of channels or samples is DOP-007's to report.
// - A call that throws on valid input fails the requirement of the check that made the call.
// - Nothing is asserted about invalid input: no requirement record covers the contract's Errors section.
//

import Contracts
import SpecKit

public enum DoPPackChecks {
    public static let all: [SpecCheck<any DoPPacker>] = [
        // REQ: DOP-001
        SpecCheck("DOP-001 every DoP sample is a 24-bit value with a marker byte in bits 23...16",
                  requirements: ["DOP-001"]) { subject, checker in
            checkTopByteIsMarker(subject, checker)
        },
        // REQ: DOP-001
        SpecCheck("DOP-001 the DSD data occupies all 16 least significant bits",
                  requirements: ["DOP-001"]) { subject, checker in
            checkDataFillsLow16(subject, checker)
        },
        // REQ: DOP-002
        SpecCheck("DOP-002 the first sample period carries firstMarker",
                  requirements: ["DOP-002"]) { subject, checker in
            checkFirstMarker(subject, checker)
        },
        // REQ: DOP-002
        SpecCheck("DOP-002 the marker alternates between 0x05 and 0xFA from each sample period to the next",
                  requirements: ["DOP-002"]) { subject, checker in
            checkMarkerAlternates(subject, checker)
        },
        // REQ: DOP-002
        SpecCheck("DOP-002 every call's markers start from its own firstMarker, whatever calls came before",
                  requirements: ["DOP-002"]) { subject, checker in
            checkMarkersPerCall(subject, checker)
        },
        // REQ: DOP-003
        SpecCheck("DOP-003 all channels carry the same marker within a sample period",
                  requirements: ["DOP-003"]) { subject, checker in
            checkSameMarkerAcrossChannels(subject, checker)
        },
        // REQ: DOP-004
        SpecCheck("DOP-004 byte i lands in sample period i/2 only, an even (older) byte in bits 15...8",
                  requirements: ["DOP-004"]) { subject, checker in
            checkBytePlacement(subject, checker)
        },
        // REQ: DOP-005
        SpecCheck("DOP-005 changing one channel's data changes no other channel's samples",
                  requirements: ["DOP-005"]) { subject, checker in
            checkChannelIsolation(subject, checker)
        },
        // REQ: DOP-005
        SpecCheck("DOP-005 changing a single byte of one channel changes no other channel's samples",
                  requirements: ["DOP-005"]) { subject, checker in
            checkChannelIsolationPerByte(subject, checker)
        },
        // REQ: DOP-006
        SpecCheck("DOP-006 bit k of an input byte (bit 7 the oldest) lands in data bit 8+k or k",
                  requirements: ["DOP-006"]) { subject, checker in
            checkBitOrderWithinByte(subject, checker)
        },
        // REQ: DOP-007
        SpecCheck("DOP-007 one output array per channel, one sample per two input bytes",
                  requirements: ["DOP-007"]) { subject, checker in
            checkSampleCounts(subject, checker)
        },
        // REQ: DOP-007
        SpecCheck("DOP-007 data bits of sample j equal byte 2j << 8 | byte 2j+1 of the same channel",
                  requirements: ["DOP-007"]) { subject, checker in
            checkExactData(subject, checker)
        },
        // REQ: DOP-007
        SpecCheck("DOP-007 a lone 1 among 0s is carried exactly once, in its own place",
                  requirements: ["DOP-007"]) { subject, checker in
            checkLoneBit(subject, checker, lone: 1)
        },
        // REQ: DOP-007
        SpecCheck("DOP-007 a lone 0 among 1s is carried exactly once, in its own place",
                  requirements: ["DOP-007"]) { subject, checker in
            checkLoneBit(subject, checker, lone: 0)
        },
        // REQ: DOP-007
        SpecCheck("DOP-007 each sample has as many 1 bits as its two input bytes",
                  requirements: ["DOP-007"]) { subject, checker in
            checkBitCounts(subject, checker)
        },
        // REQ: DOP-007
        SpecCheck("DOP-007 all-0 and all-1 DSD data come out unchanged, not inverted",
                  requirements: ["DOP-007"]) { subject, checker in
            checkConstantData(subject, checker)
        },
    ]
}

// MARK: - Test data

private let markers: [UInt8] = [0x05, 0xFA]

/// A number of channels and a per-channel byte count (always even, as the contract requires).
private struct Shape: Sendable {
    let channels: Int
    let bytes: Int
    init(_ channels: Int, _ bytes: Int) {
        self.channels = channels
        self.bytes = bytes
    }
    var periods: Int { bytes / 2 }
}

/// The shapes most checks run over: one to 32 channels, one to 513 sample periods, around 2^4, 2^7 and 2^8.
private let shapes: [Shape] = [
    Shape(1, 2), Shape(1, 4), Shape(1, 6), Shape(1, 8), Shape(1, 16), Shape(1, 30), Shape(1, 32), Shape(1, 34),
    Shape(1, 254), Shape(1, 256), Shape(1, 258), Shape(1, 1026),
    Shape(2, 2), Shape(2, 4), Shape(2, 10), Shape(2, 64), Shape(2, 514),
    Shape(3, 6), Shape(3, 18), Shape(4, 8), Shape(5, 2), Shape(5, 50), Shape(6, 12), Shape(6, 384),
    Shape(7, 14), Shape(8, 2), Shape(8, 256), Shape(12, 20), Shape(16, 32), Shape(32, 4),
]

/// Long streams: past 2^16, 2^12 and 2^10 sample periods per channel.
private let longShapes: [Shape] = [Shape(1, 131_076), Shape(2, 8_194), Shape(6, 2_050)]

/// Bytes that read the same from either end, so whichever way a byte's bits are read is invisible.
private let palindromicMasks: [UInt8] = [
    0xFF, 0x81, 0x42, 0x24, 0x18, 0xC3, 0xA5, 0x99, 0x66, 0x5A, 0x3C, 0xE7, 0xDB, 0xBD, 0x7E,
]

/// Single bits and mixed patterns, to follow each bit position of a byte.
private let bitMasks: [UInt8] = [
    0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01, 0xF0, 0x0F, 0xC0, 0x03, 0xAA, 0x55, 0xE0, 0x07, 0x8C, 0x31,
]

/// SplitMix64: a small seeded generator, so every run sees the same data.
private struct SplitMix64 {
    private var state: UInt64

    init(_ seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in 0..<n (0 when n is not positive).
    mutating func below(_ n: Int) -> Int {
        n > 0 ? Int(truncatingIfNeeded: next() % UInt64(n)) : 0
    }

    /// A byte in 1...255.
    mutating func nonzeroByte() -> UInt8 {
        1 &+ UInt8(truncatingIfNeeded: next() % 255)
    }

    mutating func bytes(_ count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: max(0, count))
        var i = 0
        while i < out.count {
            var r = next()
            var k = 0
            while k < 8 && i < out.count {
                out[i] = UInt8(truncatingIfNeeded: r)
                r >>= 8
                i += 1
                k += 1
            }
        }
        return out
    }

    /// Independent random data for every channel.
    mutating func input(_ shape: Shape) -> [[UInt8]] {
        var dsd: [[UInt8]] = []
        dsd.reserveCapacity(shape.channels)
        for _ in 0..<max(0, shape.channels) { dsd.append(bytes(shape.bytes)) }
        return dsd
    }
}

private func uniform(_ shape: Shape, _ value: UInt8) -> [[UInt8]] {
    [[UInt8]](repeating: [UInt8](repeating: value, count: max(0, shape.bytes)), count: max(0, shape.channels))
}

private func complement(_ dsd: [[UInt8]]) -> [[UInt8]] {
    dsd.map { channel in channel.map { ~$0 } }
}

/// Positions worth perturbing in a channel of `bytes` bytes: all of a short one, the edges and samples of a long one.
private func bytePositions(_ bytes: Int, _ rng: inout SplitMix64) -> [Int] {
    if bytes <= 70 { return Array(0..<max(0, bytes)) }
    var p: [Int]
    if bytes > 4096 {
        // A long stream: its edges and both sides of sample period 2^16.
        p = [0, 1, 131_070, 131_071, 131_072, 131_073, bytes - 2, bytes - 1]
    } else {
        p = [0, 1, 2, 3, 30, 31, 32, 33, 254, 255, 256, 257, 510, 511, 512, 513,
             bytes / 2 - 1, bytes / 2, bytes - 4, bytes - 3, bytes - 2, bytes - 1]
    }
    for _ in 0..<4 { p.append(rng.below(bytes)) }
    return p.filter { $0 >= 0 && $0 < bytes }
}

// MARK: - Reading the output

private func markerOf(_ sample: UInt32) -> UInt8 { UInt8(truncatingIfNeeded: sample >> 16) }
private func dataOf(_ sample: UInt32) -> UInt32 { sample & 0xFFFF }
private func isMarker(_ byte: UInt8) -> Bool { byte == 0x05 || byte == 0xFA }
private func otherMarker(_ marker: UInt8) -> UInt8 { marker == 0x05 ? 0xFA : 0x05 }
private func expectedMarker(_ first: UInt8, period j: Int) -> UInt8 { j % 2 == 0 ? first : otherMarker(first) }

/// The 16 data bits the two bytes of one sample period make: the older byte's 8 samples above the newer byte's.
private func word(_ older: UInt8, _ newer: UInt8) -> UInt32 { UInt32(older) << 8 | UInt32(newer) }

/// How many of channel `c`'s first `periods` sample periods `out` has (0 when it has no such channel).
private func available(_ out: [[UInt32]], _ c: Int, _ periods: Int) -> Int {
    guard c >= 0, c < out.count else { return 0 }
    return max(0, min(out[c].count, periods))
}

private func hexDigits(_ value: UInt32, _ width: Int) -> String {
    let digits = String(value, radix: 16, uppercase: true)
    return "0x" + String(repeating: "0", count: max(0, width - digits.count)) + digits
}

private func hex8(_ value: UInt8) -> String { hexDigits(UInt32(value), 2) }
private func hex16(_ value: UInt32) -> String { hexDigits(value, 4) }
private func hex32(_ value: UInt32) -> String { hexDigits(value, 8) }

private func describe(_ dsd: [[UInt8]], _ first: UInt8) -> String {
    "\(dsd.count) ch x \(dsd.first?.count ?? 0) bytes, firstMarker \(hex8(first))"
}

/// Calls the subject on valid input; a throw fails `requirement` and yields nil.
private func pack(_ subject: any DoPPacker, _ dsd: [[UInt8]], _ first: UInt8,
                  _ checker: Checker, _ requirement: String) -> [[UInt32]]? {
    do {
        return try subject.dopPack(dsd: dsd, firstMarker: first)
    } catch {
        checker.fail(requirement, "\(describe(dsd, first)): threw \(error) for valid input")
        return nil
    }
}

/// Collects one scenario's per-sample comparisons: reports the first few mismatches, then a total, so a check
/// over many samples stays fast and its report small. A scenario whose output has no sample to compare asserts
/// nothing: missing samples are DOP-007's to report.
private struct Tally {
    let requirement: String
    let scenario: String
    private(set) var compared = 0
    private(set) var mismatches = 0

    init(_ requirement: String, _ scenario: String) {
        self.requirement = requirement
        self.scenario = scenario
    }

    mutating func check(_ ok: Bool, _ checker: Checker, _ message: @autoclosure () -> String) {
        compared += 1
        guard !ok else { return }
        mismatches += 1
        if mismatches <= 3 { checker.fail(requirement, "\(scenario): \(message())") }
    }

    func finish(_ checker: Checker) {
        if mismatches > 3 {
            checker.fail(requirement, "\(scenario): \(mismatches) of \(compared) comparisons failed in all")
        } else if mismatches == 0 && compared > 0 {
            checker.expect(true, requirement, "\(scenario): all \(compared) comparisons held")
        }
    }
}

// MARK: - DOP-001

/// Bits 31...24 are zero and bits 23...16 hold a marker byte, for any data (including data that is all ones or
/// looks like markers).
private func checkTopByteIsMarker(_ subject: any DoPPacker, _ checker: Checker) {
    let req = "DOP-001"
    var rng = SplitMix64(0xD0_0001)
    for (index, shape) in (shapes + longShapes).enumerated() {
        for first in markers {
            let inputs = index < shapes.count
                ? [rng.input(shape), uniform(shape, 0x00), uniform(shape, 0xFF), uniform(shape, 0x05),
                   uniform(shape, 0xFA)]
                : [rng.input(shape)]
            for dsd in inputs {
                guard let out = pack(subject, dsd, first, checker, req) else { continue }
                var tally = Tally(req, describe(dsd, first))
                for c in 0..<shape.channels {
                    for j in 0..<available(out, c, shape.periods) {
                        let v = out[c][j]
                        tally.check(v >> 24 == 0, checker,
                                    "channel \(c) sample \(j) = \(hex32(v)) has bits 31...24 set; a DoP sample is 24 bits")
                        tally.check(isMarker(markerOf(v)), checker,
                                    "channel \(c) sample \(j) = \(hex32(v)): its 8 most significant bits (23...16) are \(hex8(markerOf(v))), not a DoP marker byte")
                    }
                }
                tally.finish(checker)
            }
        }
    }
}

/// Complementing every DSD bit of the input complements all 16 low bits of every sample: the data fills bits
/// 15...0 and nothing below the marker byte is left out. (Which data bit goes where is DOP-004/006/007's.)
private func checkDataFillsLow16(_ subject: any DoPPacker, _ checker: Checker) {
    let req = "DOP-001"
    var rng = SplitMix64(0xD0_0011)
    for (index, shape) in shapes.enumerated() {
        let first = markers[index % 2]
        let noise = rng.input(shape)
        let pairs = [(uniform(shape, 0x00), uniform(shape, 0xFF)), (noise, complement(noise))]
        for (a, b) in pairs {
            guard let outA = pack(subject, a, first, checker, req),
                  let outB = pack(subject, b, first, checker, req) else { continue }
            var tally = Tally(req, "\(describe(a, first)) against its bitwise complement")
            for c in 0..<shape.channels {
                let n = min(available(outA, c, shape.periods), available(outB, c, shape.periods))
                for j in 0..<n {
                    let flipped = dataOf(outA[c][j]) ^ dataOf(outB[c][j])
                    tally.check(flipped == 0xFFFF, checker,
                                "channel \(c) sample \(j): complementing every DSD bit changed bits 15...0 by \(hex16(flipped)), want 0xFFFF (16 data bits)")
                }
            }
            tally.finish(checker)
        }
    }
}

// MARK: - DOP-002

/// Sample period 0 carries firstMarker (checked on channel 0; that the other channels match is DOP-003's).
private func checkFirstMarker(_ subject: any DoPPacker, _ checker: Checker) {
    let req = "DOP-002"
    var rng = SplitMix64(0xD0_0021)
    for shape in shapes + longShapes {
        for first in markers {
            let inputs = [rng.input(shape), uniform(shape, otherMarker(first)), uniform(shape, 0x00)]
            for dsd in inputs {
                guard let out = pack(subject, dsd, first, checker, req),
                      available(out, 0, shape.periods) > 0 else { continue }
                let m = markerOf(out[0][0])
                checker.expect(m == first, req,
                               "\(describe(dsd, first)): sample period 0 carries marker \(hex8(m)), want firstMarker \(hex8(first))")
            }
        }
    }
}

/// In every channel, the marker of period j + 1 is the other one of 0x05 and 0xFA than that of period j.
private func checkMarkerAlternates(_ subject: any DoPPacker, _ checker: Checker) {
    let req = "DOP-002"
    var rng = SplitMix64(0xD0_0022)
    for shape in shapes + longShapes {
        for first in markers {
            let inputs = [rng.input(shape), uniform(shape, first)]
            for dsd in inputs {
                guard let out = pack(subject, dsd, first, checker, req) else { continue }
                var tally = Tally(req, describe(dsd, first))
                for c in 0..<shape.channels {
                    let n = available(out, c, shape.periods)
                    guard n >= 2 else { continue }
                    for j in 1..<n {
                        let previous = markerOf(out[c][j - 1])
                        let current = markerOf(out[c][j])
                        tally.check(isMarker(previous) && current == otherMarker(previous), checker,
                                    "channel \(c): marker \(hex8(previous)) in sample period \(j - 1) is followed by \(hex8(current)) in period \(j); it must alternate between 0x05 and 0xFA")
                    }
                }
                tally.finish(checker)
            }
        }
    }
}

private struct Call {
    let channels: Int
    let periods: Int
    let first: UInt8
}

/// A run of calls on one subject, with odd and even period counts and both firstMarker values: each call's
/// marker sequence is firstMarker, other, firstMarker, ... from its own period 0.
private func checkMarkersPerCall(_ subject: any DoPPacker, _ checker: Checker) {
    let req = "DOP-002"
    var rng = SplitMix64(0xD0_0023)
    var plan = [
        Call(channels: 1, periods: 1, first: 0x05), Call(channels: 1, periods: 1, first: 0x05),
        Call(channels: 2, periods: 3, first: 0x05), Call(channels: 1, periods: 1, first: 0xFA),
        Call(channels: 1, periods: 1, first: 0xFA), Call(channels: 3, periods: 5, first: 0xFA),
        Call(channels: 1, periods: 2, first: 0x05), Call(channels: 2, periods: 1, first: 0x05),
        Call(channels: 1, periods: 3, first: 0xFA), Call(channels: 1, periods: 1, first: 0x05),
        Call(channels: 1, periods: 1, first: 0xFA), Call(channels: 1, periods: 2, first: 0xFA),
    ]
    for _ in 0..<40 {
        plan.append(Call(channels: 1 + rng.below(4), periods: 1 + rng.below(9), first: markers[rng.below(2)]))
    }
    for (index, call) in plan.enumerated() {
        let dsd = rng.input(Shape(call.channels, 2 * call.periods))
        guard let out = pack(subject, dsd, call.first, checker, req) else { continue }
        var tally = Tally(req, "call \(index) of a run on one subject (\(describe(dsd, call.first)))")
        for j in 0..<available(out, 0, call.periods) {
            let m = markerOf(out[0][j])
            let want = expectedMarker(call.first, period: j)
            tally.check(m == want, checker, "sample period \(j) carries marker \(hex8(m)), want \(hex8(want))")
        }
        tally.finish(checker)
    }
}

// MARK: - DOP-003

/// For every sample period, every channel's sample carries channel 0's marker, whatever the channels' data.
private func checkSameMarkerAcrossChannels(_ subject: any DoPPacker, _ checker: Checker) {
    let req = "DOP-003"
    var rng = SplitMix64(0xD0_0031)
    let contrastValues: [UInt8] = [0x00, 0xFF, 0x05, 0xFA, 0xA5]
    for shape in (shapes + longShapes) where shape.channels >= 2 {
        for first in markers {
            var contrast: [[UInt8]] = []
            for c in 0..<shape.channels {
                let value = contrastValues[c % contrastValues.count]
                contrast.append([UInt8](repeating: value, count: shape.bytes))
            }
            for dsd in [rng.input(shape), contrast] {
                guard let out = pack(subject, dsd, first, checker, req) else { continue }
                var tally = Tally(req, describe(dsd, first))
                let channels = min(shape.channels, out.count)
                if channels >= 2 {
                    var n = shape.periods
                    for c in 0..<channels { n = min(n, available(out, c, shape.periods)) }
                    for j in 0..<max(0, n) {
                        let reference = markerOf(out[0][j])
                        for c in 1..<channels {
                            let m = markerOf(out[c][j])
                            tally.check(m == reference, checker,
                                        "sample period \(j): channel \(c) carries marker \(hex8(m)) but channel 0 carries \(hex8(reference))")
                        }
                    }
                }
                tally.finish(checker)
            }
        }
    }
}

// MARK: - DOP-004

/// XOR byte i of every channel with a palindromic mask: only sample period i/2 may change, by mask << 8 when i is
/// even (the older byte, whose oldest sample is t0 = bit 15) and by mask when i is odd. Comparing two outputs
/// leaves inverted data (DOP-007) out; a palindromic mask leaves the bit order inside a byte (DOP-006) out; the
/// same change in every channel leaves the channel routing (DOP-005) out.
private func checkBytePlacement(_ subject: any DoPPacker, _ checker: Checker) {
    let req = "DOP-004"
    var rng = SplitMix64(0xD0_0041)
    let cases = [Shape(1, 2), Shape(1, 4), Shape(1, 6), Shape(1, 8), Shape(1, 34), Shape(1, 66), Shape(2, 4),
                 Shape(2, 18), Shape(3, 10), Shape(4, 32), Shape(8, 6), Shape(1, 1026), Shape(2, 514),
                 Shape(1, 131_076)]
    for (index, shape) in cases.enumerated() {
        let first = markers[index % 2]
        let base = rng.input(shape)
        guard let outBase = pack(subject, base, first, checker, req) else { continue }
        for i in bytePositions(shape.bytes, &rng) {
            let mask = palindromicMasks[(i + index) % palindromicMasks.count]
            var changed = base
            for c in 0..<shape.channels { changed[c][i] ^= mask }
            guard let outChanged = pack(subject, changed, first, checker, req) else { continue }
            let target = i / 2
            let wantAtTarget = i % 2 == 0 ? UInt32(mask) << 8 : UInt32(mask)
            var tally = Tally(req, "\(describe(base, first)), byte \(i) of every channel XOR \(hex8(mask))")
            for c in 0..<shape.channels {
                let n = min(available(outBase, c, shape.periods), available(outChanged, c, shape.periods))
                for j in 0..<n {
                    let diff = dataOf(outBase[c][j]) ^ dataOf(outChanged[c][j])
                    let want = j == target ? wantAtTarget : 0
                    tally.check(diff == want, checker,
                                "channel \(c) sample \(j): data bits changed by \(hex16(diff)), want \(hex16(want)) (byte \(i) holds DSD samples \(8 * i)...\(8 * i + 7), which belong in sample period \(target), bits \(i % 2 == 0 ? "15...8" : "7...0"))")
                }
            }
            tally.finish(checker)
        }
    }
}

// MARK: - DOP-005

/// Replace every byte of channel k with a different value: no other channel's data bits may change.
private func checkChannelIsolation(_ subject: any DoPPacker, _ checker: Checker) {
    let req = "DOP-005"
    var rng = SplitMix64(0xD0_0051)
    let cases = [Shape(2, 2), Shape(2, 8), Shape(2, 64), Shape(2, 1026), Shape(3, 6), Shape(3, 30), Shape(4, 4),
                 Shape(5, 20), Shape(6, 12), Shape(7, 2), Shape(8, 8), Shape(8, 130), Shape(16, 6), Shape(32, 2)]
    for (index, shape) in cases.enumerated() {
        let first = markers[index % 2]
        let base = rng.input(shape)
        guard let outBase = pack(subject, base, first, checker, req) else { continue }
        for k in 0..<shape.channels {
            var changed = base
            for i in 0..<shape.bytes { changed[k][i] ^= rng.nonzeroByte() }
            guard let outChanged = pack(subject, changed, first, checker, req) else { continue }
            var tally = Tally(req, "\(describe(base, first)), every byte of channel \(k) changed")
            for c in 0..<shape.channels where c != k {
                let n = min(available(outBase, c, shape.periods), available(outChanged, c, shape.periods))
                for j in 0..<n {
                    let before = dataOf(outBase[c][j])
                    let after = dataOf(outChanged[c][j])
                    tally.check(before == after, checker,
                                "channel \(c) sample \(j): data bits went \(hex16(before)) -> \(hex16(after)) though only channel \(k)'s DSD data changed")
                }
            }
            tally.finish(checker)
        }
    }
}

/// Complement a single byte of channel k: no other channel's data bits may change.
private func checkChannelIsolationPerByte(_ subject: any DoPPacker, _ checker: Checker) {
    let req = "DOP-005"
    var rng = SplitMix64(0xD0_0052)
    let cases = [Shape(2, 2), Shape(2, 4), Shape(3, 4), Shape(4, 6), Shape(5, 2), Shape(8, 2)]
    for (index, shape) in cases.enumerated() {
        let first = markers[index % 2]
        let base = rng.input(shape)
        guard let outBase = pack(subject, base, first, checker, req) else { continue }
        for k in 0..<shape.channels {
            for i in 0..<shape.bytes {
                var changed = base
                changed[k][i] = ~changed[k][i]
                guard let outChanged = pack(subject, changed, first, checker, req) else { continue }
                var tally = Tally(req, "\(describe(base, first)), byte \(i) of channel \(k) complemented")
                for c in 0..<shape.channels where c != k {
                    let n = min(available(outBase, c, shape.periods), available(outChanged, c, shape.periods))
                    for j in 0..<n {
                        let before = dataOf(outBase[c][j])
                        let after = dataOf(outChanged[c][j])
                        tally.check(before == after, checker,
                                    "channel \(c) sample \(j): data bits went \(hex16(before)) -> \(hex16(after)) though only channel \(k)'s DSD data changed")
                    }
                }
                tally.finish(checker)
            }
        }
    }
}

// MARK: - DOP-006

/// XOR every byte of every channel with the same mask: every sample's data bits must change by
/// mask << 8 | mask, i.e. bit k of a byte (bit 7 its oldest sample) stays bit k of the byte's half of the 16 data
/// bits. Changing every byte the same way leaves byte order and time order (DOP-004), channel routing (DOP-005) and
/// inversion (DOP-007) out.
private func checkBitOrderWithinByte(_ subject: any DoPPacker, _ checker: Checker) {
    let req = "DOP-006"
    var rng = SplitMix64(0xD0_0061)
    let cases = [Shape(1, 2), Shape(1, 4), Shape(1, 10), Shape(1, 64), Shape(1, 1026), Shape(2, 2), Shape(2, 16),
                 Shape(3, 6), Shape(6, 30), Shape(8, 8), Shape(16, 6), Shape(32, 2)]
    for (index, shape) in cases.enumerated() {
        let first = markers[index % 2]
        for base in [rng.input(shape), uniform(shape, 0x00)] {
            guard let outBase = pack(subject, base, first, checker, req) else { continue }
            for mask in bitMasks {
                let changed = base.map { channel in channel.map { $0 ^ mask } }
                guard let outChanged = pack(subject, changed, first, checker, req) else { continue }
                let want = UInt32(mask) << 8 | UInt32(mask)
                var tally = Tally(req, "\(describe(base, first)), every byte XOR \(hex8(mask))")
                for c in 0..<shape.channels {
                    let n = min(available(outBase, c, shape.periods), available(outChanged, c, shape.periods))
                    for j in 0..<n {
                        let diff = dataOf(outBase[c][j]) ^ dataOf(outChanged[c][j])
                        tally.check(diff == want, checker,
                                    "channel \(c) sample \(j): data bits changed by \(hex16(diff)), want \(hex16(want)) (a byte's most significant bit is its oldest sample, so bit k of each byte stays bit k of its half)")
                    }
                }
                tally.finish(checker)
            }
        }
    }
}

// MARK: - DOP-007

/// One output array per input channel, each with one sample per two input bytes (none for empty channels).
private func checkSampleCounts(_ subject: any DoPPacker, _ checker: Checker) {
    let req = "DOP-007"
    var rng = SplitMix64(0xD0_0071)
    let empty = [Shape(1, 0), Shape(2, 0), Shape(5, 0), Shape(8, 0)]
    for (index, shape) in (empty + shapes + longShapes).enumerated() {
        let firsts = index < empty.count ? markers : [markers[index % 2]]
        for first in firsts {
            let dsd = rng.input(shape)
            guard let out = pack(subject, dsd, first, checker, req) else { continue }
            checker.expect(out.count == shape.channels, req,
                           "\(describe(dsd, first)): \(out.count) output arrays, want one per channel (\(shape.channels))")
            for c in 0..<min(out.count, shape.channels) {
                checker.expect(out[c].count == shape.periods, req,
                               "\(describe(dsd, first)): channel \(c) has \(out[c].count) samples, want \(shape.periods) (one per two bytes)")
            }
        }
    }
}

/// Data bits of sample j of channel c are byte 2j (its oldest sample at bit 15) above byte 2j + 1.
private func checkExactData(_ subject: any DoPPacker, _ checker: Checker) {
    let req = "DOP-007"
    var rng = SplitMix64(0xD0_0072)
    for (index, shape) in (shapes + longShapes).enumerated() {
        var ramp: [[UInt8]] = []
        for c in 0..<shape.channels {
            var channel = [UInt8](repeating: 0, count: shape.bytes)
            for j in 0..<shape.periods {
                channel[2 * j] = UInt8(truncatingIfNeeded: (j >> 8) &+ 16 &* c)
                channel[2 * j + 1] = UInt8(truncatingIfNeeded: j)
            }
            ramp.append(channel)
        }
        var runs: [([[UInt8]], UInt8)] = []
        if index < shapes.count {
            // Both markers on random data, so the data never depends on the marker.
            runs.append((rng.input(shape), markers[0]))
            runs.append((rng.input(shape), markers[1]))
            runs.append((ramp, markers[index % 2]))
        } else {
            runs.append((rng.input(shape), markers[index % 2]))
            runs.append((ramp, markers[(index + 1) % 2]))
        }
        for (dsd, first) in runs {
            guard let out = pack(subject, dsd, first, checker, req) else { continue }
            var tally = Tally(req, describe(dsd, first))
            for c in 0..<shape.channels {
                for j in 0..<available(out, c, shape.periods) {
                    let got = dataOf(out[c][j])
                    let want = word(dsd[c][2 * j], dsd[c][2 * j + 1])
                    tally.check(got == want, checker,
                                "channel \(c) sample \(j): data bits \(hex16(got)), want \(hex16(want)) (bytes \(2 * j) and \(2 * j + 1) of the channel)")
                }
            }
            tally.finish(checker)
        }
    }
}

/// One DSD sample differs from all the others (a lone 1 among 0s, or a lone 0 among 1s): the output carries
/// exactly one differing bit, in the channel, sample period and bit the sample belongs to.
private func checkLoneBit(_ subject: any DoPPacker, _ checker: Checker, lone: UInt8) {
    let req = "DOP-007"
    var rng = SplitMix64(lone == 1 ? 0xD0_0073 : 0xD0_0074)
    let cases = [Shape(1, 2), Shape(1, 4), Shape(1, 6), Shape(2, 2), Shape(2, 4), Shape(3, 4), Shape(4, 2),
                 Shape(1, 1026), Shape(3, 258)]
    let background: UInt8 = lone == 1 ? 0x00 : 0xFF
    for (index, shape) in cases.enumerated() {
        let first = markers[index % 2]
        let bits = shape.bytes * 8
        var times: [Int]
        if bits <= 64 {
            times = Array(0..<max(0, bits))
        } else {
            times = [0, 1, 7, 8, 9, 15, 16, 17, 31, 32, bits / 2, bits - 17, bits - 16, bits - 9, bits - 8, bits - 1]
            for _ in 0..<8 { times.append(rng.below(bits)) }
            times = times.filter { $0 >= 0 && $0 < bits }
        }
        for k in 0..<shape.channels {
            for t in times {
                var dsd = uniform(shape, background)
                let bit = UInt8(0x80) >> UInt8(t % 8)
                if lone == 1 { dsd[k][t / 8] |= bit } else { dsd[k][t / 8] &= ~bit }
                guard let out = pack(subject, dsd, first, checker, req) else { continue }
                let period = t / 16
                let position = 15 - t % 16
                var carried = 0
                var inPlace = false
                for c in 0..<shape.channels {
                    for j in 0..<available(out, c, shape.periods) {
                        let data = dataOf(out[c][j])
                        let differing = lone == 1 ? data : ~data & 0xFFFF
                        carried += differing.nonzeroBitCount
                        if c == k && j == period { inPlace = (differing >> UInt32(position)) & 1 == 1 }
                    }
                }
                let what = "\(describe(dsd, first)): DSD sample \(t) of channel \(k) (byte \(t / 8), bit \(7 - t % 8)) is the only \(lone)"
                checker.expect(carried == 1, req, "\(what); the output's data bits hold \(carried) such bits, want 1")
                checker.expect(inPlace, req, "\(what); it is not at channel \(k), sample \(period), bit \(position)")
            }
        }
    }
}

/// Each sample's 16 data bits have as many 1s as the two input bytes of its period.
private func checkBitCounts(_ subject: any DoPPacker, _ checker: Checker) {
    let req = "DOP-007"
    var rng = SplitMix64(0xD0_0075)
    for (index, shape) in shapes.enumerated() {
        let first = markers[index % 2]
        let dsd = rng.input(shape)
        guard let out = pack(subject, dsd, first, checker, req) else { continue }
        var tally = Tally(req, describe(dsd, first))
        for c in 0..<shape.channels {
            for j in 0..<available(out, c, shape.periods) {
                let got = dataOf(out[c][j]).nonzeroBitCount
                let want = dsd[c][2 * j].nonzeroBitCount + dsd[c][2 * j + 1].nonzeroBitCount
                tally.check(got == want, checker,
                            "channel \(c) sample \(j): \(got) data bits set, but bytes \(2 * j) and \(2 * j + 1) hold \(want) 1s")
            }
        }
        tally.finish(checker)
    }
}

/// All-0 DSD data gives data bits 0x0000 and all-1 data gives 0xFFFF.
private func checkConstantData(_ subject: any DoPPacker, _ checker: Checker) {
    let req = "DOP-007"
    for (index, shape) in (shapes + longShapes).enumerated() {
        for value: UInt8 in [0x00, 0xFF] {
            let first = markers[(index + Int(value & 1)) % 2]
            let dsd = uniform(shape, value)
            guard let out = pack(subject, dsd, first, checker, req) else { continue }
            let want: UInt32 = value == 0 ? 0x0000 : 0xFFFF
            var tally = Tally(req, "\(describe(dsd, first)), every byte \(hex8(value))")
            for c in 0..<shape.channels {
                for j in 0..<available(out, c, shape.periods) {
                    let got = dataOf(out[c][j])
                    tally.check(got == want, checker, "channel \(c) sample \(j): data bits \(hex16(got)), want \(hex16(want))")
                }
            }
            tally.finish(checker)
        }
    }
}
