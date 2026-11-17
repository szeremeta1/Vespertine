//
// Vespertine: the receiver's side of pairing for the fake receiver: it answers pair-setup with the SRP exchange worked
// out independently for the building-block tests (PIN 3939, so the sender must be given that exchange's private number),
// keeps the Macs that pair with it, and answers pair-verify with keys of its own, checking every seal and signature the
// way a receiver does.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
@testable import VespertineAirPlay

final class FakePairing: @unchecked Sendable {
    let id = Data("AA:BB:CC:DD:EE:FF".utf8)
    let longTerm = Curve25519.Signing.PrivateKey()
    private let session = Curve25519.KeyAgreement.PrivateKey()
    private let lock = NSLock()
    private var _controllers: [Data: Data] = [:]
    private var _pinShown = 0
    private var transient = false
    private var proved = false
    private var client = Data()
    /// Takes the short form (no PIN) only when true: a receiver set to ask for a PIN refuses it.
    let allowsTransient: Bool

    init(allowsTransient: Bool = true) {
        self.allowsTransient = allowsTransient
    }

    /// The Macs paired with this receiver: their names and Ed25519 public keys.
    var controllers: [Data: Data] { lock.withLock { _controllers } }
    /// How often it was asked to show its PIN.
    var pinShown: Int { lock.withLock { _pinShown } }
    /// What a Mac keeps of this receiver.
    var paired: PairedReceiver { PairedReceiver(id: id, publicKey: longTerm.publicKey.rawRepresentation) }

    func forget() { lock.withLock { _controllers = [:] } }
    func showPIN() { lock.withLock { _pinShown += 1 } }

    private static func message(_ pairs: KeyValuePairs<PairingTLV.Tag, Data>) -> Data { PairingTLV(pairs).encoded }
    private static func refusal(_ state: UInt8, code: UInt8 = 2) -> Data { message([.state: Data([state]), .error: Data([code])]) }
    private static let setupKey = PairingCrypto.key(secret: hex(srpKey), salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")

    /// The receiver's keys for the sealed connection: the Mac's, the other way round.
    private static func channel(secret: Data) -> PairingChannelKeys {
        let keys = PairingChannelKeys.control(secret: secret)
        return PairingChannelKeys(write: keys.read, read: keys.write)
    }

    /// The answer to one pairing message, and, when that answer ends pairing, the keys everything after it is sealed with.
    func answer(path: String, body: Data) -> (Data, PairingChannelKeys?) {
        guard let tlv = PairingTLV(decoding: body), let state = tlv.byte(.state) else { return (Self.refusal(0, code: 1), nil) }
        switch (path, state) {
        case ("/pair-setup", 1):
            transient = tlv.byte(.flags) == PairSetup.transientFlag
            proved = false
            guard !transient || allowsTransient else { return (Self.refusal(2, code: 6), nil) }
            return (Self.message([.state: Data([2]), .publicKey: hex(srpServerKey), .salt: hex(srpSalt)]), nil)
        case ("/pair-setup", 3):
            guard tlv[.publicKey] == hex(srpClientKey), tlv[.proof] == hex(srpProof) else { return (Self.refusal(4), nil) }
            proved = true
            return (Self.message([.state: Data([4]), .proof: hex(srpServerProof)]), transient ? Self.channel(secret: hex(srpKey)) : nil)
        case ("/pair-setup", 5):
            let signed = PairingCrypto.bytes(secret: hex(srpKey), salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
            guard proved, !transient, let sealed = tlv[.encryptedData],
                  let plain = try? PairingCrypto.open(sealed, key: Self.setupKey, nonce: PairingCrypto.nonce("PS-Msg05")),
                  let inner = PairingTLV(decoding: plain), let name = inner[.identifier], let key = inner[.publicKey], let signature = inner[.signature],
                  let known = try? Curve25519.Signing.PublicKey(rawRepresentation: key), known.isValidSignature(signature, for: signed + name + key)
            else { return (Self.refusal(6), nil) }
            lock.withLock { _controllers[name] = key }
            let mine = longTerm.publicKey.rawRepresentation
            let signing = PairingCrypto.bytes(secret: hex(srpKey), salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
            guard let own = try? longTerm.signature(for: signing + id + mine),
                  let out = try? PairingCrypto.seal(Self.message([.identifier: id, .publicKey: mine, .signature: own]), key: Self.setupKey,
                                                    nonce: PairingCrypto.nonce("PS-Msg06")) else { return (Self.refusal(6, code: 1), nil) }
            return (Self.message([.state: Data([6]), .encryptedData: out]), nil)
        case ("/pair-verify", 1):
            guard let theirs = tlv[.publicKey], let key = verifyKey(with: theirs) else { return (Self.refusal(2, code: 1), nil) }
            client = theirs
            let mine = session.publicKey.rawRepresentation
            guard let signature = try? longTerm.signature(for: mine + id + theirs),
                  let sealed = try? PairingCrypto.seal(Self.message([.identifier: id, .signature: signature]), key: key, nonce: PairingCrypto.nonce("PV-Msg02"))
            else { return (Self.refusal(2, code: 1), nil) }
            return (Self.message([.state: Data([2]), .publicKey: mine, .encryptedData: sealed]), nil)
        case ("/pair-verify", 3):
            let mine = session.publicKey.rawRepresentation
            guard let key = verifyKey(with: client), let secret = secret(with: client), let sealed = tlv[.encryptedData],
                  let plain = try? PairingCrypto.open(sealed, key: key, nonce: PairingCrypto.nonce("PV-Msg03")),
                  let inner = PairingTLV(decoding: plain), let name = inner[.identifier], let signature = inner[.signature],
                  let raw = controllers[name], let known = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
                  known.isValidSignature(signature, for: client + name + mine) else { return (Self.refusal(4), nil) }
            return (Self.message([.state: Data([4])]), Self.channel(secret: secret))
        default:
            return (Self.refusal(state &+ 1, code: 1), nil)
        }
    }

    private func secret(with client: Data) -> Data? {
        guard let point = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: client),
              let agreed = try? session.sharedSecretFromKeyAgreement(with: point) else { return nil }
        return agreed.withUnsafeBytes { Data($0) }
    }

    private func verifyKey(with client: Data) -> SymmetricKey? {
        secret(with: client).map { PairingCrypto.key(secret: $0, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info") }
    }
}
