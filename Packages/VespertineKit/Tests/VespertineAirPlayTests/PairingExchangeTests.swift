//
// Vespertine: pairing spoken over a connection to the fake receiver: without a PIN, with one, and again on a later
// connection; what the receiver is sent, that everything after pairing goes sealed, and every way it can say no.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import Network
import Testing
@testable import VespertineAirPlay

@Suite("AirPlay pairing over a connection", .serialized)
struct PairingExchangeTests {
    let me = PairingIdentity(id: "6E1F4C0A-3B7D-4E55-9C21-0A1B2C3D4E5F", seed: Data(repeating: 7, count: 32))

    private func paired(_ pairing: FakePairing = FakePairing()) throws -> (FakeRAOPReceiver, FakePairing) {
        let receiver = try FakeRAOPReceiver()
        receiver.pairing = pairing
        return (receiver, pairing)
    }

    private func connect(to receiver: FakeRAOPReceiver) async throws -> RTSPConnection {
        let connection = RTSPConnection(endpoint: endpoint(receiver))
        try await connection.connect()
        return connection
    }

    private func options(_ cseq: Int) -> RTSPMessage { .request("OPTIONS", "*", headers: [("CSeq", String(cseq))]) }

    @Test("A receiver that must be paired with refuses a request that comes before pairing")
    func unpaired() async throws {
        let (receiver, _) = try paired()
        defer { receiver.stop() }
        let connection = try await connect(to: receiver)
        let answer = try await connection.send(options(1))
        #expect(answer.status == 470)
        await connection.close()
    }

    @Test("Without a PIN: two requests, then everything on the connection is sealed, long requests included")
    func withoutPIN() async throws {
        let (receiver, pairing) = try paired()
        defer { receiver.stop() }
        let connection = try await connect(to: receiver)
        let exchange = PairingExchange(connection: connection)
        #expect(await connection.isSecured == false)
        try await exchange.withoutPIN(secret: hex(srpSecret))
        #expect(await connection.isSecured)
        #expect(await exchange.cseq == 3)
        #expect(pairing.pinShown == 0)
        #expect(pairing.controllers.isEmpty)

        let requests = receiver.requests
        #expect(requests.map { $0.method ?? "" } == ["POST", "POST"])
        #expect(requests.map { $0.url ?? "" } == ["/pair-setup", "/pair-setup"])
        #expect(requests.compactMap { $0["CSeq"] } == ["1", "2"])
        #expect(requests.allSatisfy { $0["X-Apple-HKP"] == "4" && $0["User-Agent"] == "AirPlay/320.20" && $0["Content-Type"] == "application/octet-stream" })
        // "Pair with me, and no PIN": method 0, state 1, flags 0x10.
        #expect(requests[0].body == hex("000100060101130110"))

        let answer = try await connection.send(options(3))
        #expect(answer.status == 200)
        #expect(answer["Public"]?.contains("SETUP") == true)
        // More than one frame each way would need a long answer too; a long request is three frames.
        let long = Data((0..<2500).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let second = try await connection.send(.request("SET_PARAMETER", "rtsp://127.0.0.1/1", headers: [("CSeq", "4")], body: long))
        #expect(second.status == 200)
        #expect(second["CSeq"] == "4")
        #expect(receiver.requests.last?.body == long)
        #expect(receiver.sealed == [false, false, true, true])
        await connection.close()
    }

    @Test("With a PIN: the receiver is asked to show it, keys are traded and kept, and pair-verify seals this and later connections")
    func withPIN() async throws {
        let (receiver, pairing) = try paired(FakePairing(allowsTransient: false))
        defer { receiver.stop() }
        let first = try await connect(to: receiver)
        let exchange = PairingExchange(connection: first)
        try await exchange.showPIN()
        #expect(pairing.pinShown == 1)
        let kept = try await exchange.setup(pin: "3939", identity: me, secret: hex(srpSecret))
        #expect(kept == pairing.paired)
        #expect(pairing.controllers == [Data(me.id.utf8): me.publicKey])
        // Pair-setup with a PIN seals nothing by itself.
        #expect(await first.isSecured == false)
        #expect(receiver.requests.map { $0.url ?? "" } == ["/pair-pin-start", "/pair-setup", "/pair-setup", "/pair-setup"])
        #expect(receiver.requests.allSatisfy { $0["X-Apple-HKP"] == "3" })
        #expect(receiver.requests[0].body.isEmpty && receiver.requests[0]["Content-Type"] == nil)

        try await exchange.verify(identity: me, receiver: kept)
        #expect(await first.isSecured)
        #expect(await exchange.cseq == 7)
        let answer = try await first.send(options(7))
        #expect(answer.status == 200)
        #expect(receiver.sealed == [false, false, false, false, false, false, true])
        await first.close()

        // Another day: pair-verify alone.
        let second = try await connect(to: receiver)
        try await PairingExchange(connection: second).verify(identity: me, receiver: kept)
        let again = try await second.send(options(3))
        #expect(again.status == 200)
        #expect(receiver.requests.suffix(3).map { $0.url ?? "" } == ["/pair-verify", "/pair-verify", "*"])
        #expect(receiver.sealed.suffix(3) == [false, false, true])
        await second.close()
    }

    @Test("A wrong PIN is refused as one, and nothing is kept or sealed")
    func wrongPIN() async throws {
        let (receiver, pairing) = try paired()
        defer { receiver.stop() }
        let connection = try await connect(to: receiver)
        let exchange = PairingExchange(connection: connection)
        await #expect(throws: PairingError.authentication) {
            _ = try await exchange.setup(pin: "1234", identity: me, secret: hex(srpSecret))
        }
        #expect(pairing.controllers.isEmpty)
        #expect(await connection.isSecured == false)
        await connection.close()
    }

    @Test("A receiver set to ask for a PIN refuses pairing without one, by its own error code")
    func noTransient() async throws {
        let (receiver, _) = try paired(FakePairing(allowsTransient: false))
        defer { receiver.stop() }
        let connection = try await connect(to: receiver)
        await #expect(throws: PairingError.refused(code: 6)) {
            try await PairingExchange(connection: connection).withoutPIN(secret: hex(srpSecret))
        }
        #expect(await connection.isSecured == false)
        await connection.close()
    }

    @Test("Pair-verify: a receiver that has forgotten this Mac says so; another receiver, or one with another key, is not trusted")
    func verifyRefusals() async throws {
        let (receiver, pairing) = try paired()
        defer { receiver.stop() }
        let first = try await connect(to: receiver)
        let kept = try await PairingExchange(connection: first).setup(pin: "3939", identity: me, secret: hex(srpSecret))
        await first.close()

        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let second = try await connect(to: receiver)
        await #expect(throws: PairingError.notAuthentic) {
            try await PairingExchange(connection: second).verify(identity: me, receiver: PairedReceiver(id: kept.id, publicKey: other))
        }
        await #expect(throws: PairingError.wrongReceiver) {
            try await PairingExchange(connection: second, cseq: 2).verify(identity: me, receiver: PairedReceiver(id: Data("11:22:33:44:55:66".utf8), publicKey: kept.publicKey))
        }
        #expect(await second.isSecured == false)

        pairing.forget()
        await #expect(throws: PairingError.authentication) {
            try await PairingExchange(connection: second, cseq: 3).verify(identity: me, receiver: kept)
        }
        #expect(await second.isSecured == false)
        await second.close()
    }

    @Test("A receiver that refuses the request itself is reported with its status")
    func refusedRequest() async throws {
        let (receiver, _) = try paired()
        defer { receiver.stop() }
        receiver.refuse = ["POST": 403]
        let connection = try await connect(to: receiver)
        await #expect(throws: RAOPError.refused("/pair-setup", 403)) {
            try await PairingExchange(connection: connection).withoutPIN(secret: hex(srpSecret))
        }
        await connection.close()
    }

    @Test("A sealed answer that doesn't open ends the connection")
    func spoiled() async throws {
        let (receiver, _) = try paired()
        defer { receiver.stop() }
        let connection = try await connect(to: receiver)
        try await PairingExchange(connection: connection).withoutPIN(secret: hex(srpSecret))
        receiver.spoilNextAnswer = true
        await #expect(throws: RAOPError.closed) {
            _ = try await connection.send(options(3))
        }
        await connection.close()
    }

    @Test("An answer that calls itself HTTP is read like one that calls itself RTSP")
    func httpAnswer() throws {
        var parser = RTSPParser()
        parser.append(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nCSeq: 5\r\n\r\nhi".utf8))
        let answer = try #require(try parser.next())
        #expect(answer.status == 200)
        #expect(answer["CSeq"] == "5")
        #expect(answer.body == Data("hi".utf8))
    }
}
