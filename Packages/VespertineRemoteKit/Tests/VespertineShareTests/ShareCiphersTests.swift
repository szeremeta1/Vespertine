//
// Vespertine: the two ciphers SMB 3 encrypts with, against the vectors their own standards publish.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineShare

@Suite struct ShareCiphersTests {
    // The GCM specification's own test cases 1 to 4 (McGrew and Viega, appendix B; SP 800-38D points to them).
    private static let gcmKey = "feffe9928665731c6d6a8f9467308308"
    private static let gcmNonce = "cafebabefacedbaddecaf888"
    private static let gcmMessage = "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255"
    private static let gcmEncrypted = "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091473f5985"

    @Test(arguments: [false, true]) func gcmMatchesItsSpecification(plain: Bool) {
        let zeros = [UInt8](repeating: 0, count: 16), zeroNonce = [UInt8](repeating: 0, count: 12)
        let one = ShareCiphers.seal(.gcm, key: zeros, nonce: zeroNonce, [], aad: [], plain: plain)
        #expect(one.ciphertext.isEmpty && hex(one.tag) == "58e2fccefa7e3061367f1d57a4e7455a")
        let two = ShareCiphers.seal(.gcm, key: zeros, nonce: zeroNonce, zeros, aad: [], plain: plain)
        #expect(hex(two.ciphertext) == "0388dace60b6a392f328c2b971b2fe78" && hex(two.tag) == "ab6e47d42cec13bdf53a67b21257bddf")

        let key = unhex(Self.gcmKey), nonce = unhex(Self.gcmNonce), message = unhex(Self.gcmMessage)
        let three = ShareCiphers.seal(.gcm, key: key, nonce: nonce, message, aad: [], plain: plain)
        #expect(hex(three.ciphertext) == Self.gcmEncrypted && hex(three.tag) == "4d5c2af327cd64a62cf35abd2ba6fab4")
        // With extra data that is covered by the tag but not encrypted, and a message that doesn't fill its last block.
        let aad = unhex("feedfacedeadbeeffeedfacedeadbeefabaddad2")
        let four = ShareCiphers.seal(.gcm, key: key, nonce: nonce, Array(message.prefix(60)), aad: aad, plain: plain)
        #expect(hex(four.ciphertext) == String(Self.gcmEncrypted.prefix(120)) && hex(four.tag) == "5bc94fbc3221a5db94fae95ae7121a47")

        #expect(ShareCiphers.open(.gcm, key: key, nonce: nonce, four, aad: aad, plain: plain) == Array(message.prefix(60)))
        var changed = four
        changed.ciphertext[7] ^= 0x80
        #expect(ShareCiphers.open(.gcm, key: key, nonce: nonce, changed, aad: aad, plain: plain) == nil)
        #expect(ShareCiphers.open(.gcm, key: key, nonce: nonce, four, aad: Array(aad.dropLast()), plain: plain) == nil)
    }

    @Test(arguments: [false, true]) func ccmMatchesRFC3610AndSP80038C(plain: Bool) {
        // RFC 3610, packet vector 1: a 13-byte nonce, an 8-byte tag, 8 bytes of header that stay readable.
        let packet = [UInt8](0..<0x1f)
        let first = ShareCiphers.ccm(key: [UInt8](0xc0..<0xd0), nonce: unhex("00000003020100a0a1a2a3a4a5"), Array(packet[8...]), aad: Array(packet[..<8]),
                                     tagLength: 8, opening: false, plain: plain)
        #expect(hex(first.ciphertext + first.tag) == "588c979a61c663d2f066d0c2c0f989806d5f6b61dac38417e8d12cfdf926e0")

        // SP 800-38C, examples 1 and 2: 7- and 8-byte nonces, 4- and 6-byte tags.
        let key = [UInt8](0x40..<0x50)
        let one = ShareCiphers.ccm(key: key, nonce: unhex("10111213141516"), unhex("20212223"), aad: [UInt8](0..<8), tagLength: 4, opening: false, plain: plain)
        #expect(hex(one.ciphertext + one.tag) == "7162015b4dac255d")
        let two = ShareCiphers.ccm(key: key, nonce: unhex("1011121314151617"), [UInt8](0x20..<0x30), aad: [UInt8](0..<16), tagLength: 6, opening: false, plain: plain)
        #expect(hex(two.ciphertext + two.tag) == "d2a1f0e051ea5f62081a7792073d593d1fc64fbfaccd")

        // Opening gives the message back and the same tag.
        let opened = ShareCiphers.ccm(key: key, nonce: unhex("1011121314151617"), two.ciphertext, aad: [UInt8](0..<16), tagLength: 6, opening: true, plain: plain)
        #expect(opened.ciphertext == [UInt8](0x20..<0x30) && opened.tag == two.tag)
    }

    @Test func theSystemsCiphersAndTheOnesWrittenHereAgree() {
        // On Apple's systems encryption uses the system's AES; elsewhere both sides of this are the same code.
        var seed: UInt64 = 7
        func bytes(_ count: Int) -> [UInt8] {
            (0..<count).map { _ in
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return UInt8(truncatingIfNeeded: seed >> 33)
            }
        }
        for length in [0, 1, 15, 16, 17, 31, 32, 33, 64, 113, 1000, 65536 + 5] {
            for kind in [ShareCiphers.Kind.gcm, .ccm] {
                let key = bytes(16), nonce = bytes(kind.nonceLength), message = bytes(length), aad = bytes(32)
                let sealed = ShareCiphers.seal(kind, key: key, nonce: nonce, message, aad: aad)
                #expect(sealed == ShareCiphers.seal(kind, key: key, nonce: nonce, message, aad: aad, plain: true))
                #expect(ShareCiphers.open(kind, key: key, nonce: nonce, sealed, aad: aad) == message)
                #expect(ShareCiphers.open(kind, key: key, nonce: nonce, sealed, aad: aad, plain: true) == message)
                var changed = sealed
                changed.tag[0] ^= 1
                #expect(ShareCiphers.open(kind, key: key, nonce: nonce, changed, aad: aad) == nil)
                #expect(ShareCiphers.open(kind, key: key, nonce: nonce, changed, aad: aad, plain: true) == nil)
            }
        }
    }
}
