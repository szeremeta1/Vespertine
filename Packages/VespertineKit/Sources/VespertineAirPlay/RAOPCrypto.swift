//
// Vespertine: RAOP's encryption, for receivers that ask for it (`et=1`, the AirPort Express). Each audio packet's whole
// 16-byte blocks are AES-128-CBC encrypted with the session key, the IV starting over for every packet, the tail left in
// the clear; the key goes to the receiver in the ANNOUNCE, wrapped with RSA-OAEP (SHA-1) under the AirPort Express public
// key that every open sender carries (libraop raop_client.c, OwnTone raop.c). Only that public key is needed.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CommonCrypto
import Foundation
import Security

public enum RAOPCryptoError: Error { case aes(Int32), rsa(String) }

public enum AESCBC {
    /// Encrypts (or decrypts) the whole blocks of `data` in place; the last `count % 16` bytes stay as they are.
    public static func apply(_ data: inout Data, key: Data, iv: Data, encrypt: Bool) throws {
        let whole = data.count / 16 * 16
        guard whole > 0 else { return }
        var out = Data(count: whole)
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                                k.baseAddress, kCCKeySizeAES128, v.baseAddress, i.baseAddress, whole, o.baseAddress, whole, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess, moved == whole else { throw RAOPCryptoError.aes(status) }
        data.replaceSubrange(data.startIndex..<(data.startIndex + whole), with: out)
    }

    public static func randomBytes(_ count: Int) -> Data {
        var d = Data(count: count)
        _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return d
    }
}

public enum RSAWrap {
    /// The AirPort Express public key's modulus (2048-bit), as published by libraop (MIT) and OwnTone; the exponent is 65537.
    static let airPortModulus = """
        59dE8qLieItsH1WgjrcFRKj6eUWqi+bGLOX1HL3U3GhC/j0Qg90u3sG/1CUtwC5vOYvfDmFI6oSFXi5ELabWJmT2dKHzBJKa3k9ok+8t9ucRqMd6DZHJ2YCCLlDR\
        KSKv6kDqnw4UwPdpOMXziC/AMj3Z/lUVX1G7WSHCAWKf1zNS1eLvqr+boEjXuBOitnZ/bDzPHrTOZz0Dew0uowxf/+sG+NCK3eQJVxqcaJ/vEHKIVd2M+5qL71yJ\
        Q+87X6oV3eaYvt3zWZYD6z5vYTcrtij2VZ9Zmni/UAaHqn9JdsBWLUEpVviYnhimNVvYFZeCXg/IdTQ+x4IRdiXNv5hEew==
        """

    /// The AirPort Express key as a SecKey.
    public static func airPortExpressKey() throws -> SecKey {
        guard let modulus = Data(base64Encoded: airPortModulus) else { throw RAOPCryptoError.rsa("modulus") }
        return try publicKey(modulus: modulus, exponent: Data([0x01, 0x00, 0x01]))
    }

    /// A public key from its modulus and exponent (PKCS#1 RSAPublicKey DER, what SecKeyCreateWithData takes).
    public static func publicKey(modulus: Data, exponent: Data) throws -> SecKey {
        func integer(_ bytes: Data) -> Data {
            var b = Data(bytes.drop { $0 == 0 })
            if let first = b.first, first & 0x80 != 0 { b.insert(0, at: 0) }
            return Data([0x02]) + length(b.count) + b
        }
        let body = integer(modulus) + integer(exponent)
        let der = Data([0x30]) + length(body.count) + body
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            throw RAOPCryptoError.rsa(error.map { String(describing: $0.takeRetainedValue()) } ?? "key")
        }
        return key
    }

    static func length(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        if n < 0x100 { return Data([0x81, UInt8(n)]) }
        return Data([0x82, UInt8(n >> 8), UInt8(n & 0xff)])
    }

    /// RSA-OAEP (SHA-1) of `data` under `key`.
    public static func encrypt(_ data: Data, key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let out = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, data as CFData, &error) else {
            throw RAOPCryptoError.rsa(error.map { String(describing: $0.takeRetainedValue()) } ?? "encrypt")
        }
        return out as Data
    }

    public static func decrypt(_ data: Data, key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let out = SecKeyCreateDecryptedData(key, .rsaEncryptionOAEPSHA1, data as CFData, &error) else {
            throw RAOPCryptoError.rsa(error.map { String(describing: $0.takeRetainedValue()) } ?? "decrypt")
        }
        return out as Data
    }
}
