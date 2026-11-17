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

    let sender = AirPlay2Sender(deviceID: AirPlay2Sender.deviceID([0x02, 0x1A, 0xFF, 0x00, 0x9C, 0x07]), name: "Vespertine", model: "Mac14,5", osVersion: "15.1")

    @Test("A moment is whole seconds and a 64-bit fraction, and comes back to the nanosecond")
    func networkTime() {
        #expect(AirPlay2NetworkTime(nanoseconds: 0) == AirPlay2NetworkTime(seconds: 0, fraction: 0))
        #expect(AirPlay2NetworkTime(nanoseconds: 1_500_000_000) == AirPlay2NetworkTime(seconds: 1, fraction: 1 << 63))
        #expect(AirPlay2NetworkTime(nanoseconds: 250_000_000) == AirPlay2NetworkTime(seconds: 0, fraction: 1 << 62))
        #expect(AirPlay2NetworkTime(seconds: 7, fraction: 1 << 63).nanoseconds == 7_500_000_000)
        // Rounded down on the way out, so never more than a nanosecond short on the way back.
        for nanos: UInt64 in [1, 999_999_999, 1_000_000_001, 1_763_400_000_123_456_789, 86_400_000_000_000 - 1] {
            let back = AirPlay2NetworkTime(nanoseconds: nanos).nanoseconds
            #expect(back == nanos || back == nanos - 1, "\(nanos)")
        }
    }

    @Test("The first SETUP of a buffered session names this Mac's PTP clock and a group, and no NTP port")
    func sessionSetup() throws {
        let uuid = try #require(UUID(uuidString: "6E1F4C0A-3B7D-4E55-9C21-0A1B2C3D4E5F"))
        let group = try #require(UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"))
        let body = AirPlay2Message.bufferedSessionSetup(sender: sender, sessionUUID: uuid, groupUUID: group, addresses: ["192.168.1.20", "fe80::1"])
        let said = try #require(AirPlay2Message.decode(body))
        #expect(said["timingProtocol"] as? String == "PTP")
        #expect(said["timingPort"] == nil)
        let peer = try #require(said["timingPeerInfo"] as? [String: Any])
        #expect(peer["Addresses"] as? [String] == ["192.168.1.20", "fe80::1"])
        #expect(peer["ID"] as? String == "192.168.1.20")
        #expect(said["groupUUID"] as? String == "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")
        #expect(said["groupContainsGroupLeader"] as? Bool == false)
        #expect(said["sessionUUID"] as? String == "6E1F4C0A-3B7D-4E55-9C21-0A1B2C3D4E5F")
        #expect(said["deviceID"] as? String == "02:1A:FF:00:9C:07")
        #expect(said["name"] as? String == "Vespertine")
    }

    @Test("The stream SETUP asks for a buffered stream of 24-bit ALAC at 48 kHz, and its answer gives the port and the room")
    func streamSetup() throws {
        let body = AirPlay2Message.bufferedStreamSetup(key: Data(0..<32), connectionID: 0xDEAD_BEEF, kind: deep)
        let streams = try #require(AirPlay2Message.decode(body)?["streams"] as? [[String: Any]])
        #expect(streams.count == 1)
        let stream = streams[0]
        #expect(stream["type"] as? Int == 103)
        #expect(stream["audioFormat"] as? Int == 0x200000)
        #expect(stream["ct"] as? Int == 2)
        #expect(stream["sr"] as? Int == 48_000)
        #expect(stream["spf"] as? Int == 352)
        #expect(stream["shk"] as? Data == Data(0..<32))
        #expect(stream["streamConnectionID"] as? Int == 0xDEAD_BEEF)
        // A buffered stream has no control port and no latency to agree: the sender says when each frame plays.
        #expect(stream["controlPort"] == nil)
        #expect(stream["latencyMin"] == nil)

        let answer: [String: Any] = ["streams": [["type": 103, "dataPort": 40_123, "audioBufferSize": 8_388_608]]]
        let read = try #require(AirPlay2Message.bufferedStream(in: AirPlay2Message.encode(answer)))
        #expect(read.dataPort == 40_123)
        #expect(read.bufferSize == 8_388_608)
        // An answer for a realtime stream, one with no room, and one with no port are not this.
        let realtime: [String: Any] = ["streams": [["type": 96, "dataPort": 40_123, "controlPort": 40_124]]]
        #expect(AirPlay2Message.bufferedStream(in: AirPlay2Message.encode(realtime)) == nil)
        let noRoom: [String: Any] = ["streams": [["type": 103, "dataPort": 40_123, "audioBufferSize": 0]]]
        #expect(AirPlay2Message.bufferedStream(in: AirPlay2Message.encode(noRoom)) == nil)
        let noPort: [String: Any] = ["streams": [["type": 103, "audioBufferSize": 8_388_608]]]
        #expect(AirPlay2Message.bufferedStream(in: AirPlay2Message.encode(noPort)) == nil)
        #expect(AirPlay2Message.bufferedStream(in: Data()) == nil)
    }

    @Test("Play names a frame, the moment it sounds and the clock, bit for bit; pause and flush say only what they mean")
    func anchors() throws {
        // A fraction and a clock identity with the top bit set: both must arrive as the same 64 bits.
        let time = AirPlay2NetworkTime(seconds: 1_763_400_000, fraction: 0xC000_0000_0000_0001)
        let clock: UInt64 = 0xF0_18_98_FF_FE_12_34_56
        let said = try #require(AirPlay2Message.decode(AirPlay2Message.play(rtpTime: 4_000_000_000, at: time, clock: clock)))
        #expect(said["rate"] as? Int == 1)
        #expect(said["rtpTime"] as? Int == 4_000_000_000)
        #expect(said["networkTimeSecs"] as? Int == 1_763_400_000)
        #expect((said["networkTimeFrac"] as? Int).map { UInt64(bitPattern: Int64($0)) } == 0xC000_0000_0000_0001)
        #expect((said["networkTimeTimelineID"] as? Int).map { UInt64(bitPattern: Int64($0)) } == clock)

        let paused = try #require(AirPlay2Message.decode(AirPlay2Message.pause()))
        #expect(paused["rate"] as? Int == 0)
        #expect(paused.count == 1)

        let flush = try #require(AirPlay2Message.decode(AirPlay2Message.flushBuffered(untilSequence: 0x80_0005, untilTimestamp: 4_100_000_000)))
        #expect(flush["flushUntilSeq"] as? Int == 5)
        #expect(flush["flushUntilTS"] as? Int == 4_100_000_000)
        #expect(flush.count == 2)
    }

    @Test("The clocks of a session are told as a bare list of addresses")
    func peers() throws {
        let body = AirPlay2Message.peers(["192.168.1.20", "192.168.1.31"])
        #expect(body.prefix(8) == Data("bplist00".utf8))
        let list = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String]
        #expect(list == ["192.168.1.20", "192.168.1.31"])
    }
}
