// Vespertine: the master switch's reach into the library: what the queries return while TIDAL is off.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB

extension LibraryDatabase {
    /// Whether the TIDAL account's rows take part in the library's lists, counts, albums, artists, genres, favorites, history, playlists
    /// and smart playlists. The app sets it from Settings › Online › "TIDAL integration" (off by default, decision 209). Off, every query
    /// answers as if the library had never had a TIDAL account; nothing is deleted. A database nobody switched (the command-line
    /// tools, the sync) sees everything.
    public var includeTidal: Bool {
        get { includesTidal.withLock { $0 } }
        set { includesTidal.withLock { $0 = newValue } }
    }

    /// The TIDAL sources to leave out of the queries now: none while TIDAL is on, or when the library has no TIDAL account.
    func hiddenSourceIDs(_ db: Database) throws -> Set<Int64> {
        guard !includeTidal else { return [] }
        return Set(try Int64.fetchAll(db, sql: "SELECT id FROM source WHERE path = ?", arguments: [LibrarySource.tidalPath]))
    }

    /// A condition on `track` rows (or the table `qualifier` names) that holds for every row the library shows: "1" when nothing is
    /// hidden, which leaves a library without TIDAL on the very SQL it always ran.
    public func visibleTracksClause(_ db: Database, qualifier: String = "track") throws -> String {
        let hidden = try hiddenSourceIDs(db).sorted()
        switch hidden.count {
        case 0: return "1"
        case 1: return "\(qualifier).sourceId IS NOT \(hidden[0])"
        default: return "(\(qualifier).sourceId IS NULL OR \(qualifier).sourceId NOT IN (\(hidden.map(String.init).joined(separator: ", "))))"
        }
    }

    /// A condition on `source` rows: the TIDAL account is no folder or share, and only shows while TIDAL is on.
    func visibleSourcesClause() -> String {
        includeTidal ? "1" : "path != '\(LibrarySource.tidalPath)'"
    }

    /// A condition on `playlist` rows: a playlist that stands for one of TIDAL's (`tidalPlaylist`, from the playlist sync) shows only
    /// while TIDAL is on.
    func visiblePlaylistsClause(_ db: Database) throws -> String {
        guard !includeTidal, try db.tableExists("tidalPlaylist") else { return "1" }
        return "id NOT IN (SELECT playlistId FROM tidalPlaylist)"
    }
}
