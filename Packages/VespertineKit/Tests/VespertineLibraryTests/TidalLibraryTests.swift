//
// Vespertine: TIDAL tracks in the library: the v23 migration, upserts by TIDAL id, what a sync removes, and (with the scanner) the
// downloaded files that stand in for a stream.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
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

// MARK: - The scanner links downloaded files

/// A FLAC (made by Core Audio) whose Vorbis comments are `comments`, written into the file's metadata blocks.
private func makeTaggedFLAC(_ url: URL, comments: [String: String], seconds: Double = 0.5) throws {
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16]
    do {
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<2 { for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = Float(sin(Double(i) * 0.03)) * 0.3 } }
        try file.write(from: buffer)
    }
    let data = try Data(contentsOf: url)
    precondition(data.prefix(4) == Data("fLaC".utf8))
    var blocks: [(type: UInt8, body: Data)] = []
    var offset = 4
    while true {
        let header = data[offset]
        let length = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
        if header & 0x7F != 4 { blocks.append((header & 0x7F, data.subdata(in: offset + 4..<offset + 4 + length))) }
        offset += 4 + length
        if header & 0x80 != 0 { break }
    }
    func le32(_ n: Int) -> Data { Data([UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24 & 0xFF)]) }
    var vorbis = le32(4) + Data("test".utf8) + le32(comments.count)
    for (key, value) in comments.sorted(by: { $0.key < $1.key }) {
        let entry = Data("\(key)=\(value)".utf8)
        vorbis += le32(entry.count) + entry
    }
    blocks.append((4, vorbis))
    var out = Data("fLaC".utf8)
    for (i, block) in blocks.enumerated() {
        let n = block.body.count
        out.append(block.type | (i == blocks.count - 1 ? 0x80 : 0))
        out.append(contentsOf: [UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        out += block.body
    }
    out += data.subdata(in: offset..<data.count)
    try out.write(to: url)
}

@Suite("Downloaded TIDAL files in a scanned folder")
struct TidalDownloadScanTests {
    private struct Rig {
        var dir: URL
        var db: LibraryDatabase
        var scanner: LibraryScanner
        var source: LibrarySource
        var tidal: Int64
    }

    /// A library with TIDAL tracks 777 and 778, and a folder (the library's only folder source) to scan.
    private func rig() async throws -> Rig {
        let dir = try tempDir()
        let db = try LibraryDatabase.inMemory()
        let tidal = try #require(try db.tidalSource(userId: 1).id)
        try db.upsertTidalTracks([input(777, title: "Streamed One", album: "Album", artist: "Artist"),
                                  input(778, title: "Streamed Two", album: "Album", artist: "Artist")], sourceId: tidal)
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference))
        return Rig(dir: dir, db: db, scanner: scanner, source: source, tidal: tidal)
    }

    private func download(_ rig: Rig, tidalId: Int) throws -> TidalTrackRecord {
        let id = try #require(try rig.db.writer.read { try Int64.fetchOne($0, sql: "SELECT trackId FROM tidalTrack WHERE tidalId = ?", arguments: [tidalId]) })
        return try #require(try rig.db.tidalRecord(trackId: id))
    }

    @Test("A tagged file for a TIDAL track in the library adds no track and becomes its download")
    func linksInsteadOfAdding() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let file = rig.dir.appendingPathComponent("Artist/Album/1-01 Streamed One.flac")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeTaggedFLAC(file, comments: ["TITLE": "Streamed One", "ARTIST": "Artist", "ALBUM": "Album", "TIDAL_TRACK_ID": "777"])
        let summary = try await rig.scanner.scan(rig.source)
        #expect(summary.added == 0 && summary.linked == 1 && summary.failed.isEmpty)
        #expect(try rig.db.allTracks().count == 2, "the two TIDAL tracks, and no third for the file")
        let record = try download(rig, tidalId: 777)
        let path = try #require(record.downloadPath)
        #expect(URL(fileURLWithPath: path).resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
        let track = try #require(try rig.db.tracks(ids: [record.trackId]).first)
        #expect(track.filePath == path && track.location == "tidal://track/777" && track.fileSize > 0)
        #expect(record.formatIsProbed && track.codec == "FLAC" && track.sampleRate == 44_100)
        #expect(try download(rig, tidalId: 778).downloadPath == nil)
    }

    @Test("Scanning again changes nothing")
    func rescanIsIdempotent() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        try makeTaggedFLAC(rig.dir.appendingPathComponent("a.flac"), comments: ["TITLE": "A", "TIDAL_TRACK_ID": "777"])
        try await rig.scanner.scan(rig.source)
        let before = try rig.db.allTracks()
        let path = try download(rig, tidalId: 777).downloadPath
        for _ in 0..<2 {
            let summary = try await rig.scanner.scan(rig.source)
            #expect(summary.added == 0 && summary.updated == 0 && summary.linked == 0 && summary.missing == 0, "the file is found as it was")
        }
        #expect(try rig.db.allTracks() == before)
        #expect(try download(rig, tidalId: 777).downloadPath == path)
        // Even when the file is read again (its date moved) it links to the same track instead of adding one.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(100)], ofItemAtPath: rig.dir.appendingPathComponent("a.flac").path)
        let touched = try await rig.scanner.scan(rig.source)
        #expect(touched.added == 0 && touched.linked == 1)
        #expect(try rig.db.allTracks().count == 2)
    }

    @Test("A file the downloader linked is not read as a new track either")
    func downloaderLinkFirst() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let file = rig.dir.appendingPathComponent("b.flac")
        try makeTaggedFLAC(file, comments: ["TITLE": "B", "TIDAL_TRACK_ID": "778"])
        try rig.db.setTidalDownload(tidalId: 778, path: file.path)
        let summary = try await rig.scanner.scan(rig.source)
        #expect(summary.added == 0 && summary.missing == 0)
        #expect(try rig.db.allTracks().count == 2)
        #expect(try download(rig, tidalId: 778).downloadPath != nil)
    }

    @Test("When the file is deleted, a rescan clears the download and keeps the track")
    func deletedFileUnlinks() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let file = rig.dir.appendingPathComponent("a.flac")
        try makeTaggedFLAC(file, comments: ["TITLE": "A", "TIDAL_TRACK_ID": "777"])
        try await rig.scanner.scan(rig.source)
        let record = try download(rig, tidalId: 777)
        #expect(record.downloadPath != nil)
        try FileManager.default.removeItem(at: file)
        let summary = try await rig.scanner.scan(rig.source)
        #expect(summary.added == 0 && summary.missing == 0)
        #expect(try download(rig, tidalId: 777).downloadPath == nil)
        let track = try #require(try rig.db.tracks(ids: [record.trackId]).first)
        #expect(track.filePath == "" && !track.isMissing && track.location == "tidal://track/777")
        #expect(try rig.db.allTracks().count == 2)
        // And the file coming back links again.
        try makeTaggedFLAC(file, comments: ["TITLE": "A", "TIDAL_TRACK_ID": "777"])
        try await rig.scanner.scan(rig.source)
        #expect(try download(rig, tidalId: 777).downloadPath != nil)
    }

    @Test("A tag that names no TIDAL track in the library gives an ordinary track")
    func unmatchedTagIsInserted() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        try makeTaggedFLAC(rig.dir.appendingPathComponent("c.flac"), comments: ["TITLE": "Stranger", "ARTIST": "Someone", "TIDAL_TRACK_ID": "9999"])
        try makeTaggedFLAC(rig.dir.appendingPathComponent("d.flac"), comments: ["TITLE": "Untagged", "ARTIST": "Someone"])
        let summary = try await rig.scanner.scan(rig.source)
        #expect(summary.added == 2 && summary.linked == 0)
        let local = try rig.db.allTracks().filter { $0.sourceId == rig.source.id }
        #expect(Set(local.map(\.title)) == ["Stranger", "Untagged"])
        #expect(local.first { $0.title == "Stranger" }?.extraTags["TIDAL_TRACK_ID"] == "9999")
    }

    @Test("A download outside the scanned folder is not touched by its scan")
    func outsideFolderUntouched() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        try rig.db.setTidalDownload(tidalId: 777, path: "/Elsewhere/TIDAL/gone.flac")
        let summary = try await rig.scanner.scan(rig.source)
        #expect(summary.missing == 0)
        #expect(try download(rig, tidalId: 777).downloadPath == "/Elsewhere/TIDAL/gone.flac")
    }
}

@Suite("TIDAL sync storage: duplicates, merges and playlists")
struct TidalSyncStorageTests {
    private func scalar(_ db: LibraryDatabase, _ sql: String, _ arguments: StatementArguments = []) throws -> Int? {
        try db.writer.read { try Int.fetchOne($0, sql: sql, arguments: arguments) }
    }

    @Test("An input listing a track twice stores it once, as its last description")
    func duplicateInputs() throws {
        let db = try LibraryDatabase.inMemory()
        let source = try #require(try db.tidalSource(userId: 1).id)
        let ids = try db.upsertTidalTracks([input(5, title: "First"), input(6), input(5, title: "Last")], sourceId: source)
        #expect(ids.count == 2)
        #expect(try scalar(db, "SELECT count(*) FROM tidalTrack") == 2)
        #expect(try db.allTracks().contains { $0.title == "Last" })
        #expect(try !db.allTracks().contains { $0.title == "First" })
        #expect(try db.tidalTrackIds() == [5, 6])
    }

    @Test("A local file tagged with a TIDAL id becomes that TIDAL row's download, bringing its playlists, favorite and plays")
    func mergesTaggedLocalTrack() throws {
        let db = try LibraryDatabase.inMemory()
        let folder = try db.addSource(LibrarySource(path: "/Music", mode: .reference))
        var local = Track.stub(path: "/Music/TIDAL/A/1-01 Song.flac")
        local.sourceId = folder.id
        local.extraTags = ["TIDAL_TRACK_ID": "77"]
        local.playCount = 3
        local.fileSize = 1234
        local.sampleRate = 192_000
        try db.writer.write { try local.insert($0) }
        let localId = try #require(local.id)
        let playlist = try db.createPlaylist(name: "Mine")
        try db.append(trackIDs: [localId], to: try #require(playlist.id))
        try db.setFavorite(true, trackIDs: [localId])
        try db.writer.write { try $0.execute(sql: "INSERT INTO playHistory (trackId, playedAt) VALUES (?, ?)", arguments: [localId, Date()]) }

        let source = try #require(try db.tidalSource(userId: 1).id)
        let ids = try db.upsertTidalTracks([input(77)], sourceId: source)
        let tidalTrack = try #require(ids[77])
        #expect(try scalar(db, "SELECT count(*) FROM track WHERE id = ?", [localId]) == 0, "the plain row is gone")
        #expect(try scalar(db, "SELECT count(*) FROM track") == 1)
        let record = try #require(try db.tidalRecord(trackId: tidalTrack))
        #expect(record.downloadPath == "/Music/TIDAL/A/1-01 Song.flac" && record.formatIsProbed)
        let merged = try #require(try db.allTracks().first)
        #expect(merged.filePath == "/Music/TIDAL/A/1-01 Song.flac" && merged.sampleRate == 192_000 && merged.playCount == 3)
        #expect(try db.tracks(in: playlist).map(\.id) == [tidalTrack])
        #expect(try db.favoriteTracks().map(\.id) == [tidalTrack])
        #expect(try scalar(db, "SELECT count(*) FROM playHistory WHERE trackId = ?", [tidalTrack]) == 1)
        // A second sync changes nothing.
        _ = try db.upsertTidalTracks([input(77)], sourceId: source)
        #expect(try scalar(db, "SELECT count(*) FROM track") == 1)
    }

    @Test("A TIDAL playlist maps to one library playlist, in TIDAL's order, renamed and refilled in place; gone playlists go")
    func playlists() throws {
        let db = try LibraryDatabase.inMemory()
        let source = try #require(try db.tidalSource(userId: 1).id)
        try db.upsertTidalTracks([input(1), input(2), input(3)], sourceId: source)
        let id = try db.setTidalPlaylist(uuid: "uuid-a", name: "Road", lastUpdated: "2026-01-01", tidalIds: [3, 1, 2, 99])
        #expect(try db.tidalPlaylistStates() == ["uuid-a": "2026-01-01"])
        let playlist = try #require(try db.playlists().first { $0.id == id })
        #expect(playlist.name == "Road")
        #expect(try db.tracks(in: playlist).map(\.trackNumber) == [3, 1, 2], "unknown ids are skipped")
        #expect(try db.tidalIds(inPlaylist: "uuid-a") == [3, 1, 2])
        let again = try db.setTidalPlaylist(uuid: "uuid-a", name: "Road trip", lastUpdated: "2026-02-01", tidalIds: [2])
        #expect(again == id)
        let renamed = try db.playlists().filter { !$0.isSmart }
        #expect(renamed.map(\.name) == ["Road trip"])
        #expect(try db.tidalIds(inPlaylist: "uuid-a") == [2])
        try db.removeTidalPlaylists(notIn: [])
        let left = try db.playlists().filter { !$0.isSmart }, states = try db.tidalPlaylistStates()
        #expect(left.isEmpty && states.isEmpty)
    }
}
