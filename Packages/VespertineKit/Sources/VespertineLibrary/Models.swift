//
// Vespertine — library records.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import VespertineAudio

/// A folder or volume the library indexes.
public struct LibrarySource: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public enum Mode: String, Codable, Sendable { case reference, managed }

    public var id: Int64?
    public var path: String
    public var bookmark: Data?
    public var mode: Mode
    public var addedAt: Date
    public var lastScannedAt: Date?
    public var isOnline: Bool
    /// Network shares: the server URL (no password), e.g. smb://user@host/share/folder.
    public var remoteURL: String?
    /// User-chosen name (network shares default to the share or folder name).
    public var name: String?
    /// Network shares: mounted read-write (tags can be edited) instead of read-only.
    public var isWritable: Bool

    public static let databaseTableName = "source"

    public var isNetwork: Bool { remoteURL != nil }

    public init(id: Int64? = nil, path: String, bookmark: Data? = nil, mode: Mode, addedAt: Date = .now, lastScannedAt: Date? = nil, isOnline: Bool = true, remoteURL: String? = nil, name: String? = nil, isWritable: Bool = false) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.mode = mode
        self.addedAt = addedAt
        self.lastScannedAt = lastScannedAt
        self.isOnline = isOnline
        self.remoteURL = remoteURL
        self.name = name
        self.isWritable = isWritable
    }

    /// The share this source indexes, for network sources.
    public var networkShare: NetworkShare? { remoteURL.flatMap(NetworkShare.init(string:)) }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// Decided from the name, never by touching the disk (a source may be on a share that's gone).
    public var url: URL {
        let isFile = LibraryScanner.audioExtensions.contains((path as NSString).pathExtension.lowercased())
        return URL(fileURLWithPath: path, isDirectory: !isFile)
    }
    /// Short name for the sidebar: the name the user gave it, "Imported Music" for the folder the app
    /// imports into, the volume name for external drives, else the folder name.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        if mode == .managed { return "Imported Music" }
        if let remoteURL, let share = NetworkShare(string: remoteURL) { return share.defaultName }
        let components = url.pathComponents
        if path.hasPrefix("/Volumes/"), components.count == 3 { return components[2] }
        return url.lastPathComponent
    }
}

/// One playable track (a file, or a region of one described by a CUE sheet).
public struct Track: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var sourceId: Int64?
    /// File path; CUE tracks append "#<number>".
    public var location: String
    public var filePath: String
    public var fileSize: Int64
    public var modifiedAt: Date
    public var addedAt: Date

    // Technical
    public var codec: String
    public var isLossless: Bool
    public var isDSD: Bool
    public var sampleRate: Double
    public var bitDepth: Int?
    public var channels: Int
    public var duration: Double
    public var bitrate: Double?
    public var cueStartFrame: Int64?
    public var cueFrameLength: Int64?

    // Descriptive
    public var title: String
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var composer: String?
    public var genre: String?
    public var releaseDate: String?
    public var year: Int?
    public var trackNumber: Int?
    public var trackTotal: Int?
    public var discNumber: Int?
    public var discTotal: Int?
    public var compilation: Bool
    public var grouping: String?
    public var comment: String?
    public var lyrics: String?
    public var bpm: Int?
    public var rating: Int?
    public var isrc: String?
    public var label: String?
    public var musicBrainzReleaseID: String?
    public var musicBrainzRecordingID: String?
    public var titleSort: String?
    public var artistSort: String?
    public var albumSort: String?
    public var albumArtistSort: String?
    public var extraTags: [String: String]

    // ReplayGain
    public var rgTrackGain: Double?
    public var rgTrackPeak: Double?
    public var rgAlbumGain: Double?
    public var rgAlbumPeak: Double?

    // Library state
    public var artworkKey: String?
    public var playCount: Int
    public var lastPlayedAt: Date?
    public var isMissing: Bool

    // Analysis
    public var effectiveBitDepth: Int?
    public var bandwidthHz: Double?
    public var analysisVerdict: String?

    public static let databaseTableName = "track"

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// Never touches the disk (without `isDirectory`, Foundation lstat()s the path — a network round
    /// trip for tracks on a share, and a hang if the share has gone away).
    public var fileURL: URL { URL(fileURLWithPath: filePath, isDirectory: false) }
    public var displayArtist: String { artist ?? albumArtist ?? "Unknown Artist" }
    public var displayAlbumArtist: String { albumArtist ?? artist ?? "Unknown Artist" }
    public var displayAlbum: String { album ?? "Unknown Album" }

    /// Key used to group tracks into albums.
    public var albumKey: String { "\(displayAlbumArtist.lowercased())\u{1F}\(displayAlbum.lowercased())" }

    /// "FLAC · 24/96", "DSD128", "MP3 · 320k"
    /// " · 5.1" for multichannel tracks, empty for mono/stereo.
    public var channelSuffix: String { channels > 2 ? " · " + ChannelLayouts.name(channels: channels) : "" }
    public var isMultichannel: Bool { channels > 2 }

    public var formatSummary: String { baseFormatSummary + channelSuffix }

    private var baseFormatSummary: String {
        if isDSD { return "DSD\(Int((sampleRate / 44_100).rounded()))" }
        let rate = sampleRate.truncatingRemainder(dividingBy: 1000) == 0
            ? String(Int(sampleRate / 1000)) : String(format: "%.1f", sampleRate / 1000)
        if !isLossless, let bitrate { return "\(codec) · \(Int(bitrate))k" }
        if let bitDepth { return "\(codec) · \(bitDepth)/\(rate)" }
        return "\(codec) · \(rate) kHz"
    }

    public var isHiRes: Bool { isDSD || (isLossless && ((bitDepth ?? 16) > 16 || sampleRate > 48_000)) }
}

public struct Playlist: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String
    public var smartRules: SmartRules?
    public var createdAt: Date
    public var sortIndex: Int

    public static let databaseTableName = "playlist"
    public var isSmart: Bool { smartRules != nil }

    public init(id: Int64? = nil, name: String, smartRules: SmartRules? = nil, createdAt: Date = .now, sortIndex: Int = 0) {
        self.id = id
        self.name = name
        self.smartRules = smartRules
        self.createdAt = createdAt
        self.sortIndex = sortIndex
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct PlaylistItem: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public var playlistId: Int64
    public var trackId: Int64
    public var position: Int

    public static let databaseTableName = "playlistItem"
}

/// Previous tag values, kept so a metadata edit can be reverted.
public struct TagHistoryEntry: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var trackId: Int64
    public var editedAt: Date
    public var previous: [String: String]
    public var fileBackupPath: String?

    public static let databaseTableName = "tagHistory"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Derived album (not stored).
public struct Album: Sendable, Hashable, Identifiable {
    public var id: String { key }
    public var key: String
    public var title: String
    public var artist: String
    public var year: Int?
    public var genre: String?
    public var trackCount: Int
    public var duration: Double
    public var artworkKey: String?
    public var formatSummary: String
    public var codec: String
    public var maxBitDepth: Int?
    public var maxSampleRate: Double
    public var isHiRes: Bool
    public var isDSD: Bool
    public var addedAt: Date
    public var totalSize: Int64
    public var sourcePath: String?
    /// Most channels on any track (2 for stereo albums).
    public var maxChannels: Int = 2
    public var isMultichannel: Bool { maxChannels > 2 }

    public init(key: String, title: String, artist: String, year: Int?, genre: String?, trackCount: Int, duration: Double,
                artworkKey: String?, formatSummary: String, codec: String, maxBitDepth: Int?, maxSampleRate: Double, isHiRes: Bool,
                isDSD: Bool, addedAt: Date, totalSize: Int64, sourcePath: String?, maxChannels: Int = 2) {
        self.key = key; self.title = title; self.artist = artist; self.year = year; self.genre = genre
        self.trackCount = trackCount; self.duration = duration; self.artworkKey = artworkKey; self.formatSummary = formatSummary
        self.codec = codec; self.maxBitDepth = maxBitDepth; self.maxSampleRate = maxSampleRate; self.isHiRes = isHiRes
        self.isDSD = isDSD; self.addedAt = addedAt; self.totalSize = totalSize; self.sourcePath = sourcePath; self.maxChannels = maxChannels
    }
}

// Only descriptive fields are overlaid: rescans still refresh file availability and CUE boundaries.
extension Track {
    mutating func copyMetadata(from t: Track) {
        title = t.title; artist = t.artist; album = t.album; albumArtist = t.albumArtist
        composer = t.composer; genre = t.genre; releaseDate = t.releaseDate; year = t.year
        trackNumber = t.trackNumber; trackTotal = t.trackTotal; discNumber = t.discNumber; discTotal = t.discTotal
        compilation = t.compilation; grouping = t.grouping; comment = t.comment; lyrics = t.lyrics
        bpm = t.bpm; rating = t.rating; isrc = t.isrc; label = t.label
        musicBrainzReleaseID = t.musicBrainzReleaseID; musicBrainzRecordingID = t.musicBrainzRecordingID
        titleSort = t.titleSort; artistSort = t.artistSort; albumSort = t.albumSort; albumArtistSort = t.albumArtistSort
        extraTags = t.extraTags; artworkKey = t.artworkKey
    }
}
