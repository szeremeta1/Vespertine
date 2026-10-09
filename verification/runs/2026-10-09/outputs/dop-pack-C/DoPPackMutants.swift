//
// Deliberately wrong DoP packers ("mutants"), each a decorator over a correct packer.
// Every mutant first calls the correct packer (so invalid input still throws InvalidInput exactly as the
// contract says), then rewrites the correct output. No mutant traps or loops on any input.
//

import Contracts
import SpecKit

// MARK: - Decorator

/// A packer that runs the correct `base` and then rewrites its (correct) output.
private struct Rewritten: DoPPacker {
    let base: any DoPPacker
    /// (input, firstMarker, correct output) -> mutated output. Only called after `base` accepted the input.
    let rewrite: @Sendable (_ dsd: [[UInt8]], _ firstMarker: UInt8, _ out: [[UInt32]]) -> [[UInt32]]

    func dopPack(dsd: [[UInt8]], firstMarker: UInt8) throws -> [[UInt32]] {
        let out = try base.dopPack(dsd: dsd, firstMarker: firstMarker)
        return rewrite(dsd, firstMarker, out)
    }
}

private func mutant(_ id: String, _ targets: [String], _ summary: String,
                    _ rewrite: @escaping @Sendable (_ dsd: [[UInt8]], _ firstMarker: UInt8, _ out: [[UInt32]]) -> [[UInt32]])
    -> Mutant<any DoPPacker> {
    Mutant(id, targets: targets, summary: summary) { base in Rewritten(base: base, rewrite: rewrite) }
}

// MARK: - Sample helpers (all total: no traps)

/// Flipping all 8 marker bits turns 0x05 into 0xFA and back.
private let markerBits: UInt32 = 0x00FF_0000

private func dataField(_ v: UInt32) -> UInt32 { v & 0xFFFF }
private func withData(_ v: UInt32, _ d: UInt32) -> UInt32 { (v & 0xFFFF_0000) | (d & 0xFFFF) }
private func hiByte(_ v: UInt32) -> UInt32 { (v >> 8) & 0xFF }
private func loByte(_ v: UInt32) -> UInt32 { v & 0xFF }

/// Bit-reverses one byte (LSB-first reading).
private func reverse8(_ b: UInt32) -> UInt32 {
    var r: UInt32 = 0
    for k in 0..<8 where (b >> UInt32(k)) & 1 == 1 { r |= 1 << UInt32(7 - k) }
    return r
}

/// Applies `f(channel, period, sample)` to every sample.
private func mapSamples(_ out: [[UInt32]], _ f: (Int, Int, UInt32) -> UInt32) -> [[UInt32]] {
    var result = out
    for c in result.indices {
        for j in result[c].indices { result[c][j] = f(c, j, out[c][j]) }
    }
    return result
}

/// Sample `j` of channel `c`, or nil.
private func sample(_ out: [[UInt32]], _ c: Int, _ j: Int) -> UInt32? {
    guard c >= 0, c < out.count, j >= 0, j < out[c].count else { return nil }
    return out[c][j]
}

// MARK: - Mutants

public enum DoPPackMutants {
    public static let all: [Mutant<any DoPPacker>] = [

        // ---------------------------------------------------------------- DOP-001: 24-bit layout
        mutant("C-DOP-001-a", ["DOP-001"],
               "every sample also carries its marker in bits 31..24, so it is not a 24-bit value") { _, _, out in
            mapSamples(out) { _, _, v in v | ((v & markerBits) << 8) }
        },
        mutant("C-DOP-001-b", ["DOP-001"],
               "24-bit sample sign-extended to 32 bits: 0xFA-marked samples get 0xFF in bits 31..24") { _, _, out in
            mapSamples(out) { _, _, v in (v & 0x0080_0000) != 0 ? (v | 0xFF00_0000) : v }
        },
        mutant("C-DOP-001-c", ["DOP-001"],
               "alternate marker made with a 32-bit NOT: every odd sample period has 0xFF in bits 31..24") { _, _, out in
            mapSamples(out) { _, j, v in j % 2 == 1 ? (v | 0xFF00_0000) : v }
        },

        // ---------------------------------------------------------------- DOP-002: marker alternation
        mutant("C-DOP-002-a", ["DOP-002"],
               "marker never alternates: every sample carries firstMarker") { _, first, out in
            mapSamples(out) { _, _, v in (UInt32(first) << 16) | dataField(v) }
        },
        mutant("C-DOP-002-b", ["DOP-002"],
               "marker phase restarts with firstMarker every 1023 periods, repeating a marker at periods 1022/1023, 2045/2046, ...") { _, _, out in
            mapSamples(out) { _, j, v in (j / 1023) % 2 == 1 ? (v ^ markerBits) : v }
        },
        mutant("C-DOP-002-c", ["DOP-002"],
               "periods 0 and 1 both carry firstMarker; alternation only starts after that") { _, _, out in
            mapSamples(out) { _, j, v in j >= 1 ? (v ^ markerBits) : v }
        },
        mutant("C-DOP-002-d", ["DOP-002", "DOP-001"],
               "alternate marker is the two's-complement negation of firstMarker (0x05->0xFB, 0xFA->0x06) on odd periods") { _, first, out in
            let other = (0x100 - UInt32(first)) & 0xFF
            return mapSamples(out) { _, j, v in j % 2 == 1 ? ((other << 16) | dataField(v)) : v }
        },

        // ---------------------------------------------------------------- DOP-003: same marker across channels
        mutant("C-DOP-003-a", ["DOP-003"],
               "odd-numbered channels (1, 3, ...) run with the opposite marker phase") { _, _, out in
            mapSamples(out) { c, _, v in c % 2 == 1 ? (v ^ markerBits) : v }
        },
        mutant("C-DOP-003-b", ["DOP-003"],
               "one marker toggle shared across a channel-major loop: with an odd period count, odd channels start on the opposite marker") { _, _, out in
            mapSamples(out) { c, _, v in
                let periods = out[c].count
                return (c % 2 == 1 && periods % 2 == 1) ? (v ^ markerBits) : v
            }
        },
        mutant("C-DOP-003-c", ["DOP-003"],
               "channels 2 and up (only with 3+ channels) run with the opposite marker phase") { _, _, out in
            mapSamples(out) { c, _, v in c >= 2 ? (v ^ markerBits) : v }
        },

        // ---------------------------------------------------------------- DOP-004: 16 bits in time order, t0 = bit 15
        mutant("C-DOP-004-a", ["DOP-004", "DOP-007"],
               "the two bytes of each sample are swapped: the later 8 DSD samples land in bits 15..8") { _, _, out in
            mapSamples(out) { _, _, v in withData(v, (loByte(v) << 8) | hiByte(v)) }
        },
        mutant("C-DOP-004-b", ["DOP-004", "DOP-007"],
               "periods come out in reverse time order: sample j carries the DSD bits of period n-1-j (markers correct)") { _, _, out in
            mapSamples(out) { c, j, v in
                let n = out[c].count
                return withData(v, dataField(sample(out, c, n - 1 - j) ?? v))
            }
        },
        mutant("C-DOP-004-c", ["DOP-004", "DOP-007"],
               "slots t7 and t8 exchanged: bit 8 and bit 7 of every sample's DSD data are swapped") { _, _, out in
            mapSamples(out) { _, _, v in
                let b8 = (v >> 8) & 1, b7 = (v >> 7) & 1
                return (v & ~UInt32(0x0180)) | (b8 << 7) | (b7 << 8)
            }
        },
        mutant("C-DOP-004-d", ["DOP-004", "DOP-007"],
               "period index wraps at 256 (UInt8): from period 256 on, samples repeat the DSD bits of period j % 256") { _, _, out in
            mapSamples(out) { c, j, v in
                j >= 256 ? withData(v, dataField(sample(out, c, j % 256) ?? v)) : v
            }
        },

        // ---------------------------------------------------------------- DOP-005: only own channel's data
        mutant("C-DOP-005-a", ["DOP-005", "DOP-004", "DOP-007"],
               "channel c carries the DSD data of channel (c+1) mod channelCount (markers correct)") { _, _, out in
            mapSamples(out) { c, j, v in
                let other = (c + 1) % max(out.count, 1)
                return withData(v, dataField(sample(out, other, j) ?? v))
            }
        },
        mutant("C-DOP-005-b", ["DOP-005", "DOP-004", "DOP-007"],
               "tail bug: the last sample of every channel after the first carries channel 0's last 16 DSD bits") { _, _, out in
            mapSamples(out) { c, j, v in
                guard c >= 1, j == out[c].count - 1 else { return v }
                return withData(v, dataField(sample(out, 0, j) ?? v))
            }
        },
        mutant("C-DOP-005-c", ["DOP-005", "DOP-004", "DOP-007"],
               "crosstalk: bit 0 (slot t15) of each sample comes from the next channel's sample (2+ channels)") { _, _, out in
            mapSamples(out) { c, j, v in
                let other = (c + 1) % max(out.count, 1)
                let bit = (sample(out, other, j) ?? v) & 1
                return (v & ~UInt32(1)) | bit
            }
        },

        // ---------------------------------------------------------------- DOP-006: each byte read MSB first
        mutant("C-DOP-006-a", ["DOP-006", "DOP-004", "DOP-007"],
               "every input byte is read least significant bit first (bit-reversed)") { _, _, out in
            mapSamples(out) { _, _, v in withData(v, (reverse8(hiByte(v)) << 8) | reverse8(loByte(v))) }
        },
        mutant("C-DOP-006-b", ["DOP-006", "DOP-004", "DOP-007"],
               "only the second byte of each sample (bits 7..0) is read least significant bit first") { _, _, out in
            mapSamples(out) { _, _, v in withData(v, (hiByte(v) << 8) | reverse8(loByte(v))) }
        },
        mutant("C-DOP-006-c", ["DOP-006", "DOP-004", "DOP-007"],
               "each input byte is read low nibble first (nibbles swapped, each nibble MSB first)") { _, _, out in
            mapSamples(out) { _, _, v in
                let h = hiByte(v), l = loByte(v)
                let hs = ((h << 4) | (h >> 4)) & 0xFF, ls = ((l << 4) | (l >> 4)) & 0xFF
                return withData(v, (hs << 8) | ls)
            }
        },

        // ---------------------------------------------------------------- DOP-007: every bit exactly once
        mutant("C-DOP-007-a", ["DOP-007"],
               "the last sample of every non-empty channel is dropped (one sample short)") { _, _, out in
            out.map { ch in ch.isEmpty ? ch : Array(ch.dropLast()) }
        },
        mutant("C-DOP-007-b", ["DOP-007"],
               "every non-empty channel gets one extra trailing sample repeating its last 16 DSD bits (marker continues the alternation)") { _, _, out in
            out.map { ch in
                guard let last = ch.last else { return ch }
                return ch + [last ^ markerBits]
            }
        },
        mutant("C-DOP-007-c", ["DOP-007"],
               "output is cut off after 4096 sample periods (longer input loses its tail)") { _, _, out in
            out.map { ch in ch.count > 4096 ? Array(ch.prefix(4096)) : ch }
        },
        mutant("C-DOP-007-d", ["DOP-007", "DOP-004"],
               "DSD polarity inverted: all 16 DSD bits of every sample are complemented (markers correct)") { _, _, out in
            mapSamples(out) { _, _, v in v ^ 0xFFFF }
        },
    ]
}
