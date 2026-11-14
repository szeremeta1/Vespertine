# TIDAL Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TIDAL tracks resolve, stream and play through Vespertine's own engine (BTS FLAC and hi-res DASH FLAC), live in the library database, and can be downloaded on request.

**Architecture:** A new `VespertineTidal` target ports python-tidal's auth, request gate and stream resolution, and adds a fragmented-MP4-to-FLAC remuxer. Its readers implement `PlaybackCacheReader`, so the existing `NetworkPlaybackCache` stages TIDAL streams exactly as it stages share files. Library data goes through a `v23-tidal` migration.

**Tech Stack:** Swift 6.2 (language mode 6), Swift Testing (`import Testing`), GRDB 7, Foundation `URLSession`, SFBAudioEngine (for decode checks in tests), macOS 14+.

**Spec:** `docs/superpowers/specs/2026-11-13-tidal-core-design.md`. Decisions: `docs/superpowers/DECISIONS.md`.

## Global Constraints

- License header on every new file: `// SPDX-License-Identifier: GPL-3.0-or-later`, in the house style (`// Vespertine: <what>.` on line 1).
- No TIDAL client ID, secret, token or real user ID in the repo, including tests and fixtures. Fixtures use fabricated IDs.
- Credentials file: `~/Library/Application Support/Vespertine/tidal-client.json` with keys `clientId`, `clientSecret`, `pkceClientId`, `pkceClientSecret`.
- Keychain service: `org.szeremeta.vespertine.tidal`.
- PKCE redirect URI: `https://tidal.com/android/login/auth`. Authorize URL: `https://login.tidal.com/authorize`. Token URL: `https://auth.tidal.com/v1/oauth2/token`. API base: `https://api.tidal.com/v1/`. Scope: `r_usr+w_usr+w_sub`.
- Backoff: 429 → `Retry-After` or 60 s; 403 whose body contains "abuse" or "suspend" (case-insensitive) → `Retry-After` or 1800 s; never shortened; requests made during a backoff are refused without being sent.
- Token refresh 60 s before expiry; one refresh in flight.
- Default `audioquality` = `HI_RES_LOSSLESS`.
- Downloads: one track at a time; random pause 1–3 s between tracks; `.partial` then rename; path `<folder>/<Album Artist>/<Album>/<disc>-<track> <Title>.flac`, with the track number zero-padded to 2 digits; default folder `~/Music/Vespertine/TIDAL`.
- No audio bytes persist outside the transient playback cache unless downloaded.
- `VespertineAudio` must not import `VespertineTidal`.
- Tests never touch the network. They use `HTTPTransport` fakes or the local `FakeHTTPServer`.

## Review Focus

1. **A DASH track whose `moof` is larger than 4 KiB** or whose `trun` sizes don't add up to the `mdat` payload. The index must fetch more bytes, or fail with `TidalError.malformedStream`, never play garbage → test in Task 6/8.
2. **A stream URL expiring halfway through a long hi-res track.** The reader must re-resolve and continue at the same offset, with the same bytes → test in Task 8.
3. **Many TIDAL tracks queued while a backoff starts.** Prefetch and the next track must not keep sending requests; each gets `backingOff` → test in Task 3 (gate) and Task 9.
4. **Signed-out or credentials file missing at launch.** No crash. TIDAL rows show signed-out, and local playback is unaffected → test in Task 2 and Task 10.
5. **A downloaded file also inside a scanned library folder.** It is linked, not duplicated, and re-scanning is idempotent → test in Task 11.

## Parallel tracks

- **Track A** (target `VespertineTidal`, pure): Tasks 1–6.
- **Track B** (`VespertineAudio` + `VespertineLibrary`): Tasks 7, 10, 11. Independent of A.
- **Track D** (after A and B merge): Tasks 8, 9, 12, 13.

App UI wiring is sub-project 2's plan.

---

### Task 1: `VespertineTidal` target, config and errors

**Files:**
- Modify: `Packages/VespertineKit/Package.swift`: add the library product and target `VespertineTidal` (deps `VespertineAudio`, `VespertineLibrary`) and the test target `VespertineTidalTests` (deps `VespertineTidal`, `VespertineAudio`, `SFBAudioEngine`; resources `.copy("Fixtures")`).
- Create: `Sources/VespertineTidal/TidalConfig.swift`, `Sources/VespertineTidal/TidalError.swift`, `Sources/VespertineTidal/HTTPTransport.swift`
- Test: `Tests/VespertineTidalTests/TidalConfigTests.swift`

**Interfaces (produces):**
- `public struct TidalClientCredentials: Codable, Sendable, Equatable { clientId, clientSecret, pkceClientId, pkceClientSecret: String }`
- `public enum TidalConfig { static func credentialsURL(base: URL = applicationSupport) -> URL; static func loadCredentials(at: URL) throws -> TidalClientCredentials?` (nil when the file is missing); `static func saveCredentials(_:to:) throws` (writes with 0600 permissions)`}`
- `public enum TidalError: Error, Equatable { case notSignedIn, missingCredentials, backingOff(remaining: TimeInterval, reason: String), abuse(retryAfter: TimeInterval), http(status: Int, body: String), encrypted, malformedStream(String), notStreamable(String), unavailable }`
- `public protocol HTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }` and `public struct URLSessionTransport: HTTPTransport`

- [ ] Step 1: Tests: `loadCredentials` returns nil for a missing file; save → load round-trips; the saved file has POSIX permissions 0600.
- [ ] Step 2: `swift test --filter TidalConfigTests` → FAIL (target missing).
- [ ] Step 3: Implement.
- [ ] Step 4: `swift test --filter TidalConfigTests` → PASS.
- [ ] Step 5: Commit `Add VespertineTidal target with credentials config`.

### Task 2: `TidalAuth` (PKCE, tokens, refresh)

**Files:** Create `Sources/VespertineTidal/TidalAuth.swift`, `Sources/VespertineTidal/TokenStore.swift`. Test `Tests/VespertineTidalTests/TidalAuthTests.swift`.

**Interfaces:**
- Consumes: `TidalClientCredentials`, `HTTPTransport`, `TidalError`.
- Produces:
  - `public struct TidalTokens: Codable, Sendable { accessToken, refreshToken: String; expiresAt: Date; userId: Int; countryCode: String }`
  - `public protocol TokenStore: Sendable { func load() -> TidalTokens?; func save(_: TidalTokens) throws; func clear() }`, with `KeychainTokenStore` (service `org.szeremeta.vespertine.tidal`) and `MemoryTokenStore` (for tests).
  - `public actor TidalAuth { init(credentials:transport:store:clock: @Sendable () -> Date = Date.init); func loginURL() -> URL; func finishLogin(redirect: URL) async throws; func validAccessToken() async throws -> String; func forceRefresh() async throws; func signOut(); var isSignedIn: Bool; var session: TidalTokens? }`
- Login URL parameters (python-tidal `pkce_login_url`): `response_type=code`, `redirect_uri`, `client_id=pkceClientId`, `lang=EN`, `appMode=android`, `client_unique_key` (random 64-bit hex), `code_challenge` = base64url(SHA256(verifier)) without padding, `code_challenge_method=S256`, `restrict_signup=true`. The verifier is base64url of 32 random bytes, without padding.
- Token POST form fields: `code`, `client_id`, `grant_type=authorization_code`, `redirect_uri`, `scope=r_usr+w_usr+w_sub`, `code_verifier`, `client_unique_key`. Refresh: `grant_type=refresh_token`, `refresh_token`, `client_id=pkceClientId`, `client_secret=pkceClientSecret`, `scope`. The response's `user.userId` and `user.countryCode` (or `user_id`) fill the tokens. A refresh response without `refresh_token` keeps the old one.

- [ ] Step 1: Tests (fake transport):
  - `loginURL` has every parameter above, and the challenge equals SHA256 of the verifier;
  - `finishLogin` with `https://tidal.com/android/login/auth?code=abc` posts exactly the listed fields and stores tokens;
  - a redirect without `code` throws `.notSignedIn`;
  - `validAccessToken` 30 s before expiry triggers one refresh;
  - 10 concurrent `validAccessToken` calls near expiry produce exactly 1 refresh request;
  - a missing refresh token in the response keeps the old one;
  - `signOut` clears the store;
  - with an empty store, `validAccessToken` throws `.notSignedIn`.
- [ ] Step 2: Run → FAIL. Step 3: Implement. Step 4: Run → PASS. Step 5: Commit `Add TIDAL PKCE auth`.

### Task 3: `TidalGate` (requests, backoff, priority)

**Files:** Create `Sources/VespertineTidal/TidalGate.swift`. Test `Tests/VespertineTidalTests/TidalGateTests.swift`.

**Interfaces:**
- Consumes: `TidalAuth.validAccessToken()`, `forceRefresh()`, `session.countryCode`; `HTTPTransport`.
- Produces: `public enum TidalPriority: Int, Comparable { case playback = 0, interactive = 1, sync = 2, download = 3 }`; `public actor TidalGate { init(auth:transport:clock:sleep:); func get(_ path: String, query: [String: String] = [:], priority: TidalPriority) async throws -> Data; func send(method: String, path: String, form: [String: String], priority: TidalPriority, ifMatch: String? = nil) async throws -> (Data, HTTPURLResponse); func get<T: Decodable>(_:query:priority:as: T.Type) async throws -> T; var backoff: (until: Date, reason: String)? }`
- Every request: base `https://api.tidal.com/v1/`, `countryCode` added to the query, `Authorization: Bearer`, the User-Agent `Mozilla/5.0 (Linux; Android 12; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/91.0.4472.114 Safari/537.36`, header `x-tidal-client-version: 2025.7.16`.
- Priority: at most 4 requests in flight. Waiting requests are released lowest-priority-value first, in FIFO order within a level.

- [ ] Step 1: Tests:
  - 429 with `Retry-After: 12` → `backoff.until` = now + 12 and the call throws `.backingOff`;
  - 429 without the header → 60 s;
  - 403 with body `{"userMessage":"abuse detected"}` → 1800 s, error `.abuse`;
  - a call during a backoff throws `.backingOff` and the fake transport receives 0 requests;
  - a shorter `Retry-After` arriving during a longer backoff doesn't shorten it;
  - 401 → one `forceRefresh` and one retry; a second 401 → `.http(401)`;
  - with 4 requests blocking, a queued `.download` and a later `.playback` → `.playback` is sent first;
  - every request carries `countryCode`, the bearer token, the User-Agent and the client version.
- [ ] Steps 2–5 as in Task 1. Commit `Add TIDAL request gate with backoff`.

### Task 4: `TidalCatalog` (read models)

**Files:** Create `Sources/VespertineTidal/Catalog/TidalModels.swift`, `Sources/VespertineTidal/Catalog/TidalCatalog.swift`. Fixtures `Tests/VespertineTidalTests/Fixtures/catalog/*.json` (fabricated, in v1 response shapes; field names taken from TidalSwiftLib `Codables/*`). Test `Tests/VespertineTidalTests/TidalCatalogTests.swift`.

**Interfaces (produces):**
- `public struct TidalTrack: Codable, Sendable, Hashable, Identifiable { id: Int; title: String; version: String?; duration: Int; trackNumber: Int; volumeNumber: Int; isrc: String?; explicit: Bool; audioQuality: String; mediaMetadata: Tags?` (`Tags { tags: [String] }`)`; replayGain: Double?; peak: Double?; copyright: String?; popularity: Int?; streamReady: Bool?; allowStreaming: Bool?; artists: [TidalArtistRef]; album: TidalAlbumRef }`
- `TidalAlbum` adds `numberOfTracks`, `numberOfVolumes`, `releaseDate`, `cover`, `upc`, `artist(s)`. Also `TidalArtist`, `TidalPlaylist` (`uuid`, `title`, `numberOfTracks`, `lastUpdated`, `description`, `squareImage`) and `TidalPage<T> { limit, offset, totalNumberOfItems, items }`.
- `public struct TidalCatalog: Sendable { init(gate:); func track(_ id: Int) async throws -> TidalTrack; func album(_:) / albumTracks(_:) / artist(_:) / playlist(_ uuid:) / playlistTracks(_:)`; `func favoriteTracks(userId:) / favoriteAlbums(userId:) / favoriteArtists(userId:) / userPlaylists(userId:)` (each pages with `limit=100` until done; returns arrays); `func search(_ query: String, limit: Int = 50) async throws -> TidalSearchResult`; `func lyrics(_ trackId:) async throws -> String?`; `func credits(_ trackId:) async throws -> [TidalCredit] }`
- `public static func coverURL(_ uuid: String, size: Int) -> URL` → `https://resources.tidal.com/images/<uuid with "-" replaced by "/">/<size>x<size>.jpg`
- Favorites endpoints: `users/{id}/favorites/tracks|albums|artists`, items wrapped as `{created, item}`. Playlists: `users/{id}/playlists`. Album tracks: `albums/{id}/tracks`. Playlist items: `playlists/{uuid}/items` (keep `type == "track"` only).

- [ ] Step 1: Tests: decode each fixture; paging a 230-item favorites fixture issues offsets 0, 100, 200 at `.sync` priority; playlist items skip videos; `coverURL("ab-cd", 320)` == `https://resources.tidal.com/images/ab/cd/320x320.jpg`.
- [ ] Steps 2–5. Commit `Add TIDAL catalog reads`.

### Task 5: `TidalStreamResolver`

**Files:** Create `Sources/VespertineTidal/Stream/TidalStreamResolver.swift`, `Sources/VespertineTidal/Stream/MPDParser.swift`. Fixtures `Fixtures/playbackinfo/bts-flac.json`, `dash-hires.json`, `bts-encrypted.json`, `dash-aac.json`. Test `TidalStreamResolverTests.swift`.

**Interfaces (produces):**
- `public struct TidalStream: Sendable, Equatable { enum Kind: Sendable, Equatable { case file(URL); case dash(initialization: URL, segments: [URL]) }; kind: Kind; codec: String; sampleRate: Int?; bitDepth: Int?; audioQuality: String; audioMode: String; fileExtension: String }` (`flac` for FLAC codecs, `m4a` otherwise)
- `public struct TidalStreamResolver: Sendable { init(gate:quality: String = "HI_RES_LOSSLESS"); func resolve(trackId: Int, priority: TidalPriority = .playback) async throws -> TidalStream }`
- Request: `tracks/{id}/playbackinfopostpaywall` with `playbackmode=STREAM`, `assetpresentation=FULL`, `audioquality`.
- MPD (XML via `XMLParser`): the first `Representation` of the first `AdaptationSet` gives `codecs`, `audioSamplingRate`, and `SegmentTemplate@initialization`, `@media`, `@startNumber` (default 1). Segment count = Σ over `S` of (`r` + 1) (`r` defaults to 0). Segment URLs = `media` with `$Number$` replaced, for numbers `startNumber ..< startNumber + count`. **Note:** python-tidal's `1 + 1 + Σ(r or 1)` over-counts. Use the DASH-correct count and verify it on the fixture.
- `encryptionType` other than `NONE`, or an MPD containing `ContentProtection`, → `.encrypted`. HTTP 401/404 with `subStatus` 4005 or "not ready" → `.notStreamable(message)`.

- [ ] Step 1: Tests:
  - the BTS fixture → `.file` with the URL, codec `flac`, extension `flac`;
  - the DASH fixture (`<S d="176400" r="49"/><S d="88200"/>`, startNumber 1) → 51 segment URLs ending `/51.mp4`, sampleRate 192000;
  - encrypted → throws `.encrypted`;
  - DASH AAC → extension `m4a`;
  - the request carries the three parameters with the default quality `HI_RES_LOSSLESS`.
- [ ] Steps 2–5. Commit `Add TIDAL stream resolver (BTS and DASH)`.

### Task 6: fMP4 parsing and `DASHFLACLayout`

**Files:** Create `Sources/VespertineTidal/Stream/MP4Boxes.swift`, `Sources/VespertineTidal/Stream/DASHFLACLayout.swift`. Fixture generator `docs/fixtures/make-tidal-dash-fixture.sh` (uses `/opt/homebrew/bin/ffmpeg`: a 3 s 96 kHz/24-bit synthesized FLAC → `ffmpeg -i in.flac -c:a copy -f dash -seg_duration 1 -single_file 0 out.mpd`). Its output goes in `Tests/VespertineTidalTests/Fixtures/dash/` (`init.mp4`, `chunk-*.m4s`, `source.flac`). Test `DASHFLACLayoutTests.swift`.

**Interfaces (produces):**
- `enum MP4Box { static func boxes(in: Data) -> [(type: String, range: Range<Int>, header: Int)] }` (handles 64-bit `largesize`).
- `public struct DASHFLACLayout: Sendable { static func flacHeader(fromInit: Data) throws -> Data` (`fLaC` + the `dfLa` metadata blocks, with the last-block bit set only on the final block); `static func mediaPayload(segmentPrefix: Data) throws -> SegmentInfo?` (nil = need more bytes); `struct SegmentInfo { payloadOffset: Int; payloadLength: Int; sampleSizesTotal: Int? }` }`
- Location of `dfLa`: `moov/trak/mdia/minf/stbl/stsd/fLaC` (the sample entry has 28 bytes of audio-sample-entry fields before its child boxes).
- `payloadOffset` = start of the `mdat` payload within the segment; the `trun` sample sizes must sum to `payloadLength` when present, else `malformedStream`.

- [ ] Step 1: Tests:
  - header from the fixture's `init.mp4` starts `fLaC` and has STREAMINFO with sample rate 96000 and 24 bits;
  - `fLaC header + concatenated payloads of all chunks`, decoded with SFBAudioEngine, equals `source.flac`'s decoded PCM sample for sample;
  - a prefix of 100 bytes → nil (needs more);
  - a corrupted `trun` sum → `malformedStream`;
  - a box with `largesize` parses.
- [ ] Steps 2–5. Commit `Add fMP4 FLAC layout for TIDAL DASH`.

### Task 7: Remote reader registry in `NetworkPlaybackCache`

**Files:** Modify `Sources/VespertineAudio/NetworkPlaybackCache.swift` (`entry(key:url:reader:foreground:cancelled:)` at line ~203, `reopener` at line ~242, the cache file extension at line ~219). Test `Tests/VespertineAudioTests/RemoteReaderRegistryTests.swift`.

**Interfaces (produces):**
- `public protocol RemoteCacheReader: PlaybackCacheReader { var fileExtension: String { get } }`. Make `PlaybackCacheReader` `public`, with the members needed: `size`, `read(at:count:)`, `changedSinceOpen`.
- `NetworkPlaybackCache.registerRemoteReader(scheme: String, _ open: @escaping @Sendable (URL) throws -> any RemoteCacheReader)` (static, lock-protected).
- `entry(...)` consults the registry for `url.scheme` before `readerFactory` and `openShare`. The reopen closure uses the same opener. The cache file's extension is `reader.fileExtension` when the reader is remote.
- `PlaybackEngine` needs no change: verify an item with `url = tidal://track/1` and `cacheKey = "tidal:1"` stages through the registry.

- [ ] Step 1: Tests:
  - a registered fake `tidal` reader over a FLAC fixture's bytes → the engine (simulated output, as in `NetworkPlaybackCacheTests`) plays it and renders the same PCM hash as the local file;
  - the cache file's extension is `flac`;
  - releasing the lease deletes the file;
  - an unregistered scheme throws (no crash).
- [ ] Steps 2–5 (`swift test --filter RemoteReaderRegistryTests`; then the full `swift test --filter NetworkPlaybackCache` → still PASS). Commit `Add remote reader registry to the playback cache`.

### Task 8: `TidalHTTPReader` and `DASHFLACReader`

**Files:** Create `Sources/VespertineTidal/Stream/TidalHTTPReader.swift`, `Sources/VespertineTidal/Stream/DASHFLACReader.swift`. Test support `Tests/VespertineTidalTests/FakeHTTPServer.swift` (an `NWListener` on 127.0.0.1 serving files with Range support, injectable stall, throttle, and expiry → 403). Test `TidalReadersTests.swift`.

**Interfaces:**
- Consumes: `RemoteCacheReader` (Task 7), `TidalStream` (Task 5), `DASHFLACLayout` (Task 6).
- Produces:
  - `final class TidalHTTPReader: RemoteCacheReader { init(stream: TidalStream, renew: @escaping @Sendable () throws -> TidalStream, session: URLSession = .shared) throws }`. `HEAD`/`Range: bytes=0-0` gives the size; `read(at:count:)` issues a blocking Range GET.
  - `final class DASHFLACReader: RemoteCacheReader { init(stream:renew:session:) throws }`. At init it fetches the init segment plus `bytes=0-4095` of each segment (8 concurrent; grows to 64 KiB if `mediaPayload` returns nil) and builds an offset table. `read` maps to the header or to segment ranges `payloadOffset + x` and may span segments.
- Retry: on 403/410 → `renew()` and retry the same range once per renewal. Other errors → waits of 2 s, 4 s, 6 s…, up to the cache's no-progress limit (the cache already enforces it; the reader just keeps retrying while not cancelled).
- `changedSinceOpen`: always false. Byte identity is guaranteed by the remux.

- [ ] Step 1: Tests (against `FakeHTTPServer`):
  - HTTP reader: the size matches; random reads match the file bytes;
  - expiry after 1 MiB → `renew` called once and the bytes still match;
  - DASH reader over the Task 6 fixture: `size` == header + Σ payloads; a full sequential read decodes equal to `source.flac`; a random read across a segment boundary matches;
  - a segment with a `moof` > 4 KiB is still indexed (fixture variant);
  - a stall → the read blocks, then returns once resumed.
- [ ] Steps 2–5. Commit `Add TIDAL HTTP and DASH readers`.

### Task 9: `TidalPlayback` registration

**Files:** Create `Sources/VespertineTidal/TidalPlayback.swift`. Test `TidalPlaybackTests.swift`.

**Interfaces:**
- Produces:
  - `public enum TidalPlayback { static func register(resolver: TidalStreamResolver)` (registers `tidal` with `NetworkPlaybackCache`: parse the id from `tidal://track/<id>`, `resolve` blocking via a semaphore at `.playback`, choose `TidalHTTPReader` for `.file` and `DASHFLACReader` for `.dash`, with renew = resolve again)`; static func url(trackId: Int) -> URL; static func cacheKey(trackId: Int) -> String` (`"tidal:<id>"`)` }`.
  - Atmos: if `audioMode == "DOLBY_ATMOS"` and the codec is `eac3`, use the `.file` reader with extension `m4a`. The existing probe hands E-AC-3 to the system renderer.
- Errors propagate from the opener as thrown errors, so the engine reports them with its existing failure path. The message comes from `TidalError.localizedDescription`; add `LocalizedError` conformance with the exact user copy from the spec's error table.

- [ ] Step 1: Tests:
  - registering with a fake gate and a BTS fixture whose URL points at `FakeHTTPServer` → `NetworkPlaybackCache.entry` for `tidal://track/7` yields the file bytes;
  - `.encrypted` → the entry throws, with the description "This track's stream is encrypted";
  - during a gate backoff, the entry throws `.backingOff` and the fake transport sees 0 requests.
- [ ] Steps 2–5. Commit `Register TIDAL streams with the playback cache`.

### Task 10: Library migration `v23-tidal`

**Files:** Modify `Sources/VespertineLibrary/LibraryDatabase.swift` (add the migration after `v22-matroska-audio`, line ~377). Create `Sources/VespertineLibrary/TidalRecords.swift`. Test `Tests/VespertineLibraryTests/TidalLibraryTests.swift`.

**Interfaces (produces):**
- Table `tidalTrack` (columns per the spec; `trackId` FK cascade, `tidalId` unique, `artistIds` JSON text, `mediaTags` JSON text) and `public struct TidalTrackRecord: Codable, FetchableRecord, PersistableRecord`.
- `public struct TidalTrackInput: Sendable { tidalId, title, artist, album, albumArtist, trackNumber, discNumber, trackTotal, discTotal, duration, isrc, releaseDate, year, copyright, explicit, popularity, listedQuality, mediaTags, replayGain (track/album gain/peak), albumId, artistIds, coverUUID, streamable, unavailableReason }`
- On `LibraryDatabase`:
  - `func tidalSource(userId: Int) throws -> LibrarySource` (creates or returns the `tidal://` row; `remoteURL = "tidal://user/<id>"`, `name = "TIDAL"`);
  - `func upsertTidalTracks(_: [TidalTrackInput], sourceId: Int64) throws -> [Int: Int64]` (tidalId → track id; location `tidal://track/<id>`; codec, rate and depth from `listedQuality` unless `formatIsProbed`: HI_RES_LOSSLESS → flac, 96000/24 placeholder; LOSSLESS → flac, 44100/16; HIGH/LOW → aac, 44100, nil; `artworkKey = "tidal:<coverUUID>"`);
  - `func removeTidalTracks(notIn keep: Set<Int>, sourceId: Int64) throws` (keeps downloaded rows, setting `unavailableReason = "notInFavorites"`);
  - `func recordProbedFormat(trackId: Int64, codec: String, sampleRate: Double, bitDepth: Int?, channels: Int) throws` (sets `formatIsProbed`);
  - `func setTidalDownload(tidalId: Int, path: String?) throws`;
  - `func tidalRecord(trackId: Int64) throws -> TidalTrackRecord?`.
- `Track` gains no stored properties.

- [ ] Step 1: Tests:
  - the migration runs on an in-memory DB with a v22 schema;
  - upserting twice gives the same ids and updated titles;
  - listed HI_RES_LOSSLESS → flac/96000/24, then `recordProbedFormat(192000, 24)` → a later upsert does not overwrite it;
  - `removeTidalTracks` deletes non-downloaded rows and keeps downloaded ones with the reason;
  - rows show in the existing albums query alongside local tracks;
  - deleting the source cascades.
- [ ] Steps 2–5. Commit `Add TIDAL library tables`.

### Task 11: Scanner links downloaded files

**Files:** Modify `Sources/VespertineLibrary/LibraryScanner.swift` (where a scanned file becomes a `Track` insert). Test in `TidalLibraryTests.swift`.

**Interfaces:**
- Consumes: `setTidalDownload` (Task 10).
- Behavior: a scanned file whose `extraTags["TIDAL_TRACK_ID"]` matches an existing `tidalTrack.tidalId` sets that row's `downloadPath` and `track.filePath`, and **is not inserted as a separate track**. Without a match, it's inserted normally. When a linked file disappears on rescan → `downloadPath = nil`.

- [ ] Step 1: Tests: scanning a folder with a tagged FLAC for an existing TIDAL row adds 0 tracks and sets `downloadPath`; rescanning is idempotent; deleting the file and rescanning clears it; an unmatched tag → a normal insert.
- [ ] Steps 2–5. Commit `Link downloaded TIDAL files instead of duplicating them`.

### Task 12: `TidalLibrarySync` (pull)

**Files:** Create `Sources/VespertineTidal/TidalLibrarySync.swift`. Test `TidalLibrarySyncTests.swift`.

**Interfaces:**
- Consumes: `TidalCatalog` favorites and playlists (Task 4); `LibraryDatabase` TIDAL API (Task 10); `Playlist`/`PlaylistItem`.
- Produces: `public actor TidalLibrarySync { init(catalog:database:userId:); func refresh() async throws -> Summary }` with `Summary { added, updated, removed, playlists: Int }`.
  - Favorite tracks, plus all tracks of favorite albums, become rows.
  - Each user playlist becomes a Vespertine `Playlist` with its items in TIDAL order, matched by a stored mapping (a `tidalPlaylist` table: `uuid` unique, `playlistId` FK, `lastUpdated`; part of this task's migration `v24-tidal-playlists`). It is refetched only when `lastUpdated` changed.
  - `removeTidalTracks(notIn:)` runs with the union of ids still present.

- [ ] Step 1: Tests (fake catalog): the first refresh creates N rows and P playlists; an unchanged `lastUpdated` → no playlist item fetch; a track dropped from favorites is removed; a downloaded one is kept.
- [ ] Steps 2–5. Commit `Pull TIDAL favorites and playlists into the library`.

### Task 13: `TidalDownloader`

**Files:** Create `Sources/VespertineTidal/TidalDownloader.swift`. Test `TidalDownloaderTests.swift`.

**Interfaces:**
- Consumes: `TidalStreamResolver`, `TidalHTTPReader`/`DASHFLACReader` (read sequentially), `TagWriter` from `VespertineLibrary` (check its API for FLAC tags, pictures and custom keys), `LibraryDatabase.setTidalDownload`.
- Produces: `@MainActor @Observable public final class TidalDownloader { init(resolver:catalog:database:folder: URL, sleep:random:); func enqueue(tracks: [TidalTrack]); func enqueue(album: Int) async; func enqueue(playlist: String) async; var items: [Item]` (`state: queued / downloading(Double) / done(URL) / failed(String) / paused(reason)`)`; func cancel(_ id: Int) }`
- The sequence and paths follow the Global Constraints; tags per the spec, including `TIDAL_TRACK_ID`; `.download` priority; a backoff → `paused` with the reason, resuming automatically when it ends.

- [ ] Step 1: Tests:
  - two tracks are never downloading at the same time (the fake records overlap);
  - a sleep of 1–3 s is injected between tracks (the fake sleep records durations in [1, 3]);
  - the final path is `<folder>/Artist/Album/1-01 Title.flac`;
  - a `.partial` exists while the download is in progress and none after it completes;
  - the tags read back include `TIDAL_TRACK_ID`;
  - a failure on track 2 of 3 still downloads track 3;
  - a backoff → `paused("…")`.
- [ ] Steps 2–5. Commit `Add explicit TIDAL downloads`.

---

## Verification (end of plan)

- `cd Packages/VespertineKit && swift test` → all suites pass, including the existing golden PCM tests unchanged.
- `swift build -c release` passes.
- `grep -rn -iE '[0-9a-zA-Z]{16}' Tests/VespertineTidalTests/Fixtures | grep -i client` → nothing, so no credentials were committed.
