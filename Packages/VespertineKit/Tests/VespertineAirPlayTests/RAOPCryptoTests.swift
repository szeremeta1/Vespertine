//
// Vespertine: AES-128-CBC per packet and the RSA-OAEP key wrap of encrypted RAOP sessions.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Security
import Testing
@testable import VespertineAirPlay

func hex(_ s: String) -> Data {
    var d = Data()
    var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return d
}

@Suite("RAOP crypto")
struct RAOPCryptoTests {
    @Test("AES-128-CBC: NIST SP 800-38A F.2.1, and the tail of a packet stays in the clear")
    func aes() throws {
        let key = hex("2b7e151628aed2a6abf7158809cf4f3c"), iv = hex("000102030405060708090a0b0c0d0e0f")
        var data = hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51") + Data([1, 2, 3])
        try AESCBC.apply(&data, key: key, iv: iv, encrypt: true)
        #expect(data.prefix(32) == hex("7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b2"))
        #expect(data.suffix(3) == Data([1, 2, 3]))
        try AESCBC.apply(&data, key: key, iv: iv, encrypt: false)
        #expect(data == hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51") + Data([1, 2, 3]))
        var short = Data([1, 2, 3])
        try AESCBC.apply(&short, key: key, iv: iv, encrypt: true)
        #expect(short == Data([1, 2, 3]))
    }

    @Test("The AirPort Express key is a 2048-bit RSA public key; a wrapped AES key is 256 bytes")
    func airPortKey() throws {
        let key = try RSAWrap.airPortExpressKey()
        #expect(SecKeyGetBlockSize(key) == 256)
        #expect(try RSAWrap.encrypt(try AESCBC.randomBytes(16), key: key).count == 256)
    }

    @Test("Wrapped with a public key built from modulus and exponent, the AES key comes back with the private key")
    func wrapUnwrap() throws {
        let (privateKey, modulus) = try TestRSA.make()
        let publicKey = try RSAWrap.publicKey(modulus: modulus, exponent: Data([1, 0, 1]))
        let aes = try AESCBC.randomBytes(16)
        #expect(aes.count == 16 && aes != Data(count: 16))
        #expect(try RSAWrap.decrypt(try RSAWrap.encrypt(aes, key: publicKey), key: privateKey) == aes)
    }
}

/// A key pair for tests (the fake receiver plays the AirPort Express with it).
enum TestRSA {
    static func make() throws -> (SecKey, Data) {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error), let pub = SecKeyCopyPublicKey(privateKey),
              let der = SecKeyCopyExternalRepresentation(pub, &error) as Data? else { throw RAOPCryptoError.rsa("test key") }
        // PKCS#1: SEQUENCE { INTEGER modulus, INTEGER exponent }; the modulus is the first integer.
        var i = 1
        i += der[i] & 0x80 != 0 ? 1 + Int(der[i] & 0x7f) : 1
        precondition(der[i] == 0x02)
        i += 1
        var length = Int(der[i])
        if length & 0x80 != 0 {
            let n = length & 0x7f
            length = der[(i + 1)...(i + n)].reduce(0) { $0 << 8 | Int($1) }
            i += n
        }
        i += 1
        return (privateKey, der.subdata(in: i..<(i + length)))
    }
}
