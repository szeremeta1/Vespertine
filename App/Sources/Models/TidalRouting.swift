//
// Vespertine: where a heart or a playlist edit goes: to TIDAL for TIDAL songs and TIDAL playlists (while TIDAL is on), to the
// library alone otherwise. Pure, so the rules are tested apart from the views.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum TidalRouting {
    enum Target: Equatable { case local, tidal }

    /// The TIDAL ids to (un)favorite on TIDAL among songs (library id, TIDAL id when it is a TIDAL song). Local songs are hearted in
    /// the library only, as always; so is everything while TIDAL is off.
    static func favoriteTargets(_ tracks: [(Int64, Int?)], tidalOn: Bool) -> [Int] {
        guard tidalOn else { return [] }
        return tracks.compactMap(\.1)
    }

    /// A playlist's edits go to TIDAL when it is linked to (or being created on) TIDAL, and TIDAL is on. Plain playlists stay local.
    static func target(linked: Bool, tidalOn: Bool) -> Target { linked && tidalOn ? .tidal : .local }

    /// Songs added to a TIDAL playlist (library id, TIDAL id): TIDAL's own go by id; a local song has to be found on TIDAL by its ISRC
    /// first (decision 300).
    static func additions(_ tracks: [(Int64, Int?)]) -> (tidal: [Int], needsLookup: [Int64]) {
        (tracks.compactMap(\.1), tracks.filter { $0.1 == nil }.map(\.0))
    }

    enum Edit: Equatable {
        case remove(trackId: Int, index: Int)
        case move(from: Int, to: Int)
    }

    /// The removes, then moves, that turn a TIDAL playlist's items (`old`, TIDAL ids) into `new`. Removes go from the highest place
    /// down, so each place is still right when it is sent.
    static func edits(from old: [Int], to new: [Int]) -> [Edit] {
        // What stays: each id of `new`, matched to its occurrences in `old` in order; the rest of `old` is removed.
        var wanted = Dictionary(new.map { ($0, 1) }, uniquingKeysWith: +)
        var kept: [Int] = []
        var removed: [Edit] = []
        for (index, id) in old.enumerated() {
            if let n = wanted[id], n > 0 { wanted[id] = n - 1; kept.append(id) } else { removed.append(.remove(trackId: id, index: index)) }
        }
        var edits = Array(removed.reversed())
        // Moves: put each place's song there, taking it from further down.
        var current = kept
        for target in new.indices where target < current.count {
            guard current[target] != new[target], let from = current[(target + 1)...].firstIndex(of: new[target]) else { continue }
            let song = current.remove(at: from)
            current.insert(song, at: target)
            edits.append(.move(from: from, to: target))
        }
        return edits
    }

    /// `edits` applied to `list` (what TIDAL does with them), for tests.
    static func apply(_ edits: [Edit], to list: [Int]) -> [Int] {
        var list = list
        for edit in edits {
            switch edit {
            case .remove(_, let index): list.remove(at: index)
            case .move(let from, let to): let song = list.remove(at: from); list.insert(song, at: to)
            }
        }
        return list
    }
}

/// What the library asks of TIDAL for a TIDAL playlist's edits (the app model, while TIDAL is on).
@MainActor
protocol TidalPlaylistRouter: AnyObject {
    func isTidalPlaylist(_ id: Int64) -> Bool
    /// Songs dropped or added: TIDAL songs go in, local songs by their TIDAL version (ISRC), or are refused.
    func append(_ trackIDs: [Int64], to playlist: Int64)
    /// The playlist's TIDAL songs before and after a removal or a reorder (already written to the library).
    func reordered(_ playlist: Int64, from old: [Int], to new: [Int])
    func renamed(_ playlist: Int64, to name: String)
    func deleted(uuid: String)
}
