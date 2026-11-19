//
// Vespertine: listening statistics outlast the library's rows: a folder taken out and added again, a file moved into
// another folder, a rescan writing rows afresh, an update from any earlier library. Remove Missing Songs alone forgets.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
@testable import VespertineLibrary

@Suite("Kept listening statistics")
struct KeptStatsTests {
    private let added = Date(timeIntervalSince1970: 1_600_000_000)
    private let lastPlayed = Date(timeIntervalSince1970: 1_700_000_000)

    /// A folder of WAV files of different lengths (so each file is its own), scanned into a new library.
    private func library(_ names: [String]) async throws -> (LibraryDatabase, LibraryScanner, LibrarySource, URL) {
        let dir = try tempDir()
        let music = dir.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        for (i, name) in names.enumerated() { try makeWAV(music.appendingPathComponent("\(name).wav"), seconds: 0.5 + Double(i) * 0.25) }
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        let source = try db.addSource(LibrarySource(path: music.path, mode: .reference))
        try await scanner.scan(source)
        return (db, scanner, source, dir)
    }

    private func track(_ db: LibraryDatabase, _ name: String) throws -> Track {
        try #require(try db.allTracks().first { $0.filePath.hasSuffix("/\(name).wav") })
    }

    /// Plays, a last play, a rating, an early date added, a favorite and two plays in the history.
    private func listen(_ db: LibraryDatabase, to id: Int64) throws {
        try db.writer.write { db in
            try db.execute(sql: "UPDATE track SET playCount = 12, lastPlayedAt = ?, rating = 80, addedAt = ? WHERE id = ?",
                           arguments: [lastPlayed, added, id])
        }
        try db.setFavorite(true, trackIDs: [id], at: added)
        try db.recordHistory(id, at: lastPlayed.addingTimeInterval(-86_400))
        try db.recordHistory(id, at: lastPlayed)
    }

    private func expectListenedTo(_ db: LibraryDatabase, _ t: Track, _ comment: Comment) throws {
        #expect(t.playCount == 12, comment)
        #expect(t.lastPlayedAt == lastPlayed, comment)
        #expect(t.rating == 80, comment)
        #expect(t.addedAt == added, comment)
        #expect(try db.favoriteTracks().map(\.id) == [t.id], comment)
        let history = try db.writer.read { db in
            try Date.fetchAll(db, sql: "SELECT playedAt FROM playHistory WHERE trackId = ? ORDER BY playedAt", arguments: [t.id])
        }
        #expect(history == [lastPlayed.addingTimeInterval(-86_400), lastPlayed], comment)
    }

    @Test("A folder taken out of the library and added again brings back plays, last play, rating, date added, favorite and history")
    func folderRemovedAndAddedAgain() async throws {
        let (db, scanner, source, dir) = try await library(["a", "b"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try listen(db, to: try #require(try track(db, "a").id))

        try db.removeSource(try #require(source.id))
        #expect(try db.allTracks().isEmpty)
        #expect(try db.keptStatsCount() == 1, "only the song with something to keep")

        let again = try db.addSource(LibrarySource(path: source.path, mode: .reference))
        try await scanner.scan(again)
        try expectListenedTo(db, try track(db, "a"), "the song took its statistics back")
        #expect(try track(db, "b").playCount == 0)
        #expect(try db.keptStatsCount() == 0, "what was given back is no longer kept")
    }

    @Test("A file moved into another folder after its own folder left the library takes its statistics along")
    func movedIntoAnotherFolder() async throws {
        let (db, scanner, source, dir) = try await library(["a", "b"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try listen(db, to: try #require(try track(db, "a").id))
        try db.removeSource(try #require(source.id))

        let elsewhere = dir.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: URL(fileURLWithPath: source.path).appendingPathComponent("a.wav"),
                                         to: elsewhere.appendingPathComponent("renamed.wav"))
        let other = try db.addSource(LibrarySource(path: elsewhere.path, mode: .reference))
        try await scanner.scan(other)
        try expectListenedTo(db, try track(db, "renamed"), "the same file, by its size and length")
    }

    @Test("Two kept songs that share a file's size and length give neither one's statistics to a stranger")
    func ambiguousKeysWait() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let music = dir.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        for name in ["x", "y"] { try makeWAV(music.appendingPathComponent("\(name).wav")) }
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        let source = try db.addSource(LibrarySource(path: music.path, mode: .reference))
        try await scanner.scan(source)
        for name in ["x", "y"] { try listen(db, to: try #require(try track(db, name).id)) }
        try db.removeSource(try #require(source.id))
        #expect(try db.keptStatsCount() == 2)

        let elsewhere = dir.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try makeWAV(elsewhere.appendingPathComponent("z.wav"))
        try await scanner.scan(try db.addSource(LibrarySource(path: elsewhere.path, mode: .reference)))
        #expect(try track(db, "z").playCount == 0, "the same size, length and title-less tags as both: whose would it be?")
        #expect(try db.keptStatsCount() == 2)
    }

    @Test("Writing a row again (a rescan, a server's listing) never lowers plays, forgets the last play or moves the date added later")
    func rowsWrittenAgainKeepTheirStatistics() async throws {
        let (db, _, _, dir) = try await library(["a"])
        defer { try? FileManager.default.removeItem(at: dir) }
        var a = try track(db, "a")
        try listen(db, to: try #require(a.id))
        a.playCount = 0
        a.lastPlayedAt = nil
        a.addedAt = .now
        a.title = "Retitled"
        let rewritten = a
        try await db.writer.write { db in var row = rewritten; try row.update(db) }
        let after = try track(db, "a")
        #expect(after.title == "Retitled", "the rest of the row is written")
        #expect(after.playCount == 12 && after.lastPlayedAt == lastPlayed && after.addedAt == added)

        let id = a.id, later = lastPlayed.addingTimeInterval(60)
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE track SET playCount = playCount + 1, lastPlayedAt = ? WHERE id = ?", arguments: [later, id])
        }
        #expect(try track(db, "a").playCount == 13, "a play still counts")
        #expect(try track(db, "a").lastPlayedAt == lastPlayed.addingTimeInterval(60))
    }

    @Test("A rescan of a file whose tags changed keeps every statistic")
    func rescanKeepsEverything() async throws {
        let (db, scanner, source, dir) = try await library(["a"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try listen(db, to: try #require(try track(db, "a").id))
        try await scanner.scan(source, restart: true)
        try expectListenedTo(db, try track(db, "a"), "after a full rescan")
    }

    @Test("Remove Missing Songs forgets, as its confirmation says, and a moved file's old entry leaves nothing behind")
    func forgettingOnPurpose() async throws {
        let (db, scanner, source, dir) = try await library(["a", "b"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try listen(db, to: try #require(try track(db, "a").id))
        try listen(db, to: try #require(try track(db, "b").id))
        let music = URL(fileURLWithPath: source.path)

        // b is moved within the folder: the new entry takes everything, nothing is kept for the old one.
        try FileManager.default.createDirectory(at: music.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: music.appendingPathComponent("b.wav"), to: music.appendingPathComponent("Sub/b.wav"))
        // a is deleted: missing, then removed on purpose.
        try FileManager.default.removeItem(at: music.appendingPathComponent("a.wav"))
        try await scanner.scan(source)
        #expect(try track(db, "b").playCount == 12)
        #expect(try db.keptStatsCount() == 0)

        #expect(try db.removeMissingSongs() == 1)
        #expect(try db.keptStatsCount() == 0)
    }

    @Test("A library from before kept statistics updates with its plays intact, and keeps them from then on")
    func olderLibraryUpdates() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Library.sqlite")
        let pool = try DatabasePool(path: url.path)
        try LibraryDatabase.migrator.migrate(pool, upTo: "v23-streamed")
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO source (path, mode, addedAt) VALUES ('/Music', 'reference', '2025-01-01 00:00:00.000')")
            try db.execute(sql: """
                INSERT INTO track (sourceId, location, filePath, fileSize, modifiedAt, addedAt, codec, isLossless, isDSD, sampleRate,
                                   bitDepth, channels, duration, title, artist, playCount, lastPlayedAt, rating)
                VALUES (1, '/Music/1.flac', '/Music/1.flac', 1234, '2025-01-01 00:00:00.000', '2025-01-02 00:00:00.000', 'FLAC', 1, 0,
                        96000, 24, 2, 200.25, 'Night Train', 'The Vesper Quartet', 31, '2025-06-01 20:00:00.000', 60)
                """)
            try db.execute(sql: "INSERT INTO favorite (trackId, favoritedAt) VALUES (1, '2025-02-01 00:00:00.000')")
        }
        try pool.close()

        let db = try LibraryDatabase(url: url)
        let song = try #require(try db.allTracks().first)
        #expect(song.playCount == 31 && song.rating == 60)
        try db.removeSource(try #require(song.sourceId))
        #expect(try db.keptStatsCount() == 1)

        // The same recording, re-tagged on the way, in a folder of its own.
        let source = try db.addSource(LibrarySource(path: "/Elsewhere", mode: .reference))
        var back = song
        back.id = nil
        back.sourceId = source.id
        back.location = "/Elsewhere/Night Train.flac"
        back.filePath = back.location
        back.fileSize = 999
        back.playCount = 0
        back.lastPlayedAt = nil
        back.rating = nil
        _ = try await LibraryScanner.upsert([back], sourceID: try #require(source.id), database: db)
        let restored = try #require(try db.allTracks().first)
        #expect(restored.playCount == 31 && restored.rating == 60, "the same title, artist, format and length")
        #expect(try db.favoriteTracks().map(\.id) == [restored.id])
    }

    @Test("Skips count, never go down when a row is written again, and come back with a folder added again")
    func skips() async throws {
        let (db, scanner, source, dir) = try await library(["a"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try #require(try track(db, "a").id)
        #expect(try track(db, "a").skipCount == nil, "never skipped")
        try db.markSkipped(id, at: lastPlayed)
        try db.markSkipped(id, at: lastPlayed.addingTimeInterval(60))
        #expect(try track(db, "a").skipCount == 2 && track(db, "a").lastSkippedAt == lastPlayed.addingTimeInterval(60))

        var stale = try track(db, "a")
        stale.skipCount = nil
        stale.lastSkippedAt = nil
        let rewritten = stale
        try await db.writer.write { db in var row = rewritten; try row.update(db) }
        #expect(try track(db, "a").skipCount == 2 && track(db, "a").lastSkippedAt == lastPlayed.addingTimeInterval(60))

        try await scanner.scan(source, restart: true)
        #expect(try track(db, "a").skipCount == 2, "a rescan keeps them")

        try db.removeSource(try #require(source.id))
        #expect(try db.keptStatsCount() == 1, "a song only skipped is kept too")
        try await scanner.scan(try db.addSource(LibrarySource(path: source.path, mode: .reference)))
        #expect(try track(db, "a").skipCount == 2 && track(db, "a").lastSkippedAt == lastPlayed.addingTimeInterval(60))
        #expect(try track(db, "a").playCount == 0)
    }
}
