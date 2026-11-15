//
// Vespertine: what the streaming core's tests are built from: a provider that talks to nothing and notes what it was asked,
// and a small library of files in memory.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
@testable import VespertineAudio
@testable import VespertineLibrary
@testable import VespertineStreaming

/// Waits for something that will happen, without a deadline it could miss on a busy machine. The long stop only ends a run that
/// would never end.
enum Patience {
    static func until(giveUpAfter: TimeInterval = 90, _ condition: @Sendable () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(giveUpAfter)
        while !(await condition()) {
            if Date() > end { return await condition() }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

/// A stream's bytes held in memory.
final class MemoryReader: RemoteCacheReader, @unchecked Sendable {
    let data: Data
    let fileExtension: String
    var size: Int64 { Int64(data.count) }
    var changedSinceOpen: Bool { false }

    init(_ data: Data, fileExtension: String) {
        self.data = data
        self.fileExtension = fileExtension
    }

    func read(at offset: Int64, count: Int) throws -> Data {
        guard offset < size else { return Data() }
        return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + count))
    }

    func cancel() {}
}

/// A provider that reaches no server. Everything it is asked is noted in `asked`.
final class FakeProvider: StreamingProvider, @unchecked Sendable {
    struct Shared: Sendable {
        var listing = ProviderLibrary()
        var asked: [String] = []
        var made = 0
        var stopped = 0
        var streams: [String: (Data, String)] = [:]
        var waitingUntil: Date?
    }

    let id: String
    let account: String
    let capabilities: ProviderCapabilities
    let playbackMode: ProviderPlaybackMode
    let storagePolicy: ProviderStoragePolicy
    let shared: Locked<Shared>
    let credentials: any CredentialStore

    init(id: String, account: String, capabilities: ProviderCapabilities, mode: ProviderPlaybackMode, policy: ProviderStoragePolicy,
         shared: Locked<Shared>, credentials: any CredentialStore) {
        self.id = id
        self.account = account
        self.capabilities = capabilities
        playbackMode = mode
        storagePolicy = policy
        self.shared = shared
        self.credentials = credentials
        shared.withLock { $0.made += 1 }
    }

    /// A descriptor whose providers share `shared`.
    static func descriptor(id: String = "fake", mode: ProviderPlaybackMode = .engine, policy: ProviderStoragePolicy = .transientCacheOnly,
                           capabilities: ProviderCapabilities = [.search, .library, .playlists, .favorites, .playReports],
                           shared: Locked<Shared>) -> ProviderDescriptor {
        ProviderDescriptor(id: id, name: "Fake", capabilities: capabilities, playbackMode: mode, storagePolicy: policy) { account, credentials in
            FakeProvider(id: id, account: account, capabilities: capabilities, mode: mode, policy: policy, shared: shared, credentials: credentials)
        }
    }

    private func note(_ what: String) { shared.withLock { $0.asked.append(what) } }

    func session() async -> ProviderSession {
        credentials.load(provider: id, account: account) == nil ? .signedOut : .signedIn(user: "listener")
    }

    func signIn(_ request: ProviderSignIn) async throws -> ProviderSession {
        note("signIn")
        try credentials.save(Data("secret".utf8), provider: id, account: account)
        return .signedIn(user: request.user)
    }

    func signOut() async {
        note("signOut")
        credentials.delete(provider: id, account: account)
    }

    func search(_ text: String, limit: Int) async throws -> [StreamedSong] {
        note("search")
        return shared.withLock { $0.listing.songs.filter { $0.title.localizedCaseInsensitiveContains(text) } }
    }

    func library(progress: @escaping @Sendable (Int) -> Void) async throws -> ProviderLibrary {
        note("library")
        return shared.withLock { $0.listing }
    }

    func tracks(of albumID: String) async throws -> [StreamedSong] {
        note("tracks")
        return shared.withLock { $0.listing.songs.filter { $0.albumId == albumID } }
    }

    func openStream(_ songID: String) throws -> any RemoteCacheReader {
        note("open \(songID)")
        guard let (data, ext) = shared.withLock({ $0.streams[songID] }) else { throw StreamingError.server("no such song") }
        return MemoryReader(data, fileExtension: ext)
    }

    func setStarred(_ starred: Bool, songID: String) async throws { note("\(starred ? "star" : "unstar") \(songID)") }
    func reportPlayed(songID: String, at date: Date) async throws { note("played \(songID)") }
    func artwork(_ coverArt: String) async throws -> Data {
        note("cover \(coverArt)")
        return Data("cover \(coverArt)".utf8)
    }

    var waitingUntil: Date? { shared.withLock { $0.waitingUntil } }
    func stop() { shared.withLock { $0.stopped += 1 } }
}

enum TestLibrary {
    /// A file's track row, as a scan would have written it.
    static func file(_ path: String, title: String, artist: String, album: String, number: Int, genre: String = "Jazz",
                     duration: Double = 200, size: Int64 = 30_000_000, sourceID: Int64?) -> Track {
        var track = Track.transient(location: path, title: title, artist: artist, album: album, duration: duration)
        track.sourceId = sourceID
        track.filePath = path
        track.fileSize = size
        track.modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        track.addedAt = Date(timeIntervalSince1970: 1_700_000_100)
        track.codec = "FLAC"
        track.isLossless = true
        track.sampleRate = 96_000
        track.bitDepth = 24
        track.albumArtist = artist
        track.genre = genre
        track.trackNumber = number
        track.year = 1999
        return track
    }

    /// A song as a server lists it.
    static func song(_ id: String, title: String, artist: String, album: String, number: Int, genre: String = "Jazz",
                     duration: Double = 200, suffix: String = "flac", bits: Int? = 24, rate: Double? = 96_000,
                     size: Int64 = 30_000_000, cover: String? = nil) -> StreamedSong {
        StreamedSong(id: id, title: title, artist: artist, album: album, albumArtist: artist, albumId: "al-\(album)", genre: genre,
                     year: 1999, trackNumber: number, duration: duration, suffix: suffix, bitDepth: bits, sampleRate: rate, channels: 2,
                     size: size, coverArt: cover)
    }

    /// A library in memory with one folder of files: two albums, a playlist, a smart playlist, a favorite and a played song.
    static func files() throws -> (database: LibraryDatabase, trackIDs: [Int64]) {
        let database = try LibraryDatabase.inMemory()
        let ids = try database.writer.write { db -> [Int64] in
            var source = LibrarySource(path: "/Volumes/test-mac/Music", mode: .reference, name: nil)
            try source.insert(db)
            var ids: [Int64] = []
            let rows = [
                file("/Volumes/test-mac/Music/Quiet Hours/01 Lamplight.flac", title: "Lamplight", artist: "The Night Shift", album: "Quiet Hours", number: 1, sourceID: source.id),
                file("/Volumes/test-mac/Music/Quiet Hours/02 Low Tide.flac", title: "Low Tide", artist: "The Night Shift", album: "Quiet Hours", number: 2, sourceID: source.id),
                file("/Volumes/test-mac/Music/Harbour/01 Slipway.flac", title: "Slipway", artist: "Anna Field", album: "Harbour", number: 1, genre: "Folk", sourceID: source.id),
            ]
            for var row in rows {
                try row.insert(db)
                ids.append(row.id!)
            }
            return ids
        }
        let playlist = try database.createPlaylist(name: "Evenings")
        try database.setPlaylistTracks([ids[0], ids[2]], playlistID: playlist.id!)
        _ = try database.createPlaylist(name: "All jazz", rules: SmartRules(rules: [SmartRule(field: .genre, op: .equals, value: "Jazz")]))
        try database.setFavorite(true, trackIDs: [ids[1]], at: Date(timeIntervalSince1970: 1_700_000_200))
        try database.recordHistory(ids[0], at: Date(timeIntervalSince1970: 1_700_000_300))
        return (database, ids)
    }
}

/// Every answer the library gives that a provider's songs could show up in.
struct LibraryAnswers: Equatable {
    var albums: [Album]
    var albumsByTitle: [Album]
    var albumsOfArtist: [Album]
    var albumTracks: [Track]
    var tracks: [Track]
    var tracksByID: [Track]
    var artists: [LibraryDatabase.ArtistSummary]
    var genres: [String]
    var playlists: [Playlist]
    var playlistTracks: [[Track]]
    /// Sorted by id: the order of a full-text search is its ranking, which is not what is being compared.
    var search: [Int64]
    var searchSubstring: [Int64]
    var history: [LibraryDatabase.HistoryEntry]
    var favorites: [Track]
    var favoriteIDs: [Int64]
    var stats: LibraryDatabase.Stats
    var folders: [LibrarySource]
    var accounts: [LibrarySource]

    init(_ database: LibraryDatabase) throws {
        albums = try database.albums()
        albumsByTitle = try database.albums(sort: .title)
        albumsOfArtist = try database.albums(artist: "The Night Shift")
        albumTracks = try database.tracks(albumKeys: albums.map(\.key))
        tracks = try database.allTracks()
        tracksByID = try database.tracks(ids: Array(1...200))
        artists = try database.artists()
        genres = Array(Set(albums.compactMap(\.genre))).sorted()
        playlists = try database.playlists()
        playlistTracks = try playlists.map { try database.tracks(in: $0) }
        search = try database.search("l").compactMap(\.id).sorted()
        // A query with a CJK character takes the substring path.
        searchSubstring = try database.search("夜").compactMap(\.id).sorted()
        history = try database.history()
        favorites = try database.favoriteTracks()
        (favoriteIDs, stats, folders) = try database.writer.read { db in
            (try database.visibleFavorites(db).map(\.id).sorted(), try database.stats(db)!, try LibraryDatabase.sources(db))
        }
        accounts = try database.streamedSources()
    }
}
