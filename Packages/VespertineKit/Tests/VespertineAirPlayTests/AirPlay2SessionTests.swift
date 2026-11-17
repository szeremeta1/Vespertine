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

    private func open(_ receiver: FakeRAOPReceiver, pairing: AirPlay2Pairing = .withoutPIN(secret: hex(srpSecret)), wish: AirPlayWish? = nil) -> RAOPSession {
        RAOPSession(name: "Fake", endpoint: endpoint(receiver), encryption: .none, pairing: pairing, sender: sender, wish: wish)
    }

    static let deep48 = AirPlayFormat(sampleRate: 48_000, bitDepth: 24)
    /// A 24-bit song at 48 kHz: there is something to gain if the receiver takes it.
    static let deepWish = AirPlayWish(sourceRate: 48_000, wantsDepth: true)
    /// What a receiver that takes 24-bit at 48 kHz and 16-bit at 44.1 kHz on a realtime stream says of itself.
    static var deepInfo: [String: Any] {
        ["name": "Fake", "audioFormats": [["type": 96, "audioInputFormats": 0x240000, "audioOutputFormats": 0x240000]]]
    }

    /// Packets of 24-bit samples: a tone with the low bits in use.
    static func deepPackets(_ count: Int, seed: UInt64 = 11) -> [[Int32]] {
        var rng = Xorshift(seed: seed)
        return (0..<count).map { p in
            (0..<704).map { i in Int32((sin(Double(p * 352 + i / 2) * 0.05) * 6_000_000).rounded()) + Int32(rng.next() % 4096) }
        }
    }

    @Test("A receiver that says it takes 24-bit at 48 kHz gets it: asked before pairing, named in the SETUP, every sample exact")
    func deepStream() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.pairing = FakePairing()
        receiver.info = Self.deepInfo
        let session = open(receiver, wish: Self.deepWish)
        #expect(session.format == .cd)
        try await session.connect(volumeDB: nil)
        #expect(session.format == Self.deep48)
        #expect(session.usesAppleEncoder)
        #expect(receiver.methods == ["GET", "POST", "POST", "SETUP", "SETUP", "RECORD"])
        #expect(receiver.requests.first?.url == "/info")
        #expect(receiver.sealed == [false, false, false, true, true, true])
        #expect(receiver.streamFormat == Self.deep48)
        let stream = try #require((receiver.setups.last?["streams"] as? [[String: Any]])?.first)
        #expect(stream["audioFormat"] as? Int == 0x200000)
        #expect(stream["sr"] as? Int == 48_000)
        #expect(stream["latencyMin"] as? Int == 12_000)
        #expect(stream["latencyMax"] as? Int == 96_000)

        let sent = Self.deepPackets(30)
        for packet in sent {
            let went = session.send(samples: packet)
            #expect(went)
        }
        await receiver.waitFor { receiver.packetCount == 30 }
        #expect(receiver.packetCount == 30)
        #expect(receiver.deepSamples == sent.flatMap { $0 })
        #expect(receiver.unopened == 0)
        // The sync packet counts the 1.75 s in frames of this stream: 84 000 at 48 kHz.
        await receiver.waitFor { !receiver.syncs.isEmpty }
        let sync = try #require(receiver.syncs.first)
        #expect(RAOPPacket.read32(sync, 16) &- RAOPPacket.read32(sync, 4) == 84_000)
        await session.teardown()
    }

    @Test("The session's clock counts in the stream's frames: a second is 48 000 of them at 48 kHz")
    func deepClock() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.pairing = FakePairing()
        receiver.info = Self.deepInfo
        let session = open(receiver, wish: Self.deepWish)
        try await session.connect(volumeDB: nil)
        let head = session.nextTimestamp
        session.send(samples: Self.deepPackets(1)[0], startNanos: 5_000_000_000)
        #expect(session.nextTimestamp == head &+ 352)
        #expect(session.clockTimestamp(nanoseconds: 6_000_000_000) == head &+ 48_000)
        await session.teardown()
    }

    @Test("A receiver that doesn't say what it takes, or says it of other streams only, gets 16-bit at 44.1 kHz as before")
    func silentReceiver() async throws {
        let otherStreams: [String: Any] = ["audioFormats": [["type": 100, "audioInputFormats": 0x3FFFFFC]]]
        let answers: [[String: Any]?] = [nil, otherStreams, ["name": "Fake"]]
        for info in answers {
            let receiver = try FakeRAOPReceiver()
            defer { receiver.stop() }
            receiver.pairing = FakePairing()
            receiver.info = info
            let session = open(receiver, wish: Self.deepWish)
            try await session.connect(volumeDB: nil)
            #expect(session.format == .cd)
            #expect(receiver.streamFormat == .cd)
            #expect(receiver.methods == ["GET", "POST", "POST", "SETUP", "SETUP", "RECORD"])
            let sent = packets(6, seed: 3)
            for packet in sent { session.send(packet) }
            await receiver.waitFor { receiver.packetCount == 6 }
            #expect(receiver.samples == sent.flatMap { $0 })
            await session.teardown()
        }
    }

    @Test("A receiver that lists 24-bit at 48 kHz and then refuses it is set up again with 16-bit at 44.1 kHz, and plays")
    func refusedFormat() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.pairing = FakePairing()
        receiver.info = Self.deepInfo
        receiver.refusedFormats = [0x200000]
        let session = open(receiver, wish: Self.deepWish)
        try await session.connect(volumeDB: nil)
        #expect(session.isConnected)
        #expect(session.format == .cd)
        #expect(receiver.streamFormat == .cd)
        #expect(receiver.methods == ["GET", "POST", "POST", "SETUP", "SETUP", "SETUP", "RECORD"])
        let named = receiver.setups.compactMap { ($0["streams"] as? [[String: Any]])?.first?["audioFormat"] as? Int }
        #expect(named == [0x200000, 0x40000])
        let sent = packets(10, seed: 5)
        for packet in sent { session.send(packet) }
        await receiver.waitFor { receiver.packetCount == 10 }
        #expect(receiver.samples == sent.flatMap { $0 })
        #expect(receiver.unopened == 0)
        await session.teardown()
    }

    @Test("Nothing is asked when 16-bit at 44.1 kHz serves the song as well, or when no wish is given")
    func nothingToAsk() async throws {
        let wishes: [AirPlayWish?] = [nil, AirPlayWish(sourceRate: 44_100, wantsDepth: false), AirPlayWish(sourceRate: 22_050, wantsDepth: false)]
        for wish in wishes {
            let receiver = try FakeRAOPReceiver()
            defer { receiver.stop() }
            receiver.pairing = FakePairing()
            receiver.info = Self.deepInfo
            let session = open(receiver, wish: wish)
            try await session.connect(volumeDB: nil)
            #expect(session.format == .cd)
            #expect(receiver.methods == ["POST", "POST", "SETUP", "SETUP", "RECORD"])
            await session.teardown()
        }
    }

    @Test("A 16-bit song at 48 kHz goes at 48 kHz to a receiver that takes it there, unresampled")
    func plain48() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.pairing = FakePairing()
        receiver.info = ["audioFormats": [["type": 96, "audioInputFormats": 0x3C0000]]]
        let session = open(receiver, wish: AirPlayWish(sourceRate: 48_000, wantsDepth: false))
        try await session.connect(volumeDB: nil)
        let plain = AirPlayFormat(sampleRate: 48_000, bitDepth: 16)
        #expect(session.format == plain)
        #expect(receiver.streamFormat == plain)
        let sent = packets(6, seed: 8)
        for packet in sent { session.send(packet) }
        await receiver.waitFor { receiver.packetCount == 6 }
        #expect(receiver.samples == sent.flatMap { $0 })
        await session.teardown()
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
