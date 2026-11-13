//
// Vespertine: pulling the TIDAL account's favorites and playlists into the library, against a fake catalog that counts what it is
// asked for.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
@testable import VespertineLibrary
@testable import VespertineTidal

func tidalTrack(_ id: Int, album: Int = 1, number: Int? = nil, title: String? = nil, artist: String = "Artist",
                albumTitle: String = "Album") -> TidalTrack {
    TidalTrack(id: id, title: title ?? "Track \(id)", duration: 200, trackNumber: number ?? id, volumeNumber: 1, isrc: "XX\(id)",
               audioQuality: "HI_RES_LOSSLESS", mediaMetadata: .init(tags: ["LOSSLESS", "HIRES_LOSSLESS"]), replayGain: -7, peak: 0.9,
               copyright: "(P) Nobody", artists: [TidalArtistRef(id: 50, name: artist, type: "MAIN")],
               album: TidalAlbumRef(id: album, title: albumTitle, cover: "cover-\(album)", releaseDate: "2021-03-04"))
}

/// The account, as the test sets it; every call is counted.
final class FakeCatalog: TidalCatalogReading, @unchecked Sendable {
    private let lock = NSLock()
    var favorites: [TidalTrack] = []
    var albums: [TidalAlbum] = []
    var albumContents: [Int: [TidalTrack]] = [:]
    var playlists: [TidalPlaylist] = []
    var playlistContents: [String: [TidalTrack]] = [:]
    private(set) var calls: [String] = []

    func set(_ change: (FakeCatalog) -> Void) { lock.withLock { change(self) } }
    var log: [String] { lock.withLock { calls } }
    private func record(_ call: String) { lock.withLock { calls.append(call) } }

    func favoriteTracks(userId: Int, priority: TidalPriority) async throws -> [TidalTrack] { record("favoriteTracks"); return lock.withLock { favorites } }
    func favoriteAlbums(userId: Int, priority: TidalPriority) async throws -> [TidalAlbum] { record("favoriteAlbums"); return lock.withLock { albums } }
    func albumTracks(_ id: Int, priority: TidalPriority) async throws -> [TidalTrack] { record("albumTracks \(id)"); return lock.withLock { albumContents[id] ?? [] } }
    func userPlaylists(userId: Int, priority: TidalPriority) async throws -> [TidalPlaylist] { record("userPlaylists"); return lock.withLock { playlists } }
    func playlistTracks(_ uuid: String, priority: TidalPriority) async throws -> [TidalTrack] {
        record("playlistTracks \(uuid)"); return lock.withLock { playlistContents[uuid] ?? [] }
    }
}

@Suite("TIDAL library sync")
struct TidalLibrarySyncTests {
    private func count(_ db: LibraryDatabase, _ sql: String) throws -> Int {
        try db.writer.read { try Int.fetchOne($0, sql: sql) ?? 0 }
    }

    private func account() -> FakeCatalog {
        let catalog = FakeCatalog()
        catalog.favorites = [tidalTrack(1), tidalTrack(2), tidalTrack(3, album: 2)]
        catalog.albums = [TidalAlbum(id: 9, title: "Saved", numberOfTracks: 2, cover: "c9", artist: TidalArtistRef(id: 60, name: "Band"))]
        catalog.albumContents = [9: [tidalTrack(90, album: 9, number: 1, albumTitle: "Saved"), tidalTrack(91, album: 9, number: 2, albumTitle: "Saved")]]
        catalog.playlists = [TidalPlaylist(uuid: "pl-1", title: "Mix", numberOfTracks: 3, lastUpdated: "2026-11-01T10:00:00.000+0000"),
                             TidalPlaylist(uuid: "pl-2", title: "Other", numberOfTracks: 1, lastUpdated: "2026-11-02T10:00:00.000+0000")]
        catalog.playlistContents = ["pl-1": [tidalTrack(2), tidalTrack(40, album: 4), tidalTrack(1)], "pl-2": [tidalTrack(41, album: 4)]]
        return catalog
    }

    @Test("The first refresh makes a row per favorite and saved-album track and per playlist track, and a playlist per TIDAL playlist")
    func firstRefresh() async throws {
        let db = try LibraryDatabase.inMemory()
        let catalog = account()
        let summary = try await TidalLibrarySync(catalog: catalog, database: db, userId: 4242).refresh()
        #expect(summary.added == 7 && summary.updated == 0 && summary.removed == 0 && summary.playlists == 2)
        #expect(try count(db, "SELECT count(*) FROM tidalTrack") == 7)
        #expect(try db.tidalTrackIds() == [1, 2, 3, 90, 91, 40, 41])
        let lists = try db.playlists().filter { !$0.isSmart }
        #expect(Set(lists.map(\.name)) == ["Mix", "Other"])
        let mix = try #require(lists.first { $0.name == "Mix" })
        #expect(try db.tracks(in: mix).map(\.title) == ["Track 2", "Track 40", "Track 1"], "in TIDAL's order")
        // What the rows say.
        let track = try #require(try db.allTracks().first { $0.title == "Track 90" })
        #expect(track.album == "Saved" && track.albumArtist == "Band" && track.artist == "Artist" && track.trackNumber == 1 && track.year == 2021)
        #expect(track.codec == "FLAC" && track.sampleRate == 96_000 && track.bitDepth == 24 && track.artworkKey == "tidal:c9")
        #expect(track.rgTrackGain == -7 && track.rgTrackPeak == 0.9 && track.location == "tidal://track/90")
        let source = try db.tidalSource(userId: 4242)
        #expect(track.sourceId == source.id)
    }

    @Test("A second refresh with nothing changed fetches no playlist items and no album already complete in the library")
    func unchangedRefresh() async throws {
        let db = try LibraryDatabase.inMemory()
        let catalog = account()
        let sync = TidalLibrarySync(catalog: catalog, database: db, userId: 4242)
        _ = try await sync.refresh()
        let before = catalog.log.count
        let summary = try await sync.refresh()
        let second = Array(catalog.log.dropFirst(before))
        #expect(!second.contains { $0.hasPrefix("playlistTracks") }, "\(second)")
        #expect(!second.contains { $0.hasPrefix("albumTracks") }, "\(second)")
        #expect(summary.added == 0 && summary.removed == 0 && summary.playlists == 2)
        #expect(try count(db, "SELECT count(*) FROM tidalTrack") == 7, "tracks only in an unfetched playlist stay")

        // A playlist edited on TIDAL is fetched again, and only that one.
        catalog.set {
            $0.playlists[1].lastUpdated = "2026-11-03T10:00:00.000+0000"
            $0.playlistContents["pl-2"] = [tidalTrack(42, album: 4)]
        }
        let mark = catalog.log.count
        let edited = try await sync.refresh()
        let third = Array(catalog.log.dropFirst(mark))
        #expect(third.filter { $0.hasPrefix("playlistTracks") } == ["playlistTracks pl-2"])
        #expect(edited.added == 1 && edited.removed == 1, "41 left the playlist, 42 came in")
        let other = try #require(try db.playlists().first { $0.name == "Other" })
        #expect(try db.tracks(in: other).map(\.title) == ["Track 42"])
    }

    @Test("A track dropped from the favorites is removed; a downloaded one stays, marked")
    func removal() async throws {
        let db = try LibraryDatabase.inMemory()
        let catalog = account()
        let sync = TidalLibrarySync(catalog: catalog, database: db, userId: 4242)
        _ = try await sync.refresh()
        try db.setTidalDownload(tidalId: 3, path: "/Music/TIDAL/Artist/Album/1-03 Track 3.flac")
        catalog.set { $0.favorites = [tidalTrack(1)] }   // 2 stays (in a playlist), 3 is downloaded
        let summary = try await sync.refresh()
        #expect(summary.removed == 0)
        catalog.set { $0.favorites = []; $0.playlistContents["pl-1"] = []; $0.playlists[0].lastUpdated = "later" }
        let next = try await sync.refresh()
        #expect(next.removed == 3, "1, 2 and 40 are gone")
        #expect(try db.tidalTrackIds() == [3, 90, 91, 41])
        let kept = try #require(try await db.writer.read { try TidalTrackRecord.filter(Column("tidalId") == 3).fetchOne($0) })
        #expect(kept.unavailableReason == TidalTrackRecord.notInFavorites && kept.downloadPath != nil)
    }

    @Test("A playlist the user deleted on TIDAL is deleted here too")
    func playlistGone() async throws {
        let db = try LibraryDatabase.inMemory()
        let catalog = account()
        let sync = TidalLibrarySync(catalog: catalog, database: db, userId: 4242)
        _ = try await sync.refresh()
        catalog.set { $0.playlists.removeLast() }
        let summary = try await sync.refresh()
        #expect(summary.playlists == 1)
        #expect(try db.playlists().filter { !$0.isSmart }.map(\.name) == ["Mix"])
        #expect(!(try db.tidalTrackIds()).contains(41))
    }
}
