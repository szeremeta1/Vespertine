//
// Vespertine: the SMB client against conversations recorded with a real Samba server (4.19): one per way of signing,
// one per way of encrypting, and a guest's two ways in. With the same identity, random bytes and files, the client must
// send exactly what it sent then, and read the server's answers as it did: signing in, the signatures on every message
// (or the encryption of every message), a folder listing, a read, a file that isn't there.
// Recorded by SMBLiveTests with VESPERTINE_SMB_RECORD set; the account and password are made up for the recording.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineShare

/// Plays a recorded conversation back: what is sent must be the recorded request, what is received is the recorded answer.
final class ReplayTransport: SMBTransport, @unchecked Sendable {
    private var sent: [[UInt8]]
    private var received: [UInt8]
    private(set) var mismatch: String?

    init(_ recording: SMBRecording) {
        sent = recording.sent.map(unhex)
        received = recording.received.flatMap(unhex)
    }

    func send(_ bytes: [UInt8]) throws {
        guard !sent.isEmpty else { mismatch = "sent more than was recorded"; throw SMBError.closed }
        let expected = sent.removeFirst()
        if bytes != expected, mismatch == nil { mismatch = "sent \(hex(bytes)) where \(hex(expected)) was recorded" }
    }

    func receive(_ count: Int) throws -> [UInt8] {
        guard received.count >= count else { throw SMBError.closed }
        defer { received.removeFirst(count) }
        return Array(received.prefix(count))
    }

    func close() {}
    var finished: Bool { sent.isEmpty && received.isEmpty }
}

struct SMBRecording {
    var sent: [String]
    var received: [String]
}

/// Records a conversation as it happens.
final class RecordingTransport: SMBTransport, @unchecked Sendable {
    private let inner: any SMBTransport
    private(set) var sent: [[UInt8]] = []
    private(set) var received: [[UInt8]] = []

    init(_ inner: any SMBTransport) { self.inner = inner }
    func send(_ bytes: [UInt8]) throws { sent.append(bytes); try inner.send(bytes) }
    func receive(_ count: Int) throws -> [UInt8] {
        let bytes = try inner.receive(count)
        received.append(bytes)
        return bytes
    }
    func close() { inner.close() }

    func source(named name: String) -> String {
        func lines(_ list: [[UInt8]]) -> String { list.map { "        \"\(hex($0))\"," }.joined(separator: "\n") }
        return "    static let \(name) = SMBRecording(\n        sent: [\n\(lines(sent))\n        ],\n        received: [\n\(lines(received))\n        ])\n"
    }
}

/// The identity every recording was made with.
let recordedOptions = SMBOptions(clientGUID: Array(0..<16), random: { count in (0..<count).map { UInt8(0xA0 + $0) } }, now: { 0x01DB_0000_0000_0000 })

/// What the recorded client did, and what it found.
let recordedAccount = SMBCredentials(name: "listener", password: "Tr0ub4dor&3 é")

func recordedConversation(_ connection: SMBConnection, credentials: SMBCredentials = recordedAccount) throws {
    try connection.connect(server: "127.0.0.1", share: "music", credentials: credentials)
    let top = try connection.open("Music/Ilse Brandt/Nocturnes", folder: true)
    let entries = try connection.list(top)
    try connection.close(top)
    #expect(entries.map(\.name) == ["note.txt"])
    #expect(entries.first?.size == 6 && entries.first?.isFolder == false)
    let file = try connection.open("Music/Ilse Brandt/Nocturnes/note.txt", folder: false)
    #expect(file.size == 6 && !file.isFolder)
    #expect(try connection.read(file, offset: 0, length: 100) == Array("hello\n".utf8))
    #expect(try connection.read(file, offset: 2, length: 3) == Array("llo".utf8))
    #expect(try connection.read(file, offset: 6, length: 10) == [])
    try connection.close(file)
    #expect(throws: SMBError.notFound) { _ = try connection.open("Music/nothing.flac", folder: false) }
}

@Suite struct SMBReplayTests {
    /// How a recording's server was set up, and so what the client must find itself with.
    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var dialect: UInt16
        var encrypted = false
        var guest = false
        var testDescription: String { name }
    }

    static let cases = [
        Case(name: "smb202", dialect: 0x0202), Case(name: "smb210", dialect: 0x0210), Case(name: "smb302", dialect: 0x0302),
        Case(name: "smb311", dialect: 0x0311),
        Case(name: "smb311gcm", dialect: 0x0311, encrypted: true), Case(name: "smb311ccm", dialect: 0x0311, encrypted: true),
        Case(name: "smb302ccm", dialect: 0x0302, encrypted: true),
        Case(name: "smb311guest", dialect: 0x0311, guest: true), Case(name: "smb311nobody", dialect: 0x0311, guest: true),
    ]

    private static func credentials(_ recorded: Case) -> SMBCredentials {
        recorded.guest ? SMBCredentials(name: "", password: "") : recordedAccount
    }

    @Test(arguments: cases)
    func theClientSaysWhatItSaidToARealServer(recorded: Case) throws {
        let recording = try #require(SMBRecordings.all[recorded.name])
        let transport = ReplayTransport(recording)
        let connection = SMBConnection(transport: transport, options: recordedOptions)
        try recordedConversation(connection, credentials: Self.credentials(recorded))
        #expect(connection.dialect == recorded.dialect)
        #expect(connection.encrypted == recorded.encrypted)
        #expect(connection.guest == recorded.guest)
        #expect(transport.mismatch == nil)
        #expect(transport.finished)
    }

    @Test func everyRecordingIsPlayed() {
        #expect(Set(Self.cases.map(\.name)) == Set(SMBRecordings.all.keys))
    }

    @Test func encryptedConversationsShowNothingOfTheShare() throws {
        // Once the session is encrypted nothing after the sign-in goes out or comes back readable: not the share's
        // name, not a folder's, not the file's contents. (The unencrypted recording has all three.)
        let share = hex("music".utf16LE), folder = hex("Nocturnes".utf16LE), contents = hex(Array("hello\n".utf8))
        let open = try #require(SMBRecordings.all["smb311"])
        let openText = (open.sent + open.received).joined()
        #expect(openText.contains(share) && openText.contains(folder) && openText.contains(contents))
        for name in ["smb311gcm", "smb302ccm"] {
            let recording = try #require(SMBRecordings.all[name])
            let text = (recording.sent + recording.received).joined()
            #expect(!text.contains(share) && !text.contains(folder) && !text.contains(contents))
        }
        // Where only the share asks for encryption, the request that names the share is the last thing in the clear.
        let perShare = try #require(SMBRecordings.all["smb311ccm"])
        let text = (perShare.sent + perShare.received).joined()
        #expect(text.contains(share) && !text.contains(folder) && !text.contains(contents))
    }

    @Test(arguments: ["smb302", "smb311"]) func anAnswerChangedOnTheWayIsRefused(name: String) throws {
        var recording = try #require(SMBRecordings.all[name])
        // One byte of the file's contents flipped in the server's answer to the first read: its signature no longer fits.
        let index = try #require(recording.received.firstIndex { $0.hasSuffix("68656c6c6f0a") })
        recording.received[index] = String(recording.received[index].dropLast(2)) + "0b"
        let connection = SMBConnection(transport: ReplayTransport(recording), options: recordedOptions)
        #expect(throws: SMBError.badSignature) { try recordedConversation(connection) }
    }

    @Test(arguments: ["smb311gcm", "smb311ccm", "smb302ccm"]) func anEncryptedAnswerChangedOnTheWayIsRefused(name: String) throws {
        let recording = try #require(SMBRecordings.all[name])
        let sealed = recording.received.indices.filter { recording.received[$0].hasPrefix("fd534d42") }
        #expect(sealed.count >= 8)
        // The last byte of an encrypted answer flipped, for the first of them and for one in the middle (a read).
        for index in [try #require(sealed.first), sealed[sealed.count / 2]] {
            var changed = recording
            let last = try #require(UInt8(changed.received[index].suffix(2), radix: 16))
            changed.received[index] = String(changed.received[index].dropLast(2)) + String(format: "%02x", last ^ 0x01)
            let connection = SMBConnection(transport: ReplayTransport(changed), options: recordedOptions)
            #expect(throws: SMBError.badSignature) { try recordedConversation(connection) }
        }
    }

    @Test func anAnswerInTheClearToAnEncryptedRequestIsRefused() throws {
        // The server said everything is to be encrypted, and then the answer to "connect to the share" arrives readable
        // (here: the one a server without encryption gave to the same request). It is not taken.
        var recording = try #require(SMBRecordings.all["smb311gcm"])
        let clear = try #require(SMBRecordings.all["smb311"])
        let index = try #require(recording.received.firstIndex { $0.hasPrefix("fd534d42") })
        recording.received[index - 1] = clear.received[index - 1]
        recording.received[index] = clear.received[index]
        #expect(clear.received[index].hasPrefix("fe534d42"))
        let connection = SMBConnection(transport: ReplayTransport(recording), options: recordedOptions)
        #expect(throws: SMBError.badSignature) { try recordedConversation(connection) }
    }

    @Test(arguments: ["smb311", "smb311gcm"]) func aChangedOpeningMessageIsCaughtAtSignIn(name: String) throws {
        // SMB 3.1.1: someone between the phone and the server changes the server's first answer (here one byte of its
        // salt; striking out a cipher or a version would be the same). Both sides sign in as if nothing happened, but
        // their keys are made from what each saw, so the server's signature on its last sign-in answer doesn't fit.
        var recording = try #require(SMBRecordings.all[name])
        let answer = recording.received[1]
        let salt = try #require(answer.range(of: "0100260000000000010020000100"))
        let at = answer.index(salt.upperBound, offsetBy: 4)
        let digit = answer[at] == "0" ? "1" : "0"
        recording.received[1] = answer.replacingCharacters(in: at...at, with: digit)
        let transport = ReplayTransport(recording)
        let connection = SMBConnection(transport: transport, options: recordedOptions)
        #expect(throws: SMBError.badSignature) { try recordedConversation(connection) }
        // Everything the client sent up to then was what it sent the untouched server.
        #expect(transport.mismatch == nil)
    }

    @Test func aGuestIsTriedByNameAndThenAsNobody() throws {
        // The server that doesn't know "guest" refuses it; the client signs in again on the same connection with no name.
        let recording = try #require(SMBRecordings.all["smb311nobody"])
        let named = try #require(SMBRecordings.all["smb311guest"])
        let setups = recording.sent.filter { $0.dropFirst(8).hasPrefix("fe534d42") && $0.dropFirst(8 + 24).hasPrefix("0100") }
        #expect(setups.count == 4)
        #expect(named.sent.filter { $0.dropFirst(8 + 24).hasPrefix("0100") }.count == 2)
        // A name given is never swapped for a guest's: the same server refuses a wrong password outright.
        let transport = ReplayTransport(recording)
        let connection = SMBConnection(transport: transport, options: recordedOptions)
        try? connection.connect(server: "127.0.0.1", share: "music", credentials: SMBCredentials(name: "listener", password: "other"))
        #expect(transport.mismatch != nil)
        #expect(!connection.guest)
    }

    @Test func aWrongPasswordGetsNoFurther() throws {
        let recording = try #require(SMBRecordings.all["smb302"])
        let transport = ReplayTransport(recording)
        let connection = SMBConnection(transport: transport, options: recordedOptions)
        // The recorded server accepted the right password: with another, what the client sends differs from the recording.
        try? connection.connect(server: "127.0.0.1", share: "music", credentials: SMBCredentials(name: "listener", password: "other"))
        #expect(transport.mismatch != nil)
    }
}
