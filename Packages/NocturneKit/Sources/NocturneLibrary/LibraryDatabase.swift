//
// Nocturne — the library database (SQLite via GRDB).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB

public final class LibraryDatabase: Sendable {
    public let writer: any DatabaseWriter

    /// Opens (or creates) the library at `url`.
    public convenience init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        try self.init(writer: DatabasePool(path: url.path, configuration: config))
    }

    public static func inMemory() throws -> LibraryDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try LibraryDatabase(writer: DatabaseQueue(configuration: config))
    }

    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nocturne", isDirectory: true)
            .appendingPathComponent("Library.sqlite")
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "source") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("bookmark", .blob)
                t.column("mode", .text).notNull()
                t.column("addedAt", .datetime).notNull()
                t.column("lastScannedAt", .datetime)
                t.column("isOnline", .boolean).notNull().defaults(to: true)
            }

            try db.create(table: "track") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("source", onDelete: .cascade)
                t.column("location", .text).notNull().unique()
                t.column("filePath", .text).notNull().indexed()
                t.column("fileSize", .integer).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("addedAt", .datetime).notNull().indexed()

                t.column("codec", .text).notNull()
                t.column("isLossless", .boolean).notNull()
                t.column("isDSD", .boolean).notNull()
                t.column("sampleRate", .double).notNull()
                t.column("bitDepth", .integer)
                t.column("channels", .integer).notNull()
                t.column("duration", .double).notNull()
                t.column("bitrate", .double)
                t.column("cueStartFrame", .integer)
                t.column("cueFrameLength", .integer)

                t.column("title", .text).notNull()
                for c in ["artist", "album", "albumArtist", "composer", "genre", "releaseDate", "grouping", "comment",
                          "lyrics", "isrc", "label", "musicBrainzReleaseID", "musicBrainzRecordingID",
                          "titleSort", "artistSort", "albumSort", "albumArtistSort", "artworkKey", "analysisVerdict"] {
                    t.column(c, .text)
                }
                for c in ["year", "trackNumber", "trackTotal", "discNumber", "discTotal", "bpm", "rating", "effectiveBitDepth"] {
                    t.column(c, .integer)
                }
                t.column("compilation", .boolean).notNull().defaults(to: false)
                t.column("extraTags", .jsonText).notNull().defaults(to: "{}")
                for c in ["rgTrackGain", "rgTrackPeak", "rgAlbumGain", "rgAlbumPeak", "bandwidthHz"] {
                    t.column(c, .double)
                }
                t.column("playCount", .integer).notNull().defaults(to: 0)
                t.column("lastPlayedAt", .datetime)
                t.column("isMissing", .boolean).notNull().defaults(to: false)

                // Grouping/sorting keys used by album and artist views.
                t.column("albumArtistSortKey", .text)
                    .generatedAs(sql: "lower(coalesce(albumArtistSort, albumArtist, artistSort, artist, 'Unknown Artist'))", .virtual)
                t.column("albumSortKey", .text)
                    .generatedAs(sql: "lower(coalesce(albumSort, album, 'Unknown Album'))", .virtual)
                t.column("albumKey", .text)
                    .generatedAs(sql: "lower(coalesce(albumArtist, artist, 'Unknown Artist')) || char(31) || lower(coalesce(album, 'Unknown Album'))", .stored)
            }
            try db.create(index: "track_albumKey", on: "track", columns: ["albumKey"])

            try db.create(virtualTable: "trackFts", using: FTS5()) { t in
                t.synchronize(withTable: "track")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("title")
                t.column("artist")
                t.column("album")
                t.column("albumArtist")
                t.column("composer")
                t.column("genre")
            }

            try db.create(table: "playlist") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("smartRules", .jsonText)
                t.column("createdAt", .datetime).notNull()
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "playlistItem") { t in
                t.belongsTo("playlist", onDelete: .cascade).notNull()
                t.belongsTo("track", onDelete: .cascade).notNull()
                t.column("position", .integer).notNull()
                t.primaryKey(["playlistId", "position"])
            }
            try db.create(table: "tagHistory") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("track", onDelete: .cascade).notNull()
                t.column("editedAt", .datetime).notNull()
                t.column("previous", .jsonText).notNull()
                t.column("fileBackupPath", .text)
            }

            // Starter smart playlists.
            var hiRes = Playlist(name: "Hi-Res ≥ 88.2 kHz", smartRules: .hiRes, sortIndex: 0)
            try hiRes.insert(db)
            var suspect = Playlist(name: "Suspect Hi-Res", smartRules: .suspect, sortIndex: 1)
            try suspect.insert(db)
        }
        m.registerMigration("v2-network-shares") { db in
            try db.alter(table: "source") { t in
                t.add(column: "remoteURL", .text)
                t.add(column: "name", .text)
                t.add(column: "isWritable", .boolean).notNull().defaults(to: false)
            }
        }
        return m
    }
}

// MARK: - Queries

public enum AlbumSort: String, Sendable, CaseIterable {
    case artist, title, year, recentlyAdded
}

public extension LibraryDatabase {
    static func albumsSQL(sort: AlbumSort, filter: String = "1") -> String {
        let order: String = switch sort {
        case .artist: "artistKey, year, titleKey"
        case .title: "titleKey"
        case .year: "year DESC, artistKey"
        case .recentlyAdded: "addedAt DESC"
        }
        return """
        SELECT albumKey AS key,
               coalesce(album, 'Unknown Album') AS title,
               coalesce(albumArtist, artist, 'Unknown Artist') AS artist,
               max(year) AS year, max(genre) AS genre,
               count(*) AS trackCount, sum(duration) AS duration,
               max(artworkKey) AS artworkKey,
               max(isDSD) AS isDSD, max(sampleRate) AS maxRate, max(bitDepth) AS maxBits,
               max(codec) AS codec, min(isLossless) AS lossless, max(bitrate) AS bitrate,
               max(addedAt) AS addedAt, sum(fileSize) AS totalSize, min(filePath) AS anyPath,
               min(albumArtistSortKey) AS artistKey, min(albumSortKey) AS titleKey
        FROM track WHERE isMissing = 0 AND (\(filter))
        GROUP BY albumKey ORDER BY \(order)
        """
    }

    static func album(from row: Row) -> Album {
        let isDSD: Bool = row["isDSD"]
        let rate: Double = row["maxRate"]
        let bits: Int? = row["maxBits"]
        let codec: String = row["codec"]
        let lossless: Bool = row["lossless"]
        let bitrate: Double? = row["bitrate"]
        let rateText = rate.truncatingRemainder(dividingBy: 1000) == 0 ? String(Int(rate / 1000)) : String(format: "%.1f", rate / 1000)
        let summary: String = if isDSD {
            "DSD\(Int((rate / 44_100).rounded()))"
        } else if !lossless, let bitrate {
            "\(codec) · \(Int(bitrate))k"
        } else if let bits {
            "\(codec) · \(bits)/\(rateText)"
        } else {
            "\(codec) · \(rateText) kHz"
        }
        return Album(key: row["key"], title: row["title"], artist: row["artist"], year: row["year"], genre: row["genre"],
                     trackCount: row["trackCount"], duration: row["duration"], artworkKey: row["artworkKey"],
                     formatSummary: summary, codec: codec, maxBitDepth: bits, maxSampleRate: rate, isHiRes: isDSD || (lossless && ((bits ?? 16) > 16 || rate > 48_000)),
                     isDSD: isDSD, addedAt: row["addedAt"], totalSize: row["totalSize"],
                     sourcePath: (row["anyPath"] as String?).map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
    }

    func albums(sort: AlbumSort = .artist) throws -> [Album] {
        try writer.read { db in try Row.fetchAll(db, sql: Self.albumsSQL(sort: sort)).map(Self.album(from:)) }
    }

    func tracks(albumKey: String) throws -> [Track] {
        try writer.read { db in
            try Track.fetchAll(db, sql: "SELECT * FROM track WHERE albumKey = ? ORDER BY discNumber, trackNumber, location", arguments: [albumKey])
        }
    }

    func albums(artist: String) throws -> [Album] {
        try writer.read { db in
            try Row.fetchAll(db, sql: Self.albumsSQL(sort: .year, filter: "lower(coalesce(albumArtist, artist, 'Unknown Artist')) = lower(?)"),
                             arguments: [artist]).map(Self.album(from:))
        }
    }

    func albums(underPath path: String) throws -> [Album] {
        try writer.read { db in
            try Row.fetchAll(db, sql: Self.albumsSQL(sort: .artist, filter: "filePath LIKE ? || '%'"), arguments: [path]).map(Self.album(from:))
        }
    }

    func allTracks() throws -> [Track] {
        try writer.read { db in
            try Track.fetchAll(db, sql: "SELECT * FROM track WHERE isMissing = 0 ORDER BY albumArtistSortKey, albumSortKey, discNumber, trackNumber")
        }
    }

    func tracks(ids: [Int64]) throws -> [Track] {
        try writer.read { db in
            let byID = Dictionary(uniqueKeysWithValues: try Track.fetchAll(db, keys: ids).compactMap { t in t.id.map { ($0, t) } })
            return ids.compactMap { byID[$0] }
        }
    }

    /// Full-text search across title/artist/album/composer/genre. Prefix matching on every word.
    func search(_ text: String, limit: Int = 500) throws -> [Track] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: text) else { return [] }
        return try writer.read { db in
            try Track.fetchAll(db, sql: """
                SELECT track.* FROM track JOIN trackFts ON trackFts.rowid = track.id
                WHERE trackFts MATCH ? AND track.isMissing = 0 ORDER BY rank LIMIT ?
                """, arguments: [pattern, limit])
        }
    }

    struct ArtistSummary: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public var name: String
        public var albumCount: Int
        public var trackCount: Int
        public var artworkKey: String?

        public init(name: String, albumCount: Int, trackCount: Int, artworkKey: String?) {
            self.name = name
            self.albumCount = albumCount
            self.trackCount = trackCount
            self.artworkKey = artworkKey
        }
    }

    func artists() throws -> [ArtistSummary] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT coalesce(albumArtist, artist, 'Unknown Artist') AS name, count(DISTINCT albumKey) AS albums,
                       count(*) AS tracks, max(artworkKey) AS art
                FROM track WHERE isMissing = 0 GROUP BY lower(name) ORDER BY min(albumArtistSortKey)
                """).map { ArtistSummary(name: $0["name"], albumCount: $0["albums"], trackCount: $0["tracks"], artworkKey: $0["art"]) }
        }
    }

    func playlists() throws -> [Playlist] {
        try writer.read { db in try Playlist.order(Column("sortIndex"), Column("name")).fetchAll(db) }
    }

    func tracks(in playlist: Playlist) throws -> [Track] {
        try writer.read { db in
            if let rules = playlist.smartRules {
                let (clause, args) = rules.sql()
                var sql = "SELECT * FROM track WHERE isMissing = 0 AND (\(clause)) ORDER BY \(rules.orderBy)"
                if let limit = rules.limit { sql += " LIMIT \(limit)" }
                return try Track.fetchAll(db, sql: sql, arguments: args)
            }
            guard let id = playlist.id else { return [] }
            return try Track.fetchAll(db, sql: """
                SELECT track.* FROM playlistItem JOIN track ON track.id = playlistItem.trackId
                WHERE playlistItem.playlistId = ? ORDER BY playlistItem.position
                """, arguments: [id])
        }
    }

    @discardableResult
    func createPlaylist(name: String, rules: SmartRules? = nil) throws -> Playlist {
        try writer.write { db in
            let next = (try Int.fetchOne(db, sql: "SELECT max(sortIndex) FROM playlist") ?? 0) + 1
            var p = Playlist(name: name, smartRules: rules, sortIndex: next)
            try p.insert(db)
            return p
        }
    }

    func append(trackIDs: [Int64], to playlistID: Int64) throws {
        try writer.write { db in
            var position = (try Int.fetchOne(db, sql: "SELECT max(position) FROM playlistItem WHERE playlistId = ?", arguments: [playlistID]) ?? -1) + 1
            for id in trackIDs {
                try PlaylistItem(playlistId: playlistID, trackId: id, position: position).insert(db)
                position += 1
            }
        }
    }

    /// Rewrites a manual playlist's order.
    func setPlaylistTracks(_ trackIDs: [Int64], playlistID: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM playlistItem WHERE playlistId = ?", arguments: [playlistID])
            for (i, id) in trackIDs.enumerated() {
                try PlaylistItem(playlistId: playlistID, trackId: id, position: i).insert(db)
            }
        }
    }

    func deletePlaylist(_ id: Int64) throws {
        _ = try writer.write { db in try Playlist.deleteOne(db, key: id) }
    }

    func renamePlaylist(_ id: Int64, to name: String) throws {
        try writer.write { db in try db.execute(sql: "UPDATE playlist SET name = ? WHERE id = ?", arguments: [name, id]) }
    }

    func updateSmartRules(_ id: Int64, _ rules: SmartRules) throws {
        try writer.write { db in
            guard var p = try Playlist.fetchOne(db, key: id) else { return }
            p.smartRules = rules
            try p.update(db)
        }
    }

    func sources() throws -> [LibrarySource] {
        try writer.read { db in try LibrarySource.order(Column("path")).fetchAll(db) }
    }

    @discardableResult
    func addSource(_ source: LibrarySource) throws -> LibrarySource {
        try writer.write { db in
            if let existing = try LibrarySource.filter(Column("path") == source.path).fetchOne(db) { return existing }
            var s = source
            try s.insert(db)
            return s
        }
    }

    /// Points a source (and every track in it) at a new local root, e.g. when a share
    /// comes back mounted somewhere else. Library state (plays, ratings, playlists) is kept.
    public func relinkSource(_ id: Int64, to newPath: String) throws {
        try writer.write { db in
            guard let source = try LibrarySource.fetchOne(db, key: id), source.path != newPath else { return }
            let old = source.path
            try db.execute(sql: """
                UPDATE track SET location = ? || substr(location, ?), filePath = ? || substr(filePath, ?)
                WHERE sourceId = ? AND substr(filePath, 1, ?) = ?
                """, arguments: [newPath, old.unicodeScalars.count + 1, newPath, old.unicodeScalars.count + 1, id, old.unicodeScalars.count, old])
            try db.execute(sql: "UPDATE source SET path = ? WHERE id = ?", arguments: [newPath, id])
        }
    }

    public func setSourceOnline(_ id: Int64, _ online: Bool) throws {
        try writer.write { db in try db.execute(sql: "UPDATE source SET isOnline = ? WHERE id = ?", arguments: [online, id]) }
    }

    func removeSource(_ id: Int64) throws {
        _ = try writer.write { db in try LibrarySource.deleteOne(db, key: id) }
    }

    func markPlayed(_ trackID: Int64, at date: Date = .now) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE track SET playCount = playCount + 1, lastPlayedAt = ? WHERE id = ?", arguments: [date, trackID])
        }
    }

    func setRating(_ rating: Int?, trackIDs: [Int64]) throws {
        try writer.write { db in
            for id in trackIDs { try db.execute(sql: "UPDATE track SET rating = ? WHERE id = ?", arguments: [rating, id]) }
        }
    }

    func saveAnalysis(trackID: Int64, effectiveBitDepth: Int?, bandwidthHz: Double, verdict: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE track SET effectiveBitDepth = ?, bandwidthHz = ?, analysisVerdict = ? WHERE id = ?",
                           arguments: [effectiveBitDepth, bandwidthHz, verdict, trackID])
        }
    }

    struct Stats: Sendable, Hashable {
        public var albums: Int
        public var tracks: Int
        public var artists: Int
        public var bytes: Int64
        public var duration: Double

        public init(albums: Int, tracks: Int, artists: Int, bytes: Int64, duration: Double) {
            self.albums = albums
            self.tracks = tracks
            self.artists = artists
            self.bytes = bytes
            self.duration = duration
        }
    }

    func stats() throws -> Stats {
        try writer.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT count(DISTINCT albumKey) AS a, count(*) AS t, count(DISTINCT lower(coalesce(albumArtist, artist))) AS ar,
                       coalesce(sum(fileSize), 0) AS b, coalesce(sum(duration), 0) AS d FROM track WHERE isMissing = 0
                """)!
            return Stats(albums: row["a"], tracks: row["t"], artists: row["ar"], bytes: row["b"], duration: row["d"])
        }
    }
}
