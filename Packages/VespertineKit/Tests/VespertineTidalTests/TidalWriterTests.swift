//
// Vespertine: TIDAL writes: favorites and playlist edits send exactly the method, path, form and etag header TIDAL expects.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineTidal

@Suite("TIDAL writes")
struct TidalWriterTests {
    private static let uuid = "00000000-1111-2222-3333-444444444444"

    /// A writer over a fake TIDAL: `GET playlists/<uuid>` answers with the etag, every other request with `reply`.
    private func writer(etag: String = "\"etag-7\"", reply: @escaping @Sendable (URLRequest) -> FakeResponse = { _ in FakeResponse(json: "{}") })
        -> (TidalWriter, FakeTransport) {
        let transport = FakeTransport { request in
            if request.httpMethod == "GET", request.url!.path == "/v1/playlists/\(Self.uuid)" {
                return FakeResponse(json: #"{"uuid":"\#(Self.uuid)","title":"Mix"}"#, headers: ["ETag": etag])
            }
            return reply(request)
        }
        return (TidalWriter(gate: makeSignedInGate(transport: transport), userId: 4242), transport)
    }

    private func path(_ request: URLRequest) -> String { String(request.url!.path.dropFirst("/v1/".count)) }

    @Test("A favorite: POST users/<id>/favorites/<kind> with the kind's id field", arguments: [
        (FavoriteKind.track, "tracks", "trackIds"), (.album, "albums", "albumIds"), (.artist, "artists", "artistIds"),
    ])
    func favorite(kind: FavoriteKind, segment: String, field: String) async throws {
        let (writer, transport) = writer()
        try await writer.setFavorite(true, kind: kind, id: 77)
        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1, "no etag is needed")
        #expect(request.httpMethod == "POST" && path(request) == "users/4242/favorites/\(segment)")
        #expect(request.formFields == [field: "77"])
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test("Un-favoriting: DELETE users/<id>/favorites/<kind>/<id>, no body", arguments: [
        (FavoriteKind.track, "tracks"), (.album, "albums"), (.artist, "artists"),
    ])
    func unfavorite(kind: FavoriteKind, segment: String) async throws {
        let (writer, transport) = writer()
        try await writer.setFavorite(false, kind: kind, id: 77)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "DELETE" && path(request) == "users/4242/favorites/\(segment)/77")
        #expect(request.formFields.isEmpty)
    }

    @Test("A new playlist: POST users/<id>/playlists with title and description, answered with its uuid")
    func create() async throws {
        let (writer, transport) = writer(reply: { _ in FakeResponse(json: #"{"uuid":"new-uuid","title":"Road","description":"Long drives"}"#) })
        let playlist = try await writer.createPlaylist(title: "Road", description: "Long drives")
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST" && path(request) == "users/4242/playlists")
        #expect(request.formFields == ["title": "Road", "description": "Long drives"])
        #expect(playlist.uuid == "new-uuid" && playlist.title == "Road" && playlist.description == "Long drives" && playlist.numberOfTracks == 0)
    }

    @Test("A new playlist whose answer wraps the playlist in data still gives its uuid")
    func createWrapped() async throws {
        let (writer, _) = writer(reply: { _ in FakeResponse(json: #"{"trn":"trn:playlist:wrapped","data":{"uuid":"wrapped"}}"#) })
        let playlist = try await writer.createPlaylist(title: "Road", description: "")
        #expect(playlist.uuid == "wrapped" && playlist.title == "Road")
    }

    /// Every playlist write: first the etag, then one request carrying it as If-None-Match.
    private func playlistWrite(_ run: (TidalWriter) async throws -> Void) async throws -> (get: URLRequest, write: URLRequest) {
        let (writer, transport) = writer()
        try await run(writer)
        let requests = transport.requests
        #expect(requests.count == 2)
        let get = try #require(requests.first), write = try #require(requests.last)
        #expect(get.httpMethod == "GET" && path(get) == "playlists/\(Self.uuid)")
        #expect(write.value(forHTTPHeaderField: "If-None-Match") == "\"etag-7\"")
        return (get, write)
    }

    @Test("Edit: POST playlists/<uuid> with title and description")
    func edit() async throws {
        let (_, write) = try await playlistWrite { try await $0.edit(Self.uuid, title: "New", description: "Words") }
        #expect(write.httpMethod == "POST" && path(write) == "playlists/\(Self.uuid)")
        #expect(write.formFields == ["title": "New", "description": "Words"])
    }

    @Test("Add: POST playlists/<uuid>/items with the track ids comma-joined and onDupes=ADD")
    func add() async throws {
        let (_, write) = try await playlistWrite { try await $0.add(trackIds: [5, 6, 7], to: Self.uuid) }
        #expect(write.httpMethod == "POST" && path(write) == "playlists/\(Self.uuid)/items")
        #expect(write.formFields == ["trackIds": "5,6,7", "onDupes": "ADD"])
    }

    @Test("Remove: DELETE playlists/<uuid>/items/<index> by index, ascending")
    func remove() async throws {
        let (_, write) = try await playlistWrite { try await $0.remove(index: 3, from: Self.uuid) }
        #expect(write.httpMethod == "DELETE" && path(write) == "playlists/\(Self.uuid)/items/3")
        #expect(write.formFields == ["order": "INDEX", "orderDirection": "ASC"])
    }

    @Test("Move: POST playlists/<uuid>/items/<from> with toIndex")
    func move() async throws {
        let (_, write) = try await playlistWrite { try await $0.move(from: 4, to: 1, in: Self.uuid) }
        #expect(write.httpMethod == "POST" && path(write) == "playlists/\(Self.uuid)/items/4")
        #expect(write.formFields == ["toIndex": "1"])
    }

    @Test("Delete: DELETE playlists/<uuid>")
    func delete() async throws {
        let (_, write) = try await playlistWrite { try await $0.delete(Self.uuid) }
        #expect(write.httpMethod == "DELETE" && path(write) == "playlists/\(Self.uuid)")
        #expect(write.formFields.isEmpty)
    }

    @Test("A 412 (the playlist changed on TIDAL) surfaces as TidalError.http(status: 412)")
    func conflict() async throws {
        let (writer, _) = writer(reply: { _ in FakeResponse(status: 412, json: #"{"status":412,"userMessage":"Precondition failed"}"#) })
        await #expect(throws: TidalError.http(status: 412, body: #"{"status":412,"userMessage":"Precondition failed"}"#)) {
            try await writer.add(trackIds: [1], to: Self.uuid)
        }
    }

    @Test("A playlist whose etag can't be had is not written to")
    func noEtag() async throws {
        let transport = FakeTransport { request in
            request.httpMethod == "GET" ? FakeResponse(json: "{}") : FakeResponse(json: "{}")   // no ETag header
        }
        let writer = TidalWriter(gate: makeSignedInGate(transport: transport), userId: 4242)
        await #expect(throws: TidalError.missingETag(playlist: Self.uuid)) { try await writer.delete(Self.uuid) }
        #expect(transport.requests.count == 1)
    }

    @Test("Every write is sent at interactive priority")
    func priority() async throws {
        // Interactive outranks sync and download: with every slot busy, a write jumps the queue of background requests.
        let latch = Latch()
        let started = Counter()
        let transport = FakeTransport { request in
            if request.url!.path.contains("tracks/") && request.httpMethod == "GET" { _ = started.next(); await latch.wait() }
            return FakeResponse(json: "{}")
        }
        let gate = makeSignedInGate(transport: transport)
        let writer = TidalWriter(gate: gate, userId: 4242)
        var busy: [Task<Data, Error>] = []
        for i in 0..<4 { busy.append(Task { try await gate.get("tracks/\(i)", priority: .download) }) }
        #expect(await eventually { started.next() >= 4 })
        let queuedDownload = Task { try await gate.get("tracks/queued", priority: .download) }
        let write = Task { try await writer.setFavorite(true, kind: .track, id: 1) }
        try await Task.sleep(for: .milliseconds(50))
        await latch.releaseOne()
        _ = try await write.value
        let order = transport.requests.map { $0.url!.path }
        #expect(order.firstIndex(of: "/v1/users/4242/favorites/tracks")! < (order.firstIndex(of: "/v1/tracks/queued") ?? Int.max))
        await latch.releaseAll()
        _ = try await queuedDownload.value
        for task in busy { _ = try await task.value }
    }
}
