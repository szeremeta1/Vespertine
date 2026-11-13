//
// Vespertine: TIDAL catalog reads: every fixture decodes, lists page through, playlist videos are skipped.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineTidal

@Suite("TIDAL catalog")
struct TidalCatalogTests {
    /// Answers a path (below `/v1/`) with a fixture, or with `respond` when given.
    private func catalog(_ routes: [String: String]) -> (TidalCatalog, FakeTransport) {
        let transport = FakeTransport { request in
            let path = String(request.url!.path.dropFirst("/v1/".count))
            guard let name = routes[path] else { return FakeResponse(status: 404, json: #"{"status":404}"#) }
            return FakeResponse(body: try Fixture.data("catalog/\(name)"))
        }
        return (TidalCatalog(gate: makeSignedInGate(transport: transport)), transport)
    }

    @Test("a track decodes with its artists, album and tags")
    func track() async throws {
        let (catalog, transport) = catalog(["tracks/100001": "track.json"])
        let track = try await catalog.track(100001)
        #expect(track.id == 100001 && track.title == "Fabricated Song" && track.version == "Remastered")
        #expect(track.duration == 215 && track.trackNumber == 3 && track.volumeNumber == 2)
        #expect(track.isrc == "TEST00000001" && track.explicit)
        #expect(track.audioQuality == "HI_RES_LOSSLESS" && track.mediaMetadata?.tags == ["LOSSLESS", "HIRES_LOSSLESS"] && track.hasHiRes)
        #expect(track.replayGain == -7.9 && track.peak == 0.98)
        #expect(track.copyright == "(c) Test Records" && track.popularity == 55)
        #expect(track.streamReady == true && track.allowStreaming == true)
        #expect(track.artists.map(\.name) == ["Test Artist", "Guest Artist"] && track.artists[1].type == "FEATURED")
        #expect(track.album.id == 300001 && track.album.title == "Fabricated Album")
        #expect(track.album.cover == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(transport.requests.first?.url?.query?.contains("countryCode=DE") == true)
    }

    @Test("an album decodes")
    func album() async throws {
        let (catalog, _) = catalog(["albums/300001": "album.json"])
        let album = try await catalog.album(300001)
        #expect(album.title == "Fabricated Album" && album.numberOfTracks == 10 && album.numberOfVolumes == 2)
        #expect(album.releaseDate == "2019-05-17" && album.upc == "000000000001" && album.version == "Deluxe")
        #expect(album.cover == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(album.artist?.name == "Test Artist" && album.artists.count == 1)
    }

    @Test("an artist and a playlist decode")
    func artistAndPlaylist() async throws {
        let (catalog, _) = catalog(["artists/200001": "artist.json", "playlists/00000000-1111-2222-3333-444444444444": "playlist.json"])
        let artist = try await catalog.artist(200001)
        #expect(artist.name == "Test Artist" && artist.picture == "11111111-2222-3333-4444-555555555555" && artist.popularity == 71)
        let playlist = try await catalog.playlist("00000000-1111-2222-3333-444444444444")
        #expect(playlist.uuid == "00000000-1111-2222-3333-444444444444" && playlist.id == playlist.uuid)
        #expect(playlist.title == "Fabricated Mix" && playlist.numberOfTracks == 3 && playlist.description == "A mix for tests")
        #expect(playlist.lastUpdated == "2024-02-03T04:05:06.000+0000" && playlist.squareImage == "12345678-1234-1234-1234-123456789012")
    }

    @Test("album tracks decode in order")
    func albumTracks() async throws {
        let (catalog, transport) = catalog(["albums/300001/tracks": "album-tracks.json"])
        let tracks = try await catalog.albumTracks(300001)
        #expect(tracks.map(\.title) == ["First", "Second"])
        #expect(transport.requests.count == 1)
    }

    @Test("a track missing optional fields still decodes with defaults")
    func lenientTrack() throws {
        let json = #"{"id":1,"title":"Bare","album":{"id":2,"title":"A"}}"#
        let track = try JSONDecoder().decode(TidalTrack.self, from: Data(json.utf8))
        #expect(track.artists.isEmpty && track.duration == 0 && track.trackNumber == 1 && track.volumeNumber == 1 && !track.explicit)
        #expect(track.isrc == nil && track.replayGain == nil)
    }

    @Test("favorite albums, artists and playlists unwrap {created, item}")
    func favoritesAndPlaylists() async throws {
        let (catalog, _) = catalog(["users/4242/favorites/albums": "favorites-albums.json",
                                    "users/4242/favorites/artists": "favorites-artists.json",
                                    "users/4242/playlists": "user-playlists.json"])
        #expect(try await catalog.favoriteAlbums(userId: 4242).map(\.title) == ["Fabricated Album"])
        #expect(try await catalog.favoriteArtists(userId: 4242).map(\.name) == ["Test Artist"])
        #expect(try await catalog.userPlaylists(userId: 4242).map(\.title) == ["Fabricated Mix"])
    }

    @Test("a 230-item favorites list is fetched at offsets 0, 100 and 200 with limit 100, at sync priority")
    func favoritesPaging() async throws {
        let template = try Fixture.string("catalog/favorites-tracks-item.json")
        let queryLog = Locked<[[String: String]]>([])
        let transport = FakeTransport { request in
            let query = FormEncoding.decode(request.url?.query ?? "")
            queryLog.mutate { $0.append(query) }
            let offset = Int(query["offset"] ?? "") ?? -1
            let count = max(0, min(100, 230 - offset))
            let items = (0..<count).map { index in
                template.replacingOccurrences(of: "\"id\":100001", with: "\"id\":\(offset + index + 1)")
            }.joined(separator: ",")
            return FakeResponse(json: #"{"limit":100,"offset":\#(offset),"totalNumberOfItems":230,"items":[\#(items)]}"#)
        }
        let catalog = TidalCatalog(gate: makeSignedInGate(transport: transport))
        let tracks = try await catalog.favoriteTracks(userId: 4242)
        #expect(tracks.count == 230)
        #expect(tracks.map(\.id) == Array(1...230))
        let log = queryLog.value
        #expect(log.map { $0["offset"] } == ["0", "100", "200"])
        #expect(log.allSatisfy { $0["limit"] == "100" && $0["countryCode"] == "DE" })
        #expect(transport.requests.allSatisfy { $0.url?.path == "/v1/users/4242/favorites/tracks" })
    }

    @Test("an empty list costs one request")
    func emptyList() async throws {
        let count = Locked(0)
        let transport = FakeTransport { _ in
            count.mutate { $0 += 1 }
            return FakeResponse(json: #"{"limit":100,"offset":0,"totalNumberOfItems":0,"items":[]}"#)
        }
        let catalog = TidalCatalog(gate: makeSignedInGate(transport: transport))
        #expect(try await catalog.favoriteTracks(userId: 4242).isEmpty)
        #expect(count.value == 1)
    }

    @Test("favorites are fetched at sync priority: an interactive call queued later is sent first")
    func favoritesPriority() async throws {
        let latch = Latch()
        let transport = FakeTransport { request in
            if request.url?.path.contains("/block/") == true { await latch.wait() }
            if request.url?.path.contains("favorites") == true {
                return FakeResponse(json: #"{"limit":100,"offset":0,"totalNumberOfItems":0,"items":[]}"#)
            }
            return FakeResponse(body: try Fixture.data("catalog/track.json"))
        }
        let gate = makeSignedInGate(transport: transport)
        let catalog = TidalCatalog(gate: gate)
        let blockers = (0..<4).map { index in Task { try await gate.get("block/\(index)", priority: .playback) } }
        #expect(await eventually { await latch.waitingCount == 4 })
        let favorites = Task { try await catalog.favoriteTracks(userId: 4242) }
        #expect(await eventually { await gate.queuedCount == 1 })
        let interactive = Task { try await catalog.track(100001) }
        #expect(await eventually { await gate.queuedCount == 2 })
        await latch.releaseAll()
        for task in blockers { _ = try await task.value }
        _ = try await favorites.value
        _ = try await interactive.value
        let order = transport.requests.dropFirst(4).compactMap { $0.url?.path }
        #expect(order == ["/v1/tracks/100001", "/v1/users/4242/favorites/tracks"])
    }

    @Test("playlist items skip videos and keep track order")
    func playlistItems() async throws {
        let (catalog, transport) = catalog(["playlists/00000000-1111-2222-3333-444444444444/items": "playlist-items.json"])
        let tracks = try await catalog.playlistTracks("00000000-1111-2222-3333-444444444444")
        #expect(tracks.map(\.title) == ["First", "Second", "Third"])
        #expect(transport.requests.count == 1)
    }

    @Test("search decodes tracks, albums, artists and playlists")
    func search() async throws {
        let (catalog, transport) = catalog(["search": "search.json"])
        let result = try await catalog.search("test artist", limit: 25)
        #expect(result.tracks.map(\.title) == ["Fabricated Song"])
        #expect(result.albums.map(\.title) == ["Fabricated Album"])
        #expect(result.artists.map(\.name) == ["Test Artist"])
        #expect(result.playlists.map(\.title) == ["Fabricated Mix"])
        let query = FormEncoding.decode(transport.requests[0].url?.query ?? "")
        #expect(query["query"] == "test artist" && query["limit"] == "25")
    }

    @Test("lyrics returns the plain text, and nil on a 404")
    func lyrics() async throws {
        let (catalog, _) = catalog(["tracks/100001/lyrics": "lyrics.json"])
        #expect(try await catalog.lyrics(100001) == "La la la\nTest line two")
        #expect(try await catalog.lyrics(5) == nil)
    }

    @Test("credits decode, with and without contributor ids")
    func credits() async throws {
        let (catalog, _) = catalog(["tracks/100001/credits": "credits.json"])
        let credits = try await catalog.credits(100001)
        #expect(credits.map(\.type) == ["Producer", "Composer"])
        #expect(credits[1].contributors.map(\.name) == ["Cleo Composer", "Dan Writer"])
        #expect(credits[1].contributors.map(\.id) == [nil, 5003])
    }

    @Test("cover URLs turn the UUID's dashes into path segments")
    func coverURL() {
        #expect(TidalCatalog.coverURL("ab-cd", size: 320).absoluteString == "https://resources.tidal.com/images/ab/cd/320x320.jpg")
        #expect(TidalCatalog.coverURL("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", size: 1280).absoluteString
                == "https://resources.tidal.com/images/aaaaaaaa/bbbb/cccc/dddd/eeeeeeeeeeee/1280x1280.jpg")
    }
}
