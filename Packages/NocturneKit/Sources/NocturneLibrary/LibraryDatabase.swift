//
// Nocturne — the library database (SQLite via GRDB).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import NocturneAudio

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
        m.registerMigration("v2-cue-state") { db in
            try db.create(table: "cueScanState") { t in
                t.belongsTo("source", onDelete: .cascade).notNull()
                t.column("filePath", .text).notNull()
                t.column("signature", .text).notNull()
                t.primaryKey(["sourceId", "filePath"])
            }
        }
        m.registerMigration("v3-cue-overrides") { db in
            try db.create(table: "cueTagOverride") { t in
                t.belongsTo("track", onDelete: .cascade).notNull()
                t.primaryKey(["trackId"])
                t.column("metadata", .blob).notNull()
            }
        }
        m.registerMigration("v5-analysis-store") { db in
            try db.create(table: "analysis") { t in
                t.primaryKey("trackId", .integer).references("track", onDelete: .cascade)
                t.column("fileSize", .integer).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("version", .integer).notNull()
                t.column("analyzedAt", .datetime).notNull()
                t.column("data", .blob).notNull()
            }
            // Verdicts from the first analyzer flagged natural roll-offs as lossy and missed synthetic
            // high frequencies; clear them so tracks are re-analyzed with the calibrated forensics.
            try db.execute(sql: "UPDATE track SET analysisVerdict = NULL, effectiveBitDepth = NULL, bandwidthHz = NULL")
            let old = SmartRules(match: .any, rules: [
                SmartRule(field: .verdict, op: .equals, value: "upsampled"),
                SmartRule(field: .verdict, op: .equals, value: "paddedBitDepth"),
                SmartRule(field: .verdict, op: .equals, value: "possibleLossyOrigin"),
            ])
            for var playlist in try Playlist.filter(Column("name") == "Suspect Hi-Res").fetchAll(db) where playlist.smartRules == old {
                playlist.smartRules = .suspect
                try playlist.update(db)
            }
        }
        m.registerMigration("v2-network-shares") { db in
            try db.alter(table: "source") { t in
                t.add(column: "remoteURL", .text)
                t.add(column: "name", .text)
                t.add(column: "isWritable", .boolean).notNull().defaults(to: false)
            }
        }
        m.registerMigration("v6-multichannel-analysis") { db in
            // Before 0.5.3, analysis read multichannel files as silence and called them genuine.
            // Forget those results so the tracks are analyzed again, channel for channel.
            try db.execute(sql: "DELETE FROM analysis WHERE trackId IN (SELECT id FROM track WHERE channels > 2)")
            try db.execute(sql: "UPDATE track SET analysisVerdict = NULL, effectiveBitDepth = NULL, bandwidthHz = NULL WHERE channels > 2")
        }
        m.registerMigration("v7-dts-recheck") { db in
            // Before 0.5.15, DTS CDs (a DTS bitstream stored as 16-bit stereo PCM) were read as stereo PCM.
            // Re-read the likely ones on the next scan (a changed date forces it); files scanned from now on
            // are checked as they're read.
            try db.execute(sql: """
                UPDATE track SET modifiedAt = '1970-01-01 00:00:00.000'
                WHERE channels = 2 AND bitDepth = 16 AND sampleRate IN (44100, 48000) AND isLossless = 1
                  AND (codec = 'WAV' OR filePath LIKE '%DTS%' OR album LIKE '%DTS%')
                """)
            // Analyses of those files treated the bitstream as audio.
            try db.execute(sql: """
                DELETE FROM analysis WHERE trackId IN (SELECT id FROM track WHERE modifiedAt = '1970-01-01 00:00:00.000')
                """)
        }
        m.registerMigration("v8-original-year") { db in
            // Before 0.5.15 the year came from DATE, which reissues and remasters set to their own date.
            // Prefer the original release date already read into extraTags.
            try db.execute(sql: """
                UPDATE track SET year = (
                    SELECT CAST(substr(o, 1, 4) AS INTEGER) FROM (SELECT coalesce(
                        json_extract(extraTags, '$.ORIGINALDATE'), json_extract(extraTags, '$.ORIGINALYEAR'),
                        json_extract(extraTags, '$."ORIGINAL DATE"'), json_extract(extraTags, '$."ORIGINAL YEAR"')) AS o))
                WHERE json_valid(extraTags) AND coalesce(
                        json_extract(extraTags, '$.ORIGINALDATE'), json_extract(extraTags, '$.ORIGINALYEAR'),
                        json_extract(extraTags, '$."ORIGINAL DATE"'), json_extract(extraTags, '$."ORIGINAL YEAR"')) GLOB '[12][0-9][0-9][0-9]*'
                  AND (year IS NULL OR CAST(substr(coalesce(
                        json_extract(extraTags, '$.ORIGINALDATE'), json_extract(extraTags, '$.ORIGINALYEAR'),
                        json_extract(extraTags, '$."ORIGINAL DATE"'), json_extract(extraTags, '$."ORIGINAL YEAR"')), 1, 4) AS INTEGER) <= year)
                """)
        }
        m.registerMigration("v9-artwork-recheck") { db in
            // 0.5.16 also finds art stored as a METADATA_BLOCK_PICTURE comment and covers next to disc
            // folders ("Album/CD 01"): re-read the tracks that have none on the next scan.
            try db.execute(sql: "UPDATE track SET modifiedAt = '1970-01-01 00:00:00.000' WHERE artworkKey IS NULL AND isMissing = 0")
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
               max(year) AS year, group_concat(DISTINCT genre) AS genre,
               count(*) AS trackCount, sum(duration) AS duration,
               max(artworkKey) AS artworkKey,
               max(isDSD) AS isDSD, max(sampleRate) AS maxRate, max(bitDepth) AS maxBits, max(channels) AS maxChannels,
               max(codec) AS codec, min(isLossless) AS lossless, max(bitrate) AS bitrate,
               max(addedAt) AS addedAt,
               -- a CUE-split file counts once (with its first track), not once per track
               sum(CASE WHEN cueStartFrame IS NULL OR cueStartFrame = 0 THEN fileSize ELSE 0 END) AS totalSize, min(filePath) AS anyPath,
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
        let maxChannels: Int = row["maxChannels"] ?? 2
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
        let channelText = maxChannels > 2 ? " · " + ChannelLayouts.name(channels: maxChannels) : ""
        return Album(key: row["key"], title: row["title"], artist: row["artist"], year: row["year"], genre: row["genre"],
                     trackCount: row["trackCount"], duration: row["duration"], artworkKey: row["artworkKey"],
                     formatSummary: summary + channelText, codec: codec, maxBitDepth: bits, maxSampleRate: rate, isHiRes: isDSD || (lossless && ((bits ?? 16) > 16 || rate > 48_000)),
                     isDSD: isDSD, addedAt: row["addedAt"], totalSize: row["totalSize"],
                     sourcePath: (row["anyPath"] as String?).map { ($0 as NSString).deletingLastPathComponent },
                     maxChannels: maxChannels)
    }

    func albums(sort: AlbumSort = .artist) throws -> [Album] {
        try writer.read { db in try Row.fetchAll(db, sql: Self.albumsSQL(sort: sort)).map(Self.album(from:)) }
    }

    func tracks(albumKey: String) throws -> [Track] {
        try writer.read { db in
            try Track.fetchAll(db, sql: "SELECT * FROM track WHERE albumKey = ? AND isMissing = 0 ORDER BY discNumber, trackNumber, location", arguments: [albumKey])
        }
    }

    func albums(artist: String) throws -> [Album] {
        try writer.read { db in
            try Row.fetchAll(db, sql: Self.albumsSQL(sort: .year, filter: "lower(coalesce(albumArtist, artist, 'Unknown Artist')) = lower(?)"),
                             arguments: [artist]).map(Self.album(from:))
        }
    }

    func albums(underPath path: String) throws -> [Album] {
        let folder = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let prefix = folder == "/" ? "/" : folder + "/"
        return try writer.read { db in
            try Row.fetchAll(db, sql: Self.albumsSQL(sort: .artist, filter: "substr(filePath, 1, length(?)) = ?"),
                             arguments: [prefix, prefix]).map(Self.album(from:))
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
                WHERE playlistItem.playlistId = ? AND track.isMissing = 0 ORDER BY playlistItem.position
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

    public func sources() throws -> [LibrarySource] {
        try writer.read { db in try LibrarySource.order(Column("path")).fetchAll(db) }
    }

    @discardableResult
    func addSource(_ source: LibrarySource) throws -> LibrarySource {
        try writer.write { db in
            let canonical = source.url.resolvingSymlinksInPath().path
            let sources = try LibrarySource.fetchAll(db)
            for existing in sources {
                let path = existing.url.resolvingSymlinksInPath().path
                if canonical == path || canonical.hasPrefix(path == "/" ? "/" : path + "/") { return existing }
                if path.hasPrefix(canonical == "/" ? "/" : canonical + "/") {
                    throw SourceOverlapError(path: existing.path)
                }
            }
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

    /// A saved analysis and whether it still describes the file (same file, same analyzer).
    public struct StoredAnalysis: Sendable {
        public var analysis: FileAnalysis
        public var analyzedAt: Date
        public var isCurrent: Bool
    }

    /// Saves a full analysis for every track that plays from `filePath` (CUE tracks share a file).
    public func saveAnalysis(_ analysis: FileAnalysis, filePath: String) throws {
        let data = try JSONEncoder().encode(analysis)
        try writer.write { db in
            for track in try Track.filter(Column("filePath") == filePath).fetchAll(db) {
                guard let id = track.id else { continue }
                try db.execute(sql: """
                    INSERT OR REPLACE INTO analysis (trackId, fileSize, modifiedAt, version, analyzedAt, data)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [id, track.fileSize, track.modifiedAt, analysis.version, Date(), data])
                try db.execute(sql: "UPDATE track SET effectiveBitDepth = ?, bandwidthHz = ?, analysisVerdict = ? WHERE id = ?",
                               arguments: [analysis.effectiveBitDepth, analysis.bandwidthHz, analysis.verdict.rawValue, id])
            }
        }
    }

    /// Saves many results in one transaction (e.g. imported from a server's analysis index).
    public func saveAnalyses(_ items: [(FileAnalysis, String)]) throws {
        guard !items.isEmpty else { return }
        let encoder = JSONEncoder()
        let encoded = try items.map { (try encoder.encode($0.0), $0.0, $0.1) }
        let now = Date()
        try writer.write { db in
            for (data, analysis, filePath) in encoded {
                for track in try Track.filter(Column("filePath") == filePath).fetchAll(db) {
                    guard let id = track.id else { continue }
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO analysis (trackId, fileSize, modifiedAt, version, analyzedAt, data)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [id, track.fileSize, track.modifiedAt, analysis.version, now, data])
                    try db.execute(sql: "UPDATE track SET effectiveBitDepth = ?, bandwidthHz = ?, analysisVerdict = ? WHERE id = ?",
                                   arguments: [analysis.effectiveBitDepth, analysis.bandwidthHz, analysis.verdict.rawValue, id])
                }
            }
        }
    }

    public func storedAnalysis(for track: Track) throws -> StoredAnalysis? {
        guard let id = track.id else { return nil }
        return try writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM analysis WHERE trackId = ?", arguments: [id]),
                  let analysis = try? JSONDecoder().decode(FileAnalysis.self, from: row["data"] as Data) else { return nil }
            let size: Int64 = row["fileSize"], modified: Date = row["modifiedAt"], version: Int = row["version"]
            let current = version >= FileAnalysis.currentVersion && size == track.fileSize
                && abs(modified.timeIntervalSince(track.modifiedAt)) < 0.001
            return StoredAnalysis(analysis: analysis, analyzedAt: row["analyzedAt"], isCurrent: current)
        }
    }

    /// Lossless, present tracks without a current analysis (never analyzed, changed since, or
    /// analyzed by an older version). One track per file.
    public func tracksNeedingAnalysis(excludingSources excluded: Set<Int64> = []) throws -> [Track] {
        try writer.read { db in
            let rows = try Track.fetchAll(db, sql: """
                SELECT t.* FROM track t LEFT JOIN analysis a ON a.trackId = t.id
                WHERE t.isMissing = 0 AND t.isLossless = 1 AND t.isDSD = 0
                  AND (a.trackId IS NULL OR a.version < ? OR a.fileSize != t.fileSize OR a.modifiedAt != t.modifiedAt)
                ORDER BY t.addedAt DESC
                """, arguments: [FileAnalysis.currentVersion])
            var seen = Set<String>()
            return rows.filter { !excluded.contains($0.sourceId ?? -1) && seen.insert($0.filePath).inserted }
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
                       coalesce((SELECT sum(size) FROM (SELECT max(fileSize) AS size FROM track WHERE isMissing = 0 GROUP BY filePath)), 0) AS b, coalesce(sum(duration), 0) AS d FROM track WHERE isMissing = 0
                """)!
            return Stats(albums: row["a"], tracks: row["t"], artists: row["ar"], bytes: row["b"], duration: row["d"])
        }
    }
}

private struct SourceOverlapError: LocalizedError {
    let path: String
    var errorDescription: String? {
        "This folder contains an existing library source (\(path)). Add non-overlapping folders to preserve track and playlist ownership."
    }
}

// MARK: - Moved and renamed files

extension LibraryDatabase {
    /// Files that were moved or renamed (e.g. by a library manager reorganizing a share) show up as a
    /// missing track plus a new one. Folds each missing track into its new copy so playlists, play counts,
    /// ratings, the date it was added and its analysis carry over, then drops the stale entry.
    ///
    /// A match is the same size, duration and title (the file itself moved), or, for files whose tags were
    /// rewritten on the way, the same title, artist, track, disc, format and duration. Either must be
    /// unambiguous on both sides. Returns the old track ID → new track ID of each match.
    @discardableResult
    static func reconcileMovedTracks(_ db: Database, sourceID: Int64) throws -> [Int64: Int64] {
        let columns = "id, fileSize, duration, cueStartFrame, title, artist, trackNumber, discNumber, sampleRate, channels"
        let missing = try Row.fetchAll(db, sql: "SELECT \(columns) FROM track WHERE sourceId = ? AND isMissing = 1", arguments: [sourceID])
        guard !missing.isEmpty else { return [:] }
        let present = try Row.fetchAll(db, sql: "SELECT \(columns) FROM track WHERE sourceId = ? AND isMissing = 0", arguments: [sourceID])

        func exactKey(_ r: Row) -> String {
            let size: Int64 = r["fileSize"], duration: Double = r["duration"], cue: Int64? = r["cueStartFrame"]
            let title: String = r["title"] ?? ""
            return "\(size)|\(Int((duration * 1000).rounded()))|\(cue ?? -1)|\(title.lowercased())"
        }
        func tagKey(_ r: Row) -> String? {
            guard let title: String = r["title"], !title.isEmpty else { return nil }
            let artist: String = r["artist"] ?? "", track: Int = r["trackNumber"] ?? 0, disc: Int = r["discNumber"] ?? 0
            let rate: Double = r["sampleRate"], channels: Int = r["channels"], duration: Double = r["duration"], cue: Int64? = r["cueStartFrame"]
            return [title.lowercased(), artist.lowercased(), "\(track)", "\(disc)", "\(Int(rate))", "\(channels)",
                    "\(Int(duration.rounded()))", "\(cue ?? -1)"].joined(separator: "|")
        }
        var used = Set<Int64>()
        var pairs: [(old: Int64, new: Int64, sameFile: Bool)] = []
        for (key, sameFile) in [(exactKey as (Row) -> String?, true), (tagKey, false)] {
            var olds: [String: [Int64]] = [:], news: [String: [Int64]] = [:]
            for r in missing { let id: Int64 = r["id"]; if !used.contains(id), let k = key(r) { olds[k, default: []].append(id) } }
            for r in present { let id: Int64 = r["id"]; if !used.contains(id), let k = key(r) { news[k, default: []].append(id) } }
            for (k, o) in olds where o.count == 1 {
                guard let n = news[k], n.count == 1 else { continue }
                pairs.append((o[0], n[0], sameFile))
                used.insert(o[0]); used.insert(n[0])
            }
        }
        for (old, new, sameFile) in pairs {
            try db.execute(sql: "UPDATE playlistItem SET trackId = ? WHERE trackId = ?", arguments: [new, old])
            try db.execute(sql: "UPDATE tagHistory SET trackId = ? WHERE trackId = ?", arguments: [new, old])
            try db.execute(sql: """
                UPDATE track SET
                  playCount = playCount + (SELECT playCount FROM track WHERE id = :old),
                  lastPlayedAt = max(coalesce(lastPlayedAt, 0), coalesce((SELECT lastPlayedAt FROM track WHERE id = :old), 0)),
                  rating = coalesce(rating, (SELECT rating FROM track WHERE id = :old)),
                  addedAt = min(addedAt, (SELECT addedAt FROM track WHERE id = :old))
                WHERE id = :new
                """, arguments: ["old": old, "new": new])
            try db.execute(sql: "UPDATE track SET lastPlayedAt = NULL WHERE id = ? AND lastPlayedAt = 0", arguments: [new])
            if sameFile, try Bool.fetchOne(db, sql: "SELECT NOT EXISTS (SELECT 1 FROM analysis WHERE trackId = ?)", arguments: [new]) == true {
                // Same bytes, so the analysis still holds.
                try db.execute(sql: """
                    UPDATE analysis SET trackId = :new, modifiedAt = (SELECT modifiedAt FROM track WHERE id = :new)
                    WHERE trackId = :old AND fileSize = (SELECT fileSize FROM track WHERE id = :new)
                    """, arguments: ["old": old, "new": new])
                try db.execute(sql: """
                    UPDATE track SET
                      analysisVerdict = (SELECT analysisVerdict FROM track WHERE id = :old),
                      bandwidthHz = (SELECT bandwidthHz FROM track WHERE id = :old),
                      effectiveBitDepth = (SELECT effectiveBitDepth FROM track WHERE id = :old)
                    WHERE id = :new AND analysisVerdict IS NULL
                    """, arguments: ["old": old, "new": new])
            }
            try db.execute(sql: "DELETE FROM track WHERE id = ?", arguments: [old])
        }
        return Dictionary(uniqueKeysWithValues: pairs.map { ($0.old, $0.new) })
    }

    /// Runs `reconcileMovedTracks` for one source. Returns the old track ID → new track ID of each match.
    @discardableResult
    public func reconcileMovedTracks(sourceID: Int64) throws -> [Int64: Int64] {
        try writer.write { db in try Self.reconcileMovedTracks(db, sourceID: sourceID) }
    }
}
