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

        var inputs: [TidalTrackInput] = []
        var present = Set<Int>()
        for track in try await catalog.favoriteTracks(userId: userId, priority: .sync) {
            inputs.append(TidalTrackInput(track))
            present.insert(track.id)
        }

        let byAlbum = try database.tidalTrackIdsByAlbum()
        for album in try await catalog.favoriteAlbums(userId: userId, priority: .sync) {
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
        try database.removeTidalPlaylists(notIn: Set(playlists.map(\.uuid)))
        let removed = try database.removeTidalTracks(notIn: present, sourceId: sourceId)

        let upserted = Set(inputs.map(\.tidalId))
        return Summary(added: upserted.subtracting(before).count, updated: upserted.intersection(before).count,
                       removed: removed, playlists: playlists.count)
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
