//
// Vespertine: TIDAL tracks in the library: the v23 migration, upserts by TIDAL id, what a sync removes, and (with the scanner) the
// downloaded files that stand in for a stream.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
@testable import VespertineLibrary

private func input(_ id: Int, title: String = "Song", album: String = "Album", artist: String = "Artist",
                   quality: String = "LOSSLESS", cover: String? = "ab-cd") -> TidalTrackInput {
    TidalTrackInput(tidalId: id, title: title, artist: artist, album: album, albumArtist: artist, trackNumber: id, discNumber: 1,
                    trackTotal: 10, discTotal: 1, duration: 200, isrc: "XX0000000\(id)", releaseDate: "2020-05-01", year: 2020,
                    copyright: "(c) Nobody", explicit: id % 2 == 0, popularity: 40, listedQuality: quality, mediaTags: ["LOSSLESS"],
                    replayGain: TidalReplayGain(trackGain: -7.5, trackPeak: 0.97, albumGain: -8.25, albumPeak: 0.99),
                    albumId: 9000 + id, artistIds: [7, 8], coverUUID: cover)
}

@Suite("TIDAL tracks in the library")
struct TidalLibraryTests {
    private func scalar(_ db: LibraryDatabase, _ sql: String, _ arguments: StatementArguments = []) throws -> Int? {
        try db.writer.read { try Int.fetchOne($0, sql: sql, arguments: arguments) }
    }

    @Test("The migration runs on a database that has the v22 schema and keeps its songs")
    func migratesFromV22() throws {
        let queue = try DatabaseQueue(configuration: LibraryDatabase.queueConfiguration())
        try LibraryDatabase.migrator.migrate(queue, upTo: "v22-matroska-audio")
        #expect(try queue.read { try Bool.fetchOne($0, sql: "SELECT count(*) = 0 FROM sqlite_master WHERE name = 'tidalTrack'") } == true)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO source (path, mode, addedAt) VALUES ('/Music', 'reference', '2025-01-01 00:00:00.000')")
            try db.execute(sql: """
                INSERT INTO track (sourceId, location, filePath, fileSize, modifiedAt, addedAt, codec, isLossless, isDSD, sampleRate, channels, duration, title)
                VALUES (1, '/Music/a.flac', '/Music/a.flac', 10, '2025-01-01 00:00:00.000', '2025-01-02 00:00:00.000', 'FLAC', 1, 0, 44100, 2, 1, 'Local')
                """)
        }
        let db = try LibraryDatabase(writer: queue)
        #expect(try db.allTracks().map(\.title) == ["Local"])
        #expect(try Set(queue.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }).contains("v23-tidal"))
        let columns = try queue.read { try Row.fetchAll($0, sql: "PRAGMA table_info(tidalTrack)").map { $0["name"] as String } }
        #expect(Set(columns) == ["trackId", "tidalId", "albumId", "artistIds", "listedQuality", "mediaTags", "explicit", "copyright",
                                 "popularity", "streamable", "unavailableReason", "downloadPath", "formatIsProbed", "lastSyncedAt"])
    }

    @Test("The TIDAL source is created once, with its address and name")
    func source() throws {
        let db = try LibraryDatabase.inMemory()
        let first = try db.tidalSource(userId: 424242)
        #expect(first.path == "tidal://" && first.remoteURL == "tidal://user/424242" && first.name == "TIDAL" && first.isTidal)
        let again = try db.tidalSource(userId: 424242)
        #expect(again.id == first.id)
        #expect(try db.sources().count == 1)
    }

    @Test("Upserting twice gives the same ids and the new titles; the track carries TIDAL's description")
    func upsertTwice() throws {
        let db = try LibraryDatabase.inMemory()
        let source = try #require(try db.tidalSource(userId: 1).id)
        let first = try db.upsertTidalTracks([input(11), input(12)], sourceId: source)
        #expect(first.count == 2)
        try db.writer.write { try $0.execute(sql: "UPDATE track SET playCount = 5 WHERE id = ?", arguments: [first[11]]) }
        let second = try db.upsertTidalTracks([input(11, title: "Renamed"), input(12, title: "Also renamed"), input(13)], sourceId: source)
        #expect(second[11] == first[11] && second[12] == first[12] && second.count == 3)
        let tracks = try db.allTracks()
        #expect(Set(tracks.map(\.title)) == ["Renamed", "Also renamed", "Song"])
        #expect(try scalar(db, "SELECT count(*) FROM tidalTrack") == 3)
        let track = try #require(tracks.first { $0.title == "Renamed" })
        #expect(track.playCount == 5, "plays outlast a sync")
        #expect(track.location == "tidal://track/11" && track.filePath == "" && track.sourceId == source)
        #expect(track.artworkKey == "tidal:ab-cd")
        #expect(track.rgTrackGain == -7.5 && track.rgTrackPeak == 0.97 && track.rgAlbumGain == -8.25 && track.rgAlbumPeak == 0.99)
        #expect(track.isrc == "XX000000011" && track.year == 2020 && track.trackNumber == 11)
        let record = try #require(try db.tidalRecord(trackId: first[11]!))
        #expect(record.tidalId == 11 && record.albumId == 9011 && record.artistIds == [7, 8] && record.mediaTags == ["LOSSLESS"])
        #expect(record.copyright == "(c) Nobody" && record.popularity == 40 && !record.explicit && record.streamable)
        #expect(record.lastSyncedAt != nil && record.downloadPath == nil && !record.formatIsProbed)
        #expect(try db.tidalRecord(trackId: 99_999) == nil)
    }

    @Test("The listed quality gives the format a track starts with", arguments: [
        ("HI_RES_LOSSLESS", "FLAC", 96_000.0, 24 as Int?), ("LOSSLESS", "FLAC", 44_100.0, 16), ("HIGH", "AAC", 44_100.0, nil), ("LOW", "AAC", 44_100.0, nil),
    ])
    func listedFormat(quality: String, codec: String, rate: Double, depth: Int?) throws {
        let db = try LibraryDatabase.inMemory()
        let source = try #require(try db.tidalSource(userId: 1).id)
        let ids = try db.upsertTidalTracks([input(1, quality: quality)], sourceId: source)
        let track = try #require(try db.allTracks().first { $0.id == ids[1] })
        #expect(track.codec == codec && track.sampleRate == rate && track.bitDepth == depth)
        #expect(track.isLossless == (codec == "FLAC"))
    }

    @Test("A probed format replaces the listed one and a later sync does not overwrite it")
    func probedFormatSticks() throws {
        let db = try LibraryDatabase.inMemory()
        let source = try #require(try db.tidalSource(userId: 1).id)
        let id = try #require(try db.upsertTidalTracks([input(1, quality: "HI_RES_LOSSLESS")], sourceId: source)[1])
        var track = try #require(try db.allTracks().first)
        #expect(track.codec == "FLAC" && track.sampleRate == 96_000 && track.bitDepth == 24)
        try db.recordProbedFormat(trackId: id, codec: "flac", sampleRate: 192_000, bitDepth: 24, channels: 2)
        #expect(try db.tidalRecord(trackId: id)?.formatIsProbed == true)
        try db.upsertTidalTracks([input(1, title: "Later", quality: "HI_RES_LOSSLESS")], sourceId: source)
        track = try #require(try db.allTracks().first)
        #expect(track.title == "Later")
        #expect(track.codec == "FLAC" && track.sampleRate == 192_000 && track.bitDepth == 24 && track.isLossless)
        // Even if TIDAL now lists it lower, the stream that played is what it is.
        try db.upsertTidalTracks([input(1, quality: "HIGH")], sourceId: source)
        #expect(try db.allTracks().first?.sampleRate == 192_000)
    }

    @Test("Removing what is not in the favorites deletes undownloaded rows and keeps downloaded ones, marked")
    func removal() throws {
        let db = try LibraryDatabase.inMemory()
        let source = try #require(try db.tidalSource(userId: 1).id)
        let ids = try db.upsertTidalTracks((1...4).map { input($0, title: "T\($0)") }, sourceId: source)
        try db.setTidalDownload(tidalId: 2, path: "/Music/TIDAL/Artist/Album/1-02 T2.flac")
        try db.setTidalDownload(tidalId: 3, path: "/Music/TIDAL/Artist/Album/1-03 T3.flac")
        try db.removeTidalTracks(notIn: [1, 3], sourceId: source)
        #expect(Set(try db.allTracks().map(\.title)) == ["T1", "T2", "T3"])
        #expect(try db.tidalRecord(trackId: ids[2]!)?.unavailableReason == "notInFavorites")
        #expect(try db.tidalRecord(trackId: ids[2]!)?.downloadPath == "/Music/TIDAL/Artist/Album/1-02 T2.flac")
        #expect(try db.tidalRecord(trackId: ids[3]!)?.unavailableReason == nil, "still a favorite")
        #expect(try db.tidalRecord(trackId: ids[4]!) == nil)
        #expect(try scalar(db, "SELECT count(*) FROM tidalTrack") == 3)
        // Back in the favorites, it is an ordinary row again.
        try db.upsertTidalTracks([input(2)], sourceId: source)
        #expect(try db.tidalRecord(trackId: ids[2]!)?.unavailableReason == nil)
    }

    @Test("A download is the track's file, and clearing it empties the path again")
    func downloadPath() throws {
        let db = try LibraryDatabase.inMemory()
        let source = try #require(try db.tidalSource(userId: 1).id)
        let id = try #require(try db.upsertTidalTracks([input(5)], sourceId: source)[5])
        try db.setTidalDownload(tidalId: 5, path: "/Music/TIDAL/x.flac")
        #expect(try db.allTracks().first?.filePath == "/Music/TIDAL/x.flac")
        #expect(try db.tidalRecord(trackId: id)?.downloadPath == "/Music/TIDAL/x.flac")
        // A sync does not forget it.
        try db.upsertTidalTracks([input(5, title: "Renamed")], sourceId: source)
        #expect(try db.allTracks().first?.filePath == "/Music/TIDAL/x.flac")
        try db.setTidalDownload(tidalId: 5, path: nil)
        #expect(try db.allTracks().first?.filePath == "")
        #expect(try db.tidalRecord(trackId: id)?.downloadPath == nil)
        try db.setTidalDownload(tidalId: 404, path: "/nowhere.flac")   // not a track: nothing happens
    }

    @Test("TIDAL tracks show in the albums query beside local tracks of the same album")
    func albumsAlongsideLocal() throws {
        let db = try LibraryDatabase.inMemory()
        let tidal = try #require(try db.tidalSource(userId: 1).id)
        try db.writer.write { db in
            try db.execute(sql: "INSERT INTO source (path, mode, addedAt) VALUES ('/Music', 'reference', '2025-01-01 00:00:00.000')")
            try db.execute(sql: """
                INSERT INTO track (sourceId, location, filePath, fileSize, modifiedAt, addedAt, codec, isLossless, isDSD, sampleRate, bitDepth, channels,
                                   duration, title, artist, album, albumArtist)
                VALUES (2, '/Music/a.flac', '/Music/a.flac', 10, '2025-01-01 00:00:00.000', '2025-01-02 00:00:00.000', 'FLAC', 1, 0, 44100, 16, 2, 100,
                        'Local', 'Other', 'Elsewhere', 'Other')
                """)
        }
        try db.upsertTidalTracks([input(1, album: "Streamed", artist: "Artist"), input(2, album: "Streamed", artist: "Artist"),
                                  input(3, album: "Elsewhere", artist: "Other")], sourceId: tidal)
        let albums = try db.albums()
        #expect(albums.map(\.title).sorted() == ["Elsewhere", "Streamed"])
        let streamed = try #require(albums.first { $0.title == "Streamed" })
        #expect(streamed.trackCount == 2 && streamed.artworkKey == "tidal:ab-cd")
        let elsewhere = try #require(albums.first { $0.title == "Elsewhere" })
        #expect(elsewhere.trackCount == 2, "the local song and the TIDAL one are one album")
    }

    @Test("Removing the TIDAL source takes its tracks and their records with it")
    func sourceCascade() throws {
        let db = try LibraryDatabase.inMemory()
        let source = try #require(try db.tidalSource(userId: 1).id)
        try db.upsertTidalTracks([input(1), input(2)], sourceId: source)
        try db.removeSource(source)
        #expect(try scalar(db, "SELECT count(*) FROM track") == 0)
        #expect(try scalar(db, "SELECT count(*) FROM tidalTrack") == 0)
    }

    @Test("Scanning the TIDAL source does nothing: it is no folder")
    func scanIgnoresTidal() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = try LibraryDatabase.inMemory()
        let source = try db.tidalSource(userId: 1)
        try db.upsertTidalTracks([input(1)], sourceId: try #require(source.id))
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        let summary = try await scanner.scan(source)
        #expect(summary.added == 0 && summary.missing == 0 && !summary.interrupted)
        #expect(try db.sources().first?.isOnline == true)
        #expect(try db.allTracks().first?.isMissing == false)
    }
}
