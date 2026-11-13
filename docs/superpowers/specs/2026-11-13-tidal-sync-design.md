# TIDAL playlist and favorites sync (two-way): design

Sub-project 3 of 4. It builds on sub-projects 1 and 2. Decisions are logged in `docs/superpowers/DECISIONS.md` (from number 300).

## Goal

Changes made in Vespertine to TIDAL favorites and TIDAL playlists reach TIDAL, and changes made on TIDAL reach Vespertine. Nothing is lost when both change.

## What syncs

| Vespertine action | TIDAL call (v1, from TidalSwiftLib `Favorites`/`PlaylistEditing`) |
|---|---|
| ♥ a TIDAL track / album / artist | `POST users/{id}/favorites/tracks` (`trackIds`) / `albums` (`albumIds`) / `artists` (`artistIds`) |
| un-♥ | `DELETE users/{id}/favorites/tracks/{id}` (albums, artists likewise) |
| New playlist → "New TIDAL Playlist…" | `POST users/{id}/playlists` (`title`, `description`) |
| Rename / edit description | `POST playlists/{uuid}` (`title`, `description`) with `If-None-Match: <etag>` |
| Add TIDAL tracks | `POST playlists/{uuid}/items` (`trackIds` comma-joined, `onDupes=ADD`) with the etag |
| Remove item at index | `DELETE playlists/{uuid}/items/{index}` (`order=INDEX`, `orderDirection=ASC`) with the etag |
| Move item | `POST playlists/{uuid}/items/{from}` (`toIndex`) with the etag |
| Delete playlist | `DELETE playlists/{uuid}` with the etag |

The etag comes from `GET playlists/{uuid}` (the `ETag` response header). Every write goes through `TidalGate` at `.interactive` priority.

## Rules

- **Local favorites vs TIDAL favorites:** for a TIDAL row, the heart *is* the TIDAL favorite. For local rows, nothing changes.
- **A TIDAL-linked playlist accepts only TIDAL tracks.** If you drop a local track on it, Vespertine looks the track up by ISRC (`GET tracks?isrc=<isrc>`, the first streamable result), adds that TIDAL track instead, and says so in a toast. With no match, the drop is refused with "Not on TIDAL". Plain Vespertine playlists stay local and may mix sources freely. (Decision 300.)
- **Offline / signed out / backoff:** writes queue in a persistent `tidalPendingOp` table (`id`, `kind`, `payload JSON`, `createdAt`, `attempts`) and run in order when the gate is available again. The UI updates immediately (optimistic), and the row shows a small "waiting to sync" clock until the write succeeds.
- **Conflicts:** before each playlist write, the etag is fetched. On HTTP 412 (etag mismatch), Vespertine pulls the playlist again (the TIDAL version wins), then re-applies the pending op if it still makes sense:
  - add → re-add;
  - remove → remove the item with the same track id nearest the old index;
  - move → skip.

  Skipped ops are reported in Settings › TIDAL › Status. (Decision 301.)
- **Pull** (sub-project 1's `TidalLibrarySync.refresh`) runs after the pending queue is empty, so a pull never undoes a write that hasn't been sent yet.
- **Smart playlists** are never pushed.

## Components

- `TidalWriter` (in `VespertineTidal`): `favorite(_:on:)`, `createPlaylist`, `rename`, `add(trackIds:to:)`, `remove(index:from:)`, `move(from:to:in:)`, `deletePlaylist`. Each fetches the etag and sends one request.
- `TidalSyncQueue` (in `VespertineTidal`): persists ops, drains them in order, handles 412 per the rules, and backs off with the gate.
- `TidalISRCLookup`: `track(forISRC:) async throws -> TidalTrack?`.
- App: the `LibraryStore` favorite and playlist mutation points call `TidalModel` when the target is TIDAL. The sidebar's Playlists "+" menu gains "New TIDAL Playlist…". TIDAL-linked playlists show the TIDAL glyph in the sidebar.

## Testing

- `TidalWriter`: exact paths, form fields and `If-None-Match` per the table (fake transport).
- `TidalSyncQueue`:
  - order is preserved;
  - ops persist across a restart (in-memory DB reopened);
  - 412 → pull, then re-apply per the rules;
  - a backoff pauses draining;
  - a pull is deferred while ops are pending.
- ISRC drop: a match adds the TIDAL track; no match refuses the drop.
