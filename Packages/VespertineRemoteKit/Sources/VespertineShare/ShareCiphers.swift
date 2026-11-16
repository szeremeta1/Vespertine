//
// Vespertine: the two ways SMB 3 encrypts its messages, AES-128-GCM (SP 800-38D) and AES-128-CCM (RFC 3610,
// SP 800-38C). Each turns a message into as many unreadable bytes plus a tag that proves nothing was changed on the way,
// and back. Written out in plain Swift, like the digests, so the client is the same code on the phone and on Linux; on
// Apple's systems the system's own (much faster) AES does the work, since a song is read through this a megabyte at a time.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
#if canImport(CryptoKit) && canImport(CommonCrypto)
import CommonCrypto
import CryptoKit
#endif

enum ShareCiphers {
    /// The ciphers by the numbers SMB gives them (MS-SMB2 2.2.3.1.2).
    enum Kind: UInt16, Sendable {
        case ccm = 1
        case gcm = 2

        /// How much of the 16-byte nonce field of an encrypted message this cipher uses.
        var nonceLength: Int { self == .gcm ? 12 : 11 }
    }

    struct Sealed: Equatable {
        var ciphertext: [UInt8]
        var tag: [UInt8]
    }

    /// Encrypts `message` with a 16-byte key. `aad` is covered by the tag but sent as it is. `plain`: as for the digests.
    static func seal(_ kind: Kind, key: [UInt8], nonce: [UInt8], _ message: [UInt8], aad: [UInt8], plain: Bool = false) -> Sealed {
        switch kind {
        case .gcm: gcmSeal(key: key, nonce: nonce, message, aad: aad, plain: plain)
        case .ccm: ccm(key: key, nonce: nonce, message, aad: aad, tagLength: 16, opening: false, plain: plain)
        }
    }

    /// The message back, or nil when the tag doesn't fit: something was changed on the way, or it was made with another key.
    static func open(_ kind: Kind, key: [UInt8], nonce: [UInt8], _ sealed: Sealed, aad: [UInt8], plain: Bool = false) -> [UInt8]? {
        switch kind {
        case .gcm:
            return gcmOpen(key: key, nonce: nonce, sealed, aad: aad, plain: plain)
        case .ccm:
            let opened = ccm(key: key, nonce: nonce, sealed.ciphertext, aad: aad, tagLength: sealed.tag.count, opening: true, plain: plain)
            return same(opened.tag, sealed.tag) ? opened.ciphertext : nil
        }
    }

    /// Compares two tags without stopping at the first byte that differs.
    private static func same(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<a.count { difference |= a[i] ^ b[i] }
        return difference == 0
    }

    // MARK: Counter mode, shared by both

    /// XORs `bytes` with the cipher's output for `counter`, `counter + 1`, …: the last `width` bytes of the block count
    /// up, high byte first.
    private static func counterMode(_ bytes: inout [UInt8], key: ShareDigests.AESKey, counter: [UInt8], width: Int) {
        var block = counter
        var stream = [UInt8](repeating: 0, count: 16)
        let count = bytes.count
        ShareDigests.withAES(key) { encrypt in
            bytes.withUnsafeMutableBufferPointer { out in
                stream.withUnsafeMutableBufferPointer { s in
                    var at = 0
                    while at < count {
                        for i in 0..<16 { s[i] = block[i] }
                        encrypt(s.baseAddress!)
                        let n = min(16, count - at)
                        for i in 0..<n { out[at + i] ^= s[i] }
                        at += n
                        var i = 15
                        while i >= 16 - width {
                            block[i] &+= 1
                            if block[i] != 0 { break }
                            i -= 1
                        }
                    }
                }
            }
        }
    }

    // MARK: GCM

    /// A 128-bit value as GCM writes it: the first byte is the high end of `high`.
    private struct Field {
        var high: UInt64 = 0
        var low: UInt64 = 0
    }

    /// What falls off the low end when a value is moved down a byte, folded back in at the top (the field's modulus).
    private static let folded: [UInt64] = (0..<256).map { byte in
        var high: UInt64 = 0, low = UInt64(byte)
        for _ in 0..<8 {
            let carry = low & 1
            low = low >> 1 | high << 63
            high >>= 1
            if carry != 0 { high ^= 0xe1 << 56 }
        }
        return high
    }

    /// GCM's keyed digest of `aad` and `ciphertext`, each padded to whole blocks, and their lengths.
    private static func ghash(hashKey: [UInt8], aad: [UInt8], ciphertext: [UInt8]) -> [UInt8] {
        // The key times every possible byte, so a block is sixteen look-ups instead of 128 shifts.
        var table = [Field](repeating: Field(), count: 256)
        var value = Field()
        for i in 0..<8 { value.high = value.high << 8 | UInt64(hashKey[i]); value.low = value.low << 8 | UInt64(hashKey[8 + i]) }
        table[0x80] = value
        var bit = 0x40
        while bit > 0 {
            let carry = value.low & 1
            value.low = value.low >> 1 | value.high << 63
            value.high >>= 1
            if carry != 0 { value.high ^= 0xe1 << 56 }
            table[bit] = value
            bit >>= 1
        }
        var step = 2
        while step < 256 {
            for j in 1..<step { table[step + j] = Field(high: table[step].high ^ table[j].high, low: table[step].low ^ table[j].low) }
            step <<= 1
        }

        var y = Field()
        var block = [UInt8](repeating: 0, count: 16)
        func absorb(_ block: UnsafeBufferPointer<UInt8>) {
            // Byte `i` of the block XORed into the digest so far.
            let before = y
            func x(_ i: Int) -> Int {
                Int(block[i] ^ UInt8(truncatingIfNeeded: (i < 8 ? before.high : before.low) >> UInt64(56 - 8 * (i & 7))))
            }
            var z = table[x(15)]
            for i in stride(from: 14, through: 0, by: -1) {
                let dropped = Int(z.low & 0xff)
                z.low = z.low >> 8 | z.high << 56
                z.high = z.high >> 8 ^ folded[dropped]
                let entry = table[x(i)]
                z.high ^= entry.high
                z.low ^= entry.low
            }
            y = z
        }
        func absorbAll(_ bytes: [UInt8]) {
            bytes.withUnsafeBufferPointer { all in
                var at = 0
                while at + 16 <= all.count {
                    absorb(UnsafeBufferPointer(rebasing: all[at..<(at + 16)]))
                    at += 16
                }
                if at < all.count {
                    for i in 0..<16 { block[i] = at + i < all.count ? all[at + i] : 0 }
                    block.withUnsafeBufferPointer(absorb)
                }
            }
        }
        absorbAll(aad)
        absorbAll(ciphertext)
        let aadBits = UInt64(aad.count) * 8, textBits = UInt64(ciphertext.count) * 8
        for i in 0..<8 {
            block[i] = UInt8(truncatingIfNeeded: aadBits >> UInt64(56 - 8 * i))
            block[8 + i] = UInt8(truncatingIfNeeded: textBits >> UInt64(56 - 8 * i))
        }
        block.withUnsafeBufferPointer(absorb)
        var out = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            out[i] = UInt8(truncatingIfNeeded: y.high >> UInt64(56 - 8 * i))
            out[8 + i] = UInt8(truncatingIfNeeded: y.low >> UInt64(56 - 8 * i))
        }
        return out
    }

    private static func gcmTag(key: ShareDigests.AESKey, nonce: [UInt8], aad: [UInt8], ciphertext: [UInt8]) -> [UInt8] {
        let hashKey = ShareDigests.aesEncrypt(block: [UInt8](repeating: 0, count: 16), key: key)
        let digest = ghash(hashKey: hashKey, aad: aad, ciphertext: ciphertext)
        let mask = ShareDigests.aesEncrypt(block: nonce + [0, 0, 0, 1], key: key)
        return (0..<16).map { digest[$0] ^ mask[$0] }
    }

    private static func gcmSeal(key: [UInt8], nonce: [UInt8], _ message: [UInt8], aad: [UInt8], plain: Bool) -> Sealed {
        precondition(nonce.count == 12)
        #if canImport(CryptoKit) && canImport(CommonCrypto)
        if !plain, let nonce = try? AES.GCM.Nonce(data: nonce),
           let box = try? AES.GCM.seal(message, using: SymmetricKey(data: key), nonce: nonce, authenticating: aad) {
            return Sealed(ciphertext: Array(box.ciphertext), tag: Array(box.tag))
        }
        #endif
        let schedule = ShareDigests.AESKey(key)
        var out = message
        counterMode(&out, key: schedule, counter: nonce + [0, 0, 0, 2], width: 4)
        return Sealed(ciphertext: out, tag: gcmTag(key: schedule, nonce: nonce, aad: aad, ciphertext: out))
    }

    private static func gcmOpen(key: [UInt8], nonce: [UInt8], _ sealed: Sealed, aad: [UInt8], plain: Bool) -> [UInt8]? {
        guard nonce.count == 12, sealed.tag.count == 16 else { return nil }
        #if canImport(CryptoKit) && canImport(CommonCrypto)
        if !plain {
            guard let nonce = try? AES.GCM.Nonce(data: nonce),
                  let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: sealed.ciphertext, tag: sealed.tag),
                  let opened = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad) else { return nil }
            return Array(opened)
        }
        #endif
        let schedule = ShareDigests.AESKey(key)
        guard same(gcmTag(key: schedule, nonce: nonce, aad: aad, ciphertext: sealed.ciphertext), sealed.tag) else { return nil }
        var out = sealed.ciphertext
        counterMode(&out, key: schedule, counter: nonce + [0, 0, 0, 2], width: 4)
        return out
    }

    // MARK: CCM

    /// Both directions of CCM: counter mode over `input`, and the tag, which is taken over the message as it reads before
    /// encryption (so when `opening`, over the output). A nonce of 7 to 13 bytes and a tag of 4 to 16 are what the
    /// standard allows; SMB uses 11 and 16.
    static func ccm(key: [UInt8], nonce: [UInt8], _ input: [UInt8], aad: [UInt8], tagLength: Int, opening: Bool, plain: Bool = false) -> Sealed {
        precondition((7...13).contains(nonce.count) && (4...16).contains(tagLength) && tagLength % 2 == 0 && aad.count < 0xff00)
        let schedule = ShareDigests.AESKey(key)
        let lengthBytes = 15 - nonce.count
        var first = [UInt8(lengthBytes - 1)] + nonce + [UInt8](repeating: 0, count: lengthBytes)
        let mask = ShareDigests.aesEncrypt(block: first, key: schedule)
        first[15] = 1

        var output = input
        var done = false
        #if canImport(CryptoKit) && canImport(CommonCrypto)
        if !plain, !output.isEmpty {
            var cryptor: CCCryptorRef?
            if CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding), first,
                                       key, key.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor) == kCCSuccess, let cryptor {
                var moved = 0
                let count = output.count
                let status = output.withUnsafeMutableBytes { CCCryptorUpdate(cryptor, input, count, $0.baseAddress, count, &moved) }
                CCCryptorRelease(cryptor)
                if status == kCCSuccess, moved == count { done = true } else { output = input }
            }
        }
        #endif
        if !done { counterMode(&output, key: schedule, counter: first, width: lengthBytes) }

        // The tag: a CBC-MAC over a first block that says what follows, the extra data with its length, then the message.
        let message = opening ? output : input
        var blocks: [UInt8] = []
        blocks.reserveCapacity(48 + aad.count + message.count)
        blocks.append((aad.isEmpty ? 0 : 0x40) | UInt8((tagLength - 2) / 2) << 3 | UInt8(lengthBytes - 1))
        blocks += nonce
        for i in 0..<lengthBytes { blocks.append(UInt8(truncatingIfNeeded: message.count >> (8 * (lengthBytes - 1 - i)))) }
        if !aad.isEmpty {
            blocks += [UInt8(aad.count >> 8), UInt8(aad.count & 0xff)] + aad
            blocks += [UInt8](repeating: 0, count: (16 - blocks.count % 16) % 16)
        }
        blocks += message
        blocks += [UInt8](repeating: 0, count: (16 - blocks.count % 16) % 16)

        var mac = [UInt8](repeating: 0, count: 16)
        done = false
        #if canImport(CryptoKit) && canImport(CommonCrypto)
        if !plain {
            // The MAC is the last block of all that encrypted in CBC mode.
            var chained = [UInt8](repeating: 0, count: blocks.count)
            var moved = 0
            let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0, key, key.count, [UInt8](repeating: 0, count: 16),
                                 blocks, blocks.count, &chained, chained.count, &moved)
            if status == kCCSuccess, moved == chained.count {
                mac = Array(chained.suffix(16))
                done = true
            }
        }
        #endif
        if !done {
            ShareDigests.withAES(schedule) { encrypt in
                mac.withUnsafeMutableBufferPointer { state in
                    blocks.withUnsafeBufferPointer { all in
                        for block in stride(from: 0, to: all.count, by: 16) {
                            for i in 0..<16 { state[i] ^= all[block + i] }
                            encrypt(state.baseAddress!)
                        }
                    }
                }
            }
        }
        return Sealed(ciphertext: output, tag: (0..<tagLength).map { mac[$0] ^ mask[$0] })
    }
}
