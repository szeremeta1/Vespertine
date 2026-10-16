//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
@testable import VespertineLibrary

@Suite("Play history")
struct PlayHistoryTests {
    /// A library of three scanned files: a.wav, b.wav, c.wav.
    private func library() async throws -> (LibraryDatabase, LibraryScanner, LibrarySource, URL) {
        let dir = try tempDir()
        for name in ["a", "b", "c"] { try makeWAV(dir.appendingPathComponent("\(name).wav")) }
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference))
        try await scanner.scan(source)
        return (db, scanner, source, dir)
    }

    private func id(_ db: LibraryDatabase, _ name: String) throws -> Int64 {
        try #require(try db.allTracks().first { $0.filePath.hasSuffix("/\(name).wav") }?.id)
    }

    @Test("Most recent first, a song heard twice listed twice; entries and the whole history can be removed")
    func orderAndRemoval() async throws {
        let (db, _, _, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try id(db, "a"), b = try id(db, "b")
        let start = Date(timeIntervalSince1970: 1_000_000)
        try db.recordHistory(a, at: start)
        try db.recordHistory(b, at: start.addingTimeInterval(60))
        try db.recordHistory(a, at: start.addingTimeInterval(120))
        try db.recordHistory(999_999)   // no such track: ignored
        let history = try db.history()
        #expect(history.map(\.track.id) == [a, b, a])
        #expect(history.map(\.playedAt) == [start.addingTimeInterval(120), start.addingTimeInterval(60), start])
        #expect(try db.history(limit: 2).count == 2)

        try db.removeHistory([history[0].id])
        #expect(try db.history().map(\.track.id) == [b, a])
        try db.clearHistory()
        #expect(try db.history().isEmpty)
    }

    @Test("Missing files are hidden, deleted tracks take their history along, and a moved file keeps it")
    func missingDeletedAndMoved() async throws {
        let (db, scanner, source, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try id(db, "a"), b = try id(db, "b")
        let date = Date(timeIntervalSince1970: 2_000_000)
        try db.recordHistory(a, at: date)
        try db.recordHistory(b, at: date.addingTimeInterval(1))

        let moved = dir.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: dir.appendingPathComponent("a.wav"), to: moved.appendingPathComponent("a.wav"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("b.wav"))
        try await scanner.scan(source)
        let history = try db.history()
        #expect(history.count == 1)
        #expect(history.first?.track.filePath.hasSuffix("/Moved/a.wav") == true)
        #expect(history.first?.playedAt == date)

        try db.removeSource(try #require(source.id))
        let rows = try await db.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM playHistory") }
        #expect(rows == 0)
    }

    @Test("Songs played before there was a history start it with their last play")
    func seededFromLastPlayed() throws {
        let queue = try DatabaseQueue()
        try LibraryDatabase.migrator.migrate(queue, upTo: "v17-dst-dsdiff")
        let played = Date(timeIntervalSince1970: 3_000_000)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO source (path, mode, addedAt) VALUES ('/m', 'reference', ?)", arguments: [played])
            for (i, last) in [played, nil].enumerated() {
                try db.execute(sql: """
                    INSERT INTO track (sourceId, location, filePath, fileSize, modifiedAt, addedAt, codec, isLossless, isDSD,
                                       sampleRate, channels, duration, title, playCount, lastPlayedAt)
                    VALUES (1, ?, ?, 1, ?, ?, 'FLAC', 1, 0, 44100, 2, 1, ?, ?, ?)
                    """, arguments: ["/m/\(i).flac", "/m/\(i).flac", played, played, "Song \(i)", last == nil ? 0 : 3, last])
            }
        }
        try LibraryDatabase.migrator.migrate(queue)
        let db = try LibraryDatabase(writer: queue, migrate: false)
        let history = try db.history()
        #expect(history.map(\.track.title) == ["Song 0"])
        #expect(history.first?.playedAt == played)
    }
}
