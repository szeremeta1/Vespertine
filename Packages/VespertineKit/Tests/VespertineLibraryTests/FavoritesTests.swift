//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
@testable import VespertineLibrary

@Suite("Favorites")
struct FavoritesTests {
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

    @Test("Newest favorite first; favoriting again keeps the first date; removing works")
    func addRemoveOrder() async throws {
        let (db, _, _, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try id(db, "a"), b = try id(db, "b"), c = try id(db, "c")
        let start = Date(timeIntervalSince1970: 1_000_000)
        try db.setFavorite(true, trackIDs: [a], at: start)
        try db.setFavorite(true, trackIDs: [c], at: start.addingTimeInterval(60))
        try db.setFavorite(true, trackIDs: [a], at: start.addingTimeInterval(120))   // already a favorite
        #expect(try db.favoriteTracks().map(\.id) == [c, a])

        try db.setFavorite(false, trackIDs: [c, b])   // b never was one
        #expect(try db.favoriteTracks().map(\.id) == [a])
        try db.setFavorite(true, trackIDs: [999_999])   // no such track: ignored
        #expect(try db.favoriteTracks().map(\.id) == [a])
    }

    @Test("Missing files are hidden, and deleted tracks take their favorite with them")
    func missingAndDeleted() async throws {
        let (db, scanner, source, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try id(db, "a"), b = try id(db, "b")
        try db.setFavorite(true, trackIDs: [a, b])
        try FileManager.default.removeItem(at: dir.appendingPathComponent("b.wav"))
        try await scanner.scan(source)
        #expect(try db.favoriteTracks().map(\.id) == [a])

        try db.removeSource(try #require(source.id))
        let rows = try await db.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM favorite") }
        #expect(rows == 0)
    }

    @Test("A moved file stays a favorite")
    func movedFile() async throws {
        let (db, scanner, source, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try id(db, "a")
        let date = Date(timeIntervalSince1970: 2_000_000)
        try db.setFavorite(true, trackIDs: [a], at: date)

        let moved = dir.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: dir.appendingPathComponent("a.wav"), to: moved.appendingPathComponent("a.wav"))
        try await scanner.scan(source)

        let favorites = try db.favoriteTracks()
        #expect(favorites.count == 1)
        #expect(favorites.first?.filePath.hasSuffix("/Moved/a.wav") == true)
        #expect(favorites.first?.id != a)
        let kept = try await db.writer.read { db in try Date.fetchOne(db, sql: "SELECT favoritedAt FROM favorite") }
        #expect(kept == date)
    }

    @Test("Smart playlists can match favorites")
    func smartRule() async throws {
        let (db, _, _, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let b = try id(db, "b")
        try db.setFavorite(true, trackIDs: [b])
        let on = try db.createPlaylist(name: "Loved", rules: SmartRules(rules: [SmartRule(field: .isFavorite, op: .isTrue)]))
        let off = try db.createPlaylist(name: "Not yet", rules: SmartRules(rules: [SmartRule(field: .isFavorite, op: .isFalse)]))
        #expect(try db.tracks(in: on).map(\.id) == [b])
        #expect(try db.tracks(in: off).count == 2)
        #expect(SmartRule.Field.isFavorite.operators == [.isTrue, .isFalse])
    }
}
