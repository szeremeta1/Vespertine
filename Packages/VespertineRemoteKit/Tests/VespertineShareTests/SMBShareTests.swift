//
// Vespertine: a share by paths over a connection that can drop: what is kept open, what is tried again on a new
// connection, and what is simply an answer about the file. And the addresses people type for a share.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineShare

/// A connection that serves files from memory and writes down what it was asked.
final class FakeSession: SMBSession, @unchecked Sendable {
    let files: [String: [UInt8]]
    var log: [String] = []
    /// What the next read fails with (once).
    var readFailure: SMBError?
    private var next: UInt8 = 0
    private var open: [[UInt8]: String] = [:]

    init(_ files: [String: [UInt8]]) { self.files = files }

    func open(_ path: String, folder: Bool) throws -> SMBHandle {
        log.append("open \(path)")
        if folder { return SMBHandle(id: [0], size: 0, modified: .distantPast, isFolder: true) }
        guard let data = files[path] else { throw SMBError.notFound }
        next += 1
        open[[next]] = path
        return SMBHandle(id: [next], size: Int64(data.count), modified: Date(timeIntervalSince1970: 1000), isFolder: false)
    }

    func close(_ handle: SMBHandle) throws {
        log.append("close \(open[handle.id] ?? "folder")")
        open[handle.id] = nil
    }

    func read(_ handle: SMBHandle, offset: Int64, length: Int) throws -> [UInt8] {
        if let failure = readFailure {
            readFailure = nil
            throw failure
        }
        guard let path = open[handle.id], let data = files[path] else { throw SMBError.status(0xC000_0128) }
        log.append("read \(path) \(offset)")
        return Array(data[min(data.count, Int(offset))..<min(data.count, Int(offset) + length)])
    }

    func list(_ folder: SMBHandle) throws -> [SMBEntry] {
        files.keys.sorted().map { SMBEntry(name: $0, isFolder: false, size: Int64(files[$0]!.count), modified: .distantPast) }
    }

    func disconnect() { log.append("disconnect") }
}

@Suite struct SMBShareTests {
    private let files: [String: [UInt8]] = ["Music/a.flac": Array(0..<100), "Music/b.flac": [1], "Music/c.flac": [2], "Music/d.flac": [3]]

    /// A share over fake connections: each connect makes a new one (or fails as `refusals` says, first come first).
    private func share(refusals: [SMBError] = []) -> (share: SMBShare, sessions: () -> [FakeSession]) {
        final class Box: @unchecked Sendable { var sessions: [FakeSession] = []; var refusals: [SMBError] = [] }
        let box = Box()
        box.refusals = refusals
        let files = files
        let share = SMBShare(folder: "/Music/") {
            if !box.refusals.isEmpty { throw box.refusals.removeFirst() }
            let session = FakeSession(files)
            box.sessions.append(session)
            return session
        }
        return (share, { box.sessions })
    }

    @Test func aFileStaysOpenBetweenReadsAndTheOldestIsClosedWhenTooManyAre() throws {
        let (share, sessions) = share()
        #expect(try share.read("a.flac", offset: 0, length: 3) == Data([0, 1, 2]))
        #expect(try share.read("a.flac", offset: 98, length: 10) == Data([98, 99]))
        #expect(try share.info("a.flac").size == 100)
        #expect(sessions().count == 1)
        #expect(sessions()[0].log == ["open Music/a.flac", "read Music/a.flac 0", "read Music/a.flac 98"])
        for name in ["b.flac", "c.flac", "d.flac"] { _ = try share.read(name, offset: 0, length: 1) }
        #expect(sessions()[0].log.contains("close Music/a.flac"))
        #expect(!sessions()[0].log.contains("close Music/b.flac"))
    }

    @Test func aDroppedLineIsMadeAgainAndTheReadCarriesOn() throws {
        let (share, sessions) = share()
        _ = try share.read("a.flac", offset: 0, length: 3)
        for failure in [SMBError.closed, .timedOut, .status(0xC000_035C)] {
            let before = sessions().count
            try #require(sessions().last != nil)
            sessions().last?.readFailure = failure
            #expect(try share.read("a.flac", offset: 10, length: 2) == Data([10, 11]))
            #expect(sessions().count == before + 1)
            #expect(sessions()[before - 1].log.last == "disconnect")
            #expect(sessions()[before].log == ["open Music/a.flac", "read Music/a.flac 10"])
        }
    }

    @Test func anAnswerAboutTheFileIsNotTriedAgain() throws {
        let (share, sessions) = share()
        #expect(throws: SMBError.notFound) { _ = try share.read("nothing.flac", offset: 0, length: 1) }
        _ = try share.read("a.flac", offset: 0, length: 1)
        sessions()[0].readFailure = .accessDenied
        #expect(throws: SMBError.accessDenied) { _ = try share.read("a.flac", offset: 0, length: 1) }
        #expect(sessions().count == 1)
    }

    @Test func aShareThatCantBeReachedSaysSoAndIsTriedAgainNextTime() throws {
        let (share, sessions) = share(refusals: [.unreachable, .signInFailed])
        #expect(throws: SMBError.unreachable) { _ = try share.list("") }
        #expect(throws: SMBError.signInFailed) { _ = try share.list("") }
        #expect(try share.list("").count == 4)
        #expect(sessions().count == 1)
        // The line drops and the server is gone when the phone connects again: the failure to connect is the answer.
        let (other, others) = self.share()
        _ = try other.read("a.flac", offset: 0, length: 1)
        others()[0].readFailure = .closed
        _ = try other.read("a.flac", offset: 0, length: 1)
        #expect(others().count == 2)
    }

    @Test func restingLetsGoOfTheConnection() throws {
        let (share, sessions) = share()
        _ = try share.read("a.flac", offset: 0, length: 1)
        share.rest()
        #expect(sessions()[0].log.last == "disconnect")
        _ = try share.read("a.flac", offset: 0, length: 1)
        #expect(sessions().count == 2)
    }

    @Test func listingOpensTheFolderAndClosesIt() throws {
        let (share, sessions) = share()
        #expect(try share.list("Albums").count == 4)
        #expect(sessions()[0].log == ["open Music/Albums", "close folder"])
    }
}

@Suite struct ShareAddressTests {
    @Test func whatPeopleTypeIsTakenApart() throws {
        let plain = try #require(ShareAddress(typed: "smb://nas.local/music/Albums/Hi-Res"))
        #expect(plain == ShareAddress(host: "nas.local", port: 445, share: "music", folder: "Albums/Hi-Res", user: ""))
        #expect(ShareAddress(typed: "//nas/music") == ShareAddress(host: "nas", share: "music", user: ""))
        #expect(ShareAddress(typed: "  \\\\NAS\\Music Share\\Rock ") == ShareAddress(host: "NAS", share: "Music Share", folder: "Rock", user: ""))
        #expect(ShareAddress(typed: "nas.tail1a2b3.ts.net/music", user: "listener") == ShareAddress(host: "nas.tail1a2b3.ts.net", share: "music", user: "listener"))
        #expect(ShareAddress(typed: "smb://listener@192.168.1.20:4450/music") == ShareAddress(host: "192.168.1.20", port: 4450, share: "music", user: "listener"))
        #expect(ShareAddress(typed: "smb://nas/My%20Music/New%20Folder") == ShareAddress(host: "nas", share: "My Music", folder: "New Folder", user: ""))
        #expect(ShareAddress(typed: "smb://[fd7a:115c:a1e0::1]/music") == ShareAddress(host: "fd7a:115c:a1e0::1", share: "music", user: ""))
        #expect(ShareAddress(typed: "smb://[fd7a:115c:a1e0::1]:4450/music")?.port == 4450)
        // A typed account wins over one in the address.
        #expect(ShareAddress(typed: "smb://guest@nas/music", user: "listener")?.user == "listener")
    }

    @Test func whatIsNotAShareIsRefused() {
        #expect(ShareAddress(typed: "") == nil)
        #expect(ShareAddress(typed: "nas") == nil)
        #expect(ShareAddress(typed: "smb://nas") == nil)
        #expect(ShareAddress(typed: "smb://nas:99999/music") == nil)
        #expect(ShareAddress(typed: "smb:///music") == nil)
    }

    @Test func anAddressIsShownAsALink() {
        #expect(ShareAddress(host: "nas.local", share: "music", folder: "Albums/Hi-Res", user: "x").display == "smb://nas.local/music/Albums/Hi-Res")
        #expect(ShareAddress(host: "nas", port: 4450, share: "music", user: "x").display == "smb://nas:4450/music")
        #expect(ShareAddress(host: "fd7a::1", share: "music", user: "x").display == "smb://[fd7a::1]/music")
    }

    @Test func accountsAreTakenApartTheWaysTheyAreWritten() {
        #expect(SMBCredentials(name: "listener", password: "p") == SMBCredentials(name: "listener", password: "p"))
        let slash = SMBCredentials(name: "STUDIO\\listener", password: "p")
        #expect(slash.user == "listener" && slash.domain == "STUDIO")
        let at = SMBCredentials(name: "listener@studio.example", password: "p")
        #expect(at.user == "listener" && at.domain == "studio.example")
        #expect(SMBCredentials(name: "listener", password: "p").domain == "")
    }
}
