//
// Vespertine: the SMB client against conversations recorded with a real Samba server (4.19), one per way of signing.
// With the same identity, random bytes and files, the client must send exactly what it sent then, and read the server's
// answers as it did: signing in, the signatures on every message, a folder listing, a read, a file that isn't there.
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
func recordedConversation(_ connection: SMBConnection) throws {
    try connection.connect(server: "127.0.0.1", share: "music", credentials: SMBCredentials(name: "listener", password: "Tr0ub4dor&3 é"))
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
    @Test(arguments: [(0x0302, "smb302"), (0x0210, "smb210"), (0x0202, "smb202")])
    func theClientSaysWhatItSaidToARealServer(dialect: Int, name: String) throws {
        let recording = try #require(SMBRecordings.all[name])
        let transport = ReplayTransport(recording)
        let connection = SMBConnection(transport: transport, options: recordedOptions)
        try recordedConversation(connection)
        #expect(connection.dialect == UInt16(dialect))
        #expect(transport.mismatch == nil)
        #expect(transport.finished)
    }

    @Test func anAnswerChangedOnTheWayIsRefused() throws {
        var recording = try #require(SMBRecordings.all["smb302"])
        // One byte of the file's contents flipped in the server's answer to the first read: its signature no longer fits.
        let index = try #require(recording.received.firstIndex { $0.hasSuffix("68656c6c6f0a") })
        recording.received[index] = String(recording.received[index].dropLast(2)) + "0b"
        let connection = SMBConnection(transport: ReplayTransport(recording), options: recordedOptions)
        #expect(throws: SMBError.badSignature) { try recordedConversation(connection) }
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
