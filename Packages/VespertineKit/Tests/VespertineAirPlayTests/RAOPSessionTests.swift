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
    @Test("The digest is RFC 2617's (no qop), and a challenge is read with or without quotes and spaces")
    func digest() {
        // RFC 2617's own example values, without qop: MD5(HA1:nonce:HA2).
        let c = RTSPDigest.Challenge(realm: "testrealm@host.com", nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093")
        #expect(RTSPDigest.md5("iTunes:raop:secret", uppercase: false).count == 32)
        #expect(RTSPDigest.md5("", uppercase: false) == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(RTSPDigest.md5("", uppercase: true) == "D41D8CD98F00B204E9800998ECF8427E")
        let lower = RTSPDigest.response(c, password: "secret", method: "ANNOUNCE", uri: "rtsp://10.0.0.2/1", uppercase: false)
        let ha1 = RTSPDigest.md5("iTunes:testrealm@host.com:secret", uppercase: false), ha2 = RTSPDigest.md5("ANNOUNCE:rtsp://10.0.0.2/1", uppercase: false)
        #expect(lower == RTSPDigest.md5("\(ha1):\(c.nonce):\(ha2)", uppercase: false))
        #expect(RTSPDigest.response(c, password: "secret", method: "ANNOUNCE", uri: "rtsp://10.0.0.2/1", uppercase: true) != lower.uppercased())
        #expect(RTSPDigest.Challenge.parse("Digest realm=\"raop\", nonce=\"abc,def\"") == RTSPDigest.Challenge(realm: "raop", nonce: "abc,def"))
        #expect(RTSPDigest.Challenge.parse("digest nonce=abc ,realm = raop") == RTSPDigest.Challenge(realm: "raop", nonce: "abc"))
        #expect(RTSPDigest.Challenge.parse("Basic realm=\"raop\"") == nil)
        #expect(RTSPDigest.Challenge.parse("Digest realm=\"raop\"") == nil)
        let header = RTSPDigest.authorization(c, password: "secret", method: "SETUP", uri: "u", uppercase: false)
        let fields = RTSPDigest.parameters(String(header.dropFirst("Digest".count)))
        #expect(fields["username"] == "iTunes" && fields["realm"] == c.realm && fields["nonce"] == c.nonce && fields["uri"] == "u")
        #expect(!header.contains("secret"))
    }

    @Test("A receiver with a password takes the session once its challenge is answered; every later request carries the digest")
    func password() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.password = "open sesame"
        let session = RAOPSession(name: "Fake", endpoint: endpoint(receiver), encryption: .none, password: "open sesame")
        try await session.connect(volumeDB: -20)
        // OPTIONS twice (refused, then answered); the rest once each.
        #expect(receiver.methods == ["OPTIONS", "OPTIONS", "ANNOUNCE", "SETUP", "RECORD", "SET_PARAMETER"])
        #expect(receiver.requests[0]["Authorization"] == nil)
        #expect(receiver.requests.dropFirst().allSatisfy { $0["Authorization"]?.hasPrefix("Digest username=\"iTunes\"") == true })
        #expect(!receiver.requests.contains { ($0["Authorization"] ?? "").contains("open sesame") })
        // Numbered in order, the refused one included.
        #expect(receiver.requests.compactMap { $0["CSeq"] } == ["1", "2", "3", "4", "5", "6"])
        await session.teardown()
    }

    @Test("A receiver that wants the digest in capitals gets it on the second try, and from then on at once")
    func passwordCapitals() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.password = "pw"
        receiver.capitalDigits = true
        let session = RAOPSession(name: "Fake", endpoint: endpoint(receiver), encryption: .none, password: "pw")
        try await session.connect(volumeDB: nil)
        #expect(receiver.methods == ["OPTIONS", "OPTIONS", "OPTIONS", "ANNOUNCE", "SETUP", "RECORD"])
        await session.teardown()
    }

    @Test("A nonce that went stale is answered again, in the case the receiver already took")
    func passwordStaleNonce() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.password = "pw"
        receiver.nonceLife = 2
        let session = RAOPSession(name: "Fake", endpoint: endpoint(receiver), encryption: .none, password: "pw")
        try await session.connect(volumeDB: nil)
        #expect(session.isConnected)
        // SETUP met the new nonce: refused, tried in capitals, then answered as before.
        #expect(receiver.methods == ["OPTIONS", "OPTIONS", "ANNOUNCE", "SETUP", "SETUP", "SETUP", "RECORD"])
        await session.teardown()
    }

    @Test("A wrong password, or none, is refused with 401 after the tries, and the session is closed")
    func passwordWrong() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.password = "right"
        let wrong = RAOPSession(name: "Fake", endpoint: endpoint(receiver), encryption: .none, password: "wrong")
        await #expect(throws: RAOPError.refused("OPTIONS", 401)) { try await wrong.connect(volumeDB: nil) }
        #expect(receiver.methods == ["OPTIONS", "OPTIONS", "OPTIONS", "OPTIONS"])
        #expect(!wrong.isConnected)
        let none = RAOPSession(name: "Fake", endpoint: endpoint(receiver), encryption: .none)
        await #expect(throws: RAOPError.refused("OPTIONS", 401)) { try await none.connect(volumeDB: nil) }
        #expect(receiver.methods.count == 5)
    }

    @Test("An MFi receiver is sent auth-setup after OPTIONS: 0x01 and a 32-byte key, new each time; then the session as usual")
    func authSetup() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.requiresAuthSetup = true
        let session = RAOPSession(name: "Fake", endpoint: endpoint(receiver), encryption: .none, authSetup: true)
        try await session.connect(volumeDB: nil)
        #expect(receiver.methods == ["OPTIONS", "POST", "ANNOUNCE", "SETUP", "RECORD"])
        let post = receiver.requests[1]
        #expect(post.url == "/auth-setup")
        #expect(post["Content-Type"] == "application/octet-stream")
        #expect(post.body.count == 33 && post.body.first == MFiAuthSetup.unencrypted)
        #expect(post.body.dropFirst() != Data(count: 32))
        #expect(MFiAuthSetup.body() != MFiAuthSetup.body())
        #expect(MFiAuthSetup.body(publicKey: Data(repeating: 9, count: 32)) == Data([0x01]) + Data(repeating: 9, count: 32))
        // The audio is unencrypted, as the 0x01 said.
        #expect(!String(decoding: receiver.requests[2].body, as: UTF8.self).contains("rsaaeskey"))
        let samples = (0..<704).map { Int16(truncatingIfNeeded: $0 &* 37) }
        session.send(Array(samples[0..<704]))
        await receiver.waitFor { receiver.samples.count >= 704 }
        #expect(Array(receiver.samples.prefix(704)) == samples)
        await session.teardown()
    }

    @Test("Without auth-setup an MFi receiver refuses the session (what a receiver did before Vespertine sent it)")
    func authSetupMissing() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.requiresAuthSetup = true
        let session = RAOPSession(name: "Fake", endpoint: endpoint(receiver), encryption: .none)
        await #expect(throws: RAOPError.refused("ANNOUNCE", 403)) { try await session.connect(volumeDB: nil) }
        #expect(!receiver.methods.contains("POST"))
    }

    @Test("A receiver that lists MFi and refuses auth-setup is still tried: the session goes on without it")
    func authSetupRefused() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.refuse = ["POST": 404]
        let session = RAOPSession(name: "Fake", endpoint: endpoint(receiver), encryption: .none, authSetup: true)
        try await session.connect(volumeDB: nil)
        #expect(receiver.methods == ["OPTIONS", "POST", "ANNOUNCE", "SETUP", "RECORD"])
        #expect(session.isConnected)
        await session.teardown()
    }

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

@Suite("RTSP connection")
struct RTSPConnectionTests {
    @Test("Requests sent at once are answered in order, each with its own answer")
    func serialized() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let connection = RTSPConnection(endpoint: endpoint(receiver))
        try await connection.connect()
        #expect(await connection.remoteAddress == "127.0.0.1")
        let answers = try await withThrowingTaskGroup(of: (Int, String?).self) { group in
            for i in 0..<20 {
                group.addTask { (i, try await connection.send(.request("OPTIONS", "*", headers: [("CSeq", String(i))]))["CSeq"]) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(answers.count == 20)
        #expect(answers.allSatisfy { String($0.0) == $0.1 })
        await connection.close()
    }
}

@Suite("RAOP session, fix round 1", .serialized)
struct RAOPSessionHardeningTests {
    @Test("A SETUP answer with an empty Session header is a protocol error, not a crash")
    func emptySession() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.sessionHeader = ""
        let session = RAOPSession(name: "Fake", endpoint: endpoint(receiver), encryption: .none)
        await #expect(throws: RAOPError.badResponse("SETUP (no session)")) { try await session.connect(volumeDB: nil) }
        #expect(!session.isConnected)
    }

    @Test("An answer that names another request's CSeq is a protocol error")
    func cseqMismatch() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.wrongCSeq = ["ANNOUNCE"]
        let session = RAOPSession(name: "Fake", endpoint: endpoint(receiver), encryption: .none)
        await #expect(throws: RAOPError.self) { try await session.connect(volumeDB: nil) }
        #expect(!receiver.methods.contains("SETUP"))
    }

    @Test("The first sync and later ones put the same frame at the same time (within 1 ms), packets sent ahead or not")
    func syncConsistency() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let session = RAOPSession(name: "Fake", endpoint: endpoint(receiver), encryption: .none)
        try await session.connect(volumeDB: nil)
        // As the pacer does: the first packet goes 250 ms before the moment its first frame counts as sent.
        let anchor = NTPClock.nanosecondsNow() + 250_000_000
        session.send(packets(1)[0], startNanos: anchor)
        try await Task.sleep(for: .milliseconds(400))
        session.sendSync()
        try await Task.sleep(for: .milliseconds(200))
        session.sendSync()
        await receiver.waitFor { receiver.syncs.count >= 3 }
        let syncs = receiver.syncs.compactMap(RAOPPacket.parseSync)
        #expect(syncs.count >= 3)
        let frame = try #require(receiver.firstTimestamp)
        // When the sync says `frame` is sent: its NTP time plus (frame − rtp) / rate.
        let times = syncs.map { s in Double(s.ntp) / 4_294_967_296 + Double(Int32(bitPattern: frame &- s.rtp)) / 44_100 }
        for t in times.dropFirst() { #expect(abs(t - times[0]) < 0.001) }
        // And that moment is the anchor (250 ms after the packet went), not when it was sent.
        let anchorNTP = Double(NTPClock.ntp(nanoseconds: anchor)) / 4_294_967_296
        #expect(abs(times[0] - anchorNTP) < 0.001)
        await session.teardown()
    }

    @Test("The clock is still right 60 hours after its anchor (no overflow)")
    func longAnchor() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let session = RAOPSession(name: "Fake", endpoint: endpoint(receiver), encryption: .none)
        try await session.connect(volumeDB: nil)
        let anchor = NTPClock.nanosecondsNow()
        let rtp = session.nextTimestamp
        session.send(packets(1)[0], startNanos: anchor)
        let hours: UInt64 = 60
        let later = try #require(session.clockTimestamp(nanoseconds: anchor + hours * 3_600 * 1_000_000_000))
        #expect(later == rtp &+ UInt32(truncatingIfNeeded: hours * 3_600 * 44_100))
        await session.teardown()
    }
}
