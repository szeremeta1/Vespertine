//
// Vespertine: reads from TIDAL's catalog and the user's library (tracks, albums, artists, playlists, favorites, search, lyrics,
// credits), every call through the gate.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public struct TidalCatalog: Sendable {
    /// Items per request when paging a list.
    static let pageSize = 100

    private let gate: TidalGate

    public init(gate: TidalGate) { self.gate = gate }

    /// The cover or picture at `size` × `size` pixels. `uuid` is the image UUID TIDAL puts in `cover`, `picture` or `squareImage`.
    public static func coverURL(_ uuid: String, size: Int) -> URL {
        URL(string: "https://resources.tidal.com/images/\(uuid.replacingOccurrences(of: "-", with: "/"))/\(size)x\(size).jpg")!
    }

    // MARK: Single items

    public func track(_ id: Int, priority: TidalPriority = .interactive) async throws -> TidalTrack {
        try await gate.get("tracks/\(id)", priority: priority, as: TidalTrack.self)
    }

    public func album(_ id: Int, priority: TidalPriority = .interactive) async throws -> TidalAlbum {
        try await gate.get("albums/\(id)", priority: priority, as: TidalAlbum.self)
    }

    public func artist(_ id: Int, priority: TidalPriority = .interactive) async throws -> TidalArtist {
        try await gate.get("artists/\(id)", priority: priority, as: TidalArtist.self)
    }

    public func playlist(_ uuid: String, priority: TidalPriority = .interactive) async throws -> TidalPlaylist {
        try await gate.get("playlists/\(uuid)", priority: priority, as: TidalPlaylist.self)
    }

    // MARK: Track lists

    public func albumTracks(_ id: Int, priority: TidalPriority = .interactive) async throws -> [TidalTrack] {
        try await allPages(path: "albums/\(id)/tracks", priority: priority, as: TidalTrack.self)
    }

    /// The playlist's tracks in order. Videos are left out.
    public func playlistTracks(_ uuid: String, priority: TidalPriority = .interactive) async throws -> [TidalTrack] {
        try await allPages(path: "playlists/\(uuid)/items", priority: priority, as: PlaylistEntry.self).compactMap(\.track)
    }

    // MARK: The user's library

    public func favoriteTracks(userId: Int, priority: TidalPriority = .sync) async throws -> [TidalTrack] {
        try await allPages(path: "users/\(userId)/favorites/tracks", priority: priority, as: Favorite<TidalTrack>.self).map(\.item)
    }

    public func favoriteAlbums(userId: Int, priority: TidalPriority = .sync) async throws -> [TidalAlbum] {
        try await allPages(path: "users/\(userId)/favorites/albums", priority: priority, as: Favorite<TidalAlbum>.self).map(\.item)
    }

    public func favoriteArtists(userId: Int, priority: TidalPriority = .sync) async throws -> [TidalArtist] {
        try await allPages(path: "users/\(userId)/favorites/artists", priority: priority, as: Favorite<TidalArtist>.self).map(\.item)
    }

    public func userPlaylists(userId: Int, priority: TidalPriority = .sync) async throws -> [TidalPlaylist] {
        try await allPages(path: "users/\(userId)/playlists", priority: priority, as: TidalPlaylist.self)
    }

    // MARK: Search, lyrics, credits

    public func search(_ query: String, limit: Int = 50, priority: TidalPriority = .interactive) async throws -> TidalSearchResult {
        let result = try await gate.get("search", query: ["query": query, "limit": String(limit), "offset": "0",
                                                          "types": "TRACKS,ALBUMS,ARTISTS,PLAYLISTS"],
                                        priority: priority, as: SearchEnvelope.self)
        return TidalSearchResult(tracks: result.tracks?.items ?? [], albums: result.albums?.items ?? [],
                                 artists: result.artists?.items ?? [], playlists: result.playlists?.items ?? [])
    }

    /// The plain-text lyrics, or nil when TIDAL has none for the track.
    public func lyrics(_ trackId: Int, priority: TidalPriority = .interactive) async throws -> String? {
        do {
            let lyrics = try await gate.get("tracks/\(trackId)/lyrics", priority: priority, as: LyricsResponse.self)
            return lyrics.lyrics.isEmpty ? nil : lyrics.lyrics
        } catch TidalError.http(status: 404, _) {
            return nil
        }
    }

    public func credits(_ trackId: Int, priority: TidalPriority = .interactive) async throws -> [TidalCredit] {
        try await gate.get("tracks/\(trackId)/credits", priority: priority, as: [TidalCredit].self)
    }

    // MARK: Paging

    /// Every item of a list, `pageSize` at a time. The offset advances by the page size, as the server counts it, so a page TIDAL
    /// filters short doesn't shift the next one.
    private func allPages<Item: Codable & Sendable>(path: String, priority: TidalPriority, as type: Item.Type) async throws -> [Item] {
        var items: [Item] = []
        var offset = 0
        while true {
            let page = try await gate.get(path, query: ["limit": String(Self.pageSize), "offset": String(offset)],
                                          priority: priority, as: TidalPage<Item>.self)
            items += page.items
            offset += Self.pageSize
            if offset >= page.totalNumberOfItems { return items }
        }
    }

    // MARK: Wire shapes

    /// `{created, item}`.
    private struct Favorite<Item: Codable & Sendable>: Codable, Sendable {
        var item: Item
    }

    /// A playlist entry: `{type: "track" | "video", item: {…}}`. Only tracks are kept.
    private struct PlaylistEntry: Codable, Sendable {
        var track: TidalTrack?

        private enum Keys: String, CodingKey { case type, item }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let type = try c.decodeIfPresent(String.self, forKey: .type)
            track = type == "track" ? try c.decode(TidalTrack.self, forKey: .item) : nil
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            if let track { try c.encode("track", forKey: .type); try c.encode(track, forKey: .item) }
        }
    }

    private struct SearchEnvelope: Decodable {
        var tracks: TidalPage<TidalTrack>?
        var albums: TidalPage<TidalAlbum>?
        var artists: TidalPage<TidalArtist>?
        var playlists: TidalPage<TidalPlaylist>?
    }

    private struct LyricsResponse: Decodable {
        var lyrics: String
    }
}
