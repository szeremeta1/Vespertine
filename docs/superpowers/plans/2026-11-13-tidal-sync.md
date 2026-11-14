# TIDAL Two-Way Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Favorites and TIDAL playlist edits made in Vespertine reach TIDAL, are queued while offline, and resolve conflicts without losing data.

**Architecture:** `TidalWriter` sends single writes through the gate with etags. `TidalSyncQueue` persists ops in the library DB and drains them in order. The app routes favorite and playlist mutations on TIDAL targets through `TidalModel`.

**Tech Stack:** Swift 6, GRDB, Swift Testing, SwiftUI.

**Spec:** `docs/superpowers/specs/2026-11-13-tidal-sync-design.md`. It depends on the core and library/UI plans.

## Global Constraints

- Endpoints, form fields and headers exactly as in the spec's table. Etag header: `If-None-Match`.
- All writes are at `TidalPriority.interactive`.
- `tidalPendingOp` columns: `id`, `kind`, `payload` (JSON), `createdAt`, `attempts`.
- On 412: pull that playlist, then re-apply add (re-add), remove (same track id nearest the old index), move (skip, and report).
- A pull is deferred while any op is pending.

## Review Focus

1. **App quit with ops pending.** They survive and drain on next launch in the same order → test in Task 2.
2. **Removing the same playlist item twice quickly** (a double click). The second op must not delete a different item → test in Task 2 (remove is by track id nearest the index).
3. **A playlist deleted on TIDAL while ops for it are pending.** Its ops are dropped and reported, and the local playlist becomes a plain one → test in Task 2.
4. **The un-favorite of a downloaded track.** The row and file stay (marked not in favorites) → test in Task 3.
5. **A dropped local track without ISRC.** It is refused with "Not on TIDAL" and nothing is sent → test in Task 4.

---

### Task 1: `TidalWriter`

**Files:** Create `Packages/VespertineKit/Sources/VespertineTidal/TidalWriter.swift`. Test `Tests/VespertineTidalTests/TidalWriterTests.swift`.

**Interfaces:** `public struct TidalWriter: Sendable { init(gate:userId:); func setFavorite(_ on: Bool, kind: FavoriteKind, id: Int) async throws` (`FavoriteKind: track | album | artist`)`; func createPlaylist(title:description:) async throws -> TidalPlaylist; func edit(_ uuid: String, title:description:) async throws; func add(trackIds: [Int], to uuid: String) async throws; func remove(index: Int, from uuid: String) async throws; func move(from: Int, to: Int, in uuid: String) async throws; func delete(_ uuid: String) async throws }`. Each playlist write first does `GET playlists/{uuid}` and reads `ETag`.

- [ ] Tests (fake transport): each method's method, path, form and `If-None-Match` per the spec table; a 412 surfaces as `TidalError.http(status: 412, …)`.
- [ ] Implement. [ ] Run. [ ] Commit `Add TIDAL writes`.

### Task 2: `TidalSyncQueue` with persistence

**Files:** Create `Packages/VespertineKit/Sources/VespertineTidal/TidalSyncQueue.swift`. Modify `Packages/VespertineKit/Sources/VespertineLibrary/LibraryDatabase.swift` (migration `v26-tidal-pending-ops`, plus the enqueue/peek/delete API). Test `TidalSyncQueueTests.swift`.

**Interfaces:** `public actor TidalSyncQueue { init(writer:database:sync: TidalLibrarySync); func enqueue(_ op: TidalOp) throws; func drain() async -> DrainReport; var pendingCount: Int }`, where `TidalOp` is `favorite`, `createPlaylist(localId:)`, `edit`, `add`, `remove(trackId:index:)`, `move`, `delete`, and `DrainReport` has `sent`, `skipped: [String]` and `dropped`. After an empty drain, it calls `sync.refresh()`.

- [ ] Tests:
  - order is preserved;
  - reopening the DB keeps ops;
  - 412 on add → pull then re-add;
  - 412 on move → skipped and reported;
  - double remove → removes by track id near the index, and the second becomes a no-op when that item is gone;
  - a playlist that 404s → its ops are dropped and the playlist unlinked;
  - a gate backoff → drain stops with the ops kept;
  - refresh is called only when the queue is empty.
- [ ] Implement. [ ] Run. [ ] Commit `Queue and drain TIDAL writes`.

### Task 3: App routing for favorites and playlists

**Files:** Modify `App/Sources/Models/LibraryStore.swift` (`setFavorite`, playlist append/remove/move/rename/delete), `App/Sources/Models/TidalModel.swift` (owns the queue and drains on start, reachability-up, sign-in and backoff end), `App/Sources/Views/SidebarView.swift` ("New TIDAL Playlist…", the TIDAL glyph on linked playlists), and the row clock indicator in `TrackViews.swift`.

- [ ] Tests: the routing decision (TIDAL vs local target) as a pure function, with unit tests; un-favoriting a downloaded track keeps the row (`notInFavorites`).
- [ ] Implement. [ ] Build the app. [ ] Commit `Sync favorites and playlists to TIDAL`.

### Task 4: ISRC lookup for drops

**Files:** Create `Packages/VespertineKit/Sources/VespertineTidal/TidalISRCLookup.swift`. Modify the playlist drop destination in `SidebarView.swift` and the playlist view. Test `TidalISRCLookupTests.swift`.

**Interfaces:** `public struct TidalISRCLookup { func track(forISRC: String) async throws -> TidalTrack? }`, using `GET tracks` with `isrc=<isrc>` and taking the first `streamReady` item.

- [ ] Tests: a match → the track; no items → nil; no ISRC → refused before any request.
- [ ] Implement, with the toast copy "Added the TIDAL version of “<title>”" and the refusal "Not on TIDAL". [ ] Commit `Match local tracks to TIDAL by ISRC on drop`.
