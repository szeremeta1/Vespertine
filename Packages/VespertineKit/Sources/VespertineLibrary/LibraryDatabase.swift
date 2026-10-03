//
// Vespertine — the library database (SQLite via GRDB).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import VespertineAudio

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

    init(writer: any DatabaseWriter, migrate: Bool = true) throws {
        self.writer = writer
        if migrate {
            try Self.migrator.migrate(writer)
            // Before anything asks what needs analyzing: after an analyzer update, stored results are judged anew
            // from their measurements instead of every file (network shares' too) being read again.
            try rejudgeStoredAnalyses()
        }
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vespertine", isDirectory: true)
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
                // `Track.albumKey` computes the same bytes in Swift; keep the two in step.
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
        m.registerMigration("v11-dsf-dates") { db in
            // 0.5.19 reads DSF release and original dates from the ID3 tag (the tag reader dropped them).
            try db.execute(sql: "UPDATE track SET modifiedAt = '1970-01-01 00:00:00.000' WHERE lower(filePath) LIKE '%.dsf' AND isMissing = 0")
        }
        m.registerMigration("v10-dts-carrier-bitrate") { db in
            // 0.5.19: a DTS CD's bitrate was the PCM carrier's 1411k; it isn't the DTS stream's, so don't show one.
            try db.execute(sql: "UPDATE track SET bitrate = NULL WHERE codec = 'DTS' AND (lower(filePath) LIKE '%.wav' OR lower(filePath) LIKE '%.flac')")
        }
        m.registerMigration("v12-favorites") { db in
            // Favorite songs: library state like plays and playlists, never written to the files.
            try db.create(table: "favorite") { t in
                t.primaryKey("trackId", .integer).references("track", onDelete: .cascade)
                t.column("favoritedAt", .datetime).notNull().indexed()
            }
        }
        m.registerMigration("v13-numbers-from-names") { db in
            // 0.6.2 reads a missing or zero track number from the file name and a missing disc number from a "CD 02"
            // folder: re-read those tracks on the next scan.
            try db.execute(sql: """
                UPDATE track SET modifiedAt = '1970-01-01 00:00:00.000'
                WHERE isMissing = 0 AND cueStartFrame IS NULL AND (trackNumber IS NULL OR trackNumber = 0 OR (discNumber IS NULL AND (
                    filePath LIKE '%/CD %/%' OR filePath LIKE '%/Disc %/%' OR filePath LIKE '%/Disk %/%' OR filePath LIKE '%Vinyl %/%'
                    OR filePath LIKE '%/Digital Media %/%' OR filePath LIKE '%CD 0%/%')))
                """)
        }
        m.registerMigration("v14-verdicts-from-analysis") { db in
            // Some tracks kept a current stored analysis but lost the verdict on the track itself (no badge, and
            // never fetched again because the analysis is current). Restore verdicts from the stored analyses.
            try db.execute(sql: """
                UPDATE track SET
                  analysisVerdict = (SELECT json_extract(CAST(a.data AS TEXT), '$.verdict') FROM analysis a WHERE a.trackId = track.id),
                  effectiveBitDepth = (SELECT json_extract(CAST(a.data AS TEXT), '$.effectiveBitDepth') FROM analysis a WHERE a.trackId = track.id),
                  bandwidthHz = (SELECT json_extract(CAST(a.data AS TEXT), '$.bandwidthHz') FROM analysis a WHERE a.trackId = track.id)
                WHERE analysisVerdict IS NULL AND EXISTS (
                  SELECT 1 FROM analysis a WHERE a.trackId = track.id AND a.fileSize = track.fileSize AND a.modifiedAt = track.modifiedAt
                    AND json_valid(CAST(a.data AS TEXT)))
                """)
        }
        m.registerMigration("v15-compilations-together") { db in
            // Compilations without an Album Artist were split into one album per track artist. The scanner now files
            // them under Various Artists (in the library only); do the same for tracks already scanned.
            try db.execute(sql: "UPDATE track SET albumArtist = ? WHERE compilation = 1 AND (albumArtist IS NULL OR trim(albumArtist) = '')",
                           arguments: [Track.variousArtists])
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
               max(codec) AS codec, count(DISTINCT codec) AS codecCount, min(isLossless) AS lossless, max(bitrate) AS bitrate,
               max(addedAt) AS addedAt,
               -- a CUE-split file counts once (with its first track), not once per track
               sum(CASE WHEN cueStartFrame IS NULL OR cueStartFrame = 0 THEN fileSize ELSE 0 END) AS totalSize, min(filePath) AS anyPath,
               min(albumArtistSortKey) AS artistKey, min(albumSortKey) AS titleKey,
               -- what filters look at: every value any track has (DSD counts as 1-bit; lossless PCM nobody analyzed yet as 'none')
               group_concat(DISTINCT replace(codec, ',', ' ') || ':' || isLossless || isDSD) AS kinds,
               group_concat(DISTINCT CAST(round(sampleRate) AS INTEGER)) AS rates,
               group_concat(DISTINCT coalesce(bitDepth, CASE WHEN isDSD THEN 1 END)) AS depths,
               group_concat(DISTINCT channels) AS channelCounts,
               group_concat(DISTINCT coalesce(analysisVerdict, CASE WHEN isLossless AND NOT isDSD THEN 'none' END)) AS verdicts,
               group_concat(DISTINCT sourceId) AS sourceIds
        FROM track WHERE isMissing = 0 AND (\(filter))
        GROUP BY albumKey ORDER BY \(order)
        """
    }

    static func album(from row: Row) -> Album {
        let isDSD: Bool = row["isDSD"]
        let rate: Double = row["maxRate"]
        let bits: Int? = row["maxBits"]
        let codecCount: Int = row["codecCount"] ?? 1
        // An album in several formats ("Gypsy" as FLAC, MP3 and AAC) names none of them.
        let codec: String = codecCount > 1 ? Album.mixedCodec : row["codec"]
        let lossless: Bool = row["lossless"]
        let bitrate: Double? = row["bitrate"]
        let maxChannels: Int = row["maxChannels"] ?? 2
        let rateText = rate.truncatingRemainder(dividingBy: 1000) == 0 ? String(Int(rate / 1000)) : String(format: "%.1f", rate / 1000)
        let summary: String = if isDSD {
            "DSD\(Int((rate / 44_100).rounded()))"
        } else if codecCount > 1 {
            bits.map { "\(codec) · up to \($0)/\(rateText)" } ?? "\(codec) · up to \(rateText) kHz"
        } else if !lossless, let bitrate {
            "\(codec) · \(Int(bitrate))k"
        } else if let bits {
            "\(codec) · \(bits)/\(rateText)"
        } else {
            "\(codec) · \(rateText) kHz"
        }
        let channelText = maxChannels > 2 ? " · " + ChannelLayouts.name(channels: maxChannels) : ""
        var album = Album(key: row["key"], title: row["title"], artist: row["artist"], year: row["year"], genre: row["genre"],
                          trackCount: row["trackCount"], duration: row["duration"], artworkKey: row["artworkKey"],
                          formatSummary: summary + channelText, codec: codec, maxBitDepth: bits, maxSampleRate: rate, isHiRes: isDSD || (lossless && ((bits ?? 16) > 16 || rate > 48_000)),
                          isDSD: isDSD, addedAt: row["addedAt"], totalSize: row["totalSize"],
                          sourcePath: (row["anyPath"] as String?).map { ($0 as NSString).deletingLastPathComponent },
                          maxChannels: maxChannels)
        album.facts = facts(from: row, album: album)
        return album
    }

    /// An album's filter facts from the aggregates of `albumsSQL`.
    private static func facts(from row: Row, album: Album) -> FilterFacts {
        func list(_ column: String) -> [String] {
            ((row[column] as String?) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var f = FilterFacts()
        // "FLAC:10" = codec, lossless, DSD
        f.formats = Set(list("kinds").map { entry in
            let flags = entry.suffix(2)
            return FormatKind.of(codec: String(entry.dropLast(3)), lossless: flags.first == "1", dsd: flags.last == "1")
        })
        f.sampleRates = Set(list("rates").compactMap { Int($0) })
        f.bitDepths = Set(list("depths").compactMap { Int($0) })
        f.channels = Set(list("channelCounts").compactMap { Int($0) })
        f.verdicts = Set(list("verdicts"))
        f.sources = Set(list("sourceIds").compactMap { Int64($0) })
        f.genres = Genres.keys(album.genre)
        f.decade = Genres.decade(album.year)
        f.artist = album.artist.lowercased()
        return f
    }

    func albums(sort: AlbumSort = .artist) throws -> [Album] {
        try writer.read { db in try Row.fetchAll(db, sql: Self.albumsSQL(sort: sort)).map(Self.album(from:)) }
    }

    func tracks(albumKey: String) throws -> [Track] {
        try writer.read { db in
            Self.albumOrder(try Track.fetchAll(db, sql: "SELECT * FROM track WHERE albumKey = ? AND isMissing = 0", arguments: [albumKey]))
        }
    }

    /// The tracks of one file (several when a CUE sheet splits it), in order.
    func tracks(filePath: String) throws -> [Track] {
        try writer.read { db in
            Self.albumOrder(try Track.fetchAll(db, sql: "SELECT * FROM track WHERE filePath = ? AND isMissing = 0", arguments: [filePath]))
        }
    }

    /// The tracks of several albums in one read: album after album as given, each in its own order.
    func tracks(albumKeys: [String]) throws -> [Track] {
        guard !albumKeys.isEmpty else { return [] }
        let found = try writer.read { db in try Self.tracks(db, albumKeys: albumKeys) }
        return Self.inAlbumOrder(found, albumKeys: albumKeys)
    }

    private static func tracks(_ db: Database, albumKeys: [String]) throws -> [Track] {
        var found: [Track] = []
        // A long list is read in parts (SQLite caps the number of arguments).
        for start in stride(from: 0, to: albumKeys.count, by: 900) {
            let part = Array(albumKeys[start..<min(start + 900, albumKeys.count)])
            let marks = Array(repeating: "?", count: part.count).joined(separator: ",")
            found += try Track.fetchAll(db, sql: "SELECT * FROM track WHERE isMissing = 0 AND albumKey IN (\(marks))",
                                        arguments: StatementArguments(part))
        }
        return found
    }

    private static func inAlbumOrder(_ tracks: [Track], albumKeys: [String]) -> [Track] {
        let byAlbum = Dictionary(grouping: tracks, by: \.albumKey)
        var seen = Set<String>()
        return albumKeys.flatMap { key in seen.insert(key).inserted ? albumOrder(byAlbum[key] ?? []) : [] }
    }

    /// An album's tracks in disc and track order. Track numbers that repeat on one disc (an SACD rip's
    /// "Multichannel 5.1" and "Stereo" folders, a CD and a vinyl copy) list folder by folder instead of
    /// interleaved. Otherwise the numbers decide, even when an album's files are spread over several folders.
    static func albumOrder(_ tracks: [Track]) -> [Track] {
        func folder(_ t: Track) -> String { (t.filePath as NSString).deletingLastPathComponent }
        let numbers = tracks.compactMap { t in t.trackNumber.map { "\(t.discNumber ?? 1)-\($0)" } }
        if Set(numbers).count < numbers.count {
            return tracks.sorted {
                (($0.discNumber ?? 1), folder($0), ($0.trackNumber ?? 0), $0.location) < (($1.discNumber ?? 1), folder($1), ($1.trackNumber ?? 0), $1.location)
            }
        }
        // SQL's order was disc, number, location, with songs without a number first on their disc.
        return tracks.sorted {
            (($0.discNumber ?? 1), $0.trackNumber ?? Int.min, $0.location) < (($1.discNumber ?? 1), $1.trackNumber ?? Int.min, $1.location)
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

    /// Rewrites a manual playlist's order. `trackIDs` is the playlist as shown, which leaves out songs whose files are
    /// missing: those entries stay, each after the song (or the nearest earlier one still listed) that it followed before.
    func setPlaylistTracks(_ trackIDs: [Int64], playlistID: Int64) throws {
        try writer.write { db in
            let old = try Row.fetchAll(db, sql: """
                SELECT playlistItem.trackId AS id, track.isMissing AS missing FROM playlistItem JOIN track ON track.id = playlistItem.trackId
                WHERE playlistItem.playlistId = ? ORDER BY playlistItem.position
                """, arguments: [playlistID])
            let shown = Dictionary(trackIDs.map { ($0, 1) }, uniquingKeysWith: +)
            // Kept entries by the occurrence they follow ("id#n": the nth time that song is listed; "" = the start).
            var kept: [String: [Int64]] = [:], counts: [Int64: Int] = [:], anchor = ""
            for row in old {
                let id: Int64 = row["id"], missing: Bool = row["missing"]
                if missing && shown[id] == nil { kept[anchor, default: []].append(id); continue }
                let n = counts[id, default: 0]
                counts[id] = n + 1
                if n < (shown[id] ?? 0) { anchor = "\(id)#\(n)" }
            }
            var order = kept[""] ?? []
            counts = [:]
            for id in trackIDs {
                let n = counts[id, default: 0]
                counts[id] = n + 1
                order.append(id)
                order += kept["\(id)#\(n)"] ?? []
            }
            try db.execute(sql: "DELETE FROM playlistItem WHERE playlistId = ?", arguments: [playlistID])
            for (i, id) in order.enumerated() {
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

    // MARK: Favorites

    /// Favorite songs, the most recently favorited first. Missing files are left out, as in playlists.
    func favoriteTracks() throws -> [Track] {
        try writer.read { db in
            try Track.fetchAll(db, sql: """
                SELECT track.* FROM favorite JOIN track ON track.id = favorite.trackId
                WHERE track.isMissing = 0 ORDER BY favorite.favoritedAt DESC, track.id
                """)
        }
    }

    /// Adds or removes favorites. Songs that already are favorites keep the date they were first favorited.
    func setFavorite(_ favorite: Bool, trackIDs: [Int64], at date: Date = .now) throws {
        guard !trackIDs.isEmpty else { return }
        try writer.write { db in
            for id in trackIDs {
                if favorite {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO favorite (trackId, favoritedAt) SELECT id, ? FROM track WHERE id = ?
                        """, arguments: [date, id])
                } else {
                    try db.execute(sql: "DELETE FROM favorite WHERE trackId = ?", arguments: [id])
                }
            }
        }
    }

    /// A favorite is a song, not a file: every version and copy of a favorite song on its album (its stereo and
    /// 5.1 versions, the same song on a share) is a favorite too, from the date the song first was. Covers songs
    /// favorited one version at a time and versions added since. Returns how many favorite songs there are
    /// (present files only), the number the sidebar shows.
    @discardableResult
    func favoriteEveryVersion() throws -> Int {
        try writer.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT track.albumKey AS album, favorite.trackId AS id, favorite.favoritedAt AS date
                FROM favorite JOIN track ON track.id = favorite.trackId WHERE track.isMissing = 0
                """)
            guard !rows.isEmpty else { return 0 }
            var dates: [Int64: Date] = [:]
            for row in rows { dates[row["id"] as Int64] = row["date"] as Date }
            let albumKeys = Array(Set(rows.compactMap { $0["album"] as String? }))
            let tracks = Self.inAlbumOrder(try Self.tracks(db, albumKeys: albumKeys), albumKeys: albumKeys)
            var songs = 0
            for album in Dictionary(grouping: tracks, by: \.albumKey).values {
                for song in TrackVersions.group(album) {
                    guard let date = song.compactMap({ $0.id.flatMap { dates[$0] } }).min() else { continue }
                    songs += 1
                    for id in song.compactMap(\.id) where dates[id] == nil {
                        try db.execute(sql: "INSERT OR IGNORE INTO favorite (trackId, favoritedAt) VALUES (?, ?)", arguments: [id, date])
                    }
                }
            }
            return songs
        }
    }

    public func sources() throws -> [LibrarySource] {
        try writer.read { db in try LibrarySource.order(Column("path")).fetchAll(db) }
    }

    /// Adds a folder (or a single file) to the library, or returns the source that already covers it. A local folder
    /// takes in the local sources inside it (a song opened with Open With, a subfolder added earlier): their tracks
    /// move to it with their plays, ratings, playlists and analyses. Network shares and the managed library always
    /// keep their own source, so a folder that contains one is refused.
    @discardableResult
    func addSource(_ source: LibrarySource) throws -> LibrarySource {
        try writer.write { db in
            let canonical = source.url.resolvingSymlinksInPath().path
            let sources = try LibrarySource.fetchAll(db)
            var inside: [LibrarySource] = []
            for existing in sources {
                let path = existing.url.resolvingSymlinksInPath().path
                if canonical == path || canonical.hasPrefix(path == "/" ? "/" : path + "/") { return existing }
                if path.hasPrefix(canonical == "/" ? "/" : canonical + "/") {
                    guard source.mode == .reference, !source.isNetwork, existing.mode == .reference, !existing.isNetwork else {
                        throw SourceOverlapError(path: existing.path)
                    }
                    inside.append(existing)
                }
            }
            var s = source
            try s.insert(db)
            for old in inside {
                try db.execute(sql: "UPDATE track SET sourceId = ? WHERE sourceId = ?", arguments: [s.id, old.id])
                try db.execute(sql: "UPDATE cueScanState SET sourceId = ? WHERE sourceId = ?", arguments: [s.id, old.id])
                try LibrarySource.deleteOne(db, key: old.id)
            }
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

    /// The sidebar name; nil or empty goes back to the default.
    public func renameSource(_ id: Int64, to name: String?) throws {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try writer.write { db in
            try db.execute(sql: "UPDATE source SET name = ? WHERE id = ?", arguments: [trimmed?.isEmpty == false ? trimmed : nil, id])
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

    /// Brings stored analyses from older versions up to the current judgement from their measurements
    /// (`FileAnalyzer.rejudged`). Those that can't be (version 1 kept no measurements) stay as they are, for a fresh
    /// analysis. Returns how many were brought up to date; nothing to do costs one query.
    @discardableResult
    public func rejudgeStoredAnalyses() throws -> Int {
        try writer.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT trackId, data FROM analysis WHERE version >= 2 AND version < ?",
                                        arguments: [FileAnalysis.currentVersion])
            let decoder = JSONDecoder(), encoder = JSONEncoder()
            var updated = 0
            for row in rows {
                guard let stored = try? decoder.decode(FileAnalysis.self, from: row["data"] as Data) else { continue }
                let analysis = FileAnalyzer.rejudged(stored)
                guard analysis.version >= FileAnalysis.currentVersion, let data = try? encoder.encode(analysis) else { continue }
                let id: Int64 = row["trackId"]
                try db.execute(sql: "UPDATE analysis SET version = ?, data = ? WHERE trackId = ?", arguments: [analysis.version, data, id])
                try db.execute(sql: "UPDATE track SET effectiveBitDepth = ?, bandwidthHz = ?, analysisVerdict = ? WHERE id = ?",
                               arguments: [analysis.effectiveBitDepth, analysis.bandwidthHz, analysis.verdict.rawValue, id])
                updated += 1
            }
            return updated
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
    /// missing track plus a new one. Folds each missing track into its new copy so playlists, favorites, play
    /// counts, ratings, the date it was added and its analysis carry over, then drops the stale entry.
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
                INSERT OR IGNORE INTO favorite (trackId, favoritedAt) SELECT ?, favoritedAt FROM favorite WHERE trackId = ?
                """, arguments: [new, old])
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
