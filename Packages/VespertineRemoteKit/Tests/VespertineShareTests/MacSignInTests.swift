//
// Vespertine: signing in to a Mac's File Sharing. A Mac reads an NTLM sign-in differently from Samba in one way that
// matters: its challenge always offers a key exchange, and it then checks the signature on the list of mechanisms as
// if the exchange had been taken, whatever the client answered. A client that left the exchange out was refused with
// the right password (found against macOS 27; Samba took the same sign-in).
//
// `MacSignIn` below is the Mac's side written out from Apple's published source (the Heimdal project on
// github.com/apple-oss-distributions: lib/gssapi/ntlm/accept_sec_context.c and crypto.c, kdc/digest-service.c,
// lib/ntlm/ntlm.c, lib/gssapi/spnego/accept_sec_context.c): the challenge it builds, and each check it makes on the
// answer, in its order. The names and the account are made up.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineShare

/// The checks a Mac makes on an NTLM sign-in, in the order it makes them.
struct MacSignIn {
    enum Refusal: Error, Equatable {
        case malformed, password, clock, names, wrappedKey, digestMissing, digest, listSignature
    }

    var user = "listener"
    var password = "Tr0ub4dor&3 é"
    /// The Mac's name: what it calls itself and its accounts' domain.
    var name = "STUDIO"
    var host = "studio.local"
    var challenge: [UInt8] = unhex("1f2e3d4c5b6a7988")
    /// The Mac's clock, as a Windows file time.
    var now: UInt64 = 0x01DC_5731_0000_0000

    // What its challenge always says (build_type2_packet): among the rest, signing, sealing and a key exchange,
    // whether the client asked for them or not.
    static let offered: UInt32 = 0x0000_0001 | 0x0000_0200 | 0x0000_0004 | 0x0200_0000 | 0x0001_0000 | 0x2000_0000
        | 0x0080_0000 | 0x0000_0010 | 0x0000_0020 | 0x0000_8000 | 0x0008_0000 | 0x4000_0000

    private func pair(_ id: UInt16, _ text: String) -> [UInt8] {
        var w = ByteWriter()
        w.u16(id); w.u16(UInt16(text.utf16.count * 2)); w.raw(text.utf16LE)
        return w.bytes
    }

    /// The attributes it sends: its name, its domain, its host name, that name's domain, and the time.
    var attributes: [UInt8] {
        var w = ByteWriter()
        w.raw(pair(1, name)); w.raw(pair(2, name)); w.raw(pair(3, host)); w.raw(pair(4, "local"))
        w.u16(7); w.u16(8); w.u64(now)
        w.u16(0); w.u16(0)
        return w.bytes
    }

    /// Its answer to a client's first message (heim_ntlm_encode_type2). A first message that isn't in Unicode gets none.
    func challengeMessage(to first: [UInt8]) throws -> [UInt8] {
        let r = ByteReader(first)
        guard try r.slice(0, 8) == NTLM.signature, try r.u32(8) == 1, try r.u32(12) & 0x1 != 0 else { throw Refusal.malformed }
        let target = name.utf16LE, info = attributes
        var w = ByteWriter()
        w.raw(NTLM.signature)
        w.u32(2)
        w.u16(UInt16(target.count)); w.u16(UInt16(target.count)); w.u32(56)
        w.u32(Self.offered)
        w.raw(challenge)
        w.zeros(8)
        w.u16(UInt16(info.count)); w.u16(UInt16(info.count)); w.u32(UInt32(56 + target.count))
        w.raw([0x06, 0x01, 0xb0, 0x1d, 0x00, 0x00, 0x00, 0x0f])   // the version it gives
        w.raw(target)
        w.raw(info)
        return w.bytes
    }

    private func seconds(_ fileTime: UInt64) -> Int64 { Int64(fileTime / 10_000_000) }

    /// Only ASCII letters are raised, as the Mac does it (ascii2ucs2le).
    private func raised(_ text: String) -> String {
        String(text.map { $0.isASCII ? Character($0.uppercased()) : $0 })
    }

    /// Takes the client's last message and the signature it sent over the list of mechanisms (nil when it sent none);
    /// gives back the session's key, or says which check refused it.
    func accept(first: [UInt8], second: [UInt8], third: [UInt8], listSignature: [UInt8]?, list: [UInt8]) throws -> [UInt8] {
        // heim_ntlm_decode_type3: the fields, and whether there is room in front of them for a digest of the messages.
        let r = ByteReader(third)
        guard (try? r.slice(0, 8)) == NTLM.signature, (try? r.u32(8)) == 3 else { throw Refusal.malformed }
        func field(_ at: Int) throws -> (length: Int, allocated: Int, offset: Int) {
            do { return (Int(try r.u16(at)), Int(try r.u16(at + 2)), Int(try r.u32(at + 4))) } catch { throw Refusal.malformed }
        }
        func bytes(_ f: (length: Int, allocated: Int, offset: Int)) throws -> [UInt8] {
            do { return try r.slice(f.offset, f.length) } catch { throw Refusal.malformed }
        }
        let lm = try field(12), nt = try field(20), domainField = try field(28), userField = try field(36), station = try field(44)
        var first52 = min(domainField.offset, userField.offset)
        for f in [lm, nt, station] where f.allocated != 0 { first52 = min(first52, f.offset) }
        guard first52 >= 52 else { throw Refusal.malformed }
        let keyField = try field(52)
        first52 = min(first52, keyField.offset)
        let flags = (try? r.u32(60)) ?? 0
        let digestAt = first52 >= 88 ? 72 : 0
        let answer = try bytes(nt), sentDomain = String(utf16LE: try bytes(domainField)), sentUser = String(utf16LE: try bytes(userField))
        let wrapped = keyField.offset != 0 ? try bytes(keyField) : []

        // kdc_authenticate: the account, then heim_ntlm_verify_ntlm2 with the domain as sent, raised, and empty.
        guard sentUser == user, answer.count > 16 + 28 else { throw Refusal.password }
        let blob = Array(answer[16...])
        let b = ByteReader(blob)
        guard (try? b.u32(0)) == 0x0000_0101, (try? b.u32(4)) == 0 else { throw Refusal.malformed }
        guard abs(seconds((try? b.u64(8)) ?? 0) - seconds(now)) <= 2 * 3600 else { throw Refusal.clock }
        let hash = ShareDigests.md4(password.utf16LE)
        var passwordKey: [UInt8]?
        for domain in [sentDomain, raised(sentDomain), ""] {
            let key = ShareDigests.hmacMD5(key: hash, (raised(sentUser) + domain).utf16LE)
            if ShareDigests.hmacMD5(key: key, challenge + blob) == Array(answer.prefix(16)) { passwordKey = key; break }
        }
        guard let passwordKey else { throw Refusal.password }
        var sessionKey = ShareDigests.hmacMD5(key: passwordKey, Array(answer.prefix(16)))

        // validate_targetinfo: the attributes that came back must carry the Mac's own name, domain and a time near its own.
        var back: [UInt16: [UInt8]] = [:]
        var at = 28
        while let id = try? b.u16(at), let length = try? b.u16(at + 2), id != 0, let value = try? b.slice(at + 4, Int(length)) {
            back[id] = value
            at += 4 + Int(length)
        }
        guard !back.isEmpty else { throw Refusal.names }
        if let time = back[7], time.count == 8, let stamp = try? ByteReader(time).u64(0) {
            guard abs(seconds(stamp) - seconds(now)) <= 300 else { throw Refusal.clock }
        }
        guard back[1] == name.utf16LE, back[2] == name.utf16LE else { throw Refusal.names }
        let marks = back[6].flatMap { try? ByteReader($0).u32(0) } ?? 0

        // The key exchange, only if the client's last message says it made one.
        if flags & 0x4000_0000 != 0 {
            guard wrapped.count == 16 else { throw Refusal.wrappedKey }
            sessionKey = ShareDigests.rc4(key: sessionKey, wrapped)
        }

        // _gss_ntlm_accept_sec_context: a client that says a digest of the three messages follows must have left room
        // for one, and a digest that is there must fit.
        if marks & 0x2 != 0, digestAt == 0 { throw Refusal.digestMissing }
        if digestAt != 0 {
            var blank = third
            blank.replaceSubrange(digestAt..<(digestAt + 16), with: [UInt8](repeating: 0, count: 16))
            guard ShareDigests.hmacMD5(key: sessionKey, first + second + blank) == Array(third[digestAt..<(digestAt + 16)]) else { throw Refusal.digest }
        }

        // SPNEGO (acceptor_complete): a signature over the list of mechanisms, when one came, must fit. The Mac's keys
        // are set up from what its own challenge offered (_gss_ntlm_set_keys with the challenge's flags): it offered a
        // key exchange, so it reads the digest in the signature as scrambled under the sealing key, always.
        if let listSignature {
            guard listSignature.count == 16 else { throw Refusal.listSignature }
            let sequence = Array(listSignature[12...])
            let signing = ShareDigests.md5(sessionKey + Array("session key to client-to-server signing key magic constant".utf8) + [0])
            let sealing = ShareDigests.md5(sessionKey + Array("session key to client-to-server sealing key magic constant".utf8) + [0])
            let digest = Array(ShareDigests.hmacMD5(key: signing, sequence + list).prefix(8))
            guard listSignature == [1, 0, 0, 0] + ShareDigests.rc4(key: sealing, digest) + sequence else { throw Refusal.listSignature }
        }
        return sessionKey
    }
}

@Suite struct MacSignInTests {
    private static let newKey: [UInt8] = (0..<16).map { UInt8(0xB0 + $0) }

    /// The client's side of a sign-in to `mac`, as `SMBConnection` does it.
    private func signIn(_ mac: MacSignIn, password: String? = nil, time: UInt64 = 0, newKey: [UInt8] = newKey) throws -> (answer: NTLM.Answer, key: [UInt8]) {
        let first = NTLM.negotiate()
        let second = try mac.challengeMessage(to: first)
        let answer = try NTLM.authenticate(user: mac.user, domain: "", password: password ?? mac.password, negotiate: first, challenge: second,
                                           clientChallenge: [UInt8](repeating: 0xC1, count: 8), time: time, newKey: newKey)
        let signature = answer.carriesDigest ? answer.listSignature(SPNEGO.mechanismList) : nil
        return (answer, try mac.accept(first: first, second: second, third: answer.message, listSignature: signature, list: SPNEGO.mechanismList))
    }

    @Test func aMacTakesTheSignIn() throws {
        let mac = MacSignIn()
        let signedIn = try signIn(mac)
        // Both sides hold the key the client made up: it is what the session's messages are then signed with.
        #expect(signedIn.key == Self.newKey)
        #expect(signedIn.answer.sessionKey == Self.newKey)
        // The Mac sent its time, so the answer carries the digest of the three messages and the list is signed.
        #expect(signedIn.answer.carriesDigest)
        // The last message says a key was exchanged and carries it, 16 bytes, wrapped: not the key itself.
        let r = ByteReader(signedIn.answer.message)
        #expect(try r.u32(60) & NTLM.keyExchange != 0)
        #expect(try r.u16(52) == 16)
        let wrapped = try r.slice(Int(r.u32(56)), 16)
        #expect(wrapped != Self.newKey)
        #expect(Int(try r.u32(56)) + 16 == signedIn.answer.message.count)
    }

    @Test func aMacChecksTheListSignatureAsAfterAKeyExchange() throws {
        // What went wrong against macOS 27: the same sign-in without the exchange. The password is right, the names
        // and the digest of the three messages fit, and the Mac still refuses, at the signature on the list of
        // mechanisms, because it reads that signature as scrambled under a sealing key.
        let mac = MacSignIn()
        #expect(throws: MacSignIn.Refusal.listSignature) { _ = try signIn(mac, newKey: []) }
    }

    @Test func aMacRefusesAWrongPasswordAtThePassword() throws {
        let mac = MacSignIn()
        #expect(throws: MacSignIn.Refusal.password) { _ = try signIn(mac, password: "other") }
    }

    @Test func theMacsOwnTimeIsUsedNotThePhones() throws {
        // The phone's clock is wildly off (`time` is 1601): the answer carries the Mac's time back, so the Mac's check
        // of it passes all the same.
        let mac = MacSignIn()
        #expect(throws: Never.self) { _ = try signIn(mac, time: 0) }
    }

    @Test func aMacsChallengeIsReadAsItIs() throws {
        // The challenge has the Mac's version in front of its names, which moves them: they are found by their offsets.
        let mac = MacSignIn()
        let parsed = try NTLM.parseChallenge(try mac.challengeMessage(to: NTLM.negotiate()))
        #expect(parsed.serverChallenge == mac.challenge)
        #expect(parsed.targetInfo == mac.attributes)
        #expect(parsed.flags & NTLM.keyExchange != 0)
    }

    @Test func nobodyExchangesNoKey() throws {
        // Signing in with no name at all: there is no key to wrap another in, so the message doesn't claim an exchange
        // (a Mac would otherwise look for the wrapped key and refuse).
        let mac = MacSignIn()
        let message = try NTLM.anonymous(challenge: try mac.challengeMessage(to: NTLM.negotiate()))
        let flags = try ByteReader(message).u32(60)
        #expect(flags & NTLM.keyExchange == 0)
        #expect(flags & NTLM.anonymous != 0)
    }

    @Test func keyExchangeMatchesTheProtocolsOwnExample() throws {
        // MS-NLMP 4.2.4: the challenge message exactly as printed in 4.2.4.3 (it offers a key exchange), user "User",
        // domain "Domain", password "Password", the client's challenge aa×8, time 0, and 55×16 as the new session key.
        let challenge = unhex([
            "4e544c4d53535000020000000c000c00", "3800000033828ae20123456789abcdef", "00000000000000002400240044000000",
            "060070170000000f5300650072007600", "6500720002000c0044006f006d006100", "69006e0001000c005300650072007600",
            "6500720000000000",
        ].joined())
        let key = [UInt8](repeating: 0x55, count: 16)
        let answer = try NTLM.authenticate(user: "User", domain: "Domain", password: "Password", negotiate: NTLM.negotiate(), challenge: challenge,
                                           clientChallenge: [UInt8](repeating: 0xaa, count: 8), time: 0, newKey: key)
        let r = ByteReader(answer.message)
        let nt = try r.slice(Int(r.u32(24)), Int(r.u16(20)))
        #expect(hex(Array(nt.prefix(16))) == "68cd0ab851e51c96aabc927bebef6a1c")
        // The key as it goes over the wire (the example's EncryptedRandomSessionKey), and the key the session keeps.
        #expect(hex(try r.slice(Int(r.u32(56)), Int(r.u16(52)))) == "c5dad2544fc9799094ce1ce90bc9d03e")
        #expect(answer.sessionKey == key)
        // 4.2.4.4: the client's sealing key, and with it and the signing key the example's sealed "Plaintext" and its
        // signature (one RC4 stream: the message first, then the digest).
        let sealing = try #require(answer.sealingKey)
        #expect(hex(sealing) == "59f600973cc4960a25480a7c196e4c58")
        let signing = ShareDigests.md5(key + NTLM.magic("signing"))
        #expect(hex(signing) == "4788dc861b4782f35d43fd98fe1a2d39")
        let plain = "Plaintext".utf16LE
        let digest = Array(ShareDigests.hmacMD5(key: signing, [0, 0, 0, 0] + plain).prefix(8))
        let stream = ShareDigests.rc4(key: sealing, plain + digest)
        #expect(hex(Array(stream.prefix(18))) == "54e50165bf1936dc996020c1811b0f06fb5f")
        #expect(hex(Array(stream.suffix(8))) == "7fb38ec5c55d4976")
    }

    @Test func rc4MatchesItsPublishedVectors() {
        // RFC 6229: the first 16 bytes of the stream for the 40-bit and the 128-bit key 0102030405… .
        let zeros = [UInt8](repeating: 0, count: 16)
        #expect(hex(ShareDigests.rc4(key: unhex("0102030405"), zeros)) == "b2396305f03dc027ccc3524a0a1118a8")
        #expect(hex(ShareDigests.rc4(key: unhex("0102030405060708090a0b0c0d0e0f10"), zeros)) == "9ac7cc9a609d1ef7b2932899cde41b97")
    }

    @Test func aShareThatIsNotThereIsSaidSoOnceSignedIn() throws {
        // Signed in, the client asks for a share and the server answers that it has none by that name (here: the
        // recorded Samba conversation up to that request, then the refusal a server sends). That is "no such share",
        // not a failed sign-in: the sign-in had gone through.
        var recording = try #require(SMBRecordings.all["smb202"])
        let ask = try #require(recording.sent.firstIndex { $0.dropFirst(8 + 24).hasPrefix("0300") })
        // Everything received before the answer to that request, as recorded.
        let before = recording.sent[..<ask].count * 2
        let answer = unhex(recording.received[before + 1])
        var refusal = Array(answer.prefix(64))
        refusal.replaceSubrange(8..<12, with: [0xCC, 0x00, 0x00, 0xC0])      // STATUS_BAD_NETWORK_NAME
        refusal.replaceSubrange(16..<20, with: [0x01, 0x00, 0x00, 0x00])     // an answer, unsigned as refusals are
        refusal.replaceSubrange(48..<64, with: [UInt8](repeating: 0, count: 16))
        refusal += [9, 0, 0, 0, 0, 0, 0, 0, 0]
        recording.sent = Array(recording.sent[...ask])
        recording.received = Array(recording.received[..<before]) + [hex([0, 0, 0, UInt8(refusal.count)]), hex(refusal)]
        let transport = ReplayTransport(recording)
        let connection = SMBConnection(transport: transport, options: recordedOptions)
        #expect(throws: SMBError.noSuchShare) {
            try connection.connect(server: "127.0.0.1", share: "music", credentials: recordedAccount)
        }
        #expect(transport.mismatch == nil)
        #expect(transport.finished)
    }
}
