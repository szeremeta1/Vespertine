//
// Vespertine: pulls the TIDAL account into the library: favorite tracks, the tracks of favorite albums, and the user's playlists
// (each a library playlist in TIDAL's order). Read only: nothing is written to TIDAL. A track that is none of these any more
// leaves the library, unless it was downloaded.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineLibrary

/// What the sync and the downloader read of the catalog (`TidalCatalog`; tests answer with a fake).
public protocol TidalCatalogReading: Sendable {
    func favoriteTracks(userId: Int, priority: TidalPriority) async throws -> [TidalTrack]
    func favoriteAlbums(userId: Int, priority: TidalPriority) async throws -> [TidalAlbum]
    func album(_ id: Int, priority: TidalPriority) async throws -> TidalAlbum
    func albumTracks(_ id: Int, priority: TidalPriority) async throws -> [TidalTrack]
    func userPlaylists(userId: Int, priority: TidalPriority) async throws -> [TidalPlaylist]
    func playlistTracks(_ uuid: String, priority: TidalPriority) async throws -> [TidalTrack]
}

extension TidalCatalog: TidalCatalogReading {}

public actor TidalLibrarySync {
    public struct Summary: Sendable, Equatable {
        /// Rows made, and rows that were there and took TIDAL's descriptions again.
        public var added: Int
        public var updated: Int
        /// Rows taken out (downloaded ones stay and are not counted).
        public var removed: Int
        /// The user's TIDAL playlists now in the library.
        public var playlists: Int
        /// Lists TIDAL sent much shorter than last time (see `TidalLibrarySync.looksTruncated`): nothing was deleted for them
        /// this time. One line per list, for the log or the UI.
        public var warnings: [String] = []
    }

    /// A list that comes back empty while the library had items from it, or shrunk by more than half and by more than 20 items,
    /// may be TIDAL answering short (an empty page from a 200), not the user's doing: deleting on it would take tracks and
    /// playlists out of the library. Such a refresh deletes nothing; when the next refresh brings the same length, it is believed.
    static func looksTruncated(fetched: Int, previous: Int?) -> Bool {
        guard let previous, previous > 0 else { return false }
        if fetched == 0 { return true }
        return fetched * 2 < previous && previous - fetched > 20
    }

    private let catalog: any TidalCatalogReading
    private let database: LibraryDatabase
    private let userId: Int

    public init(catalog: any TidalCatalogReading, database: LibraryDatabase, userId: Int) {
        self.catalog = catalog
        self.database = database
        self.userId = userId
    }

    /// One pull, every request at `.sync` priority through the gate. A playlist's items are fetched only when its `lastUpdated`
    /// moved, and a favorite album's tracks only when the library doesn't have all of them yet (albums don't change), so a
    /// refresh with nothing new costs three list requests plus their pages.
    public func refresh() async throws -> Summary {
        let source = try database.tidalSource(userId: userId)
        guard let sourceId = source.id else { throw TidalError.unavailable }
        let before = try database.tidalTrackIds()
        var warnings: [String] = []
        var confirmed: [(key: String, count: Int)] = []
        /// Whether `list`, `fetched` long now, may be acted on; records what to remember of it.
        func trusted(_ list: String, _ fetched: Int) throws -> Bool {
            let previous = try database.tidalSyncValue(list)
            let pending = try database.tidalSyncValue(list + ".pending")
            if Self.looksTruncated(fetched: fetched, previous: previous), pending != fetched {
                try database.setTidalSyncValue(list + ".pending", fetched)
                warnings.append("TIDAL sent \(fetched) \(list) where there were \(previous ?? 0): nothing removed for it until a refresh confirms it")
                return false
            }
            confirmed.append((list, fetched))
            return true
        }

        var inputs: [TidalTrackInput] = []
        var present = Set<Int>()
        let favorites = try await catalog.favoriteTracks(userId: userId, priority: .sync)
        var trustAll = try trusted("favorite tracks", favorites.count)
        for track in favorites {
            inputs.append(TidalTrackInput(track))
            present.insert(track.id)
        }

        let byAlbum = try database.tidalTrackIdsByAlbum()
        let albums = try await catalog.favoriteAlbums(userId: userId, priority: .sync)
        trustAll = try trusted("favorite albums", albums.count) && trustAll
        for album in albums {
            let known = byAlbum[album.id] ?? []
            if album.numberOfTracks > 0, known.count >= album.numberOfTracks {
                present.formUnion(known)
                continue
            }
            for track in try await catalog.albumTracks(album.id, priority: .sync) {
                inputs.append(TidalTrackInput(track, album: album))
                present.insert(track.id)
            }
        }

        let playlists = try await catalog.userPlaylists(userId: userId, priority: .sync)
        let trustPlaylists = try trusted("playlists", playlists.count)
        trustAll = trustPlaylists && trustAll
        let states = try database.tidalPlaylistStates()
        var changed: [(TidalPlaylist, [Int])] = []
        for playlist in playlists {
            if let stored = states[playlist.uuid], stored == playlist.lastUpdated, playlist.lastUpdated != nil {
                present.formUnion(try database.tidalIds(inPlaylist: playlist.uuid))
                continue
            }
            let tracks = try await catalog.playlistTracks(playlist.uuid, priority: .sync)
            inputs += tracks.map { TidalTrackInput($0) }
            present.formUnion(tracks.map(\.id))
            changed.append((playlist, tracks.map(\.id)))
        }

        // Tracks first (a playlist's items need their rows), then playlists, then what is no longer anywhere.
        try database.upsertTidalTracks(inputs, sourceId: sourceId)
        for (playlist, ids) in changed {
            try database.setTidalPlaylist(uuid: playlist.uuid, name: playlist.title, lastUpdated: playlist.lastUpdated, tidalIds: ids)
        }
        if trustPlaylists { try database.removeTidalPlaylists(notIn: Set(playlists.map(\.uuid))) }
        // A track may be in any list, so one list in doubt keeps every track this time.
        let removed = trustAll ? try database.removeTidalTracks(notIn: present, sourceId: sourceId) : 0
        for (list, count) in confirmed {
            try database.setTidalSyncValue(list, count)
            try database.setTidalSyncValue(list + ".pending", nil)
        }

        let upserted = Set(inputs.map(\.tidalId))
        return Summary(added: upserted.subtracting(before).count, updated: upserted.intersection(before).count,
                       removed: removed, playlists: trustPlaylists ? playlists.count : (try database.tidalPlaylistStates().count),
                       warnings: warnings)
    }
}

extension TidalTrackInput {
    /// A TIDAL track as the library stores it. `album`, when known (a favorite album's tracks), gives the album artist and totals.
    public init(_ track: TidalTrack, album: TidalAlbum? = nil) {
        let main = track.artists.first { $0.type == "MAIN" } ?? track.artists.first
        let title = track.version.map { $0.isEmpty ? track.title : "\(track.title) (\($0))" } ?? track.title
        let date = album?.releaseDate ?? track.album.releaseDate
        let streamable = (track.allowStreaming ?? true) && (track.streamReady ?? true)
        self.init(tidalId: track.id, title: title,
                  artist: track.artists.isEmpty ? nil : track.artists.map(\.name).joined(separator: ", "),
                  album: album?.title ?? track.album.title,
                  albumArtist: album?.artist?.name ?? album?.artists.first?.name ?? main?.name,
                  trackNumber: track.trackNumber, discNumber: track.volumeNumber,
                  trackTotal: nil, discTotal: album?.numberOfVolumes,
                  duration: Double(track.duration), isrc: track.isrc, releaseDate: date,
                  year: date.flatMap { Int($0.prefix(4)) }, copyright: track.copyright ?? album?.copyright,
                  explicit: track.explicit, popularity: track.popularity, listedQuality: track.audioQuality,
                  mediaTags: track.mediaMetadata?.tags ?? [],
                  replayGain: TidalReplayGain(trackGain: track.replayGain, trackPeak: track.peak),
                  albumId: track.album.id, artistIds: track.artists.map(\.id), coverUUID: album?.cover ?? track.album.cover,
                  streamable: streamable, unavailableReason: streamable ? nil : "notStreamable")
    }
}
