//
// Vespertine: with the TIDAL switch off, the library reads exactly as a library that never had a TIDAL account: every list, count,
// album, artist, genre, favorite and smart playlist. Switched on, the TIDAL rows show.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
@testable import VespertineLibrary

private func local(_ db: LibraryDatabase, sourceId: Int64) throws {
    try db.writer.write { db in
        func add(_ title: String, artist: String, album: String, rate: Double, bits: Int, genre: String, n: Int, year: Int) throws {
            try db.execute(sql: """
                INSERT INTO track (sourceId, location, filePath, fileSize, modifiedAt, addedAt, codec, isLossless, isDSD, sampleRate, bitDepth, channels,
                                   duration, title, artist, album, albumArtist, genre, trackNumber, year)
                VALUES (?, ?, ?, 1000, '2025-01-01 00:00:00.000', '2025-01-02 00:00:00.000', 'FLAC', 1, 0, ?, ?, 2, 100, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [sourceId, "/Music/\(title).flac", "/Music/\(title).flac", rate, bits, title, artist, album, artist, genre, n, year])
        }
        try add("Plain One", artist: "Ann", album: "Plain", rate: 44_100, bits: 16, genre: "Jazz", n: 1, year: 1999)
        try add("Plain Two", artist: "Ann", album: "Plain", rate: 44_100, bits: 16, genre: "Jazz", n: 2, year: 1999)
        try add("Big One", artist: "Bob", album: "Big", rate: 96_000, bits: 24, genre: "Rock", n: 1, year: 2005)
        try add("Shared One", artist: "Cy", album: "Shared", rate: 44_100, bits: 16, genre: "Blues", n: 1, year: 1980)
    }
}

private func tidalTrack(_ id: Int, _ title: String, artist: String, album: String, quality: String = "HI_RES_LOSSLESS") -> TidalTrackInput {
    TidalTrackInput(tidalId: id, title: title, artist: artist, album: album, albumArtist: artist, trackNumber: id, discNumber: 1, duration: 200,
                    isrc: "XX000000\(id)", year: 2020, listedQuality: quality, coverUUID: "cover-\(id)")
}

/// A library of local songs, and the same with a TIDAL account's rows added.
private struct Libraries {
    let plain: LibraryDatabase
    let mixed: LibraryDatabase

    init() throws {
        plain = try LibraryDatabase.inMemory()
        mixed = try LibraryDatabase.inMemory()
        for db in [plain, mixed] {
            let sourceId = try db.writer.write { db -> Int64 in
                try db.execute(sql: "INSERT INTO source (path, mode, addedAt) VALUES ('/Music', 'reference', '2025-01-01 00:00:00.000')")
                return db.lastInsertedRowID
            }
            try local(db, sourceId: sourceId)
        }
        let tidal = try #require(try mixed.tidalSource(userId: 7).id)
        let ids = try mixed.upsertTidalTracks([
            tidalTrack(1, "Streamed One", artist: "Ann", album: "Streamed"),          // an artist the library has
            tidalTrack(2, "Streamed Two", artist: "Ann", album: "Streamed"),
            tidalTrack(3, "Shared Two", artist: "Cy", album: "Shared"),               // an album the library has
            tidalTrack(4, "Only Tidal", artist: "Dee", album: "Dee Album"),           // an artist and album it hasn't
            tidalTrack(5, "Lossy", artist: "Dee", album: "Dee Album", quality: "HIGH"),
        ], sourceId: tidal)
        try mixed.writer.write { db in
            try db.execute(sql: "UPDATE track SET genre = 'Jazz', playCount = 9, lastPlayedAt = '2025-06-01 00:00:00.000' WHERE title LIKE 'Streamed%'")
            try db.execute(sql: "UPDATE track SET genre = 'Soul' WHERE title IN ('Only Tidal', 'Lossy')")
            try db.execute(sql: "UPDATE track SET genre = 'Blues' WHERE title = 'Shared Two'")
            // A TIDAL playlist, as the sync stores it (the link table comes with the playlist sync).
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS tidalPlaylist (uuid TEXT PRIMARY KEY, playlistId INTEGER NOT NULL UNIQUE REFERENCES playlist(id) ON DELETE CASCADE, lastUpdated TEXT)")
            try db.execute(sql: "INSERT INTO playlist (name, createdAt, sortIndex) VALUES ('From TIDAL', '2025-01-01 00:00:00.000', 5)")
            try db.execute(sql: "INSERT INTO tidalPlaylist (uuid, playlistId) VALUES ('abc', last_insert_rowid())")
        }
        // A user's own playlist mixing both, favorites and plays on both.
        for db in [plain, mixed] {
            let titles = db === mixed ? ["Plain One", "Streamed One", "Only Tidal"] : ["Plain One"]
            let tracks = try db.allTracks().filter { titles.contains($0.title) }
            let playlist = try db.createPlaylist(name: "Mine")
            try db.append(trackIDs: tracks.compactMap(\.id), to: try #require(playlist.id))
            try db.setFavorite(true, trackIDs: tracks.compactMap(\.id))
            for track in tracks { try db.recordHistory(try #require(track.id), at: Date(timeIntervalSince1970: 1_700_000_000)) }
        }
        _ = ids
    }
}

@Suite("TIDAL hidden")
struct TidalHiddenTests {
    @Test("A library with TIDAL rows, TIDAL off, equals one without them: stats, albums, artists, genres, songs")
    func listsEqual() throws {
        let both = try Libraries()
        both.mixed.includeTidal = false
        #expect(try both.mixed.stats() == both.plain.stats())
        #expect(try both.mixed.albums() == both.plain.albums())
        for sort in AlbumSort.allCases { #expect(try both.mixed.albums(sort: sort) == both.plain.albums(sort: sort)) }
        #expect(try both.mixed.artists() == both.plain.artists())
        #expect(try Genres.summarize(both.mixed.albums()) == Genres.summarize(both.plain.albums()))
        #expect(try both.mixed.allTracks().map(\.title) == both.plain.allTracks().map(\.title))
        #expect(try both.mixed.albums(artist: "Ann") == both.plain.albums(artist: "Ann"))
        #expect(try both.mixed.albums(artist: "Dee").isEmpty)
        #expect(try both.mixed.search("streamed").isEmpty)
        #expect(try both.mixed.search("shared").map(\.title) == both.plain.search("shared").map(\.title))
        for key in try both.plain.albums().map(\.key) {
            #expect(try both.mixed.tracks(albumKey: key).map(\.title) == both.plain.tracks(albumKey: key).map(\.title))
        }
        #expect(try both.mixed.tracks(albumKeys: both.plain.albums().map(\.key)).map(\.title) == both.plain.tracks(albumKeys: both.plain.albums().map(\.key)).map(\.title))
        #expect(try both.mixed.tracks(albumKey: "ann\u{1F}streamed").isEmpty)
        #expect(try both.mixed.sources().count == both.plain.sources().count)
        #expect(try !both.mixed.sources().contains { $0.isTidal })
    }

    @Test("Favorites, history, playlists and the Hi-Res smart playlist equal a library without TIDAL")
    func playlistsEqual() throws {
        let both = try Libraries()
        both.mixed.includeTidal = false
        #expect(try both.mixed.favoriteTracks().map(\.title) == both.plain.favoriteTracks().map(\.title))
        #expect(try both.mixed.favoriteEveryVersion() == both.plain.favoriteEveryVersion())
        #expect(try both.mixed.history().map(\.track.title) == both.plain.history().map(\.track.title))
        #expect(try both.mixed.playlists().map(\.name) == both.plain.playlists().map(\.name))
        #expect(try !both.mixed.playlists().map(\.name).contains("From TIDAL"))
        for (mixed, plain) in zip(try both.mixed.playlists(), try both.plain.playlists()) {
            #expect(try both.mixed.tracks(in: mixed).map(\.title) == both.plain.tracks(in: plain).map(\.title), "\(mixed.name)")
        }
        let hiRes = try #require(try both.mixed.playlists().first { $0.name == Playlist.hiResName })
        #expect(try both.mixed.tracks(in: hiRes).map(\.title) == ["Big One"])
        #expect(try both.mixed.tracksNeedingAnalysis().map(\.title).sorted() == both.plain.tracksNeedingAnalysis().map(\.title).sorted())
    }

    @Test("Switched on, the TIDAL rows show everywhere")
    func flippingShows() throws {
        let both = try Libraries()
        both.mixed.includeTidal = false
        let hidden = try both.mixed.stats()
        both.mixed.includeTidal = true
        let shown = try both.mixed.stats()
        #expect(shown.tracks == hidden.tracks + 5)
        #expect(shown.albums == hidden.albums + 2, "Streamed and Dee Album; Shared joins the local album")
        #expect(shown.artists == hidden.artists + 1)
        #expect(try both.mixed.albums().map(\.title).sorted() == ["Big", "Dee Album", "Plain", "Shared", "Streamed"])
        #expect(try both.mixed.artists().map(\.name).contains("Dee"))
        #expect(try Genres.summarize(both.mixed.albums()).map(\.name).contains("Soul"))
        #expect(try both.mixed.search("streamed").count == 2)
        #expect(try both.mixed.favoriteTracks().map(\.title).sorted() == ["Only Tidal", "Plain One", "Streamed One"])
        #expect(try both.mixed.history().count == 3)
        #expect(try both.mixed.playlists().map(\.name).contains("From TIDAL"))
        let hiRes = try #require(try both.mixed.playlists().first { $0.name == Playlist.hiResName })
        #expect(try Set(both.mixed.tracks(in: hiRes).map(\.title)) == ["Big One", "Streamed One", "Streamed Two", "Shared Two", "Only Tidal"])
        #expect(try both.mixed.sources().contains { $0.isTidal })
        #expect(try both.mixed.tracks(albumKey: "ann\u{1F}streamed").count == 2)
        both.mixed.includeTidal = false
        #expect(try both.mixed.stats() == hidden, "and off again")
    }

    @Test("Without any TIDAL rows the clause is empty: the SQL is upstream's")
    func noTidalNoClause() throws {
        let db = try LibraryDatabase.inMemory()
        db.includeTidal = false
        #expect(try db.writer.read { try db.visibleTracksClause($0) } == "1")
        let source = try db.tidalSource(userId: 1)
        let clause = try db.writer.read { try db.visibleTracksClause($0, qualifier: "t") }
        #expect(clause == "t.sourceId IS NOT \(try #require(source.id))")
        db.includeTidal = true
        #expect(try db.writer.read { try db.visibleTracksClause($0) } == "1")
    }

    @Test("TIDAL tracks are shown by default on a bare database, so tools and the sync see them; the app switches them off")
    func defaultIsEverything() throws {
        let db = try LibraryDatabase.inMemory()
        #expect(db.includeTidal)
    }

    @Test("A downloaded TIDAL file is hidden too, by its file path")
    func downloadedHidden() throws {
        let both = try Libraries()
        try both.mixed.setTidalDownload(tidalId: 4, path: "/Music/TIDAL/Only Tidal.flac")
        both.mixed.includeTidal = false
        #expect(try both.mixed.tracks(filePath: "/Music/TIDAL/Only Tidal.flac").isEmpty)
        #expect(try both.mixed.stats() == both.plain.stats())
        both.mixed.includeTidal = true
        #expect(try both.mixed.tracks(filePath: "/Music/TIDAL/Only Tidal.flac").count == 1)
    }

    @Test("Streamed TIDAL rows have no file to analyze, even when shown; downloaded ones do")
    func analysisNeedsFiles() throws {
        let both = try Libraries()
        both.mixed.includeTidal = true
        #expect(try both.mixed.tracksNeedingAnalysis().map(\.title).sorted() == ["Big One", "Plain One", "Plain Two", "Shared One"])
        try both.mixed.setTidalDownload(tidalId: 4, path: "/Music/TIDAL/Only Tidal.flac")
        #expect(try both.mixed.tracksNeedingAnalysis().map(\.title).contains("Only Tidal"))
    }

    @Test("Reordering a playlist keeps the TIDAL songs it holds while they are hidden, where they were")
    func reorderKeepsHidden() throws {
        let both = try Libraries()
        let mine = try #require(try both.mixed.playlists().first { $0.name == "Mine" })
        let id = try #require(mine.id)
        both.mixed.includeTidal = false
        let shown = try both.mixed.tracks(in: mine)
        #expect(shown.map(\.title) == ["Plain One"])
        try both.mixed.setPlaylistTracks(shown.compactMap(\.id) + [try #require(try both.mixed.allTracks().first { $0.title == "Plain Two" }?.id)], playlistID: id)
        both.mixed.includeTidal = true
        #expect(try Set(both.mixed.tracks(in: mine).map(\.title)) == ["Plain One", "Plain Two", "Streamed One", "Only Tidal"])
    }

    @Test("Songs asked for by id, a playlist file's matches, the audit and the read-only share rule leave TIDAL out")
    func otherReaders() throws {
        let both = try Libraries()
        let tidalIDs = try both.mixed.allTracks().filter { $0.location.hasPrefix("tidal://") }.compactMap(\.id)
        #expect(tidalIDs.count == 5)
        both.mixed.includeTidal = false
        #expect(try both.mixed.tracks(ids: tidalIDs).isEmpty)
        #expect(try both.mixed.auditTracks().count == both.plain.auditTracks().count)
        let entry = PlaylistEntry(path: nil, title: "Only Tidal", artist: "Dee", duration: 200)
        #expect(try both.mixed.match([entry]) == [nil])
        both.mixed.includeTidal = true
        #expect(try both.mixed.tracks(ids: tidalIDs).count == 5)
        #expect(try both.mixed.match([entry]).first.flatMap { $0 } != nil)
        let sources = try both.mixed.sources()
        #expect(TagWriter.readOnlyShares(sources).isEmpty, "TIDAL's source is network-shaped, but is no share")
    }
}
