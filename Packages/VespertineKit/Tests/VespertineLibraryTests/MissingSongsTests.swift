//
// Vespertine — songs whose files are gone: counted for the Remove Missing Songs… sheet, removed on request (the library
// rows only, never files), and marked missing when one is found gone during playback.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
@testable import VespertineLibrary

@Suite("Missing songs")
struct MissingSongsTests {
    /// Three present songs and three missing ones, one of them a favorite with plays and one with plays only.
    private func library() throws -> (db: LibraryDatabase, ids: [String: Int64]) {
        let db = try LibraryDatabase.inMemory()
        let source = try db.addSource(LibrarySource(path: "/m", mode: .reference))
        var ids: [String: Int64] = [:]
        try db.writer.write { db in
            for name in ["a", "b", "c", "gone1", "gone2", "gone3"] {
                var t = Track.stub(path: "/m/\(name).flac")
                t.sourceId = source.id
                t.isMissing = name.hasPrefix("gone")
                t.playCount = name == "gone1" || name == "gone2" ? 4 : (name == "a" ? 2 : 0)
                try t.insert(db)
                ids[name] = t.id!
            }
        }
        try db.setFavorite(true, trackIDs: [ids["gone1"]!, ids["a"]!])
        return (db, ids)
    }

    @Test("The sheet's numbers: songs without a file, favorites among them, songs with play counts among them")
    func summary() throws {
        let (db, _) = try library()
        let summary = try db.missingSongsSummary()
        #expect(summary.songs == 3 && summary.favorites == 1 && summary.played == 2)
    }

    @Test("Nothing missing: all zero")
    func summaryEmpty() throws {
        let db = try LibraryDatabase.inMemory()
        #expect(try db.missingSongsSummary() == MissingSongsSummary(songs: 0, favorites: 0, played: 0))
    }

    @Test("Removing deletes the missing rows with their favorites and history, and leaves every present song as it was")
    func removal() throws {
        let (db, ids) = try library()
        #expect(try db.removeMissingSongs() == 3)
        let left = try db.writer.read { db in try Int64.fetchSet(db, sql: "SELECT id FROM track") }
        #expect(left == Set([ids["a"]!, ids["b"]!, ids["c"]!]))
        #expect(try db.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM favorite") } == 1)
        #expect(try db.missingSongsSummary().songs == 0)
        #expect(try db.removeMissingSongs() == 0)
    }

    @Test("Marking a played song missing hides it everywhere and keeps its favorite and play count for a rescan to restore")
    func markMissing() throws {
        let (db, ids) = try library()
        let a = try #require(try db.tracks(ids: [ids["a"]!]).first)
        try db.markMissing(filePath: a.filePath, sourceID: a.sourceId)
        #expect(try db.tracks(ids: [ids["a"]!]).first?.isMissing == true)
        #expect(try db.missingSongsSummary().songs == 4)
        #expect(try db.writer.read { db in try Int.fetchOne(db, sql: "SELECT playCount FROM track WHERE id = ?", arguments: [ids["a"]!]) } == 2)
        #expect(try db.tracks(ids: [ids["b"]!]).first?.isMissing == false, "another file is not touched")
    }
}
