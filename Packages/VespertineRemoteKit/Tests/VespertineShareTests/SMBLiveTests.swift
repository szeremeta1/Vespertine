//
// Vespertine: the SMB client against a real server. Runs only when VESPERTINE_SMB names one
// ("host:port/share/user/password"), which the suite's machine does not: see docs/PHONE-SHARES.md for how it is run.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineShare

private let live: (host: String, port: Int, share: String, user: String, password: String)? = {
    guard let text = ProcessInfo.processInfo.environment["VESPERTINE_SMB"] else { return nil }
    let parts = text.split(separator: "/", maxSplits: 3).map(String.init)
    let address = parts.first?.split(separator: ":").map(String.init) ?? []
    guard parts.count == 4, address.count == 2, let port = Int(address[1]) else { return nil }
    return (address[0], port, parts[1], parts[2], parts[3])
}()

@Suite(.enabled(if: live != nil)) struct SMBLiveTests {
    @Test func listsAndReadsFromARealServer() throws {
        let live = try #require(live)
        let connection = SMBConnection(transport: try SocketTransport(host: live.host, port: live.port))
        try connection.connect(server: live.host, share: live.share, credentials: SMBCredentials(name: live.user, password: live.password))
        print("dialect", String(connection.dialect, radix: 16))
        let top = try connection.open("", folder: true)
        let names = try connection.list(top).map(\.name)
        try connection.close(top)
        print(names)
        #expect(names.contains("Music"))
        let file = try connection.open("Music/random.bin", folder: false)
        #expect(file.size == 3_000_000)
        let whole = try connection.read(file, offset: 0, length: 4_000_000)
        #expect(whole.count == 3_000_000)
        let expected = try Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["VESPERTINE_SMB_FILE"] ?? "/nonexistent"))
        #expect(Data(whole) == expected)
        #expect(try connection.read(file, offset: 2_999_990, length: 100) == Array(expected.suffix(10)))
        try connection.close(file)
        #expect(throws: SMBError.notFound) { _ = try connection.open("Music/nothing.flac", folder: false) }
        connection.disconnect()
    }

    @Test func scansARealShare() throws {
        let live = try #require(live)
        let share = SMBShare(address: ShareAddress(host: live.host, port: live.port, share: live.share, folder: "Music", user: live.user), password: live.password)
        let library = try ShareScanner.scan(share)
        for song in library.songs { print(song.path, song.tags) }
        print("covers", library.covers, "needTheMac", library.needTheMac, "unreadable", library.unreadable)
        let catalog = ShareCatalog(library)
        for album in catalog.albums {
            print("ALBUM", album.summary)
            for id in album.tracks { print("   ", catalog.tracks[id]!) }
        }
        for (key, cover) in catalog.covers {
            switch cover {
            case .file(let path): print(key, "file", try share.read(path, offset: 0, length: 4).map { String(format: "%02x", $0) }.joined())
            case .embedded(let id):
                let song = catalog.songs[id]!
                print(key, "embedded", try share.read(song.path, offset: song.tags.pictureOffset!, length: 4).map { String(format: "%02x", $0) }.joined(), song.tags.pictureLength!)
            }
        }
        // A second scan reads no file again.
        let again = try ShareScanner.scan(share, previous: library, now: library.scanned!)
        #expect(again == library)
    }

    /// Writes the conversation SMBReplayTests plays back, for the server VESPERTINE_SMB names.
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["VESPERTINE_SMB_RECORD"] ?? "").isEmpty)) func record() throws {
        let live = try #require(live)
        let transport = RecordingTransport(try SocketTransport(host: live.host, port: live.port))
        let connection = SMBConnection(transport: transport, options: recordedOptions)
        try recordedConversation(connection)
        let name = "smb" + String(connection.dialect, radix: 16)
        try transport.source(named: name).write(toFile: ProcessInfo.processInfo.environment["VESPERTINE_SMB_RECORD"]! + "/\(name).txt", atomically: true, encoding: .utf8)
    }

    @Test func aWrongPasswordIsRefusedAsASignInFailure() throws {
        let live = try #require(live)
        let connection = SMBConnection(transport: try SocketTransport(host: live.host, port: live.port))
        #expect(throws: SMBError.signInFailed) {
            try connection.connect(server: live.host, share: live.share, credentials: SMBCredentials(name: live.user, password: "wrong"))
        }
    }

    @Test func aShareThatIsNotThereIsSaidSo() throws {
        let live = try #require(live)
        let connection = SMBConnection(transport: try SocketTransport(host: live.host, port: live.port))
        #expect(throws: SMBError.noSuchShare) {
            try connection.connect(server: live.host, share: "nothing", credentials: SMBCredentials(name: live.user, password: live.password))
        }
    }
}
