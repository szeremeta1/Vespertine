//
// Vespertine: pair-setup and pair-verify, message by message, against a receiver played here: its half of SRP is the
// exchange worked out independently for the building-block tests (PIN 3939), and its keys, seals and signatures are made
// with CryptoKit the way HomeKit-style pairing says a receiver makes them.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import Testing
@testable import VespertineAirPlay

/// The receiver's side of pairing, for the tests.
private struct Accessory {
    let id = Data("AA:BB:CC:DD:EE:FF".utf8)
    let longTerm = Curve25519.Signing.PrivateKey()
    let session = Curve25519.KeyAgreement.PrivateKey()

    var paired: PairedReceiver { PairedReceiver(id: id, publicKey: longTerm.publicKey.rawRepresentation) }

    static func message(_ pairs: KeyValuePairs<PairingTLV.Tag, Data>) -> Data { PairingTLV(pairs).encoded }

    /// Pair-setup's M2 and M4 for the recorded SRP exchange.
    static let setupM2 = message([.state: Data([2]), .publicKey: hex(srpServerKey), .salt: hex(srpSalt)])
    static let setupM4 = message([.state: Data([4]), .proof: hex(srpServerProof)])
    static let setupKey = PairingCrypto.key(secret: hex(srpKey), salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")

    /// Pair-setup's M6: the receiver's name and key, sealed.
    func m6(key: SymmetricKey = Accessory.setupKey, nonce: String = "PS-Msg06") throws -> Data {
        let inner = Self.message([.identifier: id, .publicKey: longTerm.publicKey.rawRepresentation, .signature: Data(repeating: 0, count: 64)])
        return Self.message([.state: Data([6]), .encryptedData: try PairingCrypto.seal(inner, key: key, nonce: PairingCrypto.nonce(nonce))])
    }

    func secret(with client: Data) throws -> Data {
        try session.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: client)).withUnsafeBytes { Data($0) }
    }

    func verifyKey(with client: Data) throws -> SymmetricKey {
        PairingCrypto.key(secret: try secret(with: client), salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
    }

    /// Pair-verify's M2 for the client's M1: this session's key, and the signed name sealed under the agreed key.
    /// `name` and `signer` let a test answer as another receiver.
    func m2(answering m1: Data, name: Data? = nil, signer: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        let client = try #require(PairingTLV(decoding: m1)?[.publicKey])
        let mine = session.publicKey.rawRepresentation
        let name = name ?? id
        let signature = try (signer ?? longTerm).signature(for: mine + name + client)
        let inner = Self.message([.identifier: name, .signature: signature])
        let sealed = try PairingCrypto.seal(inner, key: try verifyKey(with: client), nonce: PairingCrypto.nonce("PV-Msg02"))
        return Self.message([.state: Data([2]), .publicKey: mine, .encryptedData: sealed])
    }
}

@Suite("AirPlay pairing messages")
struct PairingMessagesTests {
    let me = PairingIdentity(id: "6E1F4C0A-3B7D-4E55-9C21-0A1B2C3D4E5F", seed: Data(repeating: 7, count: 32))

    @Test("Pair-setup: PIN proved, keys traded, and the receiver's name and key come back to keep")
    func setup() throws {
        var setup = PairSetup(pin: "3939", secret: hex(srpSecret))
        #expect(setup.start == hex("000100060101"))
        let sent = try setup.proof(answering: Accessory.setupM2)
        // The state, the 384-byte key as 255 bytes and the rest, and the 64-byte proof, each piece with its two-byte header.
        #expect(sent.count == 3 + 384 + 4 + 64 + 2)
        let m3 = try #require(PairingTLV(decoding: sent))
        #expect(m3.items.map(\.type) == [6, 3, 4])
        #expect(m3.byte(.state) == 3)
        #expect(m3[.publicKey] == hex(srpClientKey))
        #expect(m3[.proof] == hex(srpProof))
        #expect(setup.sharedKey == nil)
        let shared = try setup.finish(answering: Accessory.setupM4)
        #expect(shared == hex(srpKey))
        #expect(setup.sharedKey == hex(srpKey))

        // M5 as the receiver reads it: this Mac's name and key, signed over the value both sides derive.
        let m5 = try #require(PairingTLV(decoding: try setup.exchange(me)))
        #expect(m5.byte(.state) == 5)
        let inner = try #require(PairingTLV(decoding: try PairingCrypto.open(try #require(m5[.encryptedData]), key: Accessory.setupKey, nonce: PairingCrypto.nonce("PS-Msg05"))))
        #expect(inner[.identifier] == Data(me.id.utf8))
        #expect(inner[.publicKey] == me.publicKey && me.publicKey.count == 32)
        let x = PairingCrypto.bytes(secret: hex(srpKey), salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
        let mine = try Curve25519.Signing.PublicKey(rawRepresentation: me.publicKey)
        #expect(mine.isValidSignature(try #require(inner[.signature]), for: x + Data(me.id.utf8) + me.publicKey))

        let accessory = Accessory()
        #expect(try setup.receiver(answering: try accessory.m6()) == accessory.paired)
    }

    @Test("A receiver with no PIN: the short form says so in the first message and ends with SRP's key as the secret")
    func transient() throws {
        var setup = PairSetup.withoutPIN(secret: hex(srpSecret))
        #expect(setup.transient)
        #expect(setup.start == hex("000100060101130110"))
        _ = try setup.proof(answering: Accessory.setupM2)
        let shared = try setup.finish(answering: Accessory.setupM4)
        #expect(shared == hex(srpKey))
        // No keys are traded in the short form.
        #expect(throws: PairingError.malformed) { try setup.exchange(me) }
        #expect(throws: PairingError.malformed) { try setup.receiver(answering: try Accessory().m6()) }
        let keys = PairingChannelKeys.control(secret: hex(srpKey))
        #expect(keys.write != keys.read)
        #expect(keys.write == PairingCrypto.key(secret: hex(srpKey), salt: "Control-Salt", info: "Control-Write-Encryption-Key"))
        #expect(keys.read == PairingCrypto.key(secret: hex(srpKey), salt: "Control-Salt", info: "Control-Read-Encryption-Key"))
    }

    @Test("Pair-setup: a wrong PIN, a wait, and other refusals are told apart")
    func setupRefusals() throws {
        // A wrong PIN still makes a proof; the receiver refuses it.
        var wrong = PairSetup(pin: "0000", secret: hex(srpSecret))
        let sent = try wrong.proof(answering: Accessory.setupM2)
        let m3 = try #require(PairingTLV(decoding: sent))
        #expect(m3[.proof] != hex(srpProof))
        #expect(throws: PairingError.authentication) { try wrong.finish(answering: Accessory.message([.state: Data([4]), .error: Data([2])])) }
        #expect(wrong.sharedKey == nil)

        var setup = PairSetup(pin: "3939", secret: hex(srpSecret))
        // 300 seconds, least significant byte first.
        #expect(throws: PairingError.tryLater(seconds: 300)) {
            try setup.proof(answering: Accessory.message([.state: Data([2]), .error: Data([3]), .retryDelay: Data([0x2C, 0x01])]))
        }
        #expect(throws: PairingError.tryLater(seconds: 0)) { try setup.proof(answering: Accessory.message([.state: Data([2]), .error: Data([3])])) }
        #expect(throws: PairingError.refused(code: 6)) { try setup.proof(answering: Accessory.message([.state: Data([2]), .error: Data([6])])) }
    }

    @Test("Pair-setup: a receiver that can't prove it knows the PIN, messages out of order and damaged ones are refused")
    func setupDamaged() throws {
        var setup = PairSetup(pin: "3939", secret: hex(srpSecret))
        // Nothing can be finished or traded before its step.
        #expect(throws: PairingError.malformed) { try setup.finish(answering: Accessory.setupM4) }
        #expect(throws: PairingError.malformed) { try setup.exchange(me) }
        #expect(throws: PairingError.malformed) { try setup.proof(answering: Accessory.setupM4) }
        #expect(throws: PairingError.malformed) { try setup.proof(answering: Data([6])) }
        #expect(throws: PairingError.malformed) { try setup.proof(answering: Accessory.message([.state: Data([2]), .salt: hex(srpSalt)])) }
        #expect(throws: PairingError.malformed) {
            try setup.proof(answering: Accessory.message([.state: Data([2]), .publicKey: Data(repeating: 0, count: 384), .salt: hex(srpSalt)]))
        }
        _ = try setup.proof(answering: Accessory.setupM2)
        var proof = hex(srpServerProof)
        proof[0] ^= 1
        #expect(throws: PairingError.notAuthentic) { try setup.finish(answering: Accessory.message([.state: Data([4]), .proof: proof])) }
        #expect(throws: PairingError.notAuthentic) { try setup.finish(answering: Accessory.message([.state: Data([4])])) }
        #expect(setup.sharedKey == nil)
        try setup.finish(answering: Accessory.setupM4)

        let accessory = Accessory()
        let other = PairingCrypto.key(secret: hex(srpKey), salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        #expect(throws: PairingError.notAuthentic) { try setup.receiver(answering: try accessory.m6(key: other)) }
        #expect(throws: PairingError.notAuthentic) { try setup.receiver(answering: try accessory.m6(nonce: "PS-Msg05")) }
        #expect(throws: PairingError.malformed) { try setup.receiver(answering: Accessory.message([.state: Data([6])])) }
        // A sealed message with no key in it.
        let empty = try PairingCrypto.seal(Accessory.message([.identifier: accessory.id]), key: Accessory.setupKey, nonce: PairingCrypto.nonce("PS-Msg06"))
        #expect(throws: PairingError.malformed) { try setup.receiver(answering: Accessory.message([.state: Data([6]), .encryptedData: empty])) }
    }

    @Test("Pair-verify: both sides prove their long-term keys and come away with the same secret")
    func verify() throws {
        let accessory = Accessory()
        var session = PairVerify(identity: me, receiver: accessory.paired)
        let m1 = try #require(PairingTLV(decoding: session.start))
        #expect(m1.byte(.state) == 1)
        #expect(m1[.publicKey] == session.publicKey && session.publicKey.count == 32)
        // Nothing to finish yet.
        #expect(throws: PairingError.malformed) { try session.finish(answering: Accessory.message([.state: Data([4])])) }

        let sent = try session.proof(answering: try accessory.m2(answering: session.start))
        let m3 = try #require(PairingTLV(decoding: sent))
        #expect(m3.byte(.state) == 3)
        let key = try accessory.verifyKey(with: session.publicKey)
        let inner = try #require(PairingTLV(decoding: try PairingCrypto.open(try #require(m3[.encryptedData]), key: key, nonce: PairingCrypto.nonce("PV-Msg03"))))
        #expect(inner[.identifier] == Data(me.id.utf8))
        let mine = try Curve25519.Signing.PublicKey(rawRepresentation: me.publicKey)
        let signed = session.publicKey + Data(me.id.utf8) + accessory.session.publicKey.rawRepresentation
        #expect(mine.isValidSignature(try #require(inner[.signature]), for: signed))

        let secret = try session.finish(answering: Accessory.message([.state: Data([4])]))
        let theirs = try accessory.secret(with: session.publicKey)
        #expect(secret == theirs)
        #expect(secret.count == 32)
        // Each session makes its own key.
        #expect(PairVerify(identity: me, receiver: accessory.paired).publicKey != session.publicKey)
    }

    @Test("Pair-verify: another receiver, a forged signature, a pairing the receiver forgot and damaged messages are refused")
    func verifyRefusals() throws {
        let accessory = Accessory()
        var session = PairVerify(identity: me, receiver: accessory.paired)
        let m1 = session.start
        #expect(throws: PairingError.wrongReceiver) { try session.proof(answering: try accessory.m2(answering: m1, name: Data("11:22:33:44:55:66".utf8))) }
        #expect(throws: PairingError.notAuthentic) { try session.proof(answering: try accessory.m2(answering: m1, signer: Curve25519.Signing.PrivateKey())) }
        // Sealed for another session's key.
        let other = PairVerify(identity: me, receiver: accessory.paired)
        #expect(throws: PairingError.notAuthentic) { try session.proof(answering: try accessory.m2(answering: other.start)) }
        #expect(throws: PairingError.malformed) { try session.proof(answering: Accessory.message([.state: Data([2]), .publicKey: Data(repeating: 1, count: 31)])) }
        #expect(throws: PairingError.malformed) { try session.proof(answering: Accessory.message([.state: Data([4])])) }
        #expect(throws: PairingError.authentication) { try session.proof(answering: Accessory.message([.state: Data([2]), .error: Data([2])])) }

        _ = try session.proof(answering: try accessory.m2(answering: m1))
        // The receiver no longer knows this Mac.
        #expect(throws: PairingError.authentication) { try session.finish(answering: Accessory.message([.state: Data([4]), .error: Data([2])])) }
        #expect(throws: PairingError.malformed) { try session.finish(answering: Accessory.message([.state: Data([2])])) }
    }

    @Test("This Mac's pairing identity keeps its name and key through saving, and a new one is its own")
    func identity() throws {
        let saved = try JSONEncoder().encode(me)
        #expect(try JSONDecoder().decode(PairingIdentity.self, from: saved) == me)
        let first = PairingIdentity(), second = PairingIdentity()
        #expect(first.id != second.id && first.publicKey != second.publicKey && first.publicKey.count == 32)
        #expect(UUID(uuidString: first.id) != nil)
        let message = Data("hello".utf8)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: me.publicKey)
        #expect(key.isValidSignature(try me.signature(for: message), for: message))
        #expect(throws: PairingError.malformed) { try PairingIdentity(id: "x", seed: Data([1, 2, 3])).signature(for: message) }
        let receiver = PairedReceiver(id: Data("AA".utf8), publicKey: Data(repeating: 9, count: 32))
        #expect(try JSONDecoder().decode(PairedReceiver.self, from: try JSONEncoder().encode(receiver)) == receiver)
    }
}
