//
// Vespertine: the two sealed-box pieces of HomeKit-style pairing (HomePod, Apple TV and other AirPlay 2 receivers), both
// from CryptoKit: keys derived with HKDF-SHA-512 from a shared secret under a salt and a label, and messages sealed with
// ChaCha20-Poly1305 under a twelve-byte nonce that is four zero bytes and then an eight-byte label or counter.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation

enum PairingCrypto {
    enum Failure: Error, Equatable {
        /// The nonce is longer than twelve bytes, or the sealed bytes are shorter than a tag.
        case malformed
        /// The bytes weren't sealed with this key and nonce, or were changed on the way.
        case notAuthentic
    }

    static let tagLength = 16

    /// A 32-byte key from `secret`, as pairing names its keys (for one, "Pair-Setup-Encrypt-Salt" and
    /// "Pair-Setup-Encrypt-Info").
    static func key(secret: Data, salt: String, info: String) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(salt.utf8), info: Data(info.utf8),
                               outputByteCount: 32)
    }

    /// The nonce for a labelled message, such as "PS-Msg05".
    static func nonce(_ label: String) -> Data {
        padded(Data(label.utf8))
    }

    /// The nonce for the numbered messages that follow pairing: the count, least significant byte first.
    static func nonce(counter: UInt64) -> Data {
        padded(Data((0..<8).map { UInt8(truncatingIfNeeded: counter >> UInt64($0 * 8)) }))
    }

    /// The sealed bytes followed by the 16-byte tag.
    static func seal(_ plain: Data, key: SymmetricKey, nonce: Data, authenticating extra: Data = Data()) throws -> Data {
        guard nonce.count <= 12, let nonce = try? ChaChaPoly.Nonce(data: padded(nonce)) else { throw Failure.malformed }
        let box = try ChaChaPoly.seal(plain, using: key, nonce: nonce, authenticating: extra)
        return box.ciphertext + box.tag
    }

    static func open(_ sealed: Data, key: SymmetricKey, nonce: Data, authenticating extra: Data = Data()) throws -> Data {
        guard sealed.count >= tagLength, nonce.count <= 12, let nonce = try? ChaChaPoly.Nonce(data: padded(nonce)) else {
            throw Failure.malformed
        }
        let bytes = Data(sealed)
        let split = bytes.count - tagLength
        guard let box = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: bytes.prefix(split), tag: bytes.suffix(tagLength)),
              let plain = try? ChaChaPoly.open(box, using: key, authenticating: extra) else { throw Failure.notAuthentic }
        return plain
    }

    private static func padded(_ nonce: Data) -> Data {
        nonce.count >= 12 ? Data(nonce) : Data(repeating: 0, count: 12 - nonce.count) + nonce
    }
}
