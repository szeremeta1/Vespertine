//
// Vespertine: the few digests and the one cipher signing in to an SMB server needs (MD4 and HMAC-MD5 for NTLMv2,
// HMAC-SHA-256 and AES-CMAC for signing messages, SHA-512 for SMB 3.1.1's digest of the messages that came before the
// sign-in). Written out in plain Swift so the SMB client is the same code on the
// phone and on Linux, where it is tested against a real server. None of this protects anything on its own: it is what
// the protocol asks for.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
#if canImport(CryptoKit) && canImport(CommonCrypto)
import CommonCrypto
import CryptoKit
#endif

enum ShareDigests {
    // MARK: MD4 (RFC 1320)

    static func md4(_ message: [UInt8]) -> [UInt8] {
        var a: UInt32 = 0x6745_2301, b: UInt32 = 0xefcd_ab89, c: UInt32 = 0x98ba_dcfe, d: UInt32 = 0x1032_5476
        let padded = padded(message, bigEndianLength: false)
        var x = [UInt32](repeating: 0, count: 16)
        for block in stride(from: 0, to: padded.count, by: 64) {
            for i in 0..<16 { x[i] = littleEndian32(padded, block + i * 4) }
            let aa = a, bb = b, cc = c, dd = d
            func f(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (~x & z) }
            func g(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (x & z) | (y & z) }
            func h(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x ^ y ^ z }
            for i in stride(from: 0, to: 16, by: 4) {
                a = rotl(a &+ f(b, c, d) &+ x[i], 3)
                d = rotl(d &+ f(a, b, c) &+ x[i + 1], 7)
                c = rotl(c &+ f(d, a, b) &+ x[i + 2], 11)
                b = rotl(b &+ f(c, d, a) &+ x[i + 3], 19)
            }
            for i in 0..<4 {
                a = rotl(a &+ g(b, c, d) &+ x[i] &+ 0x5a82_7999, 3)
                d = rotl(d &+ g(a, b, c) &+ x[i + 4] &+ 0x5a82_7999, 5)
                c = rotl(c &+ g(d, a, b) &+ x[i + 8] &+ 0x5a82_7999, 9)
                b = rotl(b &+ g(c, d, a) &+ x[i + 12] &+ 0x5a82_7999, 13)
            }
            for i in [0, 2, 1, 3] {
                a = rotl(a &+ h(b, c, d) &+ x[i] &+ 0x6ed9_eba1, 3)
                d = rotl(d &+ h(a, b, c) &+ x[i + 8] &+ 0x6ed9_eba1, 9)
                c = rotl(c &+ h(d, a, b) &+ x[i + 4] &+ 0x6ed9_eba1, 11)
                b = rotl(b &+ h(c, d, a) &+ x[i + 12] &+ 0x6ed9_eba1, 15)
            }
            a = a &+ aa; b = b &+ bb; c = c &+ cc; d = d &+ dd
        }
        return [a, b, c, d].flatMap(littleEndianBytes)
    }

    // MARK: MD5 (RFC 1321)

    private static let md5Shifts: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                                              5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                                              4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                                              6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
    private static let md5Sines: [UInt32] = (0..<64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4_294_967_296.0)) }

    static func md5(_ message: [UInt8]) -> [UInt8] {
        var a0: UInt32 = 0x6745_2301, b0: UInt32 = 0xefcd_ab89, c0: UInt32 = 0x98ba_dcfe, d0: UInt32 = 0x1032_5476
        let padded = padded(message, bigEndianLength: false)
        var m = [UInt32](repeating: 0, count: 16)
        for block in stride(from: 0, to: padded.count, by: 64) {
            for i in 0..<16 { m[i] = littleEndian32(padded, block + i * 4) }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32
                var g: Int
                switch i {
                case 0..<16: f = (b & c) | (~b & d); g = i
                case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (b | ~d); g = (7 * i) % 16
                }
                f = f &+ a &+ md5Sines[i] &+ m[g]
                a = d; d = c; c = b
                b = b &+ rotl(f, md5Shifts[i])
            }
            a0 = a0 &+ a; b0 = b0 &+ b; c0 = c0 &+ c; d0 = d0 &+ d
        }
        return [a0, b0, c0, d0].flatMap(littleEndianBytes)
    }

    // MARK: SHA-256 (FIPS 180-4)

    private static let sha256Constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func sha256(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        let padded = padded(message, bigEndianLength: true)
        var w = [UInt32](repeating: 0, count: 64)
        padded.withUnsafeBufferPointer { bytes in
            for block in stride(from: 0, to: bytes.count, by: 64) {
                for i in 0..<16 {
                    let at = block + i * 4
                    w[i] = UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
                }
                for i in 16..<64 {
                    let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                    let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                    w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
                }
                var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
                for i in 0..<64 {
                    let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                    let ch = (e & f) ^ (~e & g)
                    let t1 = hh &+ s1 &+ ch &+ sha256Constants[i] &+ w[i]
                    let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                    let maj = (a & b) ^ (a & c) ^ (b & c)
                    let t2 = s0 &+ maj
                    hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
                }
                h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
                h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
            }
        }
        return h.flatMap { [UInt8($0 >> 24), UInt8($0 >> 16 & 0xff), UInt8($0 >> 8 & 0xff), UInt8($0 & 0xff)] }
    }

    // MARK: SHA-512 (FIPS 180-4)

    private static let sha512Constants: [UInt64] = [
        0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc,
        0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118,
        0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
        0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694,
        0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
        0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
        0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4,
        0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70,
        0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
        0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
        0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30,
        0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
        0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8,
        0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3,
        0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
        0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b,
        0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178,
        0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
        0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c,
        0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
    ]

    /// Only ever run over the handful of short messages that open a connection, so the one written here is all there is.
    static func sha512(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt64] = [0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
                           0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179]
        // The `1` bit, zeros, and the length in bits as 128 bits, high byte first, to a whole number of 128-byte blocks.
        var padded = message
        padded.append(0x80)
        padded += [UInt8](repeating: 0, count: (239 - message.count % 128) % 128)
        let bits = UInt64(message.count) &* 8
        padded += [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { padded.append(UInt8(truncatingIfNeeded: bits >> UInt64(56 - 8 * i))) }
        var w = [UInt64](repeating: 0, count: 80)
        func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 { x >> n | x << (64 - n) }
        for block in stride(from: 0, to: padded.count, by: 128) {
            for i in 0..<16 {
                var word: UInt64 = 0
                for j in 0..<8 { word = word << 8 | UInt64(padded[block + i * 8 + j]) }
                w[i] = word
            }
            for i in 16..<80 {
                let s0 = rotr(w[i - 15], 1) ^ rotr(w[i - 15], 8) ^ (w[i - 15] >> 7)
                let s1 = rotr(w[i - 2], 19) ^ rotr(w[i - 2], 61) ^ (w[i - 2] >> 6)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<80 {
                let s1 = rotr(e, 14) ^ rotr(e, 18) ^ rotr(e, 41)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ sha512Constants[i] &+ w[i]
                let s0 = rotr(a, 28) ^ rotr(a, 34) ^ rotr(a, 39)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { word in (0..<8).map { UInt8(truncatingIfNeeded: word >> UInt64(56 - 8 * $0)) } }
    }

    // MARK: HMAC (RFC 2104)

    static func hmac(_ hash: ([UInt8]) -> [UInt8], key: [UInt8], _ message: [UInt8]) -> [UInt8] {
        var key = key.count > 64 ? hash(key) : key
        key += [UInt8](repeating: 0, count: 64 - key.count)
        return hash(key.map { $0 ^ 0x5c } + hash(key.map { $0 ^ 0x36 } + message))
    }

    static func hmacMD5(key: [UInt8], _ message: [UInt8]) -> [UInt8] { hmac(md5, key: key, message) }
    /// Every message of an SMB 2 session is signed with this, a megabyte at a time while a song plays: on Apple's
    /// systems the system's own (much faster) one does it. `plain` asks for the one written here, for comparing the two.
    static func hmacSHA256(key: [UInt8], _ message: [UInt8], plain: Bool = false) -> [UInt8] {
        #if canImport(CryptoKit) && canImport(CommonCrypto)
        if !plain { return Array(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))) }
        #endif
        return hmac(sha256, key: key, message)
    }

    // MARK: AES-128 and CMAC (FIPS 197, RFC 4493)

    private static let sbox: [UInt8] = {
        // Built from its definition (the inverse in GF(2^8), then the affine map) rather than typed out.
        var box = [UInt8](repeating: 0, count: 256)
        var p: UInt8 = 1, q: UInt8 = 1
        repeat {
            p = p ^ (p << 1) ^ (p & 0x80 != 0 ? 0x1b : 0)
            q ^= q << 1; q ^= q << 2; q ^= q << 4
            if q & 0x80 != 0 { q ^= 0x09 }
            let x = q ^ rotl8(q, 1) ^ rotl8(q, 2) ^ rotl8(q, 3) ^ rotl8(q, 4)
            box[Int(p)] = x ^ 0x63
        } while p != 1
        box[0] = 0x63
        return box
    }()

    /// The key schedule for a 16-byte key: 11 round keys of 16 bytes.
    struct AESKey {
        fileprivate var rounds: [UInt8]

        init(_ key: [UInt8]) {
            precondition(key.count == 16)
            var w = key
            var rcon: UInt8 = 1
            for i in stride(from: 16, to: 176, by: 4) {
                var t = Array(w[(i - 4)..<i])
                if i % 16 == 0 {
                    t = [sbox[Int(t[1])] ^ rcon, sbox[Int(t[2])], sbox[Int(t[3])], sbox[Int(t[0])]]
                    rcon = rcon << 1 ^ (rcon & 0x80 != 0 ? 0x1b : 0)
                }
                for j in 0..<4 { w.append(w[i - 16 + j] ^ t[j]) }
            }
            rounds = w
        }
    }

    /// Encrypts the 16 bytes at `state` in place.
    private static func encrypt(_ state: UnsafeMutablePointer<UInt8>, _ key: UnsafePointer<UInt8>, _ box: UnsafePointer<UInt8>) {
        for i in 0..<16 { state[i] ^= key[i] }
        var t = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                 UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        withUnsafeMutableBytes(of: &t) { raw in
            let s = raw.bindMemory(to: UInt8.self).baseAddress!
            for round in 1...10 {
                // SubBytes and ShiftRows together: column c, row r comes from column (c + r) mod 4.
                for c in 0..<4 {
                    for r in 0..<4 { s[c * 4 + r] = box[Int(state[((c + r) & 3) * 4 + r])] }
                }
                let k = key + round * 16
                if round < 10 {
                    for c in 0..<4 {
                        let a0 = s[c * 4], a1 = s[c * 4 + 1], a2 = s[c * 4 + 2], a3 = s[c * 4 + 3]
                        let all = a0 ^ a1 ^ a2 ^ a3
                        state[c * 4] = a0 ^ all ^ xtime(a0 ^ a1) ^ k[c * 4]
                        state[c * 4 + 1] = a1 ^ all ^ xtime(a1 ^ a2) ^ k[c * 4 + 1]
                        state[c * 4 + 2] = a2 ^ all ^ xtime(a2 ^ a3) ^ k[c * 4 + 2]
                        state[c * 4 + 3] = a3 ^ all ^ xtime(a3 ^ a0) ^ k[c * 4 + 3]
                    }
                } else {
                    for i in 0..<16 { state[i] = s[i] ^ k[i] }
                }
            }
        }
    }

    @inline(__always) private static func xtime(_ x: UInt8) -> UInt8 { x << 1 ^ (x & 0x80 != 0 ? 0x1b : 0) }

    /// Hands `body` a function that encrypts 16 bytes in place with `key`: for the modes built on the cipher (CTR, CBC-MAC),
    /// which call it once per block.
    static func withAES<T>(_ key: AESKey, _ body: ((UnsafeMutablePointer<UInt8>) -> Void) throws -> T) rethrows -> T {
        try key.rounds.withUnsafeBufferPointer { k in
            try sbox.withUnsafeBufferPointer { box in
                try body { state in encrypt(state, k.baseAddress!, box.baseAddress!) }
            }
        }
    }

    static func aesEncrypt(block: [UInt8], key: AESKey) -> [UInt8] {
        precondition(block.count == 16)
        var out = block
        out.withUnsafeMutableBufferPointer { state in
            key.rounds.withUnsafeBufferPointer { k in
                sbox.withUnsafeBufferPointer { box in encrypt(state.baseAddress!, k.baseAddress!, box.baseAddress!) }
            }
        }
        return out
    }

    /// `plain`: as for `hmacSHA256`. SMB 3 signs every message with this.
    static func aesCMAC(key: [UInt8], _ message: [UInt8], plain: Bool = false) -> [UInt8] {
        let schedule = AESKey(key)
        func doubled(_ block: [UInt8]) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 { out[i] = block[i] << 1 | (i < 15 ? block[i + 1] >> 7 : 0) }
            if block[0] & 0x80 != 0 { out[15] ^= 0x87 }
            return out
        }
        let k1 = doubled(aesEncrypt(block: [UInt8](repeating: 0, count: 16), key: schedule))
        let whole = !message.isEmpty && message.count % 16 == 0
        let blocks = max(1, (message.count + 15) / 16)
        var last = [UInt8](repeating: 0, count: 16)
        let tail = (blocks - 1) * 16
        for i in tail..<message.count { last[i - tail] = message[i] }
        if !whole { last[message.count - tail] = 0x80 }
        let subkey = whole ? k1 : doubled(k1)
        for i in 0..<16 { last[i] ^= subkey[i] }

        #if canImport(CryptoKit) && canImport(CommonCrypto)
        // A CMAC is the last block of the message encrypted in CBC mode, its final block adjusted as above.
        if !plain {
            var chained = [UInt8](repeating: 0, count: blocks * 16)
            var moved = 0
            let lead = Array(message.prefix(tail)) + last
            let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0, key, key.count, [UInt8](repeating: 0, count: 16),
                                 lead, lead.count, &chained, chained.count, &moved)
            if status == kCCSuccess, moved == chained.count { return Array(chained.suffix(16)) }
        }
        #endif

        var x = [UInt8](repeating: 0, count: 16)
        x.withUnsafeMutableBufferPointer { state in
            message.withUnsafeBufferPointer { m in
                schedule.rounds.withUnsafeBufferPointer { k in
                    sbox.withUnsafeBufferPointer { box in
                        for block in 0..<(blocks - 1) {
                            for i in 0..<16 { state[i] ^= m[block * 16 + i] }
                            encrypt(state.baseAddress!, k.baseAddress!, box.baseAddress!)
                        }
                        for i in 0..<16 { state[i] ^= last[i] }
                        encrypt(state.baseAddress!, k.baseAddress!, box.baseAddress!)
                    }
                }
            }
        }
        return x
    }

    // MARK: Pieces

    /// The message with its `1` bit, zeros and 64-bit length, as MD4, MD5 and SHA-256 all want it.
    private static func padded(_ message: [UInt8], bigEndianLength: Bool) -> [UInt8] {
        var out = message
        out.append(0x80)
        out += [UInt8](repeating: 0, count: (119 - message.count % 64) % 64)
        let bits = UInt64(message.count) &* 8
        for i in 0..<8 { out.append(UInt8(truncatingIfNeeded: bits >> UInt64(bigEndianLength ? 56 - 8 * i : 8 * i))) }
        return out
    }

    @inline(__always) private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { x << n | x >> (32 - n) }
    @inline(__always) private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { x >> n | x << (32 - n) }
    @inline(__always) private static func rotl8(_ x: UInt8, _ n: UInt8) -> UInt8 { x << n | x >> (8 - n) }
    private static func littleEndian32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
    private static func littleEndianBytes(_ x: UInt32) -> [UInt8] { [UInt8(x & 0xff), UInt8(x >> 8 & 0xff), UInt8(x >> 16 & 0xff), UInt8(x >> 24)] }
}
