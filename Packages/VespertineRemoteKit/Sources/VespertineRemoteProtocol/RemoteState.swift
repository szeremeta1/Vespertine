//
// Vespertine: what the Mac tells a remote about playback, the queue, the outputs and the library.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

public enum PlaybackValue: String, Codable, Sendable, Equatable {
    case playing, paused, stopped
}

public struct PlayerState: Codable, Sendable, Equatable {
    public var playback: PlaybackValue
    /// Waiting for a network share or a song being copied before it plays.
    public var loading: Bool
    public var nowPlaying: NowPlaying?
    /// Seconds into the song at `positionAt` (the Mac's clock). While playing, a remote adds the time since it received the
    /// message, rather than comparing clocks.
    public var position: Double
    public var positionAt: Date
    public var duration: Double
    public var shuffle: Bool
    public var repeatMode: RepeatModeValue
    public var signal: SignalSummary?
    public var output: String?
    public var volume: VolumeState
    /// The chosen output that isn't connected, while playback waits for it.
    public var waitingFor: String?
    /// The last error the Mac shows, word for word.
    public var error: String?
    /// Transitions (Smart Mix, crossfades): nil while the feature is off in the Mac's settings.
    public var transitions: Bool?

    public init(playback: PlaybackValue, loading: Bool, nowPlaying: NowPlaying?, position: Double, positionAt: Date,
                duration: Double, shuffle: Bool, repeatMode: RepeatModeValue, signal: SignalSummary?, output: String?,
                volume: VolumeState, waitingFor: String?, error: String?, transitions: Bool?) {
        self.playback = playback
        self.loading = loading
        self.nowPlaying = nowPlaying
        self.position = position
        self.positionAt = positionAt
        self.duration = duration
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.signal = signal
        self.output = output
        self.volume = volume
        self.waitingFor = waitingFor
        self.error = error
        self.transitions = transitions
    }

    /// Whether `other` says something new to a remote that has this: anything but the position, or a position that
    /// isn't where this one would have reached by `other.positionAt` (a seek, a stall), give or take `tolerance` seconds.
    public func differs(from other: PlayerState, tolerance: Double = 1.5) -> Bool {
        var a = self, b = other
        a.position = 0; a.positionAt = .distantPast
        b.position = 0; b.positionAt = .distantPast
        if a != b { return true }
        return abs(other.position - expectedPosition(at: other.positionAt)) > tolerance
    }

    /// Where the song would be at `date` if nothing changed.
    public func expectedPosition(at date: Date) -> Double {
        guard playback == .playing, !loading else { return position }
        let moved = position + date.timeIntervalSince(positionAt)
        return duration > 0 ? min(moved, duration) : moved
    }
}

public struct NowPlaying: Codable, Sendable, Equatable {
    /// The queue entry (`QueueItem.entry`).
    public var entry: String
    public var track: TrackSummary

    public init(entry: String, track: TrackSummary) {
        self.entry = entry
        self.track = track
    }
}

/// The signal path as the Mac's device chip and badge show it.
public struct SignalSummary: Codable, Sendable, Equatable {
    /// Every sample reaches the DAC unchanged.
    public var bitPerfect: Bool
    /// The badge's words ("BIT-PERFECT", "RESAMPLED", "MIXING"…), in the Mac's language.
    public var badge: String
    /// What the DAC receives ("24/192"), and whether Vespertine has the device to itself.
    public var deviceFormat: String
    public var exclusive: Bool

    public init(bitPerfect: Bool, badge: String, deviceFormat: String, exclusive: Bool) {
        self.bitPerfect = bitPerfect
        self.badge = badge
        self.deviceFormat = deviceFormat
        self.exclusive = exclusive
    }
}

public enum VolumeRoute: String, Codable, Sendable, Equatable {
    /// The DAC's or receiver's own volume: no sample changes, bit-perfect stays.
    case hardware
    /// Vespertine's digital volume for this output, which the user turned on (not bit-perfect below full level).
    case software
    /// No volume to move here: set it on the amplifier.
    case fixed
}

public struct VolumeState: Codable, Sendable, Equatable {
    public var route: VolumeRoute
    /// 0…1; nil when `route` is fixed or the level can't be read.
    public var level: Double?
    public var muted: Bool

    public init(route: VolumeRoute, level: Double?, muted: Bool) {
        self.route = route
        self.level = level
        self.muted = muted
    }
}

public struct QueueItem: Codable, Sendable, Equatable {
    /// The entry's ID in the Mac's queue (the same song can be queued twice; each entry has its own).
    public var entry: String
    public var track: TrackSummary

    public init(entry: String, track: TrackSummary) {
        self.entry = entry
        self.track = track
    }
}

public struct QueueState: Codable, Sendable, Equatable {
    /// Changes whenever the queue does.
    public var revision: Int
    public var current: QueueItem?
    /// Added with Play Next or Add to Queue: they play before the rest.
    public var playingNext: [QueueItem]
    /// The rest of the album, playlist or list that was started, up to `QueueState.continuingLimit` songs.
    public var continuing: [QueueItem]
    /// How many songs `continuing` has in all (more than it lists when the list is long).
    public var continuingTotal: Int

    public static let continuingLimit = 500

    public init(revision: Int, current: QueueItem?, playingNext: [QueueItem], continuing: [QueueItem], continuingTotal: Int) {
        self.revision = revision
        self.current = current
        self.playingNext = playingNext
        self.continuing = continuing
        self.continuingTotal = continuingTotal
    }
}

public enum OutputKind: String, Codable, Sendable, Equatable {
    /// "System Default": follows the Mac's Sound settings.
    case systemDefault
    case device
    case speakerGroup
}

public struct OutputSummary: Codable, Sendable, Equatable {
    /// What `selectOutput` takes (nil for System Default).
    public var uid: String?
    public var name: String
    /// "USB DAC · 44.1–384 kHz", as the Mac's output list shows it.
    public var detail: String
    public var kind: OutputKind
    public var selected: Bool
    /// Connected (for a speaker group: all of its outputs are).
    public var ready: Bool

    public init(uid: String?, name: String, detail: String, kind: OutputKind, selected: Bool, ready: Bool) {
        self.uid = uid
        self.name = name
        self.detail = detail
        self.kind = kind
        self.selected = selected
        self.ready = ready
    }
}

public struct OutputsState: Codable, Sendable, Equatable {
    public var outputs: [OutputSummary]

    public init(outputs: [OutputSummary]) { self.outputs = outputs }
}

public struct TrackSummary: Codable, Sendable, Equatable, Identifiable {
    /// The library's song ID; nil for a file played without being in the library.
    public var id: Int64?
    public var title: String
    public var artist: String
    public var album: String
    public var albumKey: String
    public var duration: Double
    public var trackNumber: Int?
    public var discNumber: Int?
    /// "FLAC · 24/96", "DSD128", "MP3 · 320k · 5.1"
    public var format: String
    public var artworkKey: String?
    public var favorite: Bool

    public init(id: Int64?, title: String, artist: String, album: String, albumKey: String, duration: Double,
                trackNumber: Int?, discNumber: Int?, format: String, artworkKey: String?, favorite: Bool) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumKey = albumKey
        self.duration = duration
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.format = format
        self.artworkKey = artworkKey
        self.favorite = favorite
    }
}

public struct AlbumSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String { key }
    public var key: String
    public var title: String
    public var artist: String
    public var year: Int?
    public var trackCount: Int
    public var duration: Double
    public var format: String
    public var artworkKey: String?
    public var hiRes: Bool
    public var dsd: Bool
    public var multichannel: Bool

    public init(key: String, title: String, artist: String, year: Int?, trackCount: Int, duration: Double, format: String,
                artworkKey: String?, hiRes: Bool, dsd: Bool, multichannel: Bool) {
        self.key = key
        self.title = title
        self.artist = artist
        self.year = year
        self.trackCount = trackCount
        self.duration = duration
        self.format = format
        self.artworkKey = artworkKey
        self.hiRes = hiRes
        self.dsd = dsd
        self.multichannel = multichannel
    }

    private enum CodingKeys: String, CodingKey {
        case key, title, artist, year, trackCount, duration, format, artworkKey, hiRes, dsd, multichannel
    }
}

public struct ArtistSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var albumCount: Int
    public var artworkKey: String?

    public init(name: String, albumCount: Int, artworkKey: String?) {
        self.name = name
        self.albumCount = albumCount
        self.artworkKey = artworkKey
    }

    private enum CodingKeys: String, CodingKey { case name, albumCount, artworkKey }
}

public struct PlaylistSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: Int64
    public var name: String
    public var smart: Bool
    /// How many songs it has; nil from an older Mac, which doesn't say.
    public var trackCount: Int?
    /// Up to four covers of its songs, for a tile; nil from an older Mac.
    public var artworkKeys: [String]?

    public init(id: Int64, name: String, smart: Bool, trackCount: Int? = nil, artworkKeys: [String]? = nil) {
        self.id = id
        self.name = name
        self.smart = smart
        self.trackCount = trackCount
        self.artworkKeys = artworkKeys
    }
}

/// What a search found, in groups (the answer to `RemoteCommand.find`).
public struct SearchResults: Codable, Sendable, Equatable {
    public var tracks: [TrackSummary]
    public var albums: [AlbumSummary]
    public var artists: [ArtistSummary]
    public var playlists: [PlaylistSummary]

    public init(tracks: [TrackSummary], albums: [AlbumSummary], artists: [ArtistSummary], playlists: [PlaylistSummary]) {
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
    }
}
