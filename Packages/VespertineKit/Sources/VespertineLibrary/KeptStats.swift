//
// Vespertine: listening statistics that outlast the library's rows: play counts, when a song was last played, its
// rating, the date it was added, its favorite and its play history. They survive rescans, moved files, a folder taken out
// of the library and added again, and every update.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB

// How a song's statistics are kept.
//
// They live on the song's `track` row (play count, last played, rating, date added) and in tables that follow the row
// (`favorite`, `playHistory`). Two things keep them there:
//
// 1. A row's statistics never go backwards when it is written again: a rescan, a server listing a song again or a tag
//    edit writes the whole row, freshly read, and a trigger puts back any play count it would lower, any last-played
//    date it would forget or move back, and any date added it would move later. Code that means to lower one (none does
//    today) has to drop `track_stats_never_lower` first.
// 2. A row that goes (its folder or share taken out of the library, a server account signed out of, a song taken out
//    of the library in any other way) leaves its statistics in `keptStats` first, through a trigger, so every way a row
//    can go is covered, foreign-key cascades included. A song that comes back (the same file, the same file moved,
//    or the same recording in the same format) takes its statistics back when it is added (`restoreKeptStats`).
//
// Only rows with something to keep are kept: a play, a rating, a favorite, a play in the history. Remove Missing Songs is
// the one way to forget statistics on purpose: its confirmation says so, and it drops what its removal kept.

extension LibraryDatabase {
    /// The migration that adds `keptStats` and its triggers.
    static func createKeptStats(_ db: Database) throws {
        try db.create(table: "keptStats") { t in
            t.autoIncrementedPrimaryKey("id")
            // Where the song was: a returning file (the folder added again) is found by it.
            t.column("location", .text).notNull().indexed()
            // The file itself, wherever it is now: size, length, CUE start and channels (`fileKey`).
            t.column("fileKey", .text).notNull().indexed()
            // The recording, for a file whose tags were rewritten on the way (`tagKey`); nil for a song without a title.
            t.column("tagKey", .text).indexed()
            t.column("playCount", .integer).notNull().defaults(to: 0)
            t.column("lastPlayedAt", .datetime)
            t.column("rating", .integer)
            t.column("addedAt", .datetime)
            t.column("favoritedAt", .datetime)
            t.column("favoriteBorrowed", .boolean)
            // Every time the song was heard: a JSON array of the dates, as `playHistory` stores them.
            t.column("history", .jsonText).notNull().defaults(to: "[]")
            t.column("keptAt", .datetime).notNull()
        }
        try createKeptStatsTriggersV24(db)
    }

    /// The key a file keeps when it is moved or renamed: the same expression as `reconcileMovedTracks`'s file key.
    static func fileKeySQL(_ row: String) -> String {
        "\(row).fileSize || '|' || CAST(round(\(row).duration * 1000) AS INTEGER) || '|' || coalesce(\(row).cueStartFrame, -1) || '|' || \(row).channels"
    }

    /// The key a recording keeps when its file is re-tagged on the way: title, artist, track, disc, rate, channels, length
    /// and CUE start, as `reconcileMovedTracks`'s tag key. NULL for a song without a title.
    static func tagKeySQL(_ row: String) -> String {
        """
        CASE WHEN coalesce(\(row).title, '') = '' THEN NULL ELSE
          lower(\(row).title) || '|' || lower(coalesce(\(row).artist, '')) || '|' || coalesce(\(row).trackNumber, 0) || '|' ||
          coalesce(\(row).discNumber, 0) || '|' || CAST(\(row).sampleRate AS INTEGER) || '|' || \(row).channels || '|' ||
          CAST(round(\(row).duration) AS INTEGER) || '|' || coalesce(\(row).cueStartFrame, -1) END
        """
    }

    /// The triggers as the migration that made them (v24) wrote them, before skips were counted: a migration never changes.
    static func createKeptStatsTriggersV24(_ db: Database) throws {
        // 1. A row written again never loses plays, its last play or the date it came into the library. (The update below
        // sets the old values back; recursive triggers are off, so it doesn't run this trigger again.)
        try db.execute(sql: """
            CREATE TRIGGER track_stats_never_lower AFTER UPDATE OF playCount, lastPlayedAt, addedAt ON track
            WHEN NEW.playCount < OLD.playCount
              OR (OLD.lastPlayedAt IS NOT NULL AND (NEW.lastPlayedAt IS NULL OR NEW.lastPlayedAt < OLD.lastPlayedAt))
              OR NEW.addedAt > OLD.addedAt
            BEGIN
              UPDATE track SET
                playCount = max(NEW.playCount, OLD.playCount),
                lastPlayedAt = CASE WHEN OLD.lastPlayedAt IS NULL THEN NEW.lastPlayedAt
                                    WHEN NEW.lastPlayedAt IS NULL OR NEW.lastPlayedAt < OLD.lastPlayedAt THEN OLD.lastPlayedAt
                                    ELSE NEW.lastPlayedAt END,
                addedAt = min(NEW.addedAt, OLD.addedAt)
              WHERE id = NEW.id;
            END
            """)
        // 2. A row that goes keeps what it has. BEFORE, so the favorite and history rows a cascade is about to take are
        // still there to read.
        try db.execute(sql: """
            CREATE TRIGGER track_keep_stats BEFORE DELETE ON track
            WHEN OLD.playCount > 0 OR OLD.rating IS NOT NULL
              OR EXISTS (SELECT 1 FROM favorite WHERE trackId = OLD.id)
              OR EXISTS (SELECT 1 FROM playHistory WHERE trackId = OLD.id)
            BEGIN
              INSERT INTO keptStats (location, fileKey, tagKey, playCount, lastPlayedAt, rating, addedAt, favoritedAt,
                                     favoriteBorrowed, history, keptAt)
              VALUES (OLD.location, \(fileKeySQL("OLD")), \(tagKeySQL("OLD")), OLD.playCount, OLD.lastPlayedAt, OLD.rating,
                      OLD.addedAt,
                      (SELECT favoritedAt FROM favorite WHERE trackId = OLD.id),
                      (SELECT borrowed FROM favorite WHERE trackId = OLD.id),
                      coalesce((SELECT json_group_array(playedAt) FROM (SELECT playedAt FROM playHistory WHERE trackId = OLD.id ORDER BY playedAt)), '[]'),
                      strftime('%Y-%m-%d %H:%M:%f', 'now'));
            END
            """)
    }

    /// The triggers as they are now (from v25, which counts skips).
    static func createKeptStatsTriggers(_ db: Database) throws {
        // 1. A row written again never loses plays or skips, the last of either, or the date it came into the library. (The
        // update below sets the old values back; recursive triggers are off, so it doesn't run this trigger again.)
        try db.execute(sql: """
            CREATE TRIGGER track_stats_never_lower AFTER UPDATE OF playCount, lastPlayedAt, addedAt, skipCount, lastSkippedAt ON track
            WHEN NEW.playCount < OLD.playCount
              OR (OLD.lastPlayedAt IS NOT NULL AND (NEW.lastPlayedAt IS NULL OR NEW.lastPlayedAt < OLD.lastPlayedAt))
              OR NEW.addedAt > OLD.addedAt
              OR coalesce(NEW.skipCount, 0) < coalesce(OLD.skipCount, 0)
              OR (OLD.lastSkippedAt IS NOT NULL AND (NEW.lastSkippedAt IS NULL OR NEW.lastSkippedAt < OLD.lastSkippedAt))
            BEGIN
              UPDATE track SET
                playCount = max(NEW.playCount, OLD.playCount),
                lastPlayedAt = CASE WHEN OLD.lastPlayedAt IS NULL THEN NEW.lastPlayedAt
                                    WHEN NEW.lastPlayedAt IS NULL OR NEW.lastPlayedAt < OLD.lastPlayedAt THEN OLD.lastPlayedAt
                                    ELSE NEW.lastPlayedAt END,
                addedAt = min(NEW.addedAt, OLD.addedAt),
                skipCount = CASE WHEN coalesce(NEW.skipCount, 0) < coalesce(OLD.skipCount, 0) THEN OLD.skipCount ELSE NEW.skipCount END,
                lastSkippedAt = CASE WHEN OLD.lastSkippedAt IS NULL THEN NEW.lastSkippedAt
                                     WHEN NEW.lastSkippedAt IS NULL OR NEW.lastSkippedAt < OLD.lastSkippedAt THEN OLD.lastSkippedAt
                                     ELSE NEW.lastSkippedAt END
              WHERE id = NEW.id;
            END
            """)
        // 2. A row that goes keeps what it has. BEFORE, so the favorite and history rows a cascade is about to take are
        // still there to read.
        try db.execute(sql: """
            CREATE TRIGGER track_keep_stats BEFORE DELETE ON track
            WHEN OLD.playCount > 0 OR coalesce(OLD.skipCount, 0) > 0 OR OLD.rating IS NOT NULL
              OR EXISTS (SELECT 1 FROM favorite WHERE trackId = OLD.id)
              OR EXISTS (SELECT 1 FROM playHistory WHERE trackId = OLD.id)
            BEGIN
              INSERT INTO keptStats (location, fileKey, tagKey, playCount, lastPlayedAt, skipCount, lastSkippedAt, rating, addedAt,
                                     favoritedAt, favoriteBorrowed, history, keptAt)
              VALUES (OLD.location, \(fileKeySQL("OLD")), \(tagKeySQL("OLD")), OLD.playCount, OLD.lastPlayedAt, OLD.skipCount,
                      OLD.lastSkippedAt, OLD.rating, OLD.addedAt,
                      (SELECT favoritedAt FROM favorite WHERE trackId = OLD.id),
                      (SELECT borrowed FROM favorite WHERE trackId = OLD.id),
                      coalesce((SELECT json_group_array(playedAt) FROM (SELECT playedAt FROM playHistory WHERE trackId = OLD.id ORDER BY playedAt)), '[]'),
                      strftime('%Y-%m-%d %H:%M:%f', 'now'));
            END
            """)
    }

    /// Gives songs just added the statistics kept for them, if any: the song kept at the same place first, else the one
    /// file of the same size, length, CUE start and channels, else the one recording with the same tags, format and length.
    /// A key two kept songs share is passed over: their statistics wait for a song that is theirs alone. A kept entry
    /// given back is gone. Returns the track IDs that took statistics back.
    @discardableResult
    static func restoreKeptStats(_ db: Database, trackIDs: [Int64]) throws -> [Int64] {
        guard !trackIDs.isEmpty, try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM keptStats)") == true else { return [] }
        var restored: [Int64] = []
        for id in trackIDs {
            guard let kept = try Int64.fetchOne(db, sql: """
                SELECT coalesce(
                  (SELECT k.id FROM keptStats k WHERE k.location = t.location ORDER BY k.keptAt DESC, k.id DESC LIMIT 1),
                  (SELECT min(k.id) FROM keptStats k WHERE k.fileKey = \(fileKeySQL("t")) HAVING count(*) = 1),
                  (SELECT min(k.id) FROM keptStats k WHERE k.tagKey = \(tagKeySQL("t")) HAVING count(*) = 1))
                FROM track t WHERE t.id = ?
                """, arguments: [id]) else { continue }
            try db.execute(sql: """
                UPDATE track SET
                  playCount = playCount + (SELECT playCount FROM keptStats WHERE id = :kept),
                  lastPlayedAt = CASE
                    WHEN (SELECT lastPlayedAt FROM keptStats WHERE id = :kept) IS NULL THEN lastPlayedAt
                    WHEN lastPlayedAt IS NULL THEN (SELECT lastPlayedAt FROM keptStats WHERE id = :kept)
                    ELSE max(lastPlayedAt, (SELECT lastPlayedAt FROM keptStats WHERE id = :kept)) END,
                  skipCount = CASE WHEN coalesce((SELECT skipCount FROM keptStats WHERE id = :kept), 0) = 0 THEN skipCount
                    ELSE coalesce(skipCount, 0) + (SELECT skipCount FROM keptStats WHERE id = :kept) END,
                  lastSkippedAt = CASE
                    WHEN (SELECT lastSkippedAt FROM keptStats WHERE id = :kept) IS NULL THEN lastSkippedAt
                    WHEN lastSkippedAt IS NULL THEN (SELECT lastSkippedAt FROM keptStats WHERE id = :kept)
                    ELSE max(lastSkippedAt, (SELECT lastSkippedAt FROM keptStats WHERE id = :kept)) END,
                  rating = coalesce(rating, (SELECT rating FROM keptStats WHERE id = :kept)),
                  addedAt = min(addedAt, coalesce((SELECT addedAt FROM keptStats WHERE id = :kept), addedAt))
                WHERE id = :track
                """, arguments: ["kept": kept, "track": id])
            try db.execute(sql: """
                INSERT OR IGNORE INTO favorite (trackId, favoritedAt, borrowed)
                SELECT :track, favoritedAt, coalesce(favoriteBorrowed, 0) FROM keptStats WHERE id = :kept AND favoritedAt IS NOT NULL
                """, arguments: ["kept": kept, "track": id])
            try db.execute(sql: """
                INSERT INTO playHistory (trackId, playedAt)
                SELECT :track, j.value FROM keptStats k, json_each(k.history) j WHERE k.id = :kept AND json_valid(k.history)
                  AND NOT EXISTS (SELECT 1 FROM playHistory h WHERE h.trackId = :track AND h.playedAt = j.value)
                ORDER BY j.value
                """, arguments: ["kept": kept, "track": id])
            try db.execute(sql: "DELETE FROM keptStats WHERE id = ?", arguments: [kept])
            restored.append(id)
        }
        return restored
    }

    /// How many songs' statistics are kept for songs not in the library now.
    public func keptStatsCount() throws -> Int {
        try writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM keptStats") ?? 0 }
    }
}

extension LibraryDatabase {
    /// Runs `body`, then forgets the statistics that the rows it deleted left in `keptStats`: for deletions whose
    /// statistics went elsewhere (a moved file's new entry) or are meant to go (Remove Missing Songs).
    static func withoutKeepingStats<T>(_ db: Database, _ body: () throws -> T) throws -> T {
        let before = try Int64.fetchOne(db, sql: "SELECT coalesce(max(id), 0) FROM keptStats") ?? 0
        let result = try body()
        try db.execute(sql: "DELETE FROM keptStats WHERE id > ?", arguments: [before])
        return result
    }
}
