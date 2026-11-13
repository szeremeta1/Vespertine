// Vespertine: TIDAL writes: favorites, and playlist creation and edits. One request each (after the etag for a playlist), through the
// gate at interactive priority. Queueing, retrying and conflict handling are the sync queue's.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum FavoriteKind: String, Sendable, Codable, CaseIterable {
    case track, album, artist

    /// The path segment (`users/{id}/favorites/<segment>`) and the form field that names the item.
    var segment: String { self == .track ? "tracks" : self == .album ? "albums" : "artists" }
    var field: String { self == .track ? "trackIds" : self == .album ? "albumIds" : "artistIds" }
}

public struct TidalWriter: Sendable {
    private let gate: TidalGate
    private let userId: Int

    public init(gate: TidalGate, userId: Int) {
        self.gate = gate
        self.userId = userId
    }

    // MARK: Favorites

    public func setFavorite(_ on: Bool, kind: FavoriteKind, id: Int) async throws {
        if on {
            _ = try await gate.send(method: "POST", path: "users/\(userId)/favorites/\(kind.segment)", form: [kind.field: String(id)], priority: .interactive)
        } else {
            _ = try await gate.send(method: "DELETE", path: "users/\(userId)/favorites/\(kind.segment)/\(id)", form: [:], priority: .interactive)
        }
    }

    // MARK: Playlists

    /// A new, empty playlist. TIDAL answers with the playlist (or wraps it in `data`); only its uuid is relied on.
    public func createPlaylist(title: String, description: String) async throws -> TidalPlaylist {
        let (data, _) = try await gate.send(method: "POST", path: "users/\(userId)/playlists",
                                            form: ["title": title, "description": description], priority: .interactive)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let inner = (object?["data"] as? [String: Any]) ?? object
        let uuid = (inner?["uuid"] as? String) ?? (object?["uuid"] as? String)
            ?? (object?["trn"] as? String).flatMap { $0.split(separator: ":").last.map(String.init) }
        guard let uuid, !uuid.isEmpty else {
            throw TidalError.http(status: 200, body: "No playlist in the answer: \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return TidalPlaylist(uuid: uuid, title: (inner?["title"] as? String) ?? title, numberOfTracks: (inner?["numberOfTracks"] as? Int) ?? 0,
                             lastUpdated: inner?["lastUpdated"] as? String, description: (inner?["description"] as? String) ?? description,
                             squareImage: inner?["squareImage"] as? String)
    }

    public func edit(_ uuid: String, title: String, description: String) async throws {
        try await write(method: "POST", path: "playlists/\(uuid)", form: ["title": title, "description": description], uuid: uuid)
    }

    public func add(trackIds: [Int], to uuid: String) async throws {
        try await write(method: "POST", path: "playlists/\(uuid)/items",
                        form: ["trackIds": trackIds.map(String.init).joined(separator: ","), "onDupes": "ADD"], uuid: uuid)
    }

    public func remove(index: Int, from uuid: String) async throws {
        try await write(method: "DELETE", path: "playlists/\(uuid)/items/\(index)", form: ["order": "INDEX", "orderDirection": "ASC"], uuid: uuid)
    }

    public func move(from: Int, to: Int, in uuid: String) async throws {
        try await write(method: "POST", path: "playlists/\(uuid)/items/\(from)", form: ["toIndex": String(to)], uuid: uuid)
    }

    public func delete(_ uuid: String) async throws {
        try await write(method: "DELETE", path: "playlists/\(uuid)", form: [:], uuid: uuid)
    }

    /// The playlist's current etag, then one write that carries it: TIDAL refuses it (412) when the playlist changed in between.
    private func write(method: String, path: String, form: [String: String], uuid: String) async throws {
        let (_, head) = try await gate.getResponse("playlists/\(uuid)", priority: .interactive)
        guard let etag = head.value(forHTTPHeaderField: "ETag"), !etag.isEmpty else {
            throw TidalError.missingETag(playlist: uuid)
        }
        _ = try await gate.send(method: method, path: path, form: form, priority: .interactive, ifMatch: etag)
    }
}
