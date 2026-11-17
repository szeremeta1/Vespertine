//
// Vespertine: the digests the SMB client signs in and signs with, against the vectors their own standards publish.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineShare

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
func unhex(_ text: String) -> [UInt8] {
    let digits = Array(text.filter { !$0.isWhitespace })
    return stride(from: 0, to: digits.count - 1, by: 2).map { UInt8(String(digits[$0...($0 + 1)]), radix: 16)! }
}

@Suite struct ShareDigestsTests {
    @Test func md4MatchesRFC1320() {
        #expect(hex(ShareDigests.md4([])) == "31d6cfe0d16ae931b73c59d7e0c089c0")
        #expect(hex(ShareDigests.md4(Array("abc".utf8))) == "a448017aaf21d8525fc10ae87aa6729d")
        #expect(hex(ShareDigests.md4(Array("12345678901234567890123456789012345678901234567890123456789012345678901234567890".utf8))) == "e33b4ddc9c38f2199c3e7b164fcc0536")
    }

    @Test func md5MatchesRFC1321() {
        #expect(hex(ShareDigests.md5([])) == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(hex(ShareDigests.md5(Array("message digest".utf8))) == "f96b697d7cb7938d525a2f31aaf161d0")
        #expect(hex(ShareDigests.md5(Array("12345678901234567890123456789012345678901234567890123456789012345678901234567890".utf8))) == "57edf4a22be3c955ac49da2e2107b67a")
    }

    @Test func sha256MatchesFIPS180() {
        #expect(hex(ShareDigests.sha256(Array("abc".utf8))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(hex(ShareDigests.sha256(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)))
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        #expect(hex(ShareDigests.sha256([UInt8](repeating: 0x61, count: 1_000_000))) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func sha512MatchesFIPS180() {
        #expect(hex(ShareDigests.sha512([])) == "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e")
        #expect(hex(ShareDigests.sha512(Array("abc".utf8))) == "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
        // Longer than one block.
        #expect(hex(ShareDigests.sha512(Array("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu".utf8)))
                == "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909")
    }

    @Test func hmacMatchesRFC2202AndRFC4231() {
        #expect(hex(ShareDigests.hmacMD5(key: Array("Jefe".utf8), Array("what do ya want for nothing?".utf8))) == "750c783e6ab0b503eaa86e310a5db738")
        #expect(hex(ShareDigests.hmacSHA256(key: Array("Jefe".utf8), Array("what do ya want for nothing?".utf8)))
                == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        // A key longer than a block is hashed first.
        #expect(hex(ShareDigests.hmacSHA256(key: [UInt8](repeating: 0xaa, count: 131), Array("Test Using Larger Than Block-Size Key - Hash Key First".utf8)))
                == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
    }

    @Test func aesMatchesFIPS197() {
        let key = ShareDigests.AESKey(unhex("000102030405060708090a0b0c0d0e0f"))
        #expect(hex(ShareDigests.aesEncrypt(block: unhex("00112233445566778899aabbccddeeff"), key: key)) == "69c4e0d86a7b0430d8cdb78070b4c55a")
    }

    @Test func cmacMatchesRFC4493() {
        let key = unhex("2b7e151628aed2a6abf7158809cf4f3c")
        let message = unhex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710")
        #expect(hex(ShareDigests.aesCMAC(key: key, [])) == "bb1d6929e95937287fa37d129b756746")
        #expect(hex(ShareDigests.aesCMAC(key: key, Array(message.prefix(16)))) == "070a16b46b4d4144f79bdd9dd04a287c")
        #expect(hex(ShareDigests.aesCMAC(key: key, Array(message.prefix(40)))) == "dfa66747de9ae63030ca32611497c827")
        #expect(hex(ShareDigests.aesCMAC(key: key, message)) == "51f0bebf7e3b9d92fc49741779363cfe")
    }

    @Test func theSystemsDigestsAndTheOnesWrittenHereAgree() {
        // On Apple's systems signing uses the system's HMAC and AES; elsewhere both sides of this are the same code.
        var seed: UInt64 = 42
        func bytes(_ count: Int) -> [UInt8] {
            (0..<count).map { _ in
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return UInt8(truncatingIfNeeded: seed >> 33)
            }
        }
        for length in [0, 1, 15, 16, 17, 31, 32, 33, 64, 113, 1000, 65536 + 5] {
            let key = bytes(16), message = bytes(length)
            #expect(ShareDigests.hmacSHA256(key: key, message) == ShareDigests.hmacSHA256(key: key, message, plain: true))
            #expect(ShareDigests.aesCMAC(key: key, message) == ShareDigests.aesCMAC(key: key, message, plain: true))
        }
    }

    @Test func ntlmVersion2MatchesTheProtocolsOwnExample() throws {
        // MS-NLMP 4.2.4: user "User", domain "Domain", password "Password", the server's challenge 0123456789abcdef, the
        // client's aa×8, time 0, and a server that names itself "Domain" and "Server" and sends no time of its own.
        func pair(_ id: UInt16, _ text: String) -> [UInt8] { [UInt8(id), 0, UInt8(text.utf16.count * 2), 0] + text.utf16LE }
        let info = pair(2, "Domain") + pair(1, "Server") + [0, 0, 0, 0]
        var challenge = ByteWriter()
        challenge.raw(NTLM.signature)
        challenge.u32(2)
        challenge.zeros(8)
        challenge.u32(NTLM.asked & ~NTLM.keyExchange)   // this server offers no key exchange
        challenge.raw(unhex("0123456789abcdef"))
        challenge.zeros(8)
        challenge.u16(UInt16(info.count)); challenge.u16(UInt16(info.count)); challenge.u32(56)
        challenge.zeros(8)
        challenge.raw(info)
        let answer = try NTLM.authenticate(user: "User", domain: "Domain", password: "Password", negotiate: NTLM.negotiate(), challenge: challenge.bytes,
                                           clientChallenge: [UInt8](repeating: 0xaa, count: 8), time: 0, newKey: [UInt8](repeating: 0x55, count: 16))
        // No exchange was offered, so none is made: the session's key is the one the password gives, nothing is wrapped
        // and signatures aren't scrambled.
        #expect(hex(answer.sessionKey) == "8de40ccadbc14a82f15cb0ad0de95ca3")
        #expect(answer.sealingKey == nil)
        #expect(try ByteReader(answer.message).u16(52) == 0)
        #expect(try ByteReader(answer.message).u32(60) & NTLM.keyExchange == 0)
        let r = ByteReader(answer.message)
        let lm = try r.slice(Int(r.u32(16)), Int(r.u16(12)))
        let nt = try r.slice(Int(r.u32(24)), Int(r.u16(20)))
        #expect(hex(lm) == "86c35097ac9cec102554764a57cccc19aaaaaaaaaaaaaaaa")
        #expect(hex(Array(nt.prefix(16))) == "68cd0ab851e51c96aabc927bebef6a1c")
        #expect(!answer.carriesDigest)
        #expect(String(utf16LE: try r.slice(Int(r.u32(40)), Int(r.u16(36)))) == "User")
        #expect(String(utf16LE: try r.slice(Int(r.u32(32)), Int(r.u16(28)))) == "Domain")
    }

    @Test func smb3SigningKeysAreDerivedAsTheProtocolSays() {
        // SP 800-108 in counter mode with HMAC-SHA-256, the label and context SMB 3.0 names for signing.
        let key = unhex("000102030405060708090a0b0c0d0e0f")
        var input: [UInt8] = unhex("00000001")
        input += Array("SMB2AESCMAC".utf8)
        input += [0, 0]
        input += Array("SmbSign".utf8)
        input += [0]
        input += unhex("00000080")
        #expect(SMBConnection.derive(key, label: "SMB2AESCMAC", context: "SmbSign") == Array(ShareDigests.hmacSHA256(key: key, input, plain: true).prefix(16)))
    }
}
