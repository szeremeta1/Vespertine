//
// Vespertine: a RAOP session against the fake receiver: the handshake, the audio decoded exactly (in the clear and
// encrypted), lost packets sent again, volume, flush and teardown.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network
import Testing
@testable import VespertineAirPlay

func endpoint(_ receiver: FakeRAOPReceiver) -> NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: receiver.port)!) }

func packets(_ count: Int, seed: UInt64 = 9) -> [[Int16]] {
    var rng = Xorshift(seed: seed)
    return (0..<count).map { p in (0..<704).map { i in Int16(truncatingIfNeeded: Int((sin(Double(p * 352 + i / 2) * 0.05) * 20_000)) + Int(rng.next() % 64)) } }
}

@Suite("RAOP session", .serialized)
struct RAOPSessionTests {
    @Test("Handshake in order, with the SDP, ports and RTP-Info; the audio decodes to exactly what was sent")
    func plain() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let session = RAOPSession(name: "Fake", endpoint: endpoint(receiver), encryption: .none)
        try await session.connect(volumeDB: -12)
        #expect(session.usesAppleEncoder)
        #expect(receiver.methods == ["OPTIONS", "ANNOUNCE", "SETUP", "RECORD", "SET_PARAMETER"])
        let r = receiver.requests
        #expect(r[0].url == "*")
        let sdp = String(decoding: r[1].body, as: UTF8.self)
        #expect(sdp.contains("a=fmtp:96 352 0 16 40 10 14 2 255 0 0 44100") && !sdp.contains("rsaaeskey"))
        #expect(r[1]["Content-Type"] == "application/sdp" && r[1]["Apple-Challenge"] == nil)
        #expect(r[2]["Transport"]?.contains("control_port=") == true)
        #expect(r[3]["Session"] == "DEADBEEF" && r[3]["RTP-Info"]?.hasPrefix("seq=") == true)
        #expect(String(decoding: r[4].body, as: UTF8.self) == "volume: -12.000000\r\n")
        // The receiver's timing question is answered.
        await receiver.waitFor { !receiver.timingReplies.isEmpty }
        #expect(RAOPPacket.parseTimingReply(receiver.timingReplies[0]) != nil)

        let sent = packets(40)
        for p in sent { session.send(p) }
        await receiver.waitFor { receiver.packetCount == 40 }
        #expect(receiver.samples == sent.flatMap { $0 })
        #expect(receiver.markers == 1)
        #expect(!receiver.syncs.isEmpty && receiver.syncs[0][0] == 0x90)

        try await session.flush()
        #expect(receiver.methods.last == "FLUSH")
        let next = session.nextTimestamp
        session.send(sent[0])
        await receiver.waitFor { receiver.markers == 2 }
        #expect(receiver.samples(from: next) == sent[0])
        await session.teardown()
        #expect(receiver.methods.last == "TEARDOWN")
        #expect(!session.isConnected)
    }

    @Test("An RSA receiver gets the key wrapped and the audio encrypted; decrypted, it is exactly what was sent")
    func encrypted() async throws {
        let (privateKey, modulus) = try TestRSA.make()
        let receiver = try FakeRAOPReceiver(privateKey: privateKey)
        defer { receiver.stop() }
        let session = RAOPSession(name: "Fake", endpoint: endpoint(receiver), encryption: .rsa,
                                  rsaKey: try RSAWrap.publicKey(modulus: modulus, exponent: Data([1, 0, 1])))
        try await session.connect(volumeDB: nil)
        let announce = receiver.requests[1]
        #expect(announce["Apple-Challenge"] != nil)
        #expect(String(decoding: announce.body, as: UTF8.self).contains("a=rsaaeskey:"))
        let sent = packets(20, seed: 4)
        for p in sent { session.send(p) }
        await receiver.waitFor { receiver.packetCount == 20 }
        #expect(receiver.samples == sent.flatMap { $0 })
        await session.teardown()
    }

    @Test("Lost packets the receiver asks for are sent again from the backlog")
    func retransmit() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.loseAfter = (5, 3)
        let session = RAOPSession(name: "Fake", endpoint: endpoint(receiver), encryption: .none)
        try await session.connect(volumeDB: nil)
        let sent = packets(15, seed: 2)
        for p in sent { session.send(p) }
        await receiver.waitFor { receiver.packetCount == 15 }
        #expect(receiver.resent == 3)
        #expect(session.resentPackets == 3)
        #expect(receiver.samples == sent.flatMap { $0 })
        await session.teardown()
    }

    @Test("A refused ANNOUNCE (busy with another sender) fails the connect and says so; nothing is left open")
    func busy() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.refuse = ["ANNOUNCE": 453]
        let session = RAOPSession(name: "Fake", endpoint: endpoint(receiver), encryption: .none)
        await #expect(throws: RAOPError.refused("ANNOUNCE", 453)) { try await session.connect(volumeDB: nil) }
        #expect(!session.isConnected)
        #expect(RAOPError.refused("ANNOUNCE", 453).errorDescription == "it is busy with another sender")
    }

    @Test("Nothing listening: unreachable, quickly")
    func unreachable() async throws {
        let receiver = try FakeRAOPReceiver()
        let port = receiver.port
        receiver.stop()
        let session = RAOPSession(name: "Gone", endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), encryption: .none)
        let start = Date()
        await #expect(throws: RAOPError.self) { try await session.connect(volumeDB: nil) }
        #expect(Date().timeIntervalSince(start) < 6)
    }
}
