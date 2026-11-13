# TIDAL Library and UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TIDAL music signs in, syncs, plays, downloads and shows its metadata inside Vespertine's existing views.

**Architecture:** An app-level `TidalModel` owns the `VespertineTidal` services and exposes observable state. Existing views gain a Source column, a single playability rule, a Settings tab, a login sheet, a sidebar section and an inspector group. Pure logic (playability, copy matching) lives in `VespertineLibrary` and is unit-tested.

**Tech Stack:** SwiftUI (macOS 14), Observation, WebKit (`WKWebView`), Network (`NWPathMonitor`), GRDB, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-13-tidal-library-ui-design.md`. It depends on the completed `docs/superpowers/plans/2026-11-13-tidal-core.md`.

## Global Constraints

- The visual language is the existing app's: `Palette`, `Hairline`, the existing `Form`/section styles, `.help()` tooltips, `String(localized:comment:)` for every user string.
- File headers: `// Vespertine: <what>.` + `// SPDX-License-Identifier: GPL-3.0-or-later`.
- Settings › TIDAL tab order: … Online, **TIDAL**, Remote … (symbol `music.note.house`; label "TIDAL").
- Quality picker values → `audioquality`: "Hi-Res Lossless" → `HI_RES_LOSSLESS` (default), "Lossless (16/44.1)" → `LOSSLESS`, "High (AAC 320)" → `HIGH`, "Low (AAC 96)" → `LOW`.
- Downloads folder default `~/Music/Vespertine/TIDAL`; "Add downloads folder to the library" is on by default.
- Sync at launch, every 6 h, and on demand.
- Playability reasons (exact copy): "Offline", "Sign in to TIDAL", "Not available in your country", "TIDAL asked us to wait".
- The login sheet is 480×640 with a non-persistent `WKWebsiteDataStore`.
- The app build command: `scripts/generate-project.sh && xcodebuild -project Vespertine.xcodeproj -scheme Vespertine -configuration Debug -derivedDataPath build/DD -onlyUsePackageVersionsFromResolvedFile build`.

## Review Focus

1. **App launch with no credentials file and no network.** No crash. The TIDAL section is hidden, and local playback is unchanged → test in Task 1.
2. **A queue mixing local, TIDAL-streaming and TIDAL-downloaded tracks.** Each item has the right URL and cacheKey; a downloaded file that was deleted falls back to streaming → test in Task 2.
3. **Losing the network while the songs table is open.** Rows gray out without reloading the whole library, and are re-enabled when the network returns → test in Task 3 (rule) + Task 1 (reachability → `setSourceOnline`).
4. **An album with the same ISRCs locally and on TIDAL but a different track count.** It is still grouped as copies, without crashing on unmatched tracks → test in Task 4.
5. **The login redirect arriving with an error query (`?error=access_denied`).** The sheet shows the error and stays open, and the state returns to signed out → test in Task 5 (delegate logic extracted to a testable function).

---

### Task 1: `TidalModel`

**Files:** Create `App/Sources/Models/TidalModel.swift`. Modify `App/Sources/Models/AppModel.swift` (own `tidal: TidalModel`, created at startup) and `App/Sources/Models/AppSettings.swift` (`tidalQuality`, `tidalDownloadsFolder`, `tidalAddDownloadsToLibrary`). Test `App/Tests/TidalModelTests.swift`. If the app has no test target, put the state machine in `Packages/VespertineKit/Sources/VespertineTidal/TidalSessionState.swift` and test it there.

**Interfaces:**
- Produces: `@MainActor @Observable final class TidalModel { enum State: Equatable { case missingCredentials, signedOut, signingIn, signedIn(name: String) }; var state; var isReachable: Bool; var backoff: (Date, String)?; var lastSync: Date?; func start(); func beginLogin() -> URL; func finishLogin(_ url: URL) async; func signOut(); func refresh() async; func saveCredentials(_:) }`.
- It sets the TIDAL source online state through `LibraryDatabase.setSourceOnline` whenever `state`, `isReachable` or `backoff` change.

- [ ] Tests:
  - no file → `.missingCredentials`;
  - credentials with no tokens → `.signedOut`;
  - stored tokens → `.signedIn`, and `start` triggers one refresh;
  - reachability false → the source goes offline;
  - an abuse backoff → offline;
  - `signOut` → `.signedOut`, and the rows remain.
- [ ] Implement. [ ] Run. [ ] Commit `Add TidalModel`.

### Task 2: Playable items for TIDAL rows and the probed-format hook

**Files:** Modify `App/Sources/Models/PlayerController.swift` (`makeItem`, line ~450) and the place where the controller receives the engine's `SourceFormat`/signal path for the current item. Test: extend an existing PlayerController test, or add `TidalItemTests`.

**Interfaces:**
- Consumes: `TidalPlayback.url(trackId:)`, `cacheKey(trackId:)`; `LibraryDatabase.tidalRecord(trackId:)`, `recordProbedFormat`.
- A TIDAL row whose existing `downloadPath` file is present → `url = file URL`, `cacheKey = nil`. Otherwise → `tidal://` URL plus cacheKey.

- [ ] Tests:
  - local row unchanged;
  - streaming TIDAL row → the scheme and key;
  - downloaded with the file present → the file URL;
  - downloaded but the file missing → streaming;
  - when the format arrives → `recordProbedFormat` is called once per track.
- [ ] Implement. [ ] Run. [ ] Commit `Play TIDAL rows through the engine`.

### Task 3: Playability rule and Source column

**Files:** Create `Packages/VespertineKit/Sources/VespertineLibrary/Playability.swift`. Modify `App/Sources/Views/TrackViews.swift` (column after Format, line ~142; dimming), `AlbumsViews.swift`, `QueueViews.swift`. Test `Tests/VespertineLibraryTests/PlayabilityTests.swift`.

**Interfaces:** `public enum Playability: Equatable { case playable, unavailable(reason: String) }` and `public static func playability(track: Track, source: LibrarySource?, tidal: TidalTrackRecord?, signedIn: Bool, reachable: Bool, backingOff: Bool, fileExists: (String) -> Bool) -> Playability`.

- [ ] A table-driven test over local/share/TIDAL × online/offline × signed in/out × downloaded (present or missing) × streamable/not, with the exact reason strings from the Global Constraints.
- [ ] Implement the rule. Add the column (icons per spec decision 202, `.help` tooltip, sortable by source kind) and the dimming and disabled play, reusing the existing offline-source dimming code path. Make the Format column show `≈` for unprobed TIDAL rows.
- [ ] Build the app. [ ] Commit `Add Source column and one playability rule`.

### Task 4: Album copies across local and TIDAL

**Files:** Modify `Packages/VespertineKit/Sources/VespertineLibrary/AlbumCopies.swift` (copy grouping and label). Test `Tests/VespertineLibraryTests/AlbumCopiesTidalTests.swift`.

- [ ] Tests:
  - the same album key, local and TIDAL → one album with 2 copies, the TIDAL copy labelled "TIDAL";
  - track matching by ISRC, then by title with |Δduration| ≤ 2 s;
  - a different track count still groups;
  - the preferred-copy choice persists.
- [ ] Implement. [ ] Run `swift test --filter AlbumCopies`. [ ] Commit `Group local and TIDAL copies of an album`.

### Task 5: Settings › TIDAL and the login sheet

**Files:** Create `App/Sources/Views/TidalSettingsView.swift`, `App/Sources/Views/TidalLoginSheet.swift`. Modify `App/Sources/Views/CompactViews.swift` (`SettingsTab`, `TabView` at line ~178). Test: the redirect handling as a pure function `TidalLoginRedirect.classify(_ url: URL, redirectURI: String) -> .ignore | .code(URL) | .error(String)` in `VespertineTidal`, with unit tests.

- [ ] Tests for `classify`: another host → `.ignore`; redirect with `code` → `.code`; redirect with `error=access_denied` → `.error("access_denied")`.
- [ ] Implement the tab per spec (account, credentials, quality, downloads, status, backoff notice) and the sheet (`WKNavigationDelegate` → `classify`).
- [ ] Build the app, then launch with `-VespertineDataDirectory /tmp/vespertine-test` and screenshot the tab (`screencapture -l <windowid>`, or the run skill). Compare it with the Online tab.
- [ ] Commit `Add TIDAL settings and sign-in`.

### Task 6: Sidebar TIDAL section (Search, Mixes, New Releases, Downloads)

**Files:** Modify `App/Sources/Views/SidebarView.swift`, `App/Sources/Models/AppModel.swift` (`SidebarItem` cases `.tidalSearch`, `.tidalMixes`, `.tidalNewReleases`, `.tidalDownloads`). Create `App/Sources/Views/TidalBrowseViews.swift`. Modify `App/Sources/Views/MainWindow.swift` (detail routing).

- [ ] Search results reuse the album grid and songs table components with transient tracks (no DB row): "Add to Library" (`origin = added`) and Play. Downloads shows `TidalDownloader.items`.
- [ ] Add `tidalTrack.origin` (`favorite`/`added`) in a migration `v25-tidal-origin`. Sync's removal skips `added`. Test this in `TidalLibraryTests`.
- [ ] Build the app and screenshot. [ ] Commit `Add the TIDAL sidebar section`.

### Task 7: Inspector TIDAL details, context menus, the analysis hook

**Files:** Modify `App/Sources/Views/TagEditorView.swift` (read-only plus a TIDAL group for TIDAL rows), the context menus in `TrackViews.swift` and `AlbumsViews.swift`, and `App/Sources/Models/AnalysisQueue.swift` (analyze a complete staged TIDAL entry before release). Signal path source row in `Packages/VespertineKit/Sources/VespertineAudio/SignalPath.swift`: when the item URL scheme is `tidal`, the source reads "TIDAL · <format>". Test: the analysis-hook unit test with a fake complete entry (stores under `tidal://track/<id>`), plus the signal-path label test.

- [ ] Tests. [ ] Implement (credits and lyrics fetched on open, through `TidalCatalog` at `.interactive`). [ ] Build the app and screenshot the inspector. [ ] Commit `Show TIDAL details in the inspector`.

## Verification

- `cd Packages/VespertineKit && swift test` passes. The app builds.
- Manual (needs the owner's credentials): sign in, sync, play hi-res, gray out offline, download an album, analysis shows for a streamed track.
