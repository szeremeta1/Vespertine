# TIDAL library and UI integration: design

Sub-project 2 of 4. It builds on sub-project 1 (`docs/superpowers/specs/2026-11-13-tidal-core-design.md`). The owner delegated the design decisions; each one is logged in `docs/superpowers/DECISIONS.md` (from number 200).

## Goal

TIDAL music looks and behaves like the rest of the library, in Vespertine's existing views. The only differences:
- a Source column;
- grayed rows when a track can't play right now;
- TIDAL-only details in the inspector;
- a TIDAL section in the sidebar for the catalog.

The app gets no second visual language.

## Master switch

Everything below exists only while **Settings › Online › "TIDAL integration"** is on. It is off by default. With it off, the app is exactly as before (decision 209):
- no TIDAL tab, sidebar section, Source column or inspector group;
- no reader registration, sync or network traffic;
- TIDAL-source rows filtered out of all library queries (`LibraryFilter`/stats/albums/smart playlists).

Turning it off keeps all data.

## App wiring (`App/Sources/Models/TidalModel.swift`, new)

- `@MainActor @Observable final class TidalModel`, owned by `AppModel`. It holds:
  - `TidalAuth`, `TidalGate`, `TidalCatalog`, `TidalStreamResolver`, `TidalLibrarySync`, `TidalDownloader`;
  - `state: signedOut | signingIn | signedIn(userName) | missingCredentials`;
  - `isReachable`, from `NWPathMonitor`;
  - `backoff`, mirrored from the gate.
- At launch:
  - load the credentials;
  - call `TidalPlayback.register(resolver:)`;
  - if signed in, start `TidalLibrarySync.refresh()` and refresh again every 6 h while the app runs, plus on demand.
- `TIDAL source isOnline` = signed in ∧ reachable ∧ no abuse backoff. It updates through `LibraryDatabase.setSourceOnline`.
- `PlayableItem` for a TIDAL track: `url = TidalPlayback.url(trackId:)` and `cacheKey = TidalPlayback.cacheKey(trackId:)`. If `downloadPath` is set and the file exists, the item plays the file instead, as a normal local item.
- After a TIDAL track's probe, `recordProbedFormat` stores the real format (hooked where the app already receives the engine's `SourceFormat` for the playing item).

## Settings › TIDAL (new tab, between Online and Remote)

- **Account:**
  - Signed out: a "Sign In…" button, which opens the login sheet.
  - Signed in: the account name and country, plus "Sign Out".
- **Client credentials:** shown only when missing or on "Change…". Four secure fields, saved to the credentials file.
- **Streaming quality:** a picker (Max / Hi-Res Lossless (default), Lossless (16/44.1), High (AAC 320), Low (AAC 96)). It maps to `audioquality`.
- **Downloads:**
  - the folder (default `~/Music/Vespertine/TIDAL`), with "Choose…";
  - a toggle, "Add downloads folder to the library", on by default. It adds the folder as a reference source, so downloaded files are scanned and linked.
- **Status:** the last sync time, "Refresh Now", and the backoff notice when active ("TIDAL asked Vespertine to wait 12 min (rate limit)").
- Styling follows the existing settings tabs (same `Form`, sections and footnote style as `OnlineSettings`).

## Login sheet (`TidalLoginSheet`)

- A `WKWebView` in a sheet, 480×640, loads `TidalAuth.loginURL()`.
- It uses `WKNavigationDelegate.decidePolicyFor`: a navigation whose URL starts with the redirect URI is cancelled and passed to `finishLogin(redirect:)`, and the sheet closes.
- Errors show inline, with "Try Again".
- It uses a non-persistent data store, so no TIDAL web cookies are kept.

## Library views

- **Source column** in the songs table (`TrackViews.swift`), placed after Format and hidden by default when the library has no TIDAL source:
  - a small icon: local disk `internaldrive`, share `server.rack`, TIDAL a "T" glyph in a rounded square in `Palette.text3`, downloaded TIDAL the "T" glyph plus a check;
  - the tooltip names the source ("TIDAL · streaming", "TIDAL · downloaded", "Local", "Share name").
  - It is sortable.
- **Graying:** a row plays now if it is local and its source is online, or it is TIDAL and either (downloaded and the file exists) or (the source is online and `streamable`).
  - A row that can't play uses the same dimming the app already uses for offline share sources, `Palette.text3` text.
  - Double-click and Play are disabled for it. Its tooltip gives the reason: "Offline", "Sign in to TIDAL", "Not available in your country", "TIDAL asked us to wait".
  - The same rule applies in the album grid, artist pages, queue and playlists.
- **Format column:** shows the real probed format when known. Otherwise it shows TIDAL's listed quality in the same style, with a trailing "≈" and the tooltip "Listed by TIDAL; confirmed when played".
- **Album copies:** an album present locally and on TIDAL appears as two copies of one album through the existing `AlbumCopies` grouping. The TIDAL copy's copy label is "TIDAL". The preferred-copy choice works unchanged. Tracks match by ISRC first, then by title and duration within 2 s.
- **Context menu on TIDAL rows/albums/playlists:** "Download" / "Remove Download", "Show on TIDAL" (opens `https://tidal.com/browse/track/<id>`), "Refresh from TIDAL". Writing favorites and playlists is sub-project 3; until then the heart is read-only for TIDAL rows, with the tooltip "Favorite on TIDAL".

## Sidebar: a TIDAL section

It sits below Playlists and appears only when a TIDAL source exists:
- **Search:** a search field in the detail header. Results show as Tracks / Albums / Artists / Playlists in the existing album grid and songs table.
- **My Mixes:** `users/{id}/mixes` (if available; otherwise hidden).
- **New Releases:** for favorite artists, as TidalSwiftLib `Helpers.newReleases` does. Up to 20 artists, through the gate at `.interactive`.
- **Downloads:** the download queue with progress, pause reason, failures and "Show in Finder".

Catalog items that aren't in the library play directly (transient `PlayableItem`, no DB row) and offer "Add to Library", which adds the track or album as rows. It does not mark them as TIDAL favorites until sub-project 3; it is a local add with `unavailableReason` unset, and sync keeps rows that were added locally. A `tidalTrack.origin` column (`favorite` / `added`) records how each row arrived.

## Inspector

- **Now Playing:** the existing panel. The signal path's source row reads "TIDAL · FLAC 24/192 (DASH)" or "TIDAL · FLAC 16/44.1". The streaming/buffering indicator is the existing one.
- **Details** (`TagEditorView`): for TIDAL rows, tag editing is read-only (TIDAL metadata), plus a "TIDAL" group:
  - track and album IDs (copyable)
  - listed quality and its tags (Hi-Res Lossless, Dolby Atmos…), and the delivered format with "listed vs delivered"
  - ISRC, UPC, copyright, release date, explicit, popularity
  - ReplayGain from TIDAL
  - credits (fetched on open: producers, composers, engineers…)
  - lyrics (fetched on open, scrollable)
  - "Download" / "Downloaded at <path>"

  Downloaded rows show the file's tags as normal and stay editable. Edits are written to the file, not to TIDAL.
- **Analysis:** works on what was played or downloaded. The existing `AnalysisQueue` gets TIDAL rows only when downloaded, or from the transient file while it is fully staged: when a streamed TIDAL track's cache entry `isComplete`, its file is analyzed before the lease is released. The result is stored by `filePath = "tidal://track/<id>"`, so the fake hi-res detection works for streamed tracks without keeping audio.
- **EQ and everything else:** nothing TIDAL-specific. The audio is in Vespertine's chain.

## Testing

- `TidalModel` state machine with fakes: signed out → signing in → signed in; missing credentials; reachability → source online.
- Playability rule: a table-driven unit test over every combination.
- Album-copy matching by ISRC and by title/duration.
- The analysis hook: when a staged entry is complete, analysis runs and stores under the tidal location; the file is deleted after release.
- UI: build the app (`xcodebuild … build`), plus SwiftUI previews or snapshot images of the Settings tab, a songs table with mixed sources (one grayed), and the inspector TIDAL group, compared visually with neighbouring views. No pixel tests.

## UX review amendments (2026-11-13)

These override the sections above where they conflict.

1. **Turning on is one flow.** Switching on "TIDAL integration" opens Settings › TIDAL and, if signed out, the login sheet. Turning it off asks nothing, because all data stays.
2. **Credentials: one step, not four fields.** "Import Client File…" reads a `tidal-client.json`. Alternatively, one multi-line field takes the pasted JSON. The four separate fields appear only under "Show Details". Values are validated as non-empty, and the errors name the missing key.
3. **One banner instead of a thousand tooltips.** When the TIDAL source is offline (no network, signed out or backing off), lists containing TIDAL rows show one slim banner at the top: "TIDAL is offline. Downloaded tracks still play." It ends with the reason and an action ("Sign In…", "Retry"). Per-row tooltips stay for the per-track reasons (region, removed).
4. **Search uses the existing search field.** On TIDAL › Search, the main window's search field searches TIDAL (placeholder "Search TIDAL"). The detail header gets no second field.
5. **Hide, don't disable, the heart on TIDAL rows** until two-way sync (sub-project 3) ships. The two are built together here, so this only applies if they ship separately.
6. **Download progress is visible from anywhere.** The sidebar's Downloads row shows a progress ring and the remaining count while the queue runs. A paused queue (backoff) shows a clock and its reason in the tooltip.
7. **Quality picker labels:** "Hi-Res Lossless (up to 24/192)", "Lossless (16/44.1)", "High (AAC 320)", "Low (AAC 96)". There is no "Max".
8. **Wording:** "TIDAL" in caps everywhere, and "Download" / "Remove Download" (not "Keep Offline", which already means something else for shares).
