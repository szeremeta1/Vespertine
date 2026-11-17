//
// Vespertine: the messages of HomeKit-style pairing, as HomePod, Apple TV and other AirPlay 2 receivers ask for it before
// they take audio. Two exchanges, both written here as plain steps from one message to the next, with no networking:
//
// - Pair-setup (`PairSetup`): the Mac proves it knows the PIN on the receiver's screen (SRP), then the two trade
//   long-term Ed25519 public keys under a key made from that proof. Done once per receiver. A receiver that lets anyone
//   on the network play uses the short "transient" form instead: a fixed PIN, no keys traded, and the SRP key is the
//   session's secret.
// - Pair-verify (`PairVerify`): at the start of every later session each side proves it still holds its long-term key
//   (X25519, then Ed25519 signatures), which gives the session's secret.
//
// Written from the published HomeKit Accessory Protocol and public notes on AirPlay 2; pyatv (MIT) and OwnTone
// (GPL-2.0-or-later) were read to confirm message order and labels. None of their code is included.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation

public enum PairingError: Error, Equatable, Sendable, LocalizedError {
    /// A message that isn't what this step of pairing expects, or a step taken out of order.
    case malformed
    /// The receiver says no: a wrong PIN in pair-setup, a pairing it no longer knows in pair-verify.
    case authentication
    /// Too many tries: the receiver wants this long before the next.
    case tryLater(seconds: Int)
    /// Any other error the receiver names (HomeKit's codes: 4 and 5 too many pairings or tries, 6 and 7 not now).
    case refused(code: UInt8)
    /// The receiver's proof or signature doesn't hold, or its sealed message doesn't open.
    case notAuthentic
    /// Pair-verify was answered by a receiver other than the one paired with.
    case wrongReceiver

    public var errorDescription: String? {
        switch self {
        case .authentication:
            String(localized: "it needs the code on its screen", comment: "Why an AirPlay receiver couldn't play, or couldn't be paired with: goes in “%1$@ couldn't play the song (%2$@).” The code is the one an Apple TV shows on its screen for AirPlay.")
        case .tryLater:
            String(localized: "it asks to wait before another try", comment: "Why an AirPlay receiver couldn't be paired with (too many wrong codes): goes in “%1$@ couldn't play the song (%2$@).”")
        case .malformed, .refused, .notAuthentic, .wrongReceiver:
            String(localized: "it refused the pairing", comment: "Why an AirPlay receiver couldn't play, or couldn't be paired with: goes in “%1$@ couldn't play the song (%2$@).”")
        }
    }
}

/// This Mac as receivers know it once paired: a name of its own making and an Ed25519 key. Kept for good (in the keychain).
struct PairingIdentity: Equatable, Sendable, Codable {
    let id: String
    /// The private key's 32 bytes.
    let seed: Data

    init(id: String = UUID().uuidString, seed: Data = Curve25519.Signing.PrivateKey().rawRepresentation) {
        self.id = id
        self.seed = seed
    }

    var publicKey: Data {
        (try? Curve25519.Signing.PrivateKey(rawRepresentation: seed))?.publicKey.rawRepresentation ?? Data()
    }

    func signature(for message: Data) throws -> Data {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed), let signature = try? key.signature(for: message) else {
            throw PairingError.malformed
        }
        return Data(signature)
    }
}

/// A receiver this Mac has paired with: the name it gave and its long-term Ed25519 public key.
struct PairedReceiver: Equatable, Sendable, Codable {
    let id: Data
    let publicKey: Data
}

extension PairingTLV {
    /// A receiver's reply read as step `state`: its error, if it names one, is thrown.
    static func reply(_ data: Data, state: UInt8) throws -> PairingTLV {
        guard let tlv = PairingTLV(decoding: data) else { throw PairingError.malformed }
        if let code = tlv.byte(.error) {
            switch code {
            case 2: throw PairingError.authentication
            case 3:
                // The wait in seconds, least significant byte first.
                let bytes = [UInt8]((tlv[.retryDelay] ?? Data()).prefix(4))
                var seconds = 0
                for (index, byte) in bytes.enumerated() { seconds |= Int(byte) << (8 * index) }
                throw PairingError.tryLater(seconds: seconds)
            default: throw PairingError.refused(code: code)
            }
        }
        guard tlv.byte(.state) == state else { throw PairingError.malformed }
        return tlv
    }
}

struct PairSetup: Sendable {
    /// The PIN of receivers that show none (anyone on the network may play).
    static let transientPIN = "3939"
    /// HomeKit's flag for the short form, sent in the first message.
    static let transientFlag: UInt8 = 0x10

    let transient: Bool
    private let srp: PairingSRP
    private var session: PairingSRP.Session?
    /// SRP's key, once the receiver's proof has been checked. In the short form this is the session's secret.
    private(set) var sharedKey: Data?

    /// `secret`: SRP's private number (random unless a test gives one).
    init(pin: String, transient: Bool = false, secret: Data? = nil) {
        self.transient = transient
        srp = PairingSRP(password: pin, secret: secret)
    }

    /// The short form, for receivers that ask for no PIN.
    static func withoutPIN(secret: Data? = nil) -> PairSetup {
        PairSetup(pin: transientPIN, transient: true, secret: secret)
    }

    /// M1: "pair with me".
    var start: Data {
        var tlv = PairingTLV()
        tlv.append(.method, 0)
        tlv.append(.state, 1)
        if transient { tlv.append(.flags, Self.transientFlag) }
        return tlv.encoded
    }

    /// M3, from the receiver's M2 (its salt and SRP key): this side's SRP key and the proof that it knows the PIN.
    mutating func proof(answering reply: Data) throws -> Data {
        let tlv = try PairingTLV.reply(reply, state: 2)
        guard let salt = tlv[.salt], let key = tlv[.publicKey], let session = srp.session(salt: salt, serverPublicKey: key) else {
            throw PairingError.malformed
        }
        self.session = session
        var out = PairingTLV()
        out.append(.state, 3)
        out.append(.publicKey, srp.publicKey)
        out.append(.proof, session.proof)
        return out.encoded
    }

    /// The receiver's M4 (its own proof) checked; gives SRP's key. The short form ends here.
    @discardableResult
    mutating func finish(answering reply: Data) throws -> Data {
        guard let session else { throw PairingError.malformed }
        let tlv = try PairingTLV.reply(reply, state: 4)
        guard let proof = tlv[.proof], session.accepts(proof) else { throw PairingError.notAuthentic }
        sharedKey = session.key
        return session.key
    }

    /// M5: this Mac's name and long-term public key, signed, sealed under a key from SRP's.
    func exchange(_ identity: PairingIdentity) throws -> Data {
        guard let sharedKey, !transient else { throw PairingError.malformed }
        let id = Data(identity.id.utf8), publicKey = identity.publicKey
        let x = PairingCrypto.bytes(secret: sharedKey, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
        var inner = PairingTLV()
        inner.append(.identifier, id)
        inner.append(.publicKey, publicKey)
        inner.append(.signature, try identity.signature(for: x + id + publicKey))
        var out = PairingTLV()
        out.append(.state, 5)
        out.append(.encryptedData, try PairingCrypto.seal(inner.encoded, key: Self.sealingKey(sharedKey), nonce: PairingCrypto.nonce("PS-Msg05")))
        return out.encoded
    }

    /// The receiver's M6: its name and long-term public key, to keep.
    ///
    /// Its signature over them is not checked. It could only show that the receiver holds the private half of the key it
    /// has just sent; that this is the receiver whose screen showed the PIN is already settled by SRP, whose key this
    /// message is sealed under.
    func receiver(answering reply: Data) throws -> PairedReceiver {
        guard let sharedKey, !transient else { throw PairingError.malformed }
        let tlv = try PairingTLV.reply(reply, state: 6)
        guard let sealed = tlv[.encryptedData] else { throw PairingError.malformed }
        guard let plain = try? PairingCrypto.open(sealed, key: Self.sealingKey(sharedKey), nonce: PairingCrypto.nonce("PS-Msg06")) else {
            throw PairingError.notAuthentic
        }
        guard let inner = PairingTLV(decoding: plain), let id = inner[.identifier], !id.isEmpty,
              let publicKey = inner[.publicKey], publicKey.count == 32 else { throw PairingError.malformed }
        return PairedReceiver(id: id, publicKey: publicKey)
    }

    private static func sealingKey(_ sharedKey: Data) -> SymmetricKey {
        PairingCrypto.key(secret: sharedKey, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
    }
}

struct PairVerify: Sendable {
    private let identity: PairingIdentity
    private let receiver: PairedReceiver
    /// This session's X25519 private key (32 bytes).
    private let seed: Data
    /// This session's X25519 public key, sent in M1.
    let publicKey: Data
    private var secret: Data?

    /// `seed`: this session's X25519 private key (new each time unless a test gives one).
    init(identity: PairingIdentity, receiver: PairedReceiver, seed: Data = Curve25519.KeyAgreement.PrivateKey().rawRepresentation) {
        self.identity = identity
        self.receiver = receiver
        self.seed = seed
        publicKey = (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed))?.publicKey.rawRepresentation ?? Data()
    }

    /// M1: this session's public key.
    var start: Data {
        var tlv = PairingTLV()
        tlv.append(.state, 1)
        tlv.append(.publicKey, publicKey)
        return tlv.encoded
    }

    /// M3, from the receiver's M2: its session key and its sealed, signed name are checked against the pairing, and this
    /// Mac's own signed name goes back.
    mutating func proof(answering reply: Data) throws -> Data {
        let tlv = try PairingTLV.reply(reply, state: 2)
        guard let theirs = tlv[.publicKey], theirs.count == 32, let sealed = tlv[.encryptedData],
              let mine = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed) else { throw PairingError.malformed }
        guard let point = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirs),
              let agreed = try? mine.sharedSecretFromKeyAgreement(with: point) else { throw PairingError.notAuthentic }
        let shared = agreed.withUnsafeBytes { Data($0) }
        let key = PairingCrypto.key(secret: shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        guard let plain = try? PairingCrypto.open(sealed, key: key, nonce: PairingCrypto.nonce("PV-Msg02")) else {
            throw PairingError.notAuthentic
        }
        guard let inner = PairingTLV(decoding: plain), let id = inner[.identifier], let signature = inner[.signature] else {
            throw PairingError.malformed
        }
        guard id == receiver.id else { throw PairingError.wrongReceiver }
        guard let known = try? Curve25519.Signing.PublicKey(rawRepresentation: receiver.publicKey),
              known.isValidSignature(signature, for: theirs + id + publicKey) else { throw PairingError.notAuthentic }

        let me = Data(identity.id.utf8)
        var answer = PairingTLV()
        answer.append(.identifier, me)
        answer.append(.signature, try identity.signature(for: publicKey + me + theirs))
        var out = PairingTLV()
        out.append(.state, 3)
        out.append(.encryptedData, try PairingCrypto.seal(answer.encoded, key: key, nonce: PairingCrypto.nonce("PV-Msg03")))
        secret = shared
        return out.encoded
    }

    /// The receiver's M4 (it accepts this Mac) checked; gives the session's secret.
    func finish(answering reply: Data) throws -> Data {
        guard let secret else { throw PairingError.malformed }
        _ = try PairingTLV.reply(reply, state: 4)
        return secret
    }
}

/// The two keys of the sealed channel that follows pairing, both from the session's secret (pair-verify's, or SRP's key
/// in the short form): one for what the Mac sends, one for what it receives.
struct PairingChannelKeys: Equatable, Sendable {
    let write: SymmetricKey
    let read: SymmetricKey

    /// The control channel's (the RTSP connection itself).
    static func control(secret: Data) -> PairingChannelKeys {
        PairingChannelKeys(write: PairingCrypto.key(secret: secret, salt: "Control-Salt", info: "Control-Write-Encryption-Key"),
                           read: PairingCrypto.key(secret: secret, salt: "Control-Salt", info: "Control-Read-Encryption-Key"))
    }
}
