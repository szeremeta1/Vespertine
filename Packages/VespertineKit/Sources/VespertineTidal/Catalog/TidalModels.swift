//
// Vespertine: TIDAL's v1 catalog objects (tracks, albums, artists, playlists) as the app reads them. Decoding is forgiving about
// fields TIDAL leaves out, because one odd item must not lose a whole page of favorites.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public struct TidalArtistRef: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    /// The role on this release: `MAIN`, `FEATURED`, …
    public var type: String?
    public var picture: String?

    public init(id: Int, name: String, type: String? = nil, picture: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.picture = picture
    }
}

public struct TidalAlbumRef: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var title: String
    /// An image UUID for `TidalCatalog.coverURL`.
    public var cover: String?
    public var releaseDate: String?

    public init(id: Int, title: String, cover: String? = nil, releaseDate: String? = nil) {
        self.id = id
        self.title = title
        self.cover = cover
        self.releaseDate = releaseDate
    }
}

public struct TidalTrack: Codable, Sendable, Hashable, Identifiable {
    public struct Tags: Codable, Sendable, Hashable {
        public var tags: [String]
        public init(tags: [String]) { self.tags = tags }
    }

    public var id: Int
    public var title: String
    public var version: String?
    /// Seconds.
    public var duration: Int
    public var trackNumber: Int
    public var volumeNumber: Int
    public var isrc: String?
    public var explicit: Bool
    /// `LOW`, `HIGH`, `LOSSLESS` or `HI_RES_LOSSLESS`.
    public var audioQuality: String
    public var mediaMetadata: Tags?
    public var replayGain: Double?
    public var peak: Double?
    public var copyright: String?
    public var popularity: Int?
    public var streamReady: Bool?
    public var allowStreaming: Bool?
    public var artists: [TidalArtistRef]
    public var album: TidalAlbumRef

    public init(id: Int, title: String, version: String? = nil, duration: Int, trackNumber: Int, volumeNumber: Int = 1,
                isrc: String? = nil, explicit: Bool = false, audioQuality: String = "LOSSLESS", mediaMetadata: Tags? = nil,
                replayGain: Double? = nil, peak: Double? = nil, copyright: String? = nil, popularity: Int? = nil,
                streamReady: Bool? = nil, allowStreaming: Bool? = nil, artists: [TidalArtistRef], album: TidalAlbumRef) {
        self.id = id; self.title = title; self.version = version; self.duration = duration; self.trackNumber = trackNumber
        self.volumeNumber = volumeNumber; self.isrc = isrc; self.explicit = explicit; self.audioQuality = audioQuality
        self.mediaMetadata = mediaMetadata; self.replayGain = replayGain; self.peak = peak; self.copyright = copyright
        self.popularity = popularity; self.streamReady = streamReady; self.allowStreaming = allowStreaming
        self.artists = artists; self.album = album
    }

    /// True when TIDAL tags the track as hi-res (`HIRES_LOSSLESS`).
    public var hasHiRes: Bool { mediaMetadata?.tags.contains("HIRES_LOSSLESS") ?? false }

    private enum Keys: String, CodingKey {
        case id, title, version, duration, trackNumber, volumeNumber, isrc, explicit, audioQuality, mediaMetadata
        case replayGain, peak, copyright, popularity, streamReady, allowStreaming, artists, album
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration) ?? 0
        trackNumber = try c.decodeIfPresent(Int.self, forKey: .trackNumber) ?? 1
        volumeNumber = try c.decodeIfPresent(Int.self, forKey: .volumeNumber) ?? 1
        isrc = try c.decodeIfPresent(String.self, forKey: .isrc)
        explicit = try c.decodeIfPresent(Bool.self, forKey: .explicit) ?? false
        audioQuality = try c.decodeIfPresent(String.self, forKey: .audioQuality) ?? "LOSSLESS"
        mediaMetadata = try c.decodeIfPresent(Tags.self, forKey: .mediaMetadata)
        replayGain = try c.decodeIfPresent(Double.self, forKey: .replayGain)
        peak = try c.decodeIfPresent(Double.self, forKey: .peak)
        copyright = try c.decodeIfPresent(String.self, forKey: .copyright)
        popularity = try c.decodeIfPresent(Int.self, forKey: .popularity)
        streamReady = try c.decodeIfPresent(Bool.self, forKey: .streamReady)
        allowStreaming = try c.decodeIfPresent(Bool.self, forKey: .allowStreaming)
        artists = try c.decodeIfPresent([TidalArtistRef].self, forKey: .artists) ?? []
        album = try c.decode(TidalAlbumRef.self, forKey: .album)
    }
}

public struct TidalAlbum: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var title: String
    public var version: String?
    public var duration: Int?
    public var numberOfTracks: Int
    public var numberOfVolumes: Int
    /// `yyyy-MM-dd`, as TIDAL sends it.
    public var releaseDate: String?
    public var cover: String?
    public var upc: String?
    public var explicit: Bool
    public var audioQuality: String?
    public var mediaMetadata: TidalTrack.Tags?
    public var copyright: String?
    public var artist: TidalArtistRef?
    public var artists: [TidalArtistRef]

    public init(id: Int, title: String, version: String? = nil, duration: Int? = nil, numberOfTracks: Int, numberOfVolumes: Int = 1,
                releaseDate: String? = nil, cover: String? = nil, upc: String? = nil, explicit: Bool = false,
                audioQuality: String? = nil, mediaMetadata: TidalTrack.Tags? = nil, copyright: String? = nil,
                artist: TidalArtistRef? = nil, artists: [TidalArtistRef] = []) {
        self.id = id; self.title = title; self.version = version; self.duration = duration; self.numberOfTracks = numberOfTracks
        self.numberOfVolumes = numberOfVolumes; self.releaseDate = releaseDate; self.cover = cover; self.upc = upc
        self.explicit = explicit; self.audioQuality = audioQuality; self.mediaMetadata = mediaMetadata
        self.copyright = copyright; self.artist = artist; self.artists = artists
    }

    private enum Keys: String, CodingKey {
        case id, title, version, duration, numberOfTracks, numberOfVolumes, releaseDate, cover, upc, explicit
        case audioQuality, mediaMetadata, copyright, artist, artists
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        numberOfTracks = try c.decodeIfPresent(Int.self, forKey: .numberOfTracks) ?? 0
        numberOfVolumes = try c.decodeIfPresent(Int.self, forKey: .numberOfVolumes) ?? 1
        releaseDate = try c.decodeIfPresent(String.self, forKey: .releaseDate)
        cover = try c.decodeIfPresent(String.self, forKey: .cover)
        upc = try c.decodeIfPresent(String.self, forKey: .upc)
        explicit = try c.decodeIfPresent(Bool.self, forKey: .explicit) ?? false
        audioQuality = try c.decodeIfPresent(String.self, forKey: .audioQuality)
        mediaMetadata = try c.decodeIfPresent(TidalTrack.Tags.self, forKey: .mediaMetadata)
        copyright = try c.decodeIfPresent(String.self, forKey: .copyright)
        artist = try c.decodeIfPresent(TidalArtistRef.self, forKey: .artist)
        artists = try c.decodeIfPresent([TidalArtistRef].self, forKey: .artists) ?? []
    }
}

public struct TidalArtist: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var picture: String?
    public var popularity: Int?

    public init(id: Int, name: String, picture: String? = nil, popularity: Int? = nil) {
        self.id = id; self.name = name; self.picture = picture; self.popularity = popularity
    }
}

public struct TidalPlaylist: Codable, Sendable, Hashable, Identifiable {
    public var id: String { uuid }
    public var uuid: String
    public var title: String
    public var numberOfTracks: Int
    public var lastUpdated: String?
    public var description: String?
    public var squareImage: String?

    public init(uuid: String, title: String, numberOfTracks: Int, lastUpdated: String? = nil, description: String? = nil, squareImage: String? = nil) {
        self.uuid = uuid; self.title = title; self.numberOfTracks = numberOfTracks
        self.lastUpdated = lastUpdated; self.description = description; self.squareImage = squareImage
    }

    private enum Keys: String, CodingKey { case uuid, title, numberOfTracks, lastUpdated, description, squareImage }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        title = try c.decode(String.self, forKey: .title)
        numberOfTracks = try c.decodeIfPresent(Int.self, forKey: .numberOfTracks) ?? 0
        lastUpdated = try c.decodeIfPresent(String.self, forKey: .lastUpdated)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        squareImage = try c.decodeIfPresent(String.self, forKey: .squareImage)
    }
}

/// One page of a TIDAL list.
public struct TidalPage<T: Codable & Sendable>: Codable, Sendable {
    public var limit: Int
    public var offset: Int
    public var totalNumberOfItems: Int
    public var items: [T]

    public init(limit: Int, offset: Int, totalNumberOfItems: Int, items: [T]) {
        self.limit = limit; self.offset = offset; self.totalNumberOfItems = totalNumberOfItems; self.items = items
    }
}

public struct TidalSearchResult: Sendable {
    public var tracks: [TidalTrack]
    public var albums: [TidalAlbum]
    public var artists: [TidalArtist]
    public var playlists: [TidalPlaylist]

    public init(tracks: [TidalTrack] = [], albums: [TidalAlbum] = [], artists: [TidalArtist] = [], playlists: [TidalPlaylist] = []) {
        self.tracks = tracks; self.albums = albums; self.artists = artists; self.playlists = playlists
    }
}

public struct TidalContributor: Codable, Sendable, Hashable {
    public var name: String
    public var id: Int?
}

/// A credit role (`Producer`, `Composer`, …) and who held it.
public struct TidalCredit: Codable, Sendable, Hashable {
    public var type: String
    public var contributors: [TidalContributor]
}

/// A TIDAL mix (My Mix 1, Daily Discovery…): an id string and its titles.
public struct TidalMix: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var subTitle: String?

    public init(id: String, title: String, subTitle: String? = nil) {
        self.id = id; self.title = title; self.subTitle = subTitle
    }
}
