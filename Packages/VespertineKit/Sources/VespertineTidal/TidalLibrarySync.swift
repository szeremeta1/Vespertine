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
        /// Lists TIDAL sent much shorter than the library holds (see `TidalLibrarySync.looksTruncated`): nothing was deleted
        /// for them this time. One line per list, for the log or the UI.
        public var warnings: [String] = []

        public init(added: Int, updated: Int, removed: Int, playlists: Int, warnings: [String] = []) {
            self.added = added; self.updated = updated; self.removed = removed; self.playlists = playlists; self.warnings = warnings
        }
    }

    /// A list that comes back empty while the library holds items of it, or shorter by more than half and by more than 20
    /// items, may be TIDAL answering short (an empty page in a 200), not the user's doing: deleting on it would take tracks and
    /// playlists out of the library. Nothing is deleted for such a list until `believedAfter` answers in a row have said the same,
    /// over at least `believedSpan`.
    static func looksTruncated(fetched: Int, previous: Int?) -> Bool {
        guard let previous, previous > 0 else { return false }
        if fetched == 0 { return true }
        return fetched * 2 < previous && previous - fetched > 20
    }

    static let believedAfter = 3
    static let believedSpan: TimeInterval = 24 * 3600

    private let clock: @Sendable () -> Date
    private let catalog: any TidalCatalogReading
    private let database: LibraryDatabase
    private let userId: Int

    public init(catalog: any TidalCatalogReading, database: LibraryDatabase, userId: Int, clock: @escaping @Sendable () -> Date = Date.init) {
        self.clock = clock
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
        var accepted: [(list: String, ids: Set<Int>?)] = []
        let now = Int(clock().timeIntervalSince1970)
        /// Whether `list` as fetched (`fetched` items; `ids` to record, when the library keeps a record of it) may be acted on,
        /// against what the library holds of it (`held`).
        func trusted(_ list: String, _ fetched: Int, ids: Set<Int>?, held: Int) throws -> Bool {
            guard Self.looksTruncated(fetched: fetched, previous: held) else {
                try forgetDoubt(list)
                accepted.append((list, ids))
                return true
            }
            // The same suspicious answer again extends the run; another one starts a new run.
            var seen = 1, since = now
            if try database.tidalSyncValue(list + ".doubt") == fetched,
               let count = try database.tidalSyncValue(list + ".doubtSeen"), let first = try database.tidalSyncValue(list + ".doubtSince") {
                seen = count + 1
                since = first
            }
            if seen >= Self.believedAfter, TimeInterval(now - since) >= Self.believedSpan {
                try forgetDoubt(list)
                accepted.append((list, ids))
                return true
            }
            try database.setTidalSyncValue(list + ".doubt", fetched)
            try database.setTidalSyncValue(list + ".doubtSeen", seen)
            try database.setTidalSyncValue(list + ".doubtSince", since)
            warnings.append("TIDAL sent \(fetched) \(list) where the library has \(held): nothing is removed for it until "
                            + "\(Self.believedAfter) refreshes over a day say the same (\(seen) so far)")
            return false
        }
        func forgetDoubt(_ list: String) throws {
            for key in [".doubt", ".doubtSeen", ".doubtSince"] { try database.setTidalSyncValue(list + key, nil) }
        }

        var inputs: [TidalTrackInput] = []
        var present = Set<Int>()
        let favorites = try await catalog.favoriteTracks(userId: userId, priority: .sync)
        // What the library holds of each list: its record of the last sync, or, before any (a library from before this
        // record), every TIDAL track and every album they come from.
        let heldTracks = try database.tidalFavoriteCount("favorite tracks") ?? before.count
        var trustAll = try trusted("favorite tracks", favorites.count, ids: Set(favorites.map(\.id)), held: heldTracks)
        for track in favorites {
            inputs.append(TidalTrackInput(track))
            present.insert(track.id)
        }

        let byAlbum = try database.tidalTrackIdsByAlbum()
        let albums = try await catalog.favoriteAlbums(userId: userId, priority: .sync)
        let heldAlbums = try database.tidalFavoriteCount("favorite albums") ?? byAlbum.count
        trustAll = try trusted("favorite albums", albums.count, ids: Set(albums.map(\.id)), held: heldAlbums) && trustAll
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
        let states = try database.tidalPlaylistStates()
        let trustPlaylists = try trusted("playlists", playlists.count, ids: nil, held: states.count)
        trustAll = trustPlaylists && trustAll
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
        for (list, ids) in accepted {
            if let ids { try database.setTidalFavorites(list, ids: ids) }   // playlists: their own table is the record
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
