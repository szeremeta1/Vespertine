//
// Vespertine: an AirPlay 2 session against the fake receiver set to ask for pairing: paired with or without a PIN, set
// up with the two property lists, the event connection opened, the audio sealed and decoded exactly, lost packets sent
// again, volume and titles over the sealed connection, and /feedback to keep it open.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import Network
import Testing
@testable import VespertineAirPlay

@Suite("AirPlay 2 session", .serialized)
struct AirPlay2SessionTests {
    let sender = AirPlay2Sender(deviceID: "02:1A:FF:00:9C:07", name: "Test Mac", model: "Mac14,5", osVersion: "15.1")
    let me = PairingIdentity(id: "6E1F4C0A-3B7D-4E55-9C21-0A1B2C3D4E5F", seed: Data(repeating: 7, count: 32))

    private func open(_ receiver: FakeRAOPReceiver, pairing: AirPlay2Pairing = .withoutPIN(secret: hex(srpSecret))) -> RAOPSession {
        RAOPSession(name: "Fake", endpoint: endpoint(receiver), encryption: .none, pairing: pairing, sender: sender)
    }

    @Test("Paired without a PIN: the requests in order, all sealed after pairing, and what the two SETUPs say")
    func handshake() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.pairing = FakePairing()
        let session = open(receiver)
        try await session.connect(volumeDB: -20)
        #expect(session.isConnected)
        #expect(receiver.methods == ["POST", "POST", "SETUP", "SETUP", "RECORD", "SET_PARAMETER"])
        #expect(receiver.sealed == [false, false, true, true, true, true])
        // Numbered on from pairing's two requests.
        #expect(receiver.requests.compactMap { $0["CSeq"] } == ["1", "2", "3", "4", "5", "6"])

        let setups = receiver.setups
        #expect(setups.count == 2)
        #expect(setups[0]["deviceID"] as? String == "02:1A:FF:00:9C:07")
        #expect(setups[0]["name"] as? String == "Test Mac")
        #expect(setups[0]["timingProtocol"] as? String == "NTP")
        #expect((setups[0]["timingPort"] as? Int ?? 0) > 0)
        let stream = try #require((setups[1]["streams"] as? [[String: Any]])?.first)
        #expect(stream["type"] as? Int == 96)
        #expect(stream["ct"] as? Int == 2)
        #expect((stream["controlPort"] as? Int ?? 0) > 0)
        // The audio key is the first half of the secret pairing gave.
        #expect(stream["shk"] as? Data == hex(srpKey).prefix(32))
        #expect(receiver.requests[2]["Content-Type"] == "application/x-apple-binary-plist")

        // The event connection was opened, once, before the stream was set up.
        await receiver.waitFor { receiver.eventConnections == 1 }
        #expect(receiver.eventConnections == 1)
        // RECORD made the receiver ask the time; the session answered.
        await receiver.waitFor { !receiver.timingReplies.isEmpty }
        #expect(receiver.timingReplies.count == 1)
        #expect(String(decoding: receiver.requests[5].body, as: UTF8.self) == "volume: -20.000000\r\n")
        await session.teardown()
        #expect(receiver.methods.last == "TEARDOWN")
        #expect(receiver.sealed.last == true)
    }

    @Test("The audio goes sealed and decodes to exactly what was sent; the first packet carries the marker")
    func audio() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.pairing = FakePairing()
        let session = open(receiver)
        try await session.connect(volumeDB: nil)
        let sent = packets(40)
        for packet in sent { #expect(session.send(packet)) }
        await receiver.waitFor { receiver.packetCount == 40 }
        #expect(receiver.packetCount == 40)
        #expect(receiver.samples == sent.flatMap { $0 })
        #expect(receiver.unopened == 0)
        #expect(receiver.markers == 1)
        #expect(receiver.syncs.count == 1)
        await session.teardown()
    }

    @Test("Lost packets the receiver asks for are sent again as the same sealed bytes, and open")
    func resend() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.pairing = FakePairing()
        let session = open(receiver)
        try await session.connect(volumeDB: nil)
        receiver.loseAfter = (count: 5, lose: 3)
        let sent = packets(20, seed: 4)
        for packet in sent { session.send(packet) }
        await receiver.waitFor { receiver.packetCount == 20 }
        #expect(receiver.samples == sent.flatMap { $0 })
        #expect(receiver.resent == 3)
        #expect(session.resentPackets == 3)
        #expect(receiver.unopened == 0)
        await session.teardown()
    }

    @Test("Paired with a PIN before: pair-verify opens the session, and titles, cover and flush go over the sealed connection")
    func verified() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let pairing = FakePairing(allowsTransient: false)
        receiver.pairing = pairing
        // The pairing itself, once, on a connection of its own.
        let first = RTSPConnection(endpoint: endpoint(receiver))
        try await first.connect()
        let kept = try await PairingExchange(connection: first).setup(pin: "3939", identity: me, secret: hex(srpSecret))
        await first.close()
        let before = receiver.requests.count

        let session = open(receiver, pairing: .paired(me, kept))
        try await session.connect(volumeDB: nil)
        try await session.setMetadata(title: "Song", artist: "Artist", album: nil, rtptime: session.nextTimestamp)
        try await session.flush()
        let ours = Array(receiver.requests.dropFirst(before))
        #expect(ours.map { $0.method ?? "" } == ["POST", "POST", "SETUP", "SETUP", "RECORD", "SET_PARAMETER", "FLUSH"])
        #expect(ours.prefix(2).allSatisfy { $0.url == "/pair-verify" && $0["X-Apple-HKP"] == "3" })
        #expect(Array(receiver.sealed.dropFirst(before)) == [false, false, true, true, true, true, true])
        #expect(DMAP.parse(ours[5].body)["minm"] == Data("Song".utf8))
        let sent = packets(8, seed: 2)
        for packet in sent { session.send(packet) }
        await receiver.waitFor { receiver.packetCount == 8 }
        #expect(receiver.samples == sent.flatMap { $0 })
        await session.teardown()
    }

    @Test("A receiver that has forgotten this Mac refuses the session as a pairing matter, and nothing is left open")
    func forgotten() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let pairing = FakePairing()
        receiver.pairing = pairing
        let session = open(receiver, pairing: .paired(me, pairing.paired))
        await #expect(throws: PairingError.authentication) { try await session.connect(volumeDB: nil) }
        #expect(!session.isConnected)
        #expect(receiver.setups.isEmpty)
    }

    @Test("A first SETUP answered without an event port is a protocol error, and the session is closed")
    func noEventPort() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.pairing = FakePairing()
        receiver.withholdEventPort = true
        let session = open(receiver)
        await #expect(throws: RAOPError.badResponse("SETUP")) { try await session.connect(volumeDB: nil) }
        #expect(!session.isConnected)
        #expect(receiver.methods == ["POST", "POST", "SETUP"])
    }

    @Test("While the session is open the receiver is told so with POST /feedback")
    func feedback() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.pairing = FakePairing()
        let session = open(receiver)
        try await session.connect(volumeDB: nil)
        await receiver.waitFor({ receiver.requests.contains { $0.url == "/feedback" } }, seconds: 10)
        let feedback = try #require(receiver.requests.first { $0.url == "/feedback" })
        #expect(feedback.method == "POST")
        #expect(feedback.body.isEmpty)
        #expect(session.isConnected)
        #expect(!receiver.methods.contains("OPTIONS"))
        await session.teardown()
    }

    @Test("A receiver that asks for no pairing still gets the AirPlay 1 session, unchanged")
    func airPlay1Unchanged() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let session = RAOPSession(name: "Fake", endpoint: endpoint(receiver), encryption: .none)
        try await session.connect(volumeDB: nil)
        #expect(receiver.methods == ["OPTIONS", "ANNOUNCE", "SETUP", "RECORD"])
        #expect(receiver.sealed.allSatisfy { !$0 })
        let sent = packets(4)
        for packet in sent { session.send(packet) }
        await receiver.waitFor { receiver.packetCount == 4 }
        #expect(receiver.samples == sent.flatMap { $0 })
        await session.teardown()
    }
}
