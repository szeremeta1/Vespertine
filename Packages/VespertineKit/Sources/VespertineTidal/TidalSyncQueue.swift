// Vespertine: TIDAL writes made in Vespertine (favorites, playlists), kept in the library until sent, sent in order, and fitted to
// TIDAL's own changes: TIDAL wins a conflict (412); adds and removes are applied again, moves are skipped and reported (decision
// 301). The account is pulled only once nothing waits, so a pull never undoes a write not sent yet.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import VespertineLibrary

/// One write to TIDAL. Playlists are named by the library's playlist id (a new one has no TIDAL uuid until its creation is sent),
/// except a deletion, which outlives the library's playlist.
public enum TidalOp: Codable, Sendable, Equatable {
    case favorite(kind: FavoriteKind, id: Int, on: Bool)
    case createPlaylist(localId: Int64, title: String, description: String)
    case edit(playlist: Int64, title: String, description: String)
    case add(playlist: Int64, trackIds: [Int])
    case remove(playlist: Int64, trackId: Int, index: Int)
    case move(playlist: Int64, from: Int, to: Int)
    case delete(uuid: String)

    public var kind: String {
        switch self {
        case .favorite: "favorite"
        case .createPlaylist: "createPlaylist"
        case .edit: "edit"
        case .add: "add"
        case .remove: "remove"
        case .move: "move"
        case .delete: "delete"
        }
    }

    /// The library playlist the op is about, if any.
    public var playlist: Int64? {
        switch self {
        case .createPlaylist(let id, _, _), .edit(let id, _, _), .add(let id, _), .remove(let id, _, _), .move(let id, _, _): id
        case .favorite, .delete: nil
        }
    }
}

/// What the queue needs of the library sync: the pull, a playlist's items as TIDAL has them now, and one playlist pulled again.
public protocol TidalSyncing: Sendable {
    func refresh() async throws -> TidalLibrarySync.Summary
    func playlistTrackIds(_ uuid: String) async throws -> [Int]
    func pullPlaylist(_ uuid: String) async throws
}

public actor TidalSyncQueue {
    public struct DrainReport: Sendable, Equatable {
        public var sent = 0
        /// Ops that couldn't be applied (a move on a changed playlist, a write TIDAL refused), as the user reads them.
        public var skipped: [String] = []
        /// Ops dropped because their playlist was deleted on TIDAL.
        public var dropped = 0
        /// Draining stopped with ops left (offline, signed out, TIDAL asked to wait).
        public var stopped = false
        /// The pull after an empty queue, when it ran.
        public var summary: TidalLibrarySync.Summary?
        /// Why that pull (or the draining) failed.
        public var error: String?
        public init() {}
    }

    private let writer: TidalWriter
    private let database: LibraryDatabase
    private let sync: TidalSyncing
    private var draining = false

    public init(writer: TidalWriter, database: LibraryDatabase, sync: TidalSyncing) {
        self.writer = writer
        self.database = database
        self.sync = sync
    }

    public func enqueue(_ op: TidalOp) throws {
        let payload = String(decoding: try JSONEncoder().encode(op), as: UTF8.self)
        try database.enqueueTidalOp(kind: op.kind, payload: payload)
    }

    public var pendingCount: Int { (try? database.tidalPendingOps().count) ?? 0 }

    /// The ops waiting, oldest first.
    public func pending() throws -> [TidalOp] {
        try database.tidalPendingOps().compactMap { try? JSONDecoder().decode(TidalOp.self, from: Data($0.payload.utf8)) }
    }

    /// Sends what waits, in order, then pulls the account when nothing is left. Stops (keeping the ops) at the first sign TIDAL can't
    /// be written to now.
    public func drain() async -> DrainReport {
        var report = DrainReport()
        guard !draining else { report.stopped = true; return report }
        draining = true
        defer { draining = false }
        while let row = (try? database.tidalPendingOps())?.first {
            guard let op = try? JSONDecoder().decode(TidalOp.self, from: Data(row.payload.utf8)) else {
                try? database.deleteTidalOp(row.id)
                report.dropped += 1
                continue
            }
            do {
                switch try await send(op) {
                case .sent: report.sent += 1
                case .nothing: break
                case .skipped(let why): report.skipped.append(why)
                }
                try? database.deleteTidalOp(row.id)
            } catch let error as TidalError {
                switch error {
                case .http(404, _) where op.playlist != nil:
                    report.dropped += dropPlaylist(op.playlist!)
                    report.skipped.append(Self.deletedOnTidal(name: playlistName(op.playlist!)))
                case .http(let status, _) where status != 429 && !(500...599).contains(status):
                    try? database.deleteTidalOp(row.id)
                    report.skipped.append(Self.refused(op, error))
                default:
                    // Backing off, abuse, signed out, missing etag, a server error: try again later, in the same order.
                    try? database.bumpTidalOpAttempts(row.id)
                    report.stopped = true
                    report.error = error.localizedDescription
                    return report
                }
            } catch {
                // Offline, cancelled: the op waits.
                try? database.bumpTidalOpAttempts(row.id)
                report.stopped = true
                report.error = error.localizedDescription
                return report
            }
        }
        do {
            report.summary = try await sync.refresh()
        } catch {
            report.error = error.localizedDescription
        }
        return report
    }

    private enum Outcome { case sent, nothing, skipped(String) }

    private func send(_ op: TidalOp) async throws -> Outcome {
        switch op {
        case .favorite(let kind, let id, let on):
            try await writer.setFavorite(on, kind: kind, id: id)
            switch kind {
            case .track: try? database.setTidalFavorite("favorite tracks", id: id, present: on)
            case .album: try? database.setTidalFavorite("favorite albums", id: id, present: on)
            case .artist: break
            }
            return .sent
        case .createPlaylist(let localId, let title, let description):
            guard try database.playlists().contains(where: { $0.id == localId }) else { return .nothing }   // deleted meanwhile
            if try database.tidalPlaylistUUID(playlistId: localId) != nil { return .nothing }
            let made = try await writer.createPlaylist(title: title, description: description)
            try database.linkTidalPlaylist(uuid: made.uuid, playlistId: localId)
            return .sent
        case .delete(let uuid):
            do {
                try await retryingOnce(uuid) { try await self.writer.delete(uuid) }
            } catch TidalError.http(404, _) {
                return .nothing   // gone already
            }
            return .sent
        case .edit(let local, let title, let description):
            guard let uuid = try database.tidalPlaylistUUID(playlistId: local) else { return .nothing }
            try await retryingOnce(uuid) { try await self.writer.edit(uuid, title: title, description: description) }
            return .sent
        case .add(let local, let ids):
            guard let uuid = try database.tidalPlaylistUUID(playlistId: local) else { return .nothing }
            try await retryingOnce(uuid) { try await self.writer.add(trackIds: ids, to: uuid) }
            return .sent
        case .remove(let local, let trackId, let index):
            guard let uuid = try database.tidalPlaylistUUID(playlistId: local) else { return .nothing }
            var sent = false
            try await retryingOnce(uuid) {
                // By the song, nearest where it was: the list may have moved, and a second remove of one song finds it gone.
                let items = try await self.sync.playlistTrackIds(uuid)
                guard let at = Self.nearest(trackId, to: index, in: items) else { sent = false; return }
                try await self.writer.remove(index: at, from: uuid)
                sent = true
            }
            return sent ? .sent : .nothing
        case .move(let local, let from, let to):
            guard let uuid = try database.tidalPlaylistUUID(playlistId: local) else { return .nothing }
            do {
                try await writer.move(from: from, to: to, in: uuid)
            } catch TidalError.http(412, _) {
                try await sync.pullPlaylist(uuid)
                return .skipped(Self.moveSkipped(name: playlistName(local)))
            }
            return .sent
        }
    }

    /// `write`, and once more after pulling the playlist when TIDAL says it changed (412): TIDAL's version wins, the op applies to it.
    private func retryingOnce(_ uuid: String, _ write: () async throws -> Void) async throws {
        do {
            try await write()
        } catch TidalError.http(412, _) {
            try await sync.pullPlaylist(uuid)
            try await write()
        }
    }

    /// The index of `trackId` in `items` nearest `index`; nil when it isn't there.
    static func nearest(_ trackId: Int, to index: Int, in items: [Int]) -> Int? {
        items.indices.filter { items[$0] == trackId }.min { abs($0 - index) < abs($1 - index) }
    }

    /// The playlist was deleted on TIDAL: every op for it goes, and the library's playlist becomes a plain one. Returns how many ops.
    private func dropPlaylist(_ local: Int64) -> Int {
        let rows = (try? database.tidalPendingOps()) ?? []
        var dropped = 0
        for row in rows {
            guard let op = try? JSONDecoder().decode(TidalOp.self, from: Data(row.payload.utf8)), op.playlist == local else { continue }
            try? database.deleteTidalOp(row.id)
            dropped += 1
        }
        if let uuid = try? database.tidalPlaylistUUID(playlistId: local) { try? database.unlinkTidalPlaylist(uuid: uuid) }
        return dropped
    }

    private func playlistName(_ local: Int64) -> String {
        ((try? database.playlists()) ?? []).first { $0.id == local }?.name ?? String(localized: "a playlist")
    }

    static func deletedOnTidal(name: String) -> String {
        String(localized: "“\(name)” was deleted on TIDAL. Changes to it weren’t sent; it stays here as a plain playlist.",
               comment: "Settings › TIDAL › Status after a sync. The value is the playlist's name.")
    }

    static func moveSkipped(name: String) -> String {
        String(localized: "A move in “\(name)” was skipped: the playlist had changed on TIDAL.",
               comment: "Settings › TIDAL › Status after a sync. The value is the playlist's name.")
    }

    static func refused(_ op: TidalOp, _ error: Error) -> String {
        String(localized: "TIDAL refused a change (\(op.kind)): \(error.localizedDescription)",
               comment: "Settings › TIDAL › Status. First value: the kind of change (internal name); second: TIDAL's error.")
    }
}

extension TidalLibrarySync: TidalSyncing {
    public func playlistTrackIds(_ uuid: String) async throws -> [Int] {
        try await catalog.playlistTracks(uuid, priority: .interactive).map(\.id)
    }

    /// TIDAL's version of one playlist, into the library (its tracks first, then its items in order).
    public func pullPlaylist(_ uuid: String) async throws {
        let playlist = try await catalog.playlist(uuid, priority: .interactive)
        let tracks = try await catalog.playlistTracks(uuid, priority: .interactive)
        let source = try database.tidalSource(userId: userId)
        guard let sourceId = source.id else { return }
        try database.upsertTidalTracks(tracks.map { TidalTrackInput($0) }, sourceId: sourceId)
        try database.setTidalPlaylist(uuid: uuid, name: playlist.title, lastUpdated: playlist.lastUpdated, tidalIds: tracks.map(\.id))
    }
}
