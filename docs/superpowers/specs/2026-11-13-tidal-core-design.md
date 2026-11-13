# TIDAL core: design

Status: approved in conversation 2026-11-13, awaiting written-spec review.
Sub-project 1 of 4 (1 TIDAL core, 2 library and UI integration, 3 playlist and favorites sync, 4 UPnP/OpenHome output).

## Goal

Play TIDAL tracks through Vespertine's own chain (probe, plan, bit-perfect output, EQ, room correction, analysis, gapless, speaker groups), at the quality TIDAL actually delivers, up to 24-bit/192 kHz FLAC. TIDAL music the user has saved lives in the same library as local files. Audio is never stored unless the user explicitly downloads it.

## Decisions and constraints

- **Unofficial API, personal project.** The official TIDAL SDK plays through AVPlayer with FairPlay, so its audio cannot enter Vespertine's chain. This module ports [python-tidal](https://github.com/tamland/python-tidal) (LGPL-3.0), with parts from [TidalSwiftLib](https://github.com/melgu/TidalSwiftLib) (GPL-3.0). Both are compatible with Vespertine's GPL-3.0.
- **Client credentials are never committed.** They are read from `~/Library/Application Support/Vespertine/tidal-client.json` (`clientId`, `clientSecret`, `pkceClientId`, `pkceClientSecret`). When the file is missing, Settings › TIDAL shows fields to paste them and writes the file. The repository contains no IDs, secrets or tokens, and tests use fakes.
- **No audio cache by default.** A playing TIDAL track's bytes exist only in the transient playback cache and are deleted when its lease is released, as for share files today. The only audio that persists is an explicit download.
- **Downloads are explicit only.** A track, album or playlist is downloaded only by a user command.
- **Do not get the account banned.** All API traffic goes through one gate with python-tidal's backoff rules. Downloads run one track at a time.

## Module: `VespertineTidal` (new, in `Packages/VespertineKit`)

The module has no UI. It depends on Foundation, `VespertineLibrary` (for `TagWriter` and models) and `VespertineAudio` (for the cache reader protocol). Each part below is a separate file or group of files with its own tests.

### `TidalAuth`
- PKCE login, ported from `session.py` (`pkce_login_url`, `pkce_get_auth_token`):
  - The authorize URL is `https://login.tidal.com/authorize` with `response_type=code`, the PKCE client ID, `redirect_uri=https://tidal.com/android/login/auth`, `appMode=android`, a random 64-bit `client_unique_key`, and an S256 `code_challenge`.
  - The code is exchanged at `https://auth.tidal.com/v1/oauth2/token` with `grant_type=authorization_code`, the `code_verifier`, and scope `r_usr+w_usr+w_sub`.
- Refresh with `grant_type=refresh_token` happens 60 s before expiry. Concurrent callers share one refresh in flight.
- Tokens (access, refresh, expiry, user ID, country code) are stored in the Keychain, service `org.szeremeta.vespertine.tidal`.
- Sign-out deletes the Keychain item. TIDAL rows stay in the library, marked signed out.
- A PKCE session is required for hi-res. The device-code flow is not implemented, because TIDAL rejects the PKCE client on it and the other client is capped at 16/44.1.

### `TidalGate`
- An actor through which every `api.tidal.com` request passes. It adds the bearer token, `countryCode`, an Android web-view User-Agent and the client version string (python-tidal `request.py`).
- Backoff, ported from python-tidal:
  - HTTP 429 → hold all requests for `Retry-After` seconds, or 60 s without one.
  - HTTP 403 whose body mentions abuse or suspension → hold all requests for `Retry-After`, or 30 min.
  - A running backoff is never shortened.
  - A request made during a backoff fails immediately with `TidalError.backingOff(remaining:reason:)` and is not sent.
- A 401 triggers one token refresh and one retry.
- Priority: playback requests (stream resolution) go before sync and download requests. The gate exposes its backoff state for the UI.
- CDN fetches (audio bytes, segments, images) do not pass through the gate. They have their own retry policy (see below).

### `TidalCatalog`
- Typed reads of the v1 API: tracks, albums (with tracks), artists, playlists (with items), user favorites (tracks, albums, artists; at most 100 per page), user playlists, search, mixes, lyrics and credits.
- Models are ported from TidalSwiftLib `Codables/*` and checked against python-tidal's parsers.
- Read-only in this sub-project. Writes (favorites, playlist edits) belong to sub-project 3.

### `TidalStreamResolver`
- `GET tracks/{id}/playbackinfopostpaywall` with `playbackmode=STREAM`, `assetpresentation=FULL`, and `audioquality` from the user's setting (default `HI_RES_LOSSLESS`).
- Decodes the base64 manifest according to `manifestMimeType`:
  - `application/vnd.tidal.bts`: JSON with `urls`, `codecs`, `mimeType`, `encryptionType`. This gives one file URL.
  - `application/dash+xml`: an MPD. From it come the init URL, the media URL template (`$Number$`), the segment count from the `SegmentTimeline` (`1 + Σ(r or 1)`, as in python-tidal `DashInfo.get_urls`), timescale, audio sampling rate and codecs.
- Returns `TidalStream { kind: .file(URL) | .dash(init: URL, segments: [URL]), codec, sampleRate, listedQuality, encrypted: Bool }`.
- `encryptionType` other than `NONE` → `TidalError.encrypted`. There is no decryption.
- Streams are resolved at play time, or when the next track is prepared for gapless, never in bulk. Stream URLs are short-lived and are resolved again when they expire.

### `DASHFLACRemuxer`
- Input: the init segment (fMP4 `moov` containing `fLaC` sample entry → `dfLa` box) and the media segments (`moof` + `mdat`).
- Output: a native FLAC stream, written as the segments arrive:
  1. The `fLaC` marker.
  2. The metadata blocks from `dfLa`. STREAMINFO is kept as is, and its last-block flag is set correctly.
  3. For each segment, the samples' raw FLAC frames from `mdat`, in order, using the `trun` sample sizes.
- The FLAC frames are not changed, so the decoded samples equal TIDAL's.
- Pure and synchronous over `Data`. It has no networking.

### `TidalPlaybackSource` (cache integration)

Dependency direction: `VespertineAudio` gains a small hook. A `RemoteSourceProvider` protocol, registered per URL scheme at app start, returns either a `PlaybackCacheReader` or a size-known-at-end writer for a `tidal://` URL. `VespertineTidal` implements it. `VespertineAudio` never imports `VespertineTidal`.

- **BTS:** `TidalHTTPReader: PlaybackCacheReader`. Its `size` comes from `Content-Length`, and `read(at:count:)` uses HTTP Range requests. It plugs into `NetworkPlaybackCache.entry(key:url:reader:)` unchanged, so progressive start (`NetworkStart`), guarded reads, seeking, next-track prefetch and lease deletion all keep their current behavior.
- **DASH:** a new cache entry mode, **size known at end**:
  - Segments are fetched in order and remuxed into the entry's file.
  - Guarded reads wait for bytes as today. A read past the bytes written so far waits; it is not treated as end of file until the last segment has been written and the size is final.
  - Start uses the existing lead calculation on the measured rate.
  - A seek ahead of the download waits, with the existing buffering ring.
- **Expired URL** (HTTP 403/410 from the CDN): resolve again through the gate and resume at the same byte (BTS) or segment index (DASH).
- **CDN retry:** retries with a growing wait (2 s, 4 s, 6 s…), as in TidalSwiftLib's `HLSDownloader`. The existing 2-minute no-progress limit (`defaultNoProgressLimit`) fails the track with "TIDAL isn't answering". The queue then continues as for shares: if the next track also needs the network, playback stops; downloaded and local tracks play.
- **Library rows:** `tidal://track/<id>` is the cache key. `Track.fileURL` and the probe path recognize the scheme, so nothing on the main thread treats it as a file path.
- **Atmos:** when the stream is unencrypted E-AC-3, it goes to `SystemRendererSession`, as local Atmos files do.

### `TidalDownloader`
- Explicit download of a track, album or playlist. Items are processed one track at a time (TidalSwiftLib `Download.downloadTracks`), with a random 1–3 s pause between tracks.
- Each track uses `TidalStreamResolver`. BTS is fetched whole; DASH is remuxed. Both are written to a `.partial` file and renamed when complete.
- Tagging uses Vespertine's `TagWriter`: title, artists, album, album artist, track and disc numbers, date, ISRC, copyright/label, ReplayGain, cover art (1280 px), and `TIDAL_TRACK_ID`.
- Path: `<downloads folder>/<Album Artist>/<Album>/<disc-track> <Title>.flac`. The default folder is `~/Music/Vespertine/TIDAL`, set in Settings › TIDAL.
- A backoff pauses the queue, and the UI shows the reason and the time left. Failures are reported per track; one failure does not stop the album.
- Playback has priority: the queue's CDN work yields while a playing track's buffer is under a third full, as `NetworkCache.yieldsToPlayback` does for shares.

## Library data (`VespertineLibrary`)

Migration `v23-tidal`:
- One `source` row for the account: `path = "tidal://"`, `remoteURL = "tidal://user/<userId>"`, `name = "TIDAL"`. Its `isOnline` is true when signed in and the network is reachable.
- TIDAL tracks are `track` rows with `location = "tidal://track/<id>"`. `filePath` is the download path, or empty.
- New table `tidalTrack`:
  - `trackId` (FK to `track`, cascade)
  - `tidalId` (unique)
  - `albumId`, `artistIds`
  - `listedQuality`, `mediaTags` (LOSSLESS / HIRES_LOSSLESS / DOLBY_ATMOS…)
  - `explicit`, `copyright`, `popularity`
  - `streamable`, `unavailableReason`
  - `downloadPath`, `formatIsProbed`
  - `lastSyncedAt`
- `codec`, `sampleRate` and `bitDepth` start from TIDAL's listed quality. They are replaced by the probed format after the first play or download (`formatIsProbed = true`).
- ReplayGain: TIDAL's track and album gain and peak fill `rgTrackGain`, `rgTrackPeak`, `rgAlbumGain` and `rgAlbumPeak`.
- Sync, pull only in this sub-project:
  - At launch (after sign-in) and on "Refresh TIDAL", the app fetches favorite tracks, albums and artists, and user playlists, paged through the gate.
  - Rows are upserted by `tidalId`.
  - A row no longer in favorites is removed, unless downloaded. Then it stays, with `unavailableReason = notInFavorites`.
- Scanner: a FLAC with a `TIDAL_TRACK_ID` tag inside a library folder is linked to its TIDAL row (`downloadPath`), not added as a new track.
- Artwork is fetched on demand at display size and kept by `ArtworkStore`, keyed by TIDAL cover UUID. Credits and lyrics are fetched when the inspector asks and kept in memory only.

## Errors (user-visible)

| Case | Behavior |
|---|---|
| Network lost mid-track | Buffer plays out. CDN retries with a growing wait. Buffering ring if the buffer empties. "TIDAL isn't answering" after 2 min, then the queue continues as for shares |
| Stream URL expired | Resolve again and resume at the same byte or segment, without a message |
| Token refresh fails | TIDAL rows show "Sign in to TIDAL", with a sign-in banner. Downloaded and local tracks play |
| Backoff in force | TIDAL stream start refused with "TIDAL asked us to wait N min". Downloads paused |
| Lower quality than listed | Plays. The real probed format is shown, plus "TIDAL lists Hi-Res · stream delivered 16/44.1" |
| Encrypted manifest | "This track's stream is encrypted". Not played |
| Not streamable (region, removed) | Row grayed. The reason is shown in its tooltip and the inspector |

## Testing

- `DASHFLACRemuxerTests`: an fMP4 FLAC fixture (init + segments) generated from a known FLAC. The remuxed file's decoded samples must equal the source's sample for sample, and STREAMINFO must be preserved. Also a truncated-segment case.
- `TidalStreamResolverTests`: recorded BTS and MPD manifests (fabricated IDs). Checks URL lists, segment counts, rate and codec, and refusal of encrypted manifests.
- `TidalGateTests`: 429 with and without `Retry-After`, abuse 403, refusal during backoff without sending, a backoff never shortened, 401 → one refresh, and priority order.
- `TidalAuthTests`: PKCE challenge derivation, URL parameters, token parsing, a single refresh in flight.
- `TidalPlaybackSourceTests`: a local fake HTTP server (throttle, stall, expiring URLs, Range). Following `NetworkPlaybackCacheTests`: progressive start, a seek within and past the download, URL renewal mid-track, no-progress failure, and the transient file deleted on lease release.
- `TidalDownloaderTests`: one track at a time, pause on backoff, per-track failures, `.partial` rename, tags written including `TIDAL_TRACK_ID`.
- Library: migration, upsert by `tidalId`, removal rules, scanner linking.
- Manual: sign in, play a 16/44.1 BTS track and a 24/192 DASH track to a USB DAC (rate switch and BIT-PERFECT badge), seek, pull the network mid-track, download an album, play it offline.

## Out of scope here

- Views: the Source column, graying, inspector panels, the TIDAL sidebar section, quality badges and search UI (sub-project 2).
- Writing to TIDAL: favorites, playlist create and edit (sub-project 3).
- UPnP/OpenHome output (sub-project 4).
- Videos, TIDAL Connect, decrypting encrypted streams.
