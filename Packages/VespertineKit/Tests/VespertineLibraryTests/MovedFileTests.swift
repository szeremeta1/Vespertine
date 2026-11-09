//
// Vespertine: a file moved or renamed in the music folder keeps its place in playlists, its play count and rating; a file
// that only looks like a moved one (a twin is still there) is left as missing; and a deleted one is only marked.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
@testable import VespertineLibrary

@Suite("Moved and missing files")
struct MovedFileTests {
    private func library(_ names: [String]) async throws -> (LibraryDatabase, LibraryScanner, LibrarySource, URL) {
        let dir = try tempDir()
        for name in names { try makeWAV(dir.appendingPathComponent("\(name).wav")) }
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference))
        try await scanner.scan(source)
        return (db, scanner, source, dir)
    }

    private func scalar(_ db: LibraryDatabase, _ sql: String, _ arguments: StatementArguments = []) throws -> Int? {
        try db.writer.read { try Int.fetchOne($0, sql: sql, arguments: arguments) }
    }

    private func setPlayCount(_ db: LibraryDatabase, _ id: Int64, _ count: Int) throws {
        try db.writer.write { try $0.execute(sql: "UPDATE track SET playCount = ? WHERE id = ?", arguments: [count, id]) }
    }

    private func setStats(_ db: LibraryDatabase, _ id: Int64, added: Date) throws {
        try db.writer.write { try $0.execute(sql: "UPDATE track SET playCount = 7, rating = 4, addedAt = ? WHERE id = ?", arguments: [added, id]) }
    }

    private func id(_ db: LibraryDatabase, _ name: String) throws -> Int64 {
        try #require(try db.allTracks().first { $0.filePath.hasSuffix("/\(name).wav") }?.id)
    }

    @Test("A renamed file keeps its playlist position, play count, rating and date added")
    func movedKeepsEverything() async throws {
        let (db, scanner, source, dir) = try await library(["a", "b", "c"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try id(db, "a"), b = try id(db, "b"), c = try id(db, "c")
        let playlist = try db.createPlaylist(name: "Mine")
        try db.append(trackIDs: [a, b, c], to: try #require(playlist.id))
        let added = Date(timeIntervalSince1970: 1_000_000)
        try setStats(db, b, added: added)

        let moved = dir.appendingPathComponent("Reorganized", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: dir.appendingPathComponent("b.wav"), to: moved.appendingPathComponent("b.wav"))
        try await scanner.scan(source)

        let list = try db.tracks(in: playlist)
        #expect(list.map(\.id) == [a, list[1].id, c], "the moved song stays second")
        let song = try #require(list[1])
        #expect(song.filePath.hasSuffix("/Reorganized/b.wav"))
        #expect(song.playCount == 7 && song.rating == 4)
        #expect(song.addedAt == added)
        #expect(try scalar(db, "SELECT count(*) FROM track") == 3, "no stale row is left behind")
        #expect(try db.missingSongsSummary().songs == 0)
    }

    @Test("A deleted file is marked missing with its data kept, and comes back when the file does")
    func deletedThenRestored() async throws {
        let (db, scanner, source, dir) = try await library(["a", "b"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let b = try id(db, "b")
        let playlist = try db.createPlaylist(name: "Mine")
        try db.append(trackIDs: [b], to: try #require(playlist.id))
        try setPlayCount(db, b, 3)
        let url = dir.appendingPathComponent("b.wav")
        let saved = dir.appendingPathComponent("b.saved")
        try FileManager.default.moveItem(at: url, to: saved)
        try await scanner.scan(source)

        #expect(try db.allTracks().count == 1, "hidden from every list")
        #expect(try db.tracks(in: playlist).isEmpty)
        #expect(try db.missingSongsSummary().songs == 1)
        #expect(try scalar(db, "SELECT playCount FROM track WHERE id = ?", [b]) == 3)

        try FileManager.default.moveItem(at: saved, to: url)
        try await scanner.scan(source)
        #expect(try db.tracks(in: playlist).map(\.id) == [b])
        #expect(try db.allTracks().first { $0.id == b }?.playCount == 3)
        #expect(try db.missingSongsSummary().songs == 0)
    }

    @Test("Removing missing songs takes only the missing ones, and not a song that was just moved")
    func removeOnlyMissing() async throws {
        let (db, scanner, source, dir) = try await library(["a", "b", "c"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try id(db, "a"), c = try id(db, "c")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("b.wav"))
        let moved = dir.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: dir.appendingPathComponent("c.wav"), to: moved.appendingPathComponent("c.wav"))
        try await scanner.scan(source)
        #expect(try db.missingSongsSummary().songs == 1)
        #expect(try db.removeMissingSongs() == 1)
        let left = try db.allTracks()
        #expect(left.count == 2)
        #expect(left.contains { $0.id == a })
        #expect(left.contains { $0.filePath.hasSuffix("/Moved/c.wav") } && !left.contains { $0.id == c })
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains("a.wav"), "files on disk are never touched")
    }

    @Test("A missing song with two possible new homes is not guessed at")
    func ambiguousStaysMissing() async throws {
        let (db, scanner, source, dir) = try await library(["a", "b"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let b = try id(db, "b")
        let playlist = try db.createPlaylist(name: "Mine")
        try db.append(trackIDs: [b], to: try #require(playlist.id))
        // b.wav goes away; two byte-identical copies of it appear in two other folders.
        let bytes = try Data(contentsOf: dir.appendingPathComponent("b.wav"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("b.wav"))
        for folder in ["One", "Two"] {
            let sub = dir.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try bytes.write(to: sub.appendingPathComponent("b.wav"))
        }
        try await scanner.scan(source)
        #expect(try db.missingSongsSummary().songs == 1, "the old entry is still there, marked missing")
        #expect(try db.allTracks().filter { $0.filePath.hasSuffix("/b.wav") }.count == 2)
        #expect(try db.tracks(in: playlist).isEmpty, "and the playlist still points at it, not at either copy")
    }
}
