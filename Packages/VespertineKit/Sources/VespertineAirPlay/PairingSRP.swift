//
// Vespertine: the client's half of SRP-6a as HomeKit-style pairing uses it, the first step in pairing with HomePod,
// Apple TV and other AirPlay 2 receivers: the 3072-bit group of RFC 5054 with SHA-512. The Mac proves it knows the PIN
// (or, for a receiver that lets anyone on the network play, the fixed one such receivers use) without sending it, and
// both sides come away with the same key.
//
// The exchange is the published SRP-6a (RFC 2945, RFC 5054) with the byte conventions the open-source HomeKit and
// AirPlay code agrees on: k and u hash values padded to the group's length, the proof hashes them as they are.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation

struct PairingSRP: Sendable {
    /// What both sides hold once the receiver's reply is in.
    struct Session: Equatable, Sendable {
        /// The shared key K (64 bytes), which the pairing's own keys are derived from.
        let key: Data
        /// M1: sent to the receiver to prove the PIN.
        let proof: Data
        /// M2: what a receiver that knows the PIN answers.
        let serverProof: Data

        /// Whether the receiver's answer proves it holds the same key.
        func accepts(_ answer: Data) -> Bool {
            guard answer.count == serverProof.count else { return false }
            return zip(answer, serverProof).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
        }
    }

    /// The name HomeKit-style pairing signs in as.
    static let pairSetupName = "Pair-Setup"

    /// A: sent to the receiver (leading zero bytes dropped).
    let publicKey: Data

    private let name: String
    private let password: String
    private let secret: Data
    private let arithmetic: ModularArithmetic

    /// `secret` is this pairing's private number (32 random bytes unless a test gives one).
    init(name: String = PairingSRP.pairSetupName, password: String, secret: Data? = nil) {
        self.name = name
        self.password = password
        let secret = secret ?? Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        self.secret = secret
        // The group is a constant that is odd and long, so this can't fail.
        let arithmetic = ModularArithmetic(modulus: Self.modulus)!
        self.arithmetic = arithmetic
        publicKey = Self.trimmed(arithmetic.power(Self.generator, secret))
    }

    /// The key and proofs for the receiver's salt and public key B; nil when B is one no honest receiver sends
    /// (a multiple of the modulus, which would make the key guessable).
    func session(salt: Data, serverPublicKey: Data) -> Session? {
        let n = arithmetic.byteCount
        guard !serverPublicKey.isEmpty, serverPublicKey.count <= n, !arithmetic.isZero(serverPublicKey) else { return nil }
        let serverKey = Self.trimmed(serverPublicKey)
        let k = Self.hash(Self.modulus, Self.padded(Self.generator, n))
        let x = Self.hash(salt, Self.hash(Data((name + ":" + password).utf8)))
        let u = Self.hash(Self.padded(publicKey, n), Self.padded(serverKey, n))
        guard !arithmetic.isZero(u) else { return nil }
        // S = (B − k·gˣ)^(a + u·x), taken as baseᵃ · (baseˣ)ᵘ so that only arithmetic modulo N is needed.
        let base = arithmetic.difference(serverKey, arithmetic.product(k, arithmetic.power(Self.generator, x)))
        let shared = Self.trimmed(arithmetic.product(arithmetic.power(base, secret),
                                                      arithmetic.power(arithmetic.power(base, x), u)))
        let key = Self.hash(shared)
        let group = Data(zip(Self.hash(Self.modulus), Self.hash(Self.generator)).map { $0 ^ $1 })
        let proof = Self.hash(group, Self.hash(Data(name.utf8)), salt, publicKey, serverKey, key)
        return Session(key: key, proof: proof, serverProof: Self.hash(publicKey, proof, key))
    }

    // MARK: - Bytes

    private static func hash(_ parts: Data...) -> Data {
        var hasher = SHA512()
        for part in parts { hasher.update(data: part) }
        return Data(hasher.finalize())
    }

    private static func trimmed(_ value: Data) -> Data {
        let rest = value.drop(while: { $0 == 0 })
        return rest.isEmpty ? Data([0]) : Data(rest)
    }

    private static func padded(_ value: Data, _ count: Int) -> Data {
        value.count >= count ? Data(value) : Data(repeating: 0, count: count - value.count) + value
    }

    static let generator = Data([5])

    /// The 3072-bit group of RFC 5054 (appendix A), which is also RFC 3526's group 15.
    static let modulus: Data = {
        let digits =
            "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404dd" +
            "ef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed" +
            "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f" +
            "83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b" +
            "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa0510" +
            "15728e5a8aaac42dad33170d04507a33a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7" +
            "abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864d87602733ec86a64521f2b18177b200c" +
            "bbe117577a615d6c770988c0bad946e208e24fa074e5ab3143db5bfce0fd108e4b82d120a93ad2caffffffffffffffff"
        var out = Data(capacity: digits.count / 2)
        var high: UInt8?
        for digit in digits.utf8 {
            let value = digit <= 57 ? digit - 48 : digit - 87
            if let first = high { out.append(first << 4 | value); high = nil } else { high = value }
        }
        return out
    }()
}
