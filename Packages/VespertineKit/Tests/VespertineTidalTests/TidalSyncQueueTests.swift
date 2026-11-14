//
// Vespertine: TIDAL writes made in Vespertine wait in the library (they survive a quit), are sent in order when TIDAL can be
// reached, and meet TIDAL's own changes by its rules: TIDAL wins, adds and removes are applied again, moves are skipped.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineLibrary
@testable import VespertineTidal

/// TIDAL as far as the queue sees it: playlists with items and an etag that changes with each write, favorites, and conflicts on
/// demand.
private final class FakeTidal: @unchecked Sendable {
    let lock = NSLock()
    var playlists: [String: [Int]] = [:]
    var versions: [String: Int] = [:]
    var favorites: [String] = []
    /// Writes to answer 412 before the playlist changes behind Vespertine's back.
    var conflicts = 0
    var rateLimited = false
    var created = 0

    func handle(_ request: URLRequest) -> FakeResponse {
        lock.withLock {
            let path = String(request.url!.path.dropFirst("/v1/".count))
            let parts = path.split(separator: "/").map(String.init)
            let method = request.httpMethod ?? "GET"
            if rateLimited, method != "GET" { return FakeResponse(status: 429, json: "{}", headers: ["Retry-After": "60"]) }
            if parts.first == "users", parts.count >= 3, parts[2] == "favorites" {
                favorites.append("\(method) \(parts.dropFirst(3).joined(separator: "/")) \(request.formFields.values.joined())")
                return FakeResponse(json: "{}")
            }
            if parts.first == "users", parts.count == 3, parts[2] == "playlists" {
                created += 1
                let uuid = "made-\(created)"
                playlists[uuid] = []; versions[uuid] = 1
                return FakeResponse(json: #"{"uuid":"\#(uuid)","title":"x"}"#)
            }
            guard parts.first == "playlists", parts.count >= 2, var items = playlists[parts[1]] else {
                return FakeResponse(status: 404, json: #"{"status":404}"#)
            }
            let uuid = parts[1]
            let etag = "\"v\(versions[uuid] ?? 0)\""
            if method == "GET" { return FakeResponse(json: #"{"uuid":"\#(uuid)","title":"List"}"#, headers: ["ETag": etag]) }
            if conflicts > 0 || request.value(forHTTPHeaderField: "If-None-Match") != etag {
                conflicts = max(0, conflicts - 1)
                versions[uuid, default: 0] += 1   // someone changed it on TIDAL
                return FakeResponse(status: 412, json: "{}")
            }
            let form = request.formFields
            switch (method, parts.count) {
            case ("POST", 3): items += (form["trackIds"] ?? "").split(separator: ",").compactMap { Int($0) }
            case ("DELETE", 4): items.remove(at: Int(parts[3])!)
            case ("POST", 4): let moved = items.remove(at: Int(parts[3])!); items.insert(moved, at: Int(form["toIndex"]!)!)
            case ("DELETE", 2): playlists[uuid] = nil; return FakeResponse(json: "{}")
            default: break
            }
            playlists[uuid] = items
            versions[uuid, default: 0] += 1
            return FakeResponse(json: "{}")
        }
    }
}

private final class FakeSync: TidalSyncing, @unchecked Sendable {
    let tidal: FakeTidal
    let refreshes = Locked(0)
    let pulls = Locked<[String]>([])
    init(_ tidal: FakeTidal) { self.tidal = tidal }
    func refresh() async throws -> TidalLibrarySync.Summary {
        refreshes.mutate { $0 += 1 }
        return TidalLibrarySync.Summary(added: 0, updated: 0, removed: 0, playlists: 0)
    }
    func playlistTrackIds(_ uuid: String) async throws -> [Int] {
        guard let items = tidal.lock.withLock({ tidal.playlists[uuid] }) else { throw TidalError.http(status: 404, body: "") }
        return items
    }
    func pullPlaylist(_ uuid: String) async throws { pulls.mutate { $0.append(uuid) } }
}

private struct Rig {
    let tidal = FakeTidal()
    let sync: FakeSync
    let transport: FakeTransport
    let database: LibraryDatabase

    init(database: LibraryDatabase? = nil) throws {
        let tidal = tidal
        sync = FakeSync(tidal)
        transport = FakeTransport { tidal.handle($0) }
        self.database = try database ?? LibraryDatabase.inMemory()
    }

    func queue() -> TidalSyncQueue {
        TidalSyncQueue(writer: TidalWriter(gate: makeSignedInGate(transport: transport), userId: 4242), database: database, sync: sync)
    }

    /// A linked playlist: TIDAL's `uuid` holding `items`, and the library's playlist for it.
    func playlist(_ uuid: String, _ items: [Int]) throws -> Int64 {
        tidal.lock.withLock { tidal.playlists[uuid] = items; tidal.versions[uuid] = 1 }
        return try database.setTidalPlaylist(uuid: uuid, name: uuid, lastUpdated: nil, tidalIds: [])
    }

    var writes: [String] {
        transport.requests.filter { $0.httpMethod != "GET" }.map { "\($0.httpMethod!) \(String($0.url!.path.dropFirst("/v1/".count)))" }
    }
}

@Suite("TIDAL sync queue")
struct TidalSyncQueueTests {
    @Test("Ops are sent in the order they were made; an empty queue then pulls once")
    func order() async throws {
        let rig = try Rig()
        let list = try rig.playlist("p1", [1])
        let queue = rig.queue()
        try await queue.enqueue(.favorite(kind: .track, id: 5, on: true))
        try await queue.enqueue(.add(playlist: list, trackIds: [7]))
        try await queue.enqueue(.favorite(kind: .album, id: 9, on: false))
        #expect(await queue.pendingCount == 3)
        let report = await queue.drain()
        #expect(report.sent == 3 && report.skipped.isEmpty && report.dropped == 0 && !report.stopped)
        #expect(rig.writes == ["POST users/4242/favorites/tracks", "POST playlists/p1/items", "DELETE users/4242/favorites/albums/9"])
        #expect(await queue.pendingCount == 0)
        #expect(rig.sync.refreshes.value == 1)
        #expect(rig.tidal.playlists["p1"] == [1, 7])
    }

    @Test("Ops survive a quit: a queue on the reopened library sends them, in order")
    func persists() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("queue-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let rig = try Rig(database: try LibraryDatabase(url: url))
            try await rig.queue().enqueue(.favorite(kind: .track, id: 1, on: true))
            try await rig.queue().enqueue(.favorite(kind: .track, id: 2, on: false))
        }
        let rig = try Rig(database: try LibraryDatabase(url: url))
        let queue = rig.queue()
        #expect(await queue.pendingCount == 2)
        #expect(try await queue.pending() == [.favorite(kind: .track, id: 1, on: true), .favorite(kind: .track, id: 2, on: false)])
        _ = await queue.drain()
        #expect(rig.writes == ["POST users/4242/favorites/tracks", "DELETE users/4242/favorites/tracks/2"])
    }

    @Test("An add refused for a changed playlist (412): the playlist is pulled, then the add is sent again")
    func addConflict() async throws {
        let rig = try Rig()
        let list = try rig.playlist("p1", [1, 2])
        rig.tidal.conflicts = 1
        let queue = rig.queue()
        try await queue.enqueue(.add(playlist: list, trackIds: [3]))
        let report = await queue.drain()
        #expect(rig.sync.pulls.value == ["p1"])
        #expect(rig.tidal.playlists["p1"] == [1, 2, 3])
        #expect(report.sent == 1 && report.skipped.isEmpty)
    }

    @Test("A move refused for a changed playlist (412): pulled, skipped, and reported")
    func moveConflict() async throws {
        let rig = try Rig()
        let list = try rig.playlist("p1", [1, 2, 3])
        rig.tidal.conflicts = 1
        let queue = rig.queue()
        try await queue.enqueue(.move(playlist: list, from: 0, to: 2))
        let report = await queue.drain()
        #expect(rig.sync.pulls.value == ["p1"])
        #expect(rig.tidal.playlists["p1"] == [1, 2, 3])
        #expect(report.skipped.count == 1 && report.sent == 0)
        #expect(await queue.pendingCount == 0)
    }

    @Test("Removing the same song twice (a double click) removes it once: the second finds it gone and sends nothing")
    func doubleRemove() async throws {
        let rig = try Rig()
        let list = try rig.playlist("p1", [10, 11, 12])
        let queue = rig.queue()
        try await queue.enqueue(.remove(playlist: list, trackId: 11, index: 1))
        try await queue.enqueue(.remove(playlist: list, trackId: 11, index: 1))
        _ = await queue.drain()
        #expect(rig.tidal.playlists["p1"] == [10, 12])
        #expect(rig.writes == ["DELETE playlists/p1/items/1"])
    }

    @Test("A remove finds the song by its id nearest the index it had (the list moved on TIDAL meanwhile)")
    func removeNearest() async throws {
        let rig = try Rig()
        let list = try rig.playlist("p1", [5, 9, 6, 9, 7])
        let queue = rig.queue()
        try await queue.enqueue(.remove(playlist: list, trackId: 9, index: 4))
        _ = await queue.drain()
        #expect(rig.tidal.playlists["p1"] == [5, 9, 6, 7])
    }

    @Test("A playlist deleted on TIDAL: its ops are dropped and reported, and the library's playlist becomes a plain one")
    func deletedOnTidal() async throws {
        let rig = try Rig()
        let list = try rig.playlist("gone", [1])
        rig.tidal.lock.withLock { rig.tidal.playlists["gone"] = nil }
        let queue = rig.queue()
        try await queue.enqueue(.add(playlist: list, trackIds: [2]))
        try await queue.enqueue(.remove(playlist: list, trackId: 1, index: 0))
        try await queue.enqueue(.favorite(kind: .track, id: 3, on: true))
        let report = await queue.drain()
        #expect(report.dropped == 2 && report.sent == 1)
        #expect(!report.skipped.isEmpty)
        #expect(try rig.database.tidalPlaylistUUID(playlistId: list) == nil)
        #expect(try rig.database.playlists().contains { $0.id == list }, "the playlist stays, unlinked")
    }

    @Test("While TIDAL asks to wait, draining stops with every op kept, and nothing is pulled")
    func backoff() async throws {
        let rig = try Rig()
        rig.tidal.rateLimited = true
        let queue = rig.queue()
        try await queue.enqueue(.favorite(kind: .track, id: 1, on: true))
        try await queue.enqueue(.favorite(kind: .track, id: 2, on: true))
        let report = await queue.drain()
        #expect(report.stopped && report.sent == 0)
        #expect(await queue.pendingCount == 2)
        #expect(rig.sync.refreshes.value == 0)
    }

    @Test("A playlist made in Vespertine is created on TIDAL and linked; what was added before it existed follows")
    func create() async throws {
        let rig = try Rig()
        let local = try rig.database.createPlaylist(name: "Road").id!
        let queue = rig.queue()
        try await queue.enqueue(.createPlaylist(localId: local, title: "Road", description: ""))
        try await queue.enqueue(.add(playlist: local, trackIds: [4]))
        let report = await queue.drain()
        #expect(report.sent == 2)
        #expect(try rig.database.tidalPlaylistUUID(playlistId: local) == "made-1")
        #expect(rig.tidal.playlists["made-1"] == [4])
    }

    @Test("A favorite sent updates the library's record of the list, so the next pull doesn't doubt it")
    func favoriteRecord() async throws {
        let rig = try Rig()
        try rig.database.setTidalFavorites("favorite tracks", ids: [1, 2])
        let queue = rig.queue()
        try await queue.enqueue(.favorite(kind: .track, id: 2, on: false))
        try await queue.enqueue(.favorite(kind: .track, id: 3, on: true))
        _ = await queue.drain()
        #expect(try rig.database.tidalFavoriteIds("favorite tracks") == [1, 3])
    }
}
