//
// Vespertine: the block of an AirPlay 2 buffered stream, against blocks worked out independently (Python's cryptography
// package, ChaCha20-Poly1305), read back, changed, and cut out of a connection's bytes as they arrive.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import Testing
@testable import VespertineAirPlay

@Suite("AirPlay 2 buffered audio blocks")
struct AirPlay2BufferedTests {
    let key = SymmetricKey(data: Data(0..<32))
    let deep = AirPlay2Buffered.Kind.alac48000Deep

    @Test("The one kind of audio a buffered stream of ours carries is 24-bit ALAC at 48 kHz, and no other format has a kind")
    func kinds() {
        #expect(deep.rawValue == 0x1500_0000)
        #expect(deep.format == AirPlayFormat(sampleRate: 48_000, bitDepth: 24))
        #expect(AirPlay2Buffered.Kind(format: AirPlayFormat(sampleRate: 48_000, bitDepth: 24)) == deep)
        #expect(AirPlay2Buffered.Kind(format: .cd) == nil)
        #expect(AirPlay2Buffered.Kind(format: AirPlayFormat(sampleRate: 44_100, bitDepth: 24)) == nil)
        #expect(AirPlay2Buffered.streamType == 103)
    }

    @Test("A block is the one worked out independently: length, number, time and kind in the clear, sealed audio, tag, nonce")
    func blockVector() throws {
        let block = try AirPlay2Buffered.block(sequence: 0x12_3456, timestamp: 0x0102_0304, kind: deep, payload: Data(0..<40), key: key, counter: 7)
        #expect(block == hex("004e801234560102030415000000f10e864b26ed7c8e6a3f4438f0851e95228cb052e5f81f12b28329fcfbf4c903300cb43aeec2d53ed99e71c31af7d8c3336d86fb1be14a2b0700000000000000"))
        #expect(block.count == 2 + 12 + 40 + 16 + 8)
        // No audio at all, a count that fills all eight bytes, the highest block number.
        let empty = try AirPlay2Buffered.block(sequence: 0x7F_FFFF, timestamp: 0xFFFF_FFF0, kind: deep, payload: Data(), key: key, counter: 0x0102_0304_0506_0708)
        #expect(empty == hex("0026807ffffffffffff0150000005619490f530a6180219be778c2994cfe0807060504030201"))
        // A number past 23 bits wraps, and never spills into the byte before it.
        let wrapped = try AirPlay2Buffered.block(sequence: 0x80_0001, timestamp: 0, kind: deep, payload: Data(), key: key, counter: 0)
        #expect(wrapped.subdata(in: 2..<6) == Data([0x80, 0x00, 0x00, 0x01]))
    }

    @Test("A receiver with the key reads the block back; a changed byte anywhere but its number, or another key, doesn't open")
    func blockOpens() throws {
        // As long as 352 frames of 24-bit stereo that would not compress.
        let payload = Data((0..<2_120).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let block = try AirPlay2Buffered.block(sequence: 8_000_000, timestamp: 4_000_000_000, kind: deep, payload: payload, key: key, counter: 123_456)
        let read = try #require(AirPlay2Buffered.open(block, key: key))
        #expect(read.sequence == 8_000_000)
        #expect(read.timestamp == 4_000_000_000)
        #expect(read.kind == deep.rawValue)
        #expect(read.payload == payload)
        // Read from the middle of a longer buffer.
        let inside = (Data([1, 2, 3]) + block).dropFirst(3)
        #expect(AirPlay2Buffered.open(inside, key: key)?.payload == payload)

        // The length must be the block's own; the time and kind (bytes 6 to 13) are authenticated, the audio and tag
        // sealed, the nonce part of the seal.
        for index in [0, 1, 2, 6, 9, 10, 13, 14, 1_000, block.count - 9, block.count - 8, block.count - 1] {
            var changed = block
            changed[index] ^= 0x01
            #expect(AirPlay2Buffered.open(changed, key: key) == nil, "byte \(index)")
        }
        #expect(AirPlay2Buffered.open(block, key: SymmetricKey(data: Data(repeating: 1, count: 32))) == nil)
        #expect(AirPlay2Buffered.open(block.prefix(37), key: key) == nil)
        #expect(AirPlay2Buffered.open(block.dropLast(), key: key) == nil)
        #expect(AirPlay2Buffered.open(Data(), key: key) == nil)
    }

    @Test("Blocks sealed with different counts differ even when everything else is the same; audio too long for a block is refused")
    func blockCounts() throws {
        let a = try AirPlay2Buffered.block(sequence: 1, timestamp: 2, kind: deep, payload: Data(0..<16), key: key, counter: 1)
        let b = try AirPlay2Buffered.block(sequence: 1, timestamp: 2, kind: deep, payload: Data(0..<16), key: key, counter: 2)
        #expect(a.prefix(14) == b.prefix(14))
        #expect(a.subdata(in: 14..<30) != b.subdata(in: 14..<30))
        // The longest that fits: 65 535 bytes with everything around the audio.
        let most = 65_535 - 2 - 12 - 16 - 8
        #expect(try AirPlay2Buffered.block(sequence: 0, timestamp: 0, kind: deep, payload: Data(count: most), key: key, counter: 0).count == 65_535)
        #expect(throws: PairingCrypto.Failure.malformed) {
            _ = try AirPlay2Buffered.block(sequence: 0, timestamp: 0, kind: deep, payload: Data(count: most + 1), key: key, counter: 0)
        }
    }

    @Test("Blocks are cut out of a connection's bytes however they arrive: whole ones are taken, a part is left for later")
    func split() throws {
        let blocks = try (0..<5).map { i in
            try AirPlay2Buffered.block(sequence: UInt32(i), timestamp: UInt32(i * 352), kind: deep, payload: Data(repeating: UInt8(i), count: 10 + i * 300), key: key,
                                       counter: UInt64(i))
        }
        let all = blocks.reduce(Data(), +)
        let whole = try #require(AirPlay2Buffered.split(all))
        #expect(whole.blocks == blocks)
        #expect(whole.used == all.count)
        // Cut anywhere, what is taken is always whole blocks from the front, and the rest joins what comes next.
        for cut in [0, 1, 2, 3, blocks[0].count - 1, blocks[0].count, blocks[0].count + 1, all.count - 1] {
            let first = try #require(AirPlay2Buffered.split(all.prefix(cut)))
            #expect(first.blocks == Array(blocks.prefix(first.blocks.count)))
            #expect(first.used == first.blocks.reduce(0) { $0 + $1.count })
            let rest = try #require(AirPlay2Buffered.split(all.dropFirst(first.used)))
            #expect(first.blocks + rest.blocks == blocks, "cut at \(cut)")
        }
        // Each one opens to what was sealed.
        for (i, block) in whole.blocks.enumerated() {
            let read = try #require(AirPlay2Buffered.open(block, key: key))
            #expect(read.sequence == UInt32(i))
            #expect(read.payload == Data(repeating: UInt8(i), count: 10 + i * 300))
        }
        #expect(AirPlay2Buffered.split(Data())?.blocks.isEmpty == true)
        // A length no block can have: these bytes aren't blocks.
        #expect(AirPlay2Buffered.split(Data([0x00, 0x05, 1, 2, 3])) == nil)
        #expect(AirPlay2Buffered.split(blocks[0] + Data([0x00, 0x00])) == nil)
    }

    @Test("A 24-bit / 48 kHz packet from the encoder goes through a block and decodes to the samples it was made from")
    func audioThroughBlock() throws {
        let format = deep.format
        var rng = Xorshift(seed: 9)
        let samples: [Int32] = (0..<(352 * 2)).map { _ in Int32((rng.unit() - 0.5) * 8_000_000) }
        let payload = ALACVerbatim.encode(samples: samples, bitDepth: format.bitDepth)
        let block = try AirPlay2Buffered.block(sequence: 0, timestamp: 0, kind: deep, payload: payload, key: key, counter: 0)
        let read = try #require(AirPlay2Buffered.open(block, key: key))
        let decoder = try ALACDecoder(config: format.alac)
        #expect(try decoder.decode(samples: read.payload) == samples)
    }
}
