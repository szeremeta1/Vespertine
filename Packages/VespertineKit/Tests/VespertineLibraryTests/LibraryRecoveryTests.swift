//
// Vespertine: a library file that can't be read must not stop the app from opening. The file is kept under another
// name, a new library is created, and `recovery` tells the app so it can tell the user.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
@testable import VespertineLibrary

@Suite("Library file recovery")
struct LibraryRecoveryTests {
    private func folder() throws -> URL {
        try tempDir()
    }

    /// A library with a few songs, closed, as the files it leaves on disk.
    private func makeLibrary(at url: URL, songs: Int = 3) throws {
        let db = try LibraryDatabase(url: url)
        let source = try db.addSource(LibrarySource(path: "/m", mode: .reference))
        try db.writer.write { db in
            for i in 0..<songs {
                var t = Track.stub(path: "/m/\(i).flac")
                t.sourceId = source.id
                try t.insert(db)
            }
        }
    }

    @Test("A healthy library opens as it is, with no recovery")
    func healthy() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Library.sqlite")
        try makeLibrary(at: url)
        let db = try LibraryDatabase(url: url)
        #expect(db.recovery == nil)
        #expect(try db.allTracks().count == 3)
    }

    @Test("A file that isn't a database is kept under another name and a new library takes its place")
    func garbageFile() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Library.sqlite")
        let garbage = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try garbage.write(to: url)
        let db = try LibraryDatabase(url: url)
        let recovery = try #require(db.recovery)
        #expect(try Data(contentsOf: recovery.backup) == garbage, "the old bytes are kept as they were")
        #expect(recovery.backup.deletingLastPathComponent() == url.deletingLastPathComponent())
        #expect(recovery.backup.lastPathComponent.hasPrefix("Library.sqlite.damaged-"))
        #expect(try db.allTracks().isEmpty)
        #expect(try db.playlists().count == 2, "the starter smart playlists are back")
        _ = try db.addSource(LibrarySource(path: "/m", mode: .reference))
        // And the next launch opens the new library without another recovery.
        let again = try LibraryDatabase(url: url)
        #expect(again.recovery == nil)
        #expect(try again.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM source") } == 1)
    }

    @Test("A library cut short is set aside and a new one is created, without the old write-ahead log")
    func truncated() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Library.sqlite")
        try makeLibrary(at: url, songs: 300)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size > 50_000, "the library has some size to cut")
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 6_000)
        try handle.close()
        // A write-ahead log that belonged to the old file must not be applied to the new one.
        try Data("stale".utf8).write(to: URL(fileURLWithPath: url.path + "-wal"))
        let db = try LibraryDatabase(url: url)
        let recovery = try #require(db.recovery)
        #expect(try Data(contentsOf: recovery.backup).count == 6_000)
        #expect(try db.allTracks().isEmpty)
        // SQLite may have rewritten the log when it first looked; the new library doesn't start with the old one's.
        let current = try? Data(contentsOf: URL(fileURLWithPath: url.path + "-wal"))
        #expect(current != Data("stale".utf8))
    }

    @Test("A file the app may not read is an error and is left alone, not mistaken for a damaged library")
    func unreadable() throws {
        let dir = try folder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent("Library.sqlite").path)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("Library.sqlite")
        try makeLibrary(at: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        #expect(throws: Error.self) { _ = try LibraryDatabase(url: url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!names.contains { $0.contains("damaged") })
        let db = try LibraryDatabase(url: url)
        #expect(db.recovery == nil)
        #expect(try db.allTracks().count == 3, "the library was never touched")
    }

    @Test("A library from a newer version, with a migration this build doesn't know, opens and keeps its data")
    func newerSchema() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Library.sqlite")
        try makeLibrary(at: url)
        do {
            let pool = try DatabasePool(path: url.path)
            try pool.write { db in
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99-from-the-future')")
                try db.execute(sql: "ALTER TABLE track ADD COLUMN futureColumn TEXT")
            }
        }
        let db = try LibraryDatabase(url: url)
        #expect(db.recovery == nil)
        #expect(try db.allTracks().count == 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.contains("damaged") })
    }

    @Test("Setting a file aside twice in the same second doesn't overwrite the first")
    func twiceInOneSecond() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Library.sqlite")
        let now = Date()
        try Data("one".utf8).write(to: url)
        let first = try LibraryDatabase.setAside(url, now: now)
        try Data("two".utf8).write(to: url)
        let second = try LibraryDatabase.setAside(url, now: now)
        #expect(first != second)
        #expect(try Data(contentsOf: first) == Data("one".utf8))
        #expect(try Data(contentsOf: second) == Data("two".utf8))
    }

    @Test("With recovery turned off (the command-line tool), a damaged file is an error and stays where it is")
    func toolDoesNotRecover() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Library.sqlite")
        let garbage = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 3) })
        try garbage.write(to: url)
        #expect(throws: Error.self) { _ = try LibraryDatabase(url: url, recoversDamagedFile: false) }
        #expect(try Data(contentsOf: url) == garbage)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.contains("damaged") })
    }

    @Test("A schema this SQLite can't read (what a newer one may write) is an error, not damage: the file stays")
    func malformedSchemaIsNotDamage() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Library.sqlite")
        try makeLibrary(at: url)
        // The schema text sits in the file's first page: make one statement something this SQLite can't parse.
        var bytes = try Data(contentsOf: url)
        let statement = Data("CREATE TABLE \"source\"".utf8)
        let at = try #require(bytes.range(of: statement), "the source table's statement is in the file")
        bytes.replaceSubrange(at.lowerBound + 7..<at.lowerBound + 12, with: Data("TABLX".utf8))
        try bytes.write(to: url)
        let before = try Data(contentsOf: url)
        do {
            _ = try LibraryDatabase(url: url)
            Issue.record("a schema SQLite can't parse must not open")
        } catch let error as DatabaseError {
            #expect(error.resultCode == .SQLITE_CORRUPT && (error.message ?? "").contains("malformed database schema"), "\(error.description)")
            #expect(!LibraryDatabase.isUnreadableFile(error))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.contains("damaged") })
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("Putting a set-aside file back restores it and its log files in place of whatever was made meanwhile")
    func putBack() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Library.sqlite")
        try Data("old".utf8).write(to: url)
        try Data("old-wal".utf8).write(to: URL(fileURLWithPath: url.path + "-wal"))
        let backup = try LibraryDatabase.setAside(url)
        try Data("new".utf8).write(to: url)
        try LibraryDatabase.putBack(backup, at: url)
        #expect(try Data(contentsOf: url) == Data("old".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: url.path + "-wal")) == Data("old-wal".utf8))
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }
}
