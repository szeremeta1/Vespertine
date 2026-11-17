//
// Vespertine: the AirPlay 2 session's messages: what the two SETUP requests say and how their answers are read, the keys
// of the event connection, and the sealed audio packet against packets worked out independently (Python's cryptography
// package, ChaCha20-Poly1305).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import Testing
@testable import VespertineAirPlay

@Suite("AirPlay 2 session messages")
struct AirPlay2MessagesTests {
    let sender = AirPlay2Sender(deviceID: AirPlay2Sender.deviceID([0x02, 0x1A, 0xFF, 0x00, 0x9C, 0x07]), name: "Vespertine", model: "Mac14,5", osVersion: "15.1")
    let key = SymmetricKey(data: Data(0..<32))

    @Test("The first SETUP says who is sending and where to ask the time, as a binary property list")
    func sessionSetup() throws {
        #expect(sender.deviceID == "02:1A:FF:00:9C:07")
        let uuid = try #require(UUID(uuidString: "6E1F4C0A-3B7D-4E55-9C21-0A1B2C3D4E5F"))
        let body = AirPlay2Message.sessionSetup(sender: sender, sessionUUID: uuid, timingPort: 51_234)
        #expect(body.prefix(8) == Data("bplist00".utf8))
        let said = try #require(AirPlay2Message.decode(body))
        #expect(said["deviceID"] as? String == "02:1A:FF:00:9C:07")
        #expect(said["macAddress"] as? String == "02:1A:FF:00:9C:07")
        #expect(said["sessionUUID"] as? String == "6E1F4C0A-3B7D-4E55-9C21-0A1B2C3D4E5F")
        #expect(said["timingPort"] as? Int == 51_234)
        #expect(said["timingProtocol"] as? String == "NTP")
        #expect(said["name"] as? String == "Vespertine")
        #expect(said["model"] as? String == "Mac14,5")
        #expect(said["osVersion"] as? String == "15.1")
        #expect(said["isMultiSelectAirPlay"] as? Bool == true)
        #expect(said["groupContainsGroupLeader"] as? Bool == false)
        #expect(said["senderSupportsRelay"] as? Bool == false)
        #expect(said["statsCollectionEnabled"] as? Bool == false)
        #expect(said.count == 14)
    }

    @Test("The event port is read from the first answer, and an answer without a usable one gives none")
    func eventPort() {
        #expect(AirPlay2Message.eventPort(in: AirPlay2Message.encode(["eventPort": 49_152, "timingPort": 0])) == 49_152)
        #expect(AirPlay2Message.eventPort(in: AirPlay2Message.encode(["eventPort": 0])) == nil)
        #expect(AirPlay2Message.eventPort(in: AirPlay2Message.encode(["eventPort": 70_000])) == nil)
        #expect(AirPlay2Message.eventPort(in: AirPlay2Message.encode(["eventPort": "49152"])) == nil)
        #expect(AirPlay2Message.eventPort(in: AirPlay2Message.encode(["timingPort": 5])) == nil)
        #expect(AirPlay2Message.eventPort(in: Data("not a property list".utf8)) == nil)
        #expect(AirPlay2Message.eventPort(in: Data()) == nil)
    }

    @Test("The second SETUP describes one stream: realtime ALAC at 44.1 kHz, 352 frames a packet, and the key")
    func streamSetup() throws {
        let shk = Data((0..<32).map { UInt8($0 * 3) })
        let body = AirPlay2Message.streamSetup(controlPort: 6_001, key: shk, connectionID: 0xDEAD_BEEF)
        let said = try #require(AirPlay2Message.decode(body))
        let streams = try #require(said["streams"] as? [[String: Any]])
        #expect(said.count == 1)
        #expect(streams.count == 1)
        let stream = streams[0]
        #expect(stream["type"] as? Int == 96)
        #expect(stream["audioFormat"] as? Int == 0x40000)
        #expect(stream["ct"] as? Int == 2)
        #expect(stream["audioMode"] as? String == "default")
        #expect(stream["controlPort"] as? Int == 6_001)
        #expect(stream["isMedia"] as? Bool == true)
        #expect(stream["latencyMin"] as? Int == 11_025)
        #expect(stream["latencyMax"] as? Int == 88_200)
        #expect(stream["shk"] as? Data == shk)
        #expect(stream["spf"] as? Int == 352)
        #expect(stream["sr"] as? Int == 44_100)
        #expect(stream["supportsDynamicStreamID"] as? Bool == false)
        #expect(stream["streamConnectionID"] as? Int == 0xDEAD_BEEF)
        #expect(stream.count == 13)
    }

    @Test("The receiver's audio and control ports are read from the second answer; both are needed")
    func streamPorts() throws {
        let answer = AirPlay2Message.encode(["streams": [["type": 96, "dataPort": 50_001, "controlPort": 50_002, "streamID": 1]]])
        let ports = try #require(AirPlay2Message.streamPorts(in: answer))
        #expect(ports.data == 50_001)
        #expect(ports.control == 50_002)
        #expect(AirPlay2Message.streamPorts(in: AirPlay2Message.encode(["streams": [["dataPort": 50_001]]])) == nil)
        #expect(AirPlay2Message.streamPorts(in: AirPlay2Message.encode(["streams": [["dataPort": 50_001, "controlPort": 0]]])) == nil)
        #expect(AirPlay2Message.streamPorts(in: AirPlay2Message.encode(["streams": [String]()])) == nil)
        #expect(AirPlay2Message.streamPorts(in: AirPlay2Message.encode(["eventPort": 5])) == nil)
    }

    @Test("The event connection's keys are the other way round from the control connection's, and differ from them")
    func eventKeys() {
        let secret = Data((0..<64).map { UInt8(255 - $0) })
        let events = PairingChannelKeys.events(secret: secret)
        #expect(events.write == PairingCrypto.key(secret: secret, salt: "Events-Salt", info: "Events-Read-Encryption-Key"))
        #expect(events.read == PairingCrypto.key(secret: secret, salt: "Events-Salt", info: "Events-Write-Encryption-Key"))
        #expect(events.write != events.read)
        let control = PairingChannelKeys.control(secret: secret)
        #expect(events.write != control.write && events.write != control.read && events.read != control.write && events.read != control.read)
    }

    @Test("The audio key is the first 32 bytes of the session's secret, long or short")
    func audioKey() {
        let long = Data((0..<64).map { UInt8($0) })
        #expect(AirPlay2Audio.key(secret: long) == Data(0..<32))
        #expect(AirPlay2Audio.key(secret: Data(0..<32)) == Data(0..<32))
        #expect(AirPlay2Audio.key(secret: Data(0..<31)) == nil)
        // From the middle of other bytes, the key still counts from zero.
        let slice = (Data([9, 9]) + long).dropFirst(2)
        #expect(AirPlay2Audio.key(secret: slice)?.startIndex == 0)
        #expect(AirPlay2Audio.key(secret: slice) == Data(0..<32))
    }

    @Test("An audio packet is the one worked out independently: header in the clear, sealed audio, tag, nonce")
    func packetVector() throws {
        let packet = try AirPlay2Audio.packet(seq: 0x1234, timestamp: 0x0102_0304, ssrc: 0xAABB_CCDD, payload: Data(0..<40), first: true, key: key, counter: 7)
        #expect(packet == hex("80e0123401020304aabbccddf10e864b26ed7c8e6a3f4438f0851e95228cb052e5f81f12b28329fcfbf4c903300cb43aeec2d53e1ab1d5870e10782bf6216ef1218f3fe30700000000000000"))
        #expect(packet.count == 12 + 40 + 16 + 8)
        // No audio at all, a count that fills all eight bytes, the highest sequence number.
        let empty = try AirPlay2Audio.packet(seq: 0xFFFF, timestamp: 0xFFFF_FFF0, ssrc: 1, payload: Data(), first: false, key: key, counter: 0x0102_0304_0506_0708)
        #expect(empty == hex("8060fffffffffff0000000019f2adc2d3e8323b160143d6916c5b0360807060504030201"))
    }

    @Test("A receiver with the key reads the packet back; a changed byte anywhere but the sequence number, or another key, doesn't open")
    func packetOpens() throws {
        let payload = Data((0..<1_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let packet = try AirPlay2Audio.packet(seq: 65_000, timestamp: 4_000_000_000, ssrc: 77, payload: payload, first: false, key: key, counter: 123_456)
        let read = try #require(AirPlay2Audio.open(packet, key: key))
        #expect(read.seq == 65_000)
        #expect(read.timestamp == 4_000_000_000)
        #expect(read.first == false)
        #expect(read.payload == payload)
        let marked = try AirPlay2Audio.packet(seq: 1, timestamp: 2, ssrc: 3, payload: payload, first: true, key: key, counter: 0)
        #expect(AirPlay2Audio.open(marked, key: key)?.first == true)
        // Read from the middle of a longer buffer.
        let inside = (Data([1, 2, 3]) + packet).dropFirst(3)
        #expect(AirPlay2Audio.open(inside, key: key)?.payload == payload)

        // The time and source (bytes 4 to 11) are authenticated, the audio and tag sealed, the nonce part of the seal.
        for index in [4, 7, 8, 11, 12, 500, packet.count - 9, packet.count - 8, packet.count - 1] {
            var changed = packet
            changed[index] ^= 0x01
            #expect(AirPlay2Audio.open(changed, key: key) == nil, "byte \(index)")
        }
        #expect(AirPlay2Audio.open(packet, key: SymmetricKey(data: Data(repeating: 1, count: 32))) == nil)
        #expect(AirPlay2Audio.open(packet.prefix(35), key: key) == nil)
        #expect(AirPlay2Audio.open(Data(), key: key) == nil)
        // Not an audio packet (a sync packet's type).
        var other = packet
        other[1] = 0xD4
        #expect(AirPlay2Audio.open(other, key: key) == nil)
    }

    @Test("Packets sealed with different counts differ even when everything else is the same")
    func packetCounts() throws {
        let a = try AirPlay2Audio.packet(seq: 1, timestamp: 2, ssrc: 3, payload: Data(0..<16), first: false, key: key, counter: 1)
        let b = try AirPlay2Audio.packet(seq: 1, timestamp: 2, ssrc: 3, payload: Data(0..<16), first: false, key: key, counter: 2)
        #expect(a.prefix(12) == b.prefix(12))
        #expect(a.subdata(in: 12..<28) != b.subdata(in: 12..<28))
        #expect(a.suffix(8) == Data([1, 0, 0, 0, 0, 0, 0, 0]))
        #expect(b.suffix(8) == Data([2, 0, 0, 0, 0, 0, 0, 0]))
    }
}
