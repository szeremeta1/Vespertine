//
// Vespertine: music servers in the library. An account on a server is a source whose path is
// "vespertine-stream://<provider>/<account>"; its songs are track rows with no file, streamed when played. While a provider's
// switch is off, every query answers as if the library had never had its accounts (`shownProviders`); nothing is deleted.
// The hidden-while-off design follows the one marcocebrian wrote for TIDAL in #323, made general.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import VespertineAudio

/// How a streamed song and its account are named in the library and to the engine.
public enum StreamLocation {
    public static let scheme = "vespertine-stream"
    public static let prefix = "vespertine-stream://"

    /// One song of one account of one provider.
    public struct Ref: Sendable, Hashable {
        public var provider: String
        public var account: String
        /// The song's id on the server.
        public var id: String

        public init(provider: String, account: String, id: String) {
            self.provider = provider
            self.account = account
            self.id = id
        }

        public var location: String { StreamLocation.location(provider: provider, account: account, id: id) }
        /// What the engine opens. The server's address and the credential are not in it: the provider adds them when it is opened.
        public var url: URL { URL(string: location)! }
        /// The song's key in the transient playback cache.
        public var cacheKey: String { "stream:\(provider):\(account):\(StreamLocation.encoded(id))" }
    }

    /// Letters, digits, "-", "." and "_" stay; everything else is percent-encoded, so an id is one path component.
    static func encoded(_ id: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }

    /// The `source` row's path for an account. `provider` and `account` are ids of ours (letters, digits and "-").
    public static func sourcePath(provider: String, account: String) -> String { "\(prefix)\(provider)/\(account)" }

    public static func location(provider: String, account: String, id: String) -> String {
        "\(sourcePath(provider: provider, account: account))/\(encoded(id))"
    }

    /// The provider and account of a source path, or of a song's location.
    public static func account(of path: String) -> (provider: String, account: String)? {
        guard path.hasPrefix(prefix) else { return nil }
        let parts = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    public static func ref(_ location: String) -> Ref? {
        guard location.hasPrefix(prefix) else { return nil }
        let parts = location.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, let id = String(parts[2]).removingPercentEncoding, !id.isEmpty else { return nil }
        return Ref(provider: String(parts[0]), account: String(parts[1]), id: id)
    }

    public static func ref(_ url: URL) -> Ref? { ref(url.absoluteString) }
}

public extension LibrarySource {
    /// An account on a music server, not a folder or a share: its songs have no files and are streamed.
    var isStreamed: Bool { path.hasPrefix(StreamLocation.prefix) }
    var streamedAccount: (provider: String, account: String)? { StreamLocation.account(of: path) }
}

public extension Track {
    /// Follows a format that is only what a server lists: "FLAC · 24/96 ≈".
    static let listedMark = " ≈"
    /// Kept with a streamed song's tags while its format is only what its server lists (nobody has read the stream yet).
    static let listedFormatTag = "VESPERTINE_FORMAT_LISTED"

    /// A song of a music server's account: no file, streamed when played.
    var isStreamed: Bool { filePath.isEmpty && location.hasPrefix(StreamLocation.prefix) }
    var streamRef: StreamLocation.Ref? { isStreamed ? StreamLocation.ref(location) : nil }
    /// The format shown is what the server lists and has not been confirmed by playing the song.
    var formatIsListed: Bool { extraTags[Track.listedFormatTag] != nil }
}

/// A song as a music server lists it.
public struct StreamedSong: Sendable, Hashable {
    public var id: String
    public var title: String
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var albumId: String?
    public var genre: String?
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: Double
    /// The file's extension on the server ("flac"), in lower case.
    public var suffix: String?
    public var mediaType: String?
    /// Kilobits a second.
    public var bitrate: Double?
    public var bitDepth: Int?
    public var sampleRate: Double?
    public var channels: Int?
    /// The size of the file on the server, when it says.
    public var size: Int64
    public var coverArt: String?
    public var isrc: String?
    public var musicBrainzRecordingID: String?
    public var starred: Bool
    public var replayGain: (trackGain: Double?, trackPeak: Double?, albumGain: Double?, albumPeak: Double?)?

    public static func == (a: StreamedSong, b: StreamedSong) -> Bool { a.id == b.id && a.title == b.title && a.size == b.size && a.suffix == b.suffix }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public init(id: String, title: String, artist: String? = nil, album: String? = nil, albumArtist: String? = nil, albumId: String? = nil,
                genre: String? = nil, year: Int? = nil, trackNumber: Int? = nil, discNumber: Int? = nil, duration: Double = 0,
                suffix: String? = nil, mediaType: String? = nil, bitrate: Double? = nil, bitDepth: Int? = nil, sampleRate: Double? = nil,
                channels: Int? = nil, size: Int64 = 0, coverArt: String? = nil, isrc: String? = nil, musicBrainzRecordingID: String? = nil,
                starred: Bool = false) {
        self.id = id; self.title = title; self.artist = artist; self.album = album; self.albumArtist = albumArtist; self.albumId = albumId
        self.genre = genre; self.year = year; self.trackNumber = trackNumber; self.discNumber = discNumber; self.duration = duration
        self.suffix = suffix?.lowercased(); self.mediaType = mediaType; self.bitrate = bitrate; self.bitDepth = bitDepth
        self.sampleRate = sampleRate; self.channels = channels; self.size = size; self.coverArt = coverArt; self.isrc = isrc
        self.musicBrainzRecordingID = musicBrainzRecordingID; self.starred = starred
    }

    /// The library's name for the format a file extension stands for, and whether it is lossless. An ".m4a" may hold AAC or
    /// ALAC: it is taken for AAC unless the server gives a bit depth, which it only has for lossless audio.
    public static func format(suffix: String?, bitDepth: Int?) -> (codec: String, isLossless: Bool, isDSD: Bool) {
        switch (suffix ?? "").lowercased() {
        case "flac": ("FLAC", true, false)
        case "wav", "wave": ("WAV", true, false)
        case "aif", "aiff", "aifc": ("AIFF", true, false)
        case "alac": ("ALAC", true, false)
        case "m4a", "mp4", "m4b": (bitDepth ?? 0) > 0 ? ("ALAC", true, false) : ("AAC", false, false)
        case "aac": ("AAC", false, false)
        case "mp3": ("MP3", false, false)
        case "ogg", "oga": ("Vorbis", false, false)
        case "opus": ("Opus", false, false)
        case "wv": ("WavPack", true, false)
        case "ape": ("APE", true, false)
        case "tta": ("TTA", true, false)
        case "tak": ("TAK", true, false)
        case "dsf", "dff": ("DSD", true, true)
        case "wma": ("WMA", false, false)
        case "mpc": ("Musepack", false, false)
        case let other: (other.isEmpty ? "?" : other.uppercased(), false, false)
        }
    }

    func track(location: String, sourceID: Int64, at date: Date) -> Track {
        let format = Self.format(suffix: suffix, bitDepth: bitDepth)
        var track = Track.transient(location: location, title: title.isEmpty ? id : title, artist: artist, album: album, duration: duration)
        track.sourceId = sourceID
        track.fileSize = max(0, size)
        track.modifiedAt = Date(timeIntervalSince1970: 0)
        track.addedAt = date
        track.codec = format.codec
        track.isLossless = format.isLossless
        track.isDSD = format.isDSD
        track.sampleRate = max(0, sampleRate ?? 0)
        track.bitDepth = format.isDSD || !format.isLossless ? nil : bitDepth.flatMap { $0 > 0 ? $0 : nil }
        track.channels = max(1, channels ?? 2)
        track.bitrate = bitrate
        track.albumArtist = albumArtist
        track.genre = genre
        track.year = year
        track.trackNumber = trackNumber
        track.discNumber = discNumber
        track.isrc = isrc
        track.musicBrainzRecordingID = musicBrainzRecordingID
        if let gain = replayGain {
            track.rgTrackGain = gain.trackGain; track.rgTrackPeak = gain.trackPeak
            track.rgAlbumGain = gain.albumGain; track.rgAlbumPeak = gain.albumPeak
        }
        track.extraTags = [Track.listedFormatTag: "1"]
        return track
    }
}

/// One of a server's playlists, with its songs' ids in order.
public struct StreamedPlaylist: Sendable, Hashable {
    public var id: String
    public var name: String
    public var songIDs: [String]

    public init(id: String, name: String, songIDs: [String]) {
        self.id = id
        self.name = name
        self.songIDs = songIDs
    }
}

/// What the library keeps of a streamed song beyond its track row.
public struct StreamedTrackInfo: Sendable, Hashable {
    public var albumId: String?
    public var coverArt: String?
    public var suffix: String?
    /// The format is only what the server lists.
    public var listed: Bool
    /// The stream last read was not the file the server lists; nil until one is read.
    public var converted: Bool?
}

/// The format a stream turned out to have when it was read.
public struct ConfirmedStreamFormat: Sendable, Hashable {
    public var codec: String
    public var isLossless: Bool
    public var isDSD: Bool
    public var sampleRate: Double
    public var bitDepth: Int?
    public var channels: Int
    /// The server sent something other than the file it lists.
    public var converted: Bool

    public init(codec: String, isLossless: Bool, isDSD: Bool, sampleRate: Double, bitDepth: Int?, channels: Int, converted: Bool) {
        self.codec = codec; self.isLossless = isLossless; self.isDSD = isDSD; self.sampleRate = sampleRate
        self.bitDepth = bitDepth; self.channels = channels; self.converted = converted
    }
}

// MARK: - What the switch hides

extension LibraryDatabase {
    /// The streaming providers whose accounts take part in the library's lists, counts, albums, artists, genres, favorites,
    /// history, playlists, smart playlists and search. The app sets it from each provider's switch (all off by default). A
    /// provider that is not in it is left out of every query, as if the library had never had its accounts; nothing is deleted.
    /// Nil, which is how a database starts (the command-line tools, a sync), leaves nothing out.
    public var shownProviders: Set<String>? {
        get { providersShown.withLock { $0 } }
        set { providersShown.withLock { $0 = newValue } }
    }

    /// Whether the songs of folders, drives and network shares take part in the same lists, counts and search. The app sets it
    /// from its Local Library switch (on by default). False, every query answers as if the library had no such source, and only
    /// the music of the servers that are shown is left; nothing is deleted.
    public var showsFiles: Bool {
        get { !filesHidden.withLock { $0 } }
        set { filesHidden.withLock { $0 = !newValue } }
    }

    /// The sources to leave out of the queries now: none when nothing is hidden.
    func hiddenSourceIDs(_ db: Database) throws -> Set<Int64> {
        let shown = shownProviders, files = showsFiles
        guard shown != nil || !files else { return [] }
        var hidden = Set<Int64>()
        for row in try Row.fetchAll(db, sql: "SELECT id, path FROM source") {
            let path: String = row["path"]
            if !path.hasPrefix(StreamLocation.prefix) {
                if !files { hidden.insert(row["id"]) }
            } else if let shown {
                if let account = StreamLocation.account(of: path), shown.contains(account.provider) { continue }
                hidden.insert(row["id"])
            }
        }
        return hidden
    }

    /// A condition on `track` rows (or the table `qualifier` names) that holds for every row the library shows: "1" when nothing
    /// is hidden, which leaves a library without a server account on the very SQL it always ran. With the files hidden, only the
    /// songs of the servers that are shown pass: a row without a source is a file's too.
    public func visibleTracksClause(_ db: Database, qualifier: String = "track") throws -> String {
        let hidden = try hiddenSourceIDs(db)
        guard showsFiles else {
            let shown = try Int64.fetchAll(db, sql: "SELECT id FROM source WHERE path LIKE '\(StreamLocation.prefix)%' ORDER BY id")
                .filter { !hidden.contains($0) }
            return shown.isEmpty ? "0" : "\(qualifier).sourceId IN (\(shown.map(String.init).joined(separator: ", ")))"
        }
        let ids = hidden.sorted()
        switch ids.count {
        case 0: return "1"
        case 1: return "\(qualifier).sourceId IS NOT \(ids[0])"
        default: return "(\(qualifier).sourceId IS NULL OR \(qualifier).sourceId NOT IN (\(ids.map(String.init).joined(separator: ", "))))"
        }
    }

    /// A condition on `playlist` rows: a playlist that stands for one of a server's shows only while its provider is on.
    func visiblePlaylistsClause(_ db: Database) throws -> String {
        let hidden = try hiddenSourceIDs(db).sorted()
        guard !hidden.isEmpty, try db.tableExists("streamedPlaylist") else { return "1" }
        return "id NOT IN (SELECT playlistId FROM streamedPlaylist WHERE sourceId IN (\(hidden.map(String.init).joined(separator: ", "))))"
    }

    /// `albums` with the format of each album marked the same way ("≈") where that format rests on what a server lists. An album
    /// that also has files, or songs already read, at its top rate and bit depth shows a format that was read, so it is not marked.
    func markingListedFormats(_ albums: [Album], _ db: Database) throws -> [Album] {
        guard !albums.isEmpty, try db.tableExists("streamedTrack") else { return albums }
        let visible = try visibleTracksClause(db)
        let keys = Set(try String.fetchAll(db, sql: """
            SELECT DISTINCT track.albumKey FROM streamedTrack JOIN track ON track.id = streamedTrack.trackId
            WHERE streamedTrack.listed = 1 AND track.isMissing = 0 AND \(visible)
            """))
        guard !keys.isEmpty else { return albums }
        var read: [String: (rate: Double, bits: Int)] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT albumKey, max(sampleRate) AS rate, max(coalesce(bitDepth, 0)) AS bits FROM track
            WHERE isMissing = 0 AND \(visible) AND id NOT IN (SELECT trackId FROM streamedTrack WHERE listed = 1)
            GROUP BY albumKey
            """) {
            if let key = row["albumKey"] as String? { read[key] = (rate: row["rate"] as Double? ?? 0, bits: row["bits"] as Int? ?? 0) }
        }
        return albums.map { album in
            guard keys.contains(album.key) else { return album }
            if let read = read[album.key], read.rate >= album.maxSampleRate, read.bits >= album.maxBitDepth ?? 0 { return album }
            var marked = album
            marked.formatSummary += Track.listedMark
            return marked
        }
    }

    /// The ids of the favorite songs the library shows, whether their file is missing, and their album.
    public func visibleFavorites(_ db: Database) throws -> [(id: Int64, missing: Bool, album: String?)] {
        try Row.fetchAll(db, sql: """
            SELECT favorite.trackId AS id, track.isMissing AS missing, track.albumKey AS album
            FROM favorite JOIN track ON track.id = favorite.trackId WHERE \(try visibleTracksClause(db))
            """).map { (id: $0["id"] as Int64, missing: $0["missing"] as Bool, album: $0["album"] as String?) }
    }
}

// MARK: - Accounts and their songs

public extension LibraryDatabase {
    /// The server accounts of the providers that are shown (every one on a database nobody switched), by name.
    func streamedSources() throws -> [LibrarySource] {
        try writer.read { db in try streamedSources(db) }
    }

    /// The same as one read of `db` sees them.
    func streamedSources(_ db: Database) throws -> [LibrarySource] {
        let hidden = try hiddenSourceIDs(db)
        return try LibrarySource.filter(sql: "path LIKE '\(StreamLocation.prefix)%'").order(Column("name"), Column("path")).fetchAll(db)
            .filter { !hidden.contains($0.id ?? -1) }
    }

    /// The account's source, made if the library has none for it. `name` is what the listener called the server.
    @discardableResult
    func addStreamedSource(provider: String, account: String, name: String?) throws -> LibrarySource {
        let path = StreamLocation.sourcePath(provider: provider, account: account)
        return try writer.write { db in
            if var existing = try LibrarySource.filter(Column("path") == path).fetchOne(db) {
                if let name, existing.name != name {
                    existing.name = name
                    try existing.update(db)
                }
                return existing
            }
            var source = LibrarySource(path: path, mode: .reference, name: name)
            try source.insert(db)
            return source
        }
    }

    /// Takes an account out of the library with its songs, their favorites and play counts, and the playlists that stood for
    /// the server's own. The server is not told anything.
    func removeStreamedSource(provider: String, account: String) throws {
        let path = StreamLocation.sourcePath(provider: provider, account: account)
        try writer.write { db in
            guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM source WHERE path = ?", arguments: [path]) else { return }
            try db.execute(sql: "DELETE FROM playlist WHERE id IN (SELECT playlistId FROM streamedPlaylist WHERE sourceId = ?)", arguments: [id])
            try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [id])
        }
    }

    /// Writes songs a server lists into the library: new ones are added, known ones updated with their plays, rating and date
    /// added kept. A song whose stream has been read keeps the format that was read for as long as the server's file is the
    /// same size. `artworkKeys`: the library's cover for each of the server's cover ids, where one has been fetched.
    @discardableResult
    func writeStreamedSongs(_ songs: [StreamedSong], provider: String, account: String, artworkKeys: [String: String] = [:],
                            at date: Date = .now) throws -> (added: Int, updated: Int) {
        guard !songs.isEmpty else { return (0, 0) }
        let path = StreamLocation.sourcePath(provider: provider, account: account)
        return try writer.write { db in
            guard let sourceID = try Int64.fetchOne(db, sql: "SELECT id FROM source WHERE path = ?", arguments: [path]) else { return (0, 0) }
            var added = 0, updated = 0
            for song in songs {
                let location = StreamLocation.location(provider: provider, account: account, id: song.id)
                var track = song.track(location: location, sourceID: sourceID, at: date)
                track.artworkKey = song.coverArt.flatMap { artworkKeys[$0] }
                var listed = true
                if let existing = try Track.filter(Column("location") == location).fetchOne(db) {
                    track.id = existing.id
                    track.addedAt = existing.addedAt
                    track.playCount = existing.playCount
                    track.lastPlayedAt = existing.lastPlayedAt
                    track.skipCount = existing.skipCount
                    track.lastSkippedAt = existing.lastSkippedAt
                    track.rating = existing.rating
                    if track.artworkKey == nil { track.artworkKey = existing.artworkKey }
                    if !existing.formatIsListed, existing.fileSize == track.fileSize {
                        // Read once and not changed on the server since: what was read stands.
                        track.codec = existing.codec; track.isLossless = existing.isLossless; track.isDSD = existing.isDSD
                        track.sampleRate = existing.sampleRate; track.bitDepth = existing.bitDepth; track.channels = existing.channels
                        track.extraTags[Track.listedFormatTag] = nil
                        listed = false
                    }
                    try track.update(db)
                    updated += 1
                } else {
                    try track.insert(db)
                    added += 1
                    // A song of an account signed out of and back in to takes back its plays, rating, favorite and history.
                    if let id = track.id { try LibraryDatabase.restoreKeptStats(db, trackIDs: [id]) }
                }
                guard let id = track.id else { continue }
                try db.execute(sql: """
                    INSERT INTO streamedTrack (trackId, albumId, coverArt, suffix, listed) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (trackId) DO UPDATE SET albumId = excluded.albumId, coverArt = excluded.coverArt, suffix = excluded.suffix,
                        listed = excluded.listed, converted = CASE WHEN excluded.listed THEN NULL ELSE converted END
                    """, arguments: [id, song.albumId, song.coverArt, song.suffix, listed])
            }
            return (added, updated)
        }
    }

    /// After a whole account was listed: its songs that the server no longer has are hidden as missing (their favorites and
    /// play counts stay, and they return if the server lists them again). Returns how many were hidden.
    @discardableResult
    func finishStreamedSync(provider: String, account: String, keeping ids: Set<String>, at date: Date = .now) throws -> Int {
        let path = StreamLocation.sourcePath(provider: provider, account: account)
        return try writer.write { db in
            guard let sourceID = try Int64.fetchOne(db, sql: "SELECT id FROM source WHERE path = ?", arguments: [path]) else { return 0 }
            var gone = 0
            for row in try Row.fetchAll(db, sql: "SELECT id, location FROM track WHERE sourceId = ? AND isMissing = 0", arguments: [sourceID]) {
                let location: String = row["location"]
                guard let ref = StreamLocation.ref(location), !ids.contains(ref.id) else { continue }
                try db.execute(sql: "UPDATE track SET isMissing = 1 WHERE id = ?", arguments: [row["id"] as Int64])
                gone += 1
            }
            try db.execute(sql: "UPDATE source SET lastScannedAt = ?, isOnline = 1 WHERE id = ?", arguments: [date, sourceID])
            return gone
        }
    }

    /// Gives the songs that carry the server's cover id `coverArt` the library's cover `key`.
    func setStreamedArtwork(_ key: String, coverArt: String, provider: String, account: String) throws {
        let path = StreamLocation.sourcePath(provider: provider, account: account)
        try writer.write { db in
            try db.execute(sql: """
                UPDATE track SET artworkKey = ? WHERE sourceId = (SELECT id FROM source WHERE path = ?)
                  AND id IN (SELECT trackId FROM streamedTrack WHERE coverArt = ?) AND artworkKey IS NOT ?
                """, arguments: [key, path, coverArt, key])
        }
    }

    /// The server's cover ids of an account's songs that have no cover in the library yet.
    func streamedCoversNeeded(provider: String, account: String) throws -> [String] {
        let path = StreamLocation.sourcePath(provider: provider, account: account)
        return try writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT s.coverArt FROM streamedTrack s JOIN track t ON t.id = s.trackId
                WHERE t.sourceId = (SELECT id FROM source WHERE path = ?) AND t.isMissing = 0 AND t.artworkKey IS NULL AND s.coverArt IS NOT NULL
                """, arguments: [path])
        }
    }

    /// What the server lists for the song at `location`: its file's size and extension. Nil when the library has no such song.
    func streamedListing(location: String) throws -> (size: Int64, suffix: String?)? {
        try writer.read { db in
            try Row.fetchOne(db, sql: """
                SELECT track.fileSize AS size, streamedTrack.suffix AS suffix FROM track LEFT JOIN streamedTrack ON streamedTrack.trackId = track.id
                WHERE track.location = ?
                """, arguments: [location]).map { (size: $0["size"] as Int64, suffix: $0["suffix"] as String?) }
        }
    }

    func streamedInfo(trackID: Int64) throws -> StreamedTrackInfo? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT albumId, coverArt, suffix, listed, converted FROM streamedTrack WHERE trackId = ?", arguments: [trackID]).map {
                StreamedTrackInfo(albumId: $0["albumId"], coverArt: $0["coverArt"], suffix: $0["suffix"], listed: $0["listed"], converted: $0["converted"])
            }
        }
    }

    /// A streamed song was read: the format that was read replaces the one the server lists, and the "≈" goes.
    /// Returns whether anything changed.
    @discardableResult
    func confirmStreamedFormat(_ format: ConfirmedStreamFormat, location: String) throws -> Bool {
        try writer.write { db in
            guard var track = try Track.filter(Column("location") == location).fetchOne(db), let id = track.id, track.isStreamed else { return false }
            let before = track
            track.codec = format.codec; track.isLossless = format.isLossless; track.isDSD = format.isDSD
            track.sampleRate = format.sampleRate; track.bitDepth = format.bitDepth; track.channels = format.channels
            track.extraTags[Track.listedFormatTag] = nil
            let known = try Row.fetchOne(db, sql: "SELECT listed, converted FROM streamedTrack WHERE trackId = ?", arguments: [id])
            let unchanged = before == track && (known?["listed"] as Bool?) == false && (known?["converted"] as Bool?) == format.converted
            guard !unchanged else { return false }
            try track.update(db)
            try db.execute(sql: """
                INSERT INTO streamedTrack (trackId, listed, converted) VALUES (?, 0, ?)
                ON CONFLICT (trackId) DO UPDATE SET listed = 0, converted = excluded.converted
                """, arguments: [id, format.converted])
            return true
        }
    }

    /// Makes the library's playlists for an account stand for the server's: each is created or rewritten to hold the server's
    /// songs in the server's order, and one the server no longer has is removed. Songs the library does not have are left out.
    func writeStreamedPlaylists(_ playlists: [StreamedPlaylist], provider: String, account: String) throws {
        let path = StreamLocation.sourcePath(provider: provider, account: account)
        try writer.write { db in
            guard let sourceID = try Int64.fetchOne(db, sql: "SELECT id FROM source WHERE path = ?", arguments: [path]) else { return }
            var known: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT playlistId, remoteId FROM streamedPlaylist WHERE sourceId = ?", arguments: [sourceID]) {
                let remote: String = row["remoteId"], id: Int64 = row["playlistId"]
                known[remote] = id
            }
            for listing in playlists {
                let playlistID: Int64
                if let id = known.removeValue(forKey: listing.id) {
                    playlistID = id
                    try db.execute(sql: "UPDATE playlist SET name = ? WHERE id = ? AND name != ?", arguments: [listing.name, id, listing.name])
                } else {
                    let next = (try Int.fetchOne(db, sql: "SELECT max(sortIndex) FROM playlist") ?? 0) + 1
                    var playlist = Playlist(name: listing.name, sortIndex: next)
                    try playlist.insert(db)
                    guard let id = playlist.id else { continue }
                    playlistID = id
                    try db.execute(sql: "INSERT INTO streamedPlaylist (playlistId, sourceId, remoteId) VALUES (?, ?, ?)", arguments: [id, sourceID, listing.id])
                }
                try db.execute(sql: "DELETE FROM playlistItem WHERE playlistId = ?", arguments: [playlistID])
                var position = 0
                for songID in listing.songIDs {
                    let location = StreamLocation.location(provider: provider, account: account, id: songID)
                    guard let trackID = try Int64.fetchOne(db, sql: "SELECT id FROM track WHERE location = ?", arguments: [location]) else { continue }
                    try PlaylistItem(playlistId: playlistID, trackId: trackID, position: position).insert(db)
                    position += 1
                }
            }
            for id in known.values { try db.execute(sql: "DELETE FROM playlist WHERE id = ?", arguments: [id]) }
        }
    }

    /// The playlists that stand for a server's own (they are the server's to change, not the listener's here).
    func streamedPlaylistIDs() throws -> Set<Int64> {
        try writer.read { db in
            guard try db.tableExists("streamedPlaylist") else { return [] }
            return Set(try Int64.fetchAll(db, sql: "SELECT playlistId FROM streamedPlaylist"))
        }
    }

    /// Makes the account's favorites those the server has starred: a song starred there becomes a favorite here, and a favorite
    /// of the account that is no longer starred there stops being one. Favorites of other sources are not touched.
    func writeStreamedFavorites(starred ids: Set<String>, provider: String, account: String, at date: Date = .now) throws {
        let path = StreamLocation.sourcePath(provider: provider, account: account)
        try writer.write { db in
            guard let sourceID = try Int64.fetchOne(db, sql: "SELECT id FROM source WHERE path = ?", arguments: [path]) else { return }
            let favorites = Set(try Int64.fetchAll(db, sql: """
                SELECT favorite.trackId FROM favorite JOIN track ON track.id = favorite.trackId WHERE track.sourceId = ? AND favorite.borrowed = 0
                """, arguments: [sourceID]))
            for row in try Row.fetchAll(db, sql: "SELECT id, location FROM track WHERE sourceId = ?", arguments: [sourceID]) {
                let trackID: Int64 = row["id"], location: String = row["location"]
                guard let ref = StreamLocation.ref(location) else { continue }
                if ids.contains(ref.id), !favorites.contains(trackID) {
                    try db.execute(sql: "INSERT OR REPLACE INTO favorite (trackId, favoritedAt, borrowed) VALUES (?, ?, 0)", arguments: [trackID, date])
                } else if !ids.contains(ref.id), favorites.contains(trackID) {
                    try db.execute(sql: "DELETE FROM favorite WHERE trackId = ?", arguments: [trackID])
                }
            }
        }
    }
}
