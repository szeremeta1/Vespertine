//
// Vespertine: signing in to an SMB server with a name and password (NTLMv2, carried in SPNEGO, as MS-NLMP and RFC 4178
// describe). The password itself never leaves the phone: the server sends a challenge and gets back a keyed digest.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

/// Little-endian bytes being put together.
struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u16(_ value: UInt16) { bytes += [UInt8(value & 0xff), UInt8(value >> 8)] }
    mutating func u32(_ value: UInt32) { for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(8 * i))) } }
    mutating func u64(_ value: UInt64) { for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(8 * i))) } }
    mutating func zeros(_ count: Int) { bytes += [UInt8](repeating: 0, count: count) }
    mutating func raw(_ more: [UInt8]) { bytes += more }
}

/// Little-endian bytes being taken apart. Every read is checked: a short or odd message throws rather than crashes.
struct ByteReader {
    let bytes: [UInt8]

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    func u8(_ at: Int) throws -> UInt8 {
        guard at >= 0, at < bytes.count else { throw SMBError.malformed }
        return bytes[at]
    }
    func u16(_ at: Int) throws -> UInt16 {
        guard at >= 0, at + 2 <= bytes.count else { throw SMBError.malformed }
        return UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }
    func u32(_ at: Int) throws -> UInt32 {
        guard at >= 0, at + 4 <= bytes.count else { throw SMBError.malformed }
        return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
    func u64(_ at: Int) throws -> UInt64 {
        try UInt64(u32(at)) | UInt64(u32(at + 4)) << 32
    }
    func slice(_ at: Int, _ count: Int) throws -> [UInt8] {
        guard at >= 0, count >= 0, at + count <= bytes.count else { throw SMBError.malformed }
        return Array(bytes[at..<(at + count)])
    }
}

extension String {
    /// As SMB and NTLM write text: UTF-16, low byte first, no terminator.
    var utf16LE: [UInt8] { utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] } }

    init(utf16LE bytes: [UInt8]) {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            units.append(UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
            i += 2
        }
        self = String(decoding: units, as: UTF16.self)
    }
}

enum NTLM {
    static let signature: [UInt8] = Array("NTLMSSP".utf8) + [0]

    // The few flags that matter here (MS-NLMP 2.2.2.5).
    static let unicode: UInt32 = 0x0000_0001
    static let requestTarget: UInt32 = 0x0000_0004
    static let sign: UInt32 = 0x0000_0010
    static let ntlm: UInt32 = 0x0000_0200
    static let alwaysSign: UInt32 = 0x0000_8000
    static let extendedSecurity: UInt32 = 0x0008_0000
    static let targetInfo: UInt32 = 0x0080_0000
    static let key128: UInt32 = 0x2000_0000
    /// The session's key is one this side makes up and sends wrapped in the key the password gives ("key exchange").
    static let keyExchange: UInt32 = 0x4000_0000
    static let key56: UInt32 = 0x8000_0000
    static let asked: UInt32 = unicode | requestTarget | sign | ntlm | alwaysSign | extendedSecurity | targetInfo | key128 | keyExchange | key56

    /// The first message: what this client can do.
    static func negotiate() -> [UInt8] {
        var w = ByteWriter()
        w.raw(signature)
        w.u32(1)
        w.u32(asked)
        w.zeros(16)   // no domain or workstation name is offered
        return w.bytes
    }

    struct Challenge {
        var flags: UInt32
        var serverChallenge: [UInt8]
        /// The server's attribute list, as sent (empty when it sent none).
        var targetInfo: [UInt8]
    }

    static func parseChallenge(_ message: [UInt8]) throws -> Challenge {
        let r = ByteReader(message)
        guard try r.slice(0, 8) == signature, try r.u32(8) == 2 else { throw SMBError.malformed }
        let flags = try r.u32(20)
        let challenge = try r.slice(24, 8)
        var info: [UInt8] = []
        if flags & targetInfo != 0, message.count >= 48 {
            info = try r.slice(Int(r.u32(44)), Int(r.u16(40)))
        }
        return Challenge(flags: flags, serverChallenge: challenge, targetInfo: info)
    }

    /// One attribute of the server's list (MS-NLMP 2.2.2.1).
    private static func attributes(_ info: [UInt8]) -> [(id: UInt16, value: [UInt8])] {
        var out: [(UInt16, [UInt8])] = []
        let r = ByteReader(info)
        var at = 0
        while let id = try? r.u16(at), let length = try? r.u16(at + 2), id != 0, let value = try? r.slice(at + 4, Int(length)) {
            out.append((id, value))
            at += 4 + Int(length)
        }
        return out
    }

    struct Answer {
        /// The third message.
        var message: [UInt8]
        /// The key the session's messages are signed with: the one made up here when the server takes a key exchange,
        /// otherwise the one the password and the challenge give.
        var sessionKey: [UInt8]
        /// With a key exchange NTLM's own signatures are scrambled as well, with this key (already cut to the strength
        /// agreed); nil without one.
        var sealingKey: [UInt8]?
        /// The message carries a digest of all three messages (the server sent its time, so it expects one). The SPNEGO
        /// wrapping then has to be signed as well: see `listSignature`.
        var carriesDigest: Bool

        /// NTLM's signature over the list of mechanisms offered (MS-NLMP 3.4.4.2, the first message signed from this
        /// side): what SPNEGO asks for once the NTLM messages are themselves protected by a digest. After a key
        /// exchange the digest in it goes through RC4 under the sealing key, which is how a server reads it then.
        func listSignature(_ list: [UInt8]) -> [UInt8] {
            let key = ShareDigests.md5(sessionKey + NTLM.magic("signing"))
            let sequence: [UInt8] = [0, 0, 0, 0]
            var digest = Array(ShareDigests.hmacMD5(key: key, sequence + list).prefix(8))
            if let sealingKey { digest = ShareDigests.rc4(key: sealingKey, digest) }
            return [1, 0, 0, 0] + digest + sequence
        }
    }

    /// The text a session key is hashed with for the client's signing or sealing key (MS-NLMP 3.4.5.2, 3.4.5.3).
    static func magic(_ purpose: String) -> [UInt8] {
        Array("session key to client-to-server \(purpose) key magic constant".utf8) + [0]
    }

    static let anonymous: UInt32 = 0x0000_0800

    /// The third message of someone signing in as nobody: no name, no proof of anything (MS-NLMP 3.1.5.1.2). A server
    /// that lets guests in without an account takes this.
    static func anonymous(challenge: [UInt8]) throws -> [UInt8] {
        let parsed = try parseChallenge(challenge)
        let header = 88
        var w = ByteWriter()
        w.raw(signature)
        w.u32(3)
        func put(_ count: Int, _ at: Int) { w.u16(UInt16(count)); w.u16(UInt16(count)); w.u32(UInt32(at)) }
        put(1, header)       // the LM answer: one zero byte
        put(0, header + 1)   // no NT answer
        put(0, header)       // no domain
        put(0, header)       // no user
        put(0, header + 1)   // no workstation
        put(0, header + 1)   // no session key
        w.u32(asked & ~keyExchange & (parsed.flags | unicode | ntlm) | anonymous)   // nobody has a key to exchange
        w.zeros(8)           // version
        w.zeros(16)          // no digest of the three messages: there is no key to make one with
        w.u8(0)
        return w.bytes
    }

    /// The third message: proof of the password, bound to the server's challenge.
    /// - Parameters:
    ///   - negotiate, challenge: the first two messages exactly as sent and received (the answer carries a digest of all three).
    ///   - clientChallenge: 8 random bytes.
    ///   - time: now, as a Windows file time; used only when the server didn't send its own.
    ///   - newKey: 16 random bytes: the session's key, when the server takes a key exchange.
    static func authenticate(user: String, domain: String, password: String, negotiate: [UInt8], challenge: [UInt8],
                             clientChallenge: [UInt8], time: UInt64, newKey: [UInt8]) throws -> Answer {
        let parsed = try parseChallenge(challenge)
        let hash = ShareDigests.md4(password.utf16LE)
        let key = ShareDigests.hmacMD5(key: hash, (user.uppercased() + domain).utf16LE)

        // The server's attributes go back to it, with its own time if it gave one and a note that a digest of the three
        // messages follows (which a server that sent its time expects).
        let pairs = attributes(parsed.targetInfo)
        let serverTime = pairs.first { $0.id == 7 && $0.value.count == 8 }?.value
        var info = ByteWriter()
        for pair in pairs where pair.id != 6 {
            info.u16(pair.id); info.u16(UInt16(pair.value.count)); info.raw(pair.value)
        }
        let withDigest = serverTime != nil
        if withDigest {
            let old = pairs.first { $0.id == 6 && $0.value.count == 4 }.map { (try? ByteReader($0.value).u32(0)) ?? 0 } ?? 0
            info.u16(6); info.u16(4); info.u32(old | 0x2)
        }
        info.u16(0); info.u16(0)

        var temp = ByteWriter()
        temp.u8(1); temp.u8(1); temp.zeros(6)
        if let serverTime { temp.raw(serverTime) } else { temp.u64(time) }
        temp.raw(clientChallenge)
        temp.zeros(4)
        temp.raw(info.bytes)
        temp.zeros(4)

        let proof = ShareDigests.hmacMD5(key: key, parsed.serverChallenge + temp.bytes)
        let ntResponse = proof + temp.bytes
        let baseKey = ShareDigests.hmacMD5(key: key, proof)
        // A server that offers a key exchange gets one: the session's key is made up here and sent under the key only
        // the password gives (MS-NLMP 3.1.5.1.2). Windows, Samba and a Mac all offer it, and every other client takes
        // it. A Mac goes further and reads the sign-in as if it had been taken whether it was or not, so a client that
        // leaves it out is refused there with the right password.
        let flags = asked & (parsed.flags | unicode | ntlm)
        let exchanges = flags & keyExchange != 0 && newKey.count == 16
        let sessionKey = exchanges ? newKey : baseKey
        let wrappedKey = exchanges ? ShareDigests.rc4(key: baseKey, newKey) : []
        // With the server's time in hand the older LM answer is left empty, as the protocol says.
        let lmResponse = serverTime != nil ? [UInt8](repeating: 0, count: 24)
            : ShareDigests.hmacMD5(key: key, parsed.serverChallenge + clientChallenge) + clientChallenge

        let domainBytes = domain.utf16LE, userBytes = user.utf16LE
        let header = 88
        var w = ByteWriter()
        w.raw(signature)
        w.u32(3)
        var offset = header
        // The payload order: domain, user, workstation (none), LM answer, NT answer, the wrapped session key (if any).
        let domainAt = offset; offset += domainBytes.count
        let userAt = offset; offset += userBytes.count
        let lmAt = offset; offset += lmResponse.count
        let ntAt = offset; offset += ntResponse.count
        let keyAt = offset; offset += wrappedKey.count
        func put(_ w: inout ByteWriter, _ count: Int, _ at: Int) { w.u16(UInt16(count)); w.u16(UInt16(count)); w.u32(UInt32(at)) }
        put(&w, lmResponse.count, lmAt)
        put(&w, ntResponse.count, ntAt)
        put(&w, domainBytes.count, domainAt)
        put(&w, userBytes.count, userAt)
        put(&w, 0, offset)   // workstation
        put(&w, wrappedKey.count, keyAt)
        w.u32(exchanges ? flags : flags & ~keyExchange)
        w.zeros(8)           // version
        let micAt = w.bytes.count
        w.zeros(16)          // the digest of the three messages, filled in below
        w.raw(domainBytes); w.raw(userBytes); w.raw(lmResponse); w.raw(ntResponse); w.raw(wrappedKey)

        var message = w.bytes
        if withDigest {
            let mic = ShareDigests.hmacMD5(key: sessionKey, negotiate + challenge + message)
            message.replaceSubrange(micAt..<(micAt + 16), with: mic)
        }
        // The sealing key is made from as much of the session's key as the strength agreed (MS-NLMP 3.4.5.3).
        let strength = flags & key128 != 0 ? 16 : flags & key56 != 0 ? 7 : 5
        let sealingKey = exchanges ? ShareDigests.md5(Array(sessionKey.prefix(strength)) + magic("sealing")) : nil
        return Answer(message: message, sessionKey: sessionKey, sealingKey: sealingKey, carriesDigest: withDigest)
    }
}

/// The SPNEGO wrapping around the NTLM messages (RFC 4178), in just enough DER to say "NTLM, and here is its message".
enum SPNEGO {
    private static let spnegoOID: [UInt8] = [0x06, 0x06, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x02]
    private static let ntlmOID: [UInt8] = [0x06, 0x0a, 0x2b, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x02, 0x0a]

    static func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var out = [tag]
        if content.count < 0x80 {
            out.append(UInt8(content.count))
        } else {
            var length: [UInt8] = []
            var n = content.count
            while n > 0 { length.insert(UInt8(n & 0xff), at: 0); n >>= 8 }
            out.append(0x80 | UInt8(length.count))
            out += length
        }
        return out + content
    }

    /// The opening token: NTLM is the only mechanism offered, with its first message.
    static func initial(_ ntlm: [UInt8]) -> [UInt8] {
        let mechanisms = der(0xa0, der(0x30, ntlmOID))
        let token = der(0xa2, der(0x04, ntlm))
        return der(0x60, spnegoOID + der(0xa0, der(0x30, mechanisms + token)))
    }

    /// A following token carrying an NTLM message, and the list digest when one is needed.
    static func response(_ ntlm: [UInt8], mechListMIC: [UInt8]? = nil) -> [UInt8] {
        var inner = der(0xa2, der(0x04, ntlm))
        if let mechListMIC { inner += der(0xa3, der(0x04, mechListMIC)) }
        return der(0xa1, der(0x30, inner))
    }

    /// The DER of the mechanism list this client offered: what a list digest is taken over.
    static var mechanismList: [UInt8] { der(0x30, ntlmOID) }

    /// One DER element at `at`: its tag, where its content starts and how long that is.
    private static func element(_ bytes: [UInt8], _ at: Int) -> (tag: UInt8, start: Int, length: Int)? {
        guard at + 2 <= bytes.count else { return nil }
        var length = Int(bytes[at + 1])
        var start = at + 2
        if length & 0x80 != 0 {
            let count = length & 0x7f
            guard count >= 1, count <= 4, start + count <= bytes.count else { return nil }
            length = 0
            for i in 0..<count { length = length << 8 | Int(bytes[start + i]) }
            start += count
        }
        guard start + length <= bytes.count else { return nil }
        return (bytes[at], start, length)
    }

    /// The mechanism's message inside a server's token; nil when it carries none. A server that answers with bare NTLM
    /// (no wrapping) is taken as it is.
    static func ntlmToken(in token: [UInt8]) -> [UInt8]? {
        if token.starts(with: NTLM.signature) { return token }
        guard var outer = element(token, 0) else { return nil }
        if outer.tag == 0x60 {
            // An initial token from the server: skip the OID, then the NegTokenInit.
            guard let oid = element(token, outer.start), let next = element(token, oid.start + oid.length) else { return nil }
            outer = next
        }
        guard outer.tag == 0xa1 || outer.tag == 0xa0, let sequence = element(token, outer.start), sequence.tag == 0x30 else { return nil }
        var at = sequence.start
        let end = sequence.start + sequence.length
        while at < end, let item = element(token, at) {
            if item.tag == 0xa2, let octets = element(token, item.start), octets.tag == 0x04 {
                return Array(token[octets.start..<(octets.start + octets.length)])
            }
            at = item.start + item.length
        }
        return nil
    }
}
