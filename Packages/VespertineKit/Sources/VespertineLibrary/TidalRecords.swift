// Vespertine: TIDAL tracks in the library: the `tidalTrack` table and the calls that keep it in step with the account.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB

/// What the library keeps of a track beyond its `track` row: its TIDAL identity, the quality TIDAL lists for it, and the download that
/// stands in for the stream.
public struct TidalTrackRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public var trackId: Int64
    public var tidalId: Int
    public var albumId: Int?
    public var artistIds: [Int]
    /// TIDAL's `audioQuality`: LOW, HIGH, LOSSLESS, HI_RES or HI_RES_LOSSLESS.
    public var listedQuality: String?
    /// LOSSLESS, HIRES_LOSSLESS, DOLBY_ATMOS…
    public var mediaTags: [String]
    public var explicit: Bool
    public var copyright: String?
    public var popularity: Int?
    public var streamable: Bool
    /// Why the row can't be streamed (region, removed, or `TidalTrackRecord.notInFavorites`); nil when it can.
    public var unavailableReason: String?
    /// The downloaded file, when there is one (also the track's `filePath`).
    public var downloadPath: String?
    /// `codec`, `sampleRate` and `bitDepth` of the track are the stream's own (read after the first play or download), not what TIDAL lists.
    public var formatIsProbed: Bool
    public var lastSyncedAt: Date?

    public static let databaseTableName = "tidalTrack"
    /// A downloaded track that left the favorites stays, with this reason.
    public static let notInFavorites = "notInFavorites"
}

/// TIDAL's ReplayGain values (dB and linear peak) for a track and its album.
public struct TidalReplayGain: Sendable, Hashable {
    public var trackGain: Double?
    public var trackPeak: Double?
    public var albumGain: Double?
    public var albumPeak: Double?
    public init(trackGain: Double? = nil, trackPeak: Double? = nil, albumGain: Double? = nil, albumPeak: Double? = nil) {
        self.trackGain = trackGain; self.trackPeak = trackPeak; self.albumGain = albumGain; self.albumPeak = albumPeak
    }
}

/// One track as TIDAL describes it, ready to be stored (`LibraryDatabase.upsertTidalTracks`).
public struct TidalTrackInput: Sendable {
    public var tidalId: Int
    public var title: String
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var trackTotal: Int?
    public var discTotal: Int?
    public var duration: Double
    public var isrc: String?
    public var releaseDate: String?
    public var year: Int?
    public var copyright: String?
    public var explicit: Bool
    public var popularity: Int?
    public var listedQuality: String
    public var mediaTags: [String]
    public var replayGain: TidalReplayGain
    public var albumId: Int?
    public var artistIds: [Int]
    public var coverUUID: String?
    public var streamable: Bool
    public var unavailableReason: String?

    public init(tidalId: Int, title: String, artist: String? = nil, album: String? = nil, albumArtist: String? = nil,
                trackNumber: Int? = nil, discNumber: Int? = nil, trackTotal: Int? = nil, discTotal: Int? = nil,
                duration: Double = 0, isrc: String? = nil, releaseDate: String? = nil, year: Int? = nil, copyright: String? = nil,
                explicit: Bool = false, popularity: Int? = nil, listedQuality: String = "LOSSLESS", mediaTags: [String] = [],
                replayGain: TidalReplayGain = TidalReplayGain(), albumId: Int? = nil, artistIds: [Int] = [], coverUUID: String? = nil,
                streamable: Bool = true, unavailableReason: String? = nil) {
        self.tidalId = tidalId; self.title = title; self.artist = artist; self.album = album; self.albumArtist = albumArtist
        self.trackNumber = trackNumber; self.discNumber = discNumber; self.trackTotal = trackTotal; self.discTotal = discTotal
        self.duration = duration; self.isrc = isrc; self.releaseDate = releaseDate; self.year = year; self.copyright = copyright
        self.explicit = explicit; self.popularity = popularity; self.listedQuality = listedQuality; self.mediaTags = mediaTags
        self.replayGain = replayGain; self.albumId = albumId; self.artistIds = artistIds; self.coverUUID = coverUUID
        self.streamable = streamable; self.unavailableReason = unavailableReason
    }

    /// The format a track starts with, from the quality TIDAL lists (the stream's own replaces it once read; see `recordProbedFormat`).
    /// HI_RES_LOSSLESS is a placeholder: it may arrive as 24/44.1 up to 24/192.
    var listedFormat: (codec: String, lossless: Bool, sampleRate: Double, bitDepth: Int?, bitrate: Double?) {
        switch listedQuality {
        case "HI_RES_LOSSLESS": ("FLAC", true, 96_000, 24, nil)
        case "HI_RES": ("FLAC", true, 48_000, 24, nil)    // MQA: a 24-bit FLAC that unfolds above 48 kHz
        case "HIGH": ("AAC", false, 44_100, nil, 320)
        case "LOW": ("AAC", false, 44_100, nil, 96)
        default: ("FLAC", true, 44_100, 16, nil)          // LOSSLESS, and anything TIDAL adds later
        }
    }
}

extension LibrarySource {
    /// The TIDAL account's source: not a folder, never scanned.
    public static let tidalPath = "tidal://"
    public var isTidal: Bool { path == Self.tidalPath }
}

extension LibraryDatabase {
    public static func tidalLocation(_ tidalId: Int) -> String { "tidal://track/\(tidalId)" }

    /// The account's source row: created on first use, and the same one afterwards (a library holds one TIDAL account, so a
    /// different user signing in takes the row over).
    public func tidalSource(userId: Int) throws -> LibrarySource {
        try writer.write { db in
            let remote = "tidal://user/\(userId)"
            if var existing = try LibrarySource.filter(Column("path") == LibrarySource.tidalPath).fetchOne(db) {
                if existing.remoteURL != remote || existing.name != "TIDAL" {
                    existing.remoteURL = remote; existing.name = "TIDAL"
                    try existing.update(db)
                }
                return existing
            }
            var source = LibrarySource(path: LibrarySource.tidalPath, mode: .reference, isOnline: true, remoteURL: remote, name: "TIDAL")
            try source.insert(db)
            return source
        }
    }

    /// Stores TIDAL's tracks as library tracks of the TIDAL source, by `tidalId`: a track already there keeps its id, plays, rating,
    /// date added and download, and takes TIDAL's new descriptions. Returns each tidalId's track id.
    @discardableResult
    public func upsertTidalTracks(_ inputs: [TidalTrackInput], sourceId: Int64) throws -> [Int: Int64] {
        try writer.write { db in
            var ids: [Int: Int64] = [:]
            let now = Date()
            var known: [Int: TidalTrackRecord] = [:]
            for record in try TidalTrackRecord.fetchAll(db) { known[record.tidalId] = record }
            for input in inputs {
                let format = input.listedFormat
                let existing = known[input.tidalId]
                var track: Track
                if let existing, let stored = try Track.fetchOne(db, key: existing.trackId) {
                    track = stored
                } else {
                    track = Track(id: nil, sourceId: sourceId, location: Self.tidalLocation(input.tidalId), filePath: "", fileSize: 0,
                                  modifiedAt: now, addedAt: now, codec: format.codec, isLossless: format.lossless, isDSD: false,
                                  sampleRate: format.sampleRate, bitDepth: format.bitDepth, channels: 2, duration: input.duration,
                                  bitrate: format.bitrate, cueStartFrame: nil, cueFrameLength: nil, title: input.title, artist: nil,
                                  album: nil, albumArtist: nil, composer: nil, genre: nil, releaseDate: nil, year: nil, trackNumber: nil,
                                  trackTotal: nil, discNumber: nil, discTotal: nil, compilation: false, grouping: nil, comment: nil,
                                  lyrics: nil, bpm: nil, rating: nil, isrc: nil, label: nil, musicBrainzReleaseID: nil,
                                  musicBrainzRecordingID: nil, titleSort: nil, artistSort: nil, albumSort: nil, albumArtistSort: nil,
                                  extraTags: [:], rgTrackGain: nil, rgTrackPeak: nil, rgAlbumGain: nil, rgAlbumPeak: nil, artworkKey: nil,
                                  playCount: 0, lastPlayedAt: nil, isMissing: false, effectiveBitDepth: nil, bandwidthHz: nil,
                                  analysisVerdict: nil)
                }
                track.sourceId = sourceId
                track.location = Self.tidalLocation(input.tidalId)
                track.isMissing = false
                track.title = input.title
                track.artist = input.artist
                track.album = input.album
                track.albumArtist = input.albumArtist
                track.trackNumber = input.trackNumber
                track.discNumber = input.discNumber
                track.trackTotal = input.trackTotal
                track.discTotal = input.discTotal
                track.duration = input.duration
                track.isrc = input.isrc
                track.releaseDate = input.releaseDate
                track.year = input.year
                track.artworkKey = input.coverUUID.map { "tidal:\($0)" }
                track.rgTrackGain = input.replayGain.trackGain
                track.rgTrackPeak = input.replayGain.trackPeak
                track.rgAlbumGain = input.replayGain.albumGain
                track.rgAlbumPeak = input.replayGain.albumPeak
                // What was read from the stream (or the file) is truer than what TIDAL lists.
                if existing?.formatIsProbed != true {
                    track.codec = format.codec; track.isLossless = format.lossless; track.sampleRate = format.sampleRate
                    track.bitDepth = format.bitDepth; track.bitrate = format.bitrate
                }
                try track.save(db)
                guard let trackId = track.id else { continue }
                var record = existing ?? TidalTrackRecord(trackId: trackId, tidalId: input.tidalId, albumId: nil, artistIds: [], listedQuality: nil,
                                                          mediaTags: [], explicit: false, copyright: nil, popularity: nil, streamable: true,
                                                          unavailableReason: nil, downloadPath: nil, formatIsProbed: false, lastSyncedAt: nil)
                record.trackId = trackId
                record.albumId = input.albumId
                record.artistIds = input.artistIds
                record.listedQuality = input.listedQuality
                record.mediaTags = input.mediaTags
                record.explicit = input.explicit
                record.copyright = input.copyright
                record.popularity = input.popularity
                record.streamable = input.streamable
                record.unavailableReason = input.unavailableReason
                record.lastSyncedAt = now
                try record.save(db)
                ids[input.tidalId] = trackId
            }
            return ids
        }
    }

    /// Takes out the tracks of the TIDAL source that are not in `keep` (the favorites as of now). A downloaded one stays, marked
    /// `notInFavorites`: its file is the user's.
    public func removeTidalTracks(notIn keep: Set<Int>, sourceId: Int64) throws {
        try writer.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.trackId, d.tidalId, d.downloadPath FROM tidalTrack d JOIN track t ON t.id = d.trackId WHERE t.sourceId = ?
                """, arguments: [sourceId])
            for row in rows {
                let tidalId: Int = row["tidalId"], trackId: Int64 = row["trackId"]
                guard !keep.contains(tidalId) else { continue }
                if (row["downloadPath"] as String?) != nil {
                    try db.execute(sql: "UPDATE tidalTrack SET unavailableReason = ? WHERE trackId = ?",
                                   arguments: [TidalTrackRecord.notInFavorites, trackId])
                } else {
                    try db.execute(sql: "DELETE FROM track WHERE id = ?", arguments: [trackId])
                }
            }
        }
    }

    /// The format the stream (or the downloaded file) turned out to have: it replaces what TIDAL listed, and later syncs leave it be.
    public func recordProbedFormat(trackId: Int64, codec: String, sampleRate: Double, bitDepth: Int?, channels: Int) throws {
        try writer.write { db in
            let name = Self.libraryCodecName(codec)
            let lossy = MetadataReader.lossyCodecs.contains(name)
            try db.execute(sql: """
                UPDATE track SET codec = ?, isLossless = ?, sampleRate = ?, bitDepth = ?, channels = ?, bitrate = CASE WHEN ? THEN bitrate ELSE NULL END
                WHERE id = ?
                """, arguments: [name, !lossy, sampleRate, bitDepth, channels, lossy, trackId])
            try db.execute(sql: "UPDATE tidalTrack SET formatIsProbed = 1 WHERE trackId = ?", arguments: [trackId])
        }
    }

    /// The names the library shows for a codec ("FLAC", not "flac"): its filters and format marks compare them.
    static func libraryCodecName(_ codec: String) -> String {
        switch codec.lowercased() {
        case "flac": "FLAC"
        case "aac": "AAC"
        case "alac": "ALAC"
        default: codec
        }
    }

    /// The track's download is at `path` (it plays from there, offline), or is gone (nil).
    public func setTidalDownload(tidalId: Int, path: String?) throws {
        try writer.write { db in
            guard let trackId = try Int64.fetchOne(db, sql: "SELECT trackId FROM tidalTrack WHERE tidalId = ?", arguments: [tidalId]) else { return }
            if let path {
                // Size and date as a scan of the folder will list them, so that scan finds the file unchanged.
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                let modified = attributes?[.modificationDate] as? Date
                try db.execute(sql: "UPDATE tidalTrack SET downloadPath = ? WHERE trackId = ?", arguments: [path, trackId])
                try db.execute(sql: "UPDATE track SET filePath = ?, fileSize = ?, modifiedAt = coalesce(?, modifiedAt) WHERE id = ?",
                               arguments: [path, size, modified, trackId])
            } else {
                try Self.clearTidalDownload(db, trackId: trackId)
            }
        }
    }

    static func clearTidalDownload(_ db: Database, trackId: Int64) throws {
        try db.execute(sql: "UPDATE tidalTrack SET downloadPath = NULL WHERE trackId = ?", arguments: [trackId])
        try db.execute(sql: "UPDATE track SET filePath = '', fileSize = 0 WHERE id = ?", arguments: [trackId])
    }

    public func tidalRecord(trackId: Int64) throws -> TidalTrackRecord? {
        try writer.read { db in try TidalTrackRecord.fetchOne(db, key: trackId) }
    }

    /// A scanned file that carries `TIDAL_TRACK_ID` of a track the library has: the track now has this file as its download, and the
    /// file is not a track of its own. False when no such track is there (the file is then added like any other).
    static func linkTidalDownload(_ db: Database, scanned file: Track) throws -> Bool {
        guard let text = file.extraTags["TIDAL_TRACK_ID"], let tidalId = Int(text.trimmingCharacters(in: .whitespaces)),
              let trackId = try Int64.fetchOne(db, sql: "SELECT trackId FROM tidalTrack WHERE tidalId = ?", arguments: [tidalId])
        else { return false }
        // The file is the truth about its own format; size and date are what the next scan compares to leave it alone.
        try db.execute(sql: """
            UPDATE track SET filePath = ?, fileSize = ?, modifiedAt = ?, codec = ?, isLossless = ?, isDSD = ?, sampleRate = ?, bitDepth = ?,
                             channels = ?, bitrate = ?
            WHERE id = ?
            """, arguments: [file.filePath, file.fileSize, file.modifiedAt, file.codec, file.isLossless, file.isDSD, file.sampleRate,
                             file.bitDepth, file.channels, file.bitrate, trackId])
        try db.execute(sql: "UPDATE tidalTrack SET downloadPath = ?, formatIsProbed = 1 WHERE trackId = ?", arguments: [file.filePath, trackId])
        return true
    }
}
