//
// Vespertine: a library file written by an early build opens with every later migration and keeps what the user made in
// it: songs, play counts, ratings, playlists and their order, the sources, and the tag history that reverts an edit.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
@testable import VespertineLibrary

@Suite("Libraries from earlier builds")
struct OldLibraryMigrationTests {
    /// The first schema ("v1") with a few songs, a manual playlist, a tag edit and a source, then opened through `url`.
    private func oldLibrary(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("Library.sqlite")
        let pool = try DatabasePool(path: url.path)
        try LibraryDatabase.migrator.migrate(pool, upTo: "v1")
        try pool.write { db in
            try db.execute(sql: "INSERT INTO source (path, mode, addedAt) VALUES ('/Music Share', 'reference', '2025-01-01 00:00:00.000')")
            for i in 1...4 {
                try db.execute(sql: """
                    INSERT INTO track (sourceId, location, filePath, fileSize, modifiedAt, addedAt, codec, isLossless, isDSD, sampleRate,
                                       bitDepth, channels, duration, title, artist, album, trackNumber, playCount, rating, analysisVerdict)
                    VALUES (1, ?, ?, ?, '2025-01-01 00:00:00.000', '2025-01-02 00:00:00.000', 'FLAC', 1, 0, 96000, 24, ?, 180.5,
                            ?, 'The Vesper Quartet', 'Downstairs Sessions', ?, ?, ?, 'genuine')
                    """, arguments: ["/Music Share/\(i).flac", "/Music Share/\(i).flac", 1000 + i, i == 4 ? 6 : 2, "Song \(i)", i, i * 3, i])
            }
            try db.execute(sql: "INSERT INTO playlist (name, createdAt, sortIndex) VALUES ('Evening', '2025-01-03 00:00:00.000', 2)")
            let playlistID = db.lastInsertedRowID
            for (position, track) in [3, 1, 4].enumerated() {
                try db.execute(sql: "INSERT INTO playlistItem (playlistId, trackId, position) VALUES (?, ?, ?)", arguments: [playlistID, track, position])
            }
            try db.execute(sql: """
                INSERT INTO tagHistory (trackId, editedAt, previous, fileBackupPath) VALUES (2, '2025-01-04 00:00:00.000', '{"title":"Old title"}', '/Tag Backups/2.flac')
                """)
        }
        try pool.close()
        return url
    }

    @Test("Songs, counts, ratings, playlists in order, sources and tag history survive every later migration")
    func keepsWhatTheUserMade() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try oldLibrary(in: dir)
        let db = try LibraryDatabase(url: url)

        let tracks = try db.allTracks()
        #expect(tracks.count == 4)
        #expect(Set(tracks.map(\.title)) == ["Song 1", "Song 2", "Song 3", "Song 4"])
        let byTitle = Dictionary(uniqueKeysWithValues: tracks.map { ($0.title, $0) })
        #expect(byTitle["Song 3"]?.playCount == 9 && byTitle["Song 3"]?.rating == 3)
        #expect(byTitle["Song 4"]?.playCount == 12)
        #expect(byTitle["Song 2"]?.album == "Downstairs Sessions")

        let evening = try #require(try db.playlists().first { $0.name == "Evening" })
        #expect(try db.tracks(in: evening).map(\.title) == ["Song 3", "Song 1", "Song 4"])
        #expect(try db.playlists().count == 3, "the two starter smart playlists and the user's own")
        #expect(try db.sources().map(\.path) == ["/Music Share"])
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM tagHistory WHERE trackId = 2") } == 1)
        #expect(try Set(db.writer.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }).contains("v22-matroska-audio"))

        // Opening it again changes nothing.
        let again = try LibraryDatabase(url: url)
        #expect(try again.allTracks().count == 4)
        #expect(try again.tracks(in: try #require(try again.playlists().first { $0.name == "Evening" })).count == 3)
    }
}
