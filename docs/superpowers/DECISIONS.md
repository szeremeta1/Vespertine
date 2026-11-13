# TIDAL + UPnP integration: decision log

Decisions made while working on my own (the owner said "fly solo, take the best decisions and note them down", 2026-11-13). Newest at the bottom. Each entry says what was decided and why.

## Agreed with the owner in conversation (2026-11-13)

1. Unofficial TIDAL API, ported from python-tidal (LGPL-3), with parts of TidalSwiftLib (GPL-3). The official SDK (AVPlayer + FairPlay) can't feed Vespertine's chain.
2. Four sub-projects: 1 TIDAL core, 2 library/UI, 3 playlist/favorites sync, 4 UPnP/OpenHome output.
3. Saved TIDAL music lives in the same library as local files (`track` rows, source TIDAL), plus a TIDAL sidebar section for the catalog.
4. No audio cache by default. Audio persists only through an explicit Download (track, album, playlist), saved to a user folder, tagged, and linked to the TIDAL row.
5. Anti-ban: one gate with python-tidal backoff (429 → Retry-After or 60 s; abuse 403 → Retry-After or 30 min); downloads one track at a time.
6. Output: UPnP renderer (the owner has moOde, upmpdcli + MPD, hardware volume fixed at 100%). OpenHome preferred, with UPnP A/V as fallback. Bit-perfect pass-through when no effects; processed 24-bit FLAC when EQ or room correction is on. Advice about renderer settings is generic, for all renderers.
7. Client credentials are never committed; they live in `~/Library/Application Support/Vespertine/tidal-client.json`.

## Made solo

8. **DASH uses a random-access reader, not a new cache mode.** The first 4 KiB of each segment is read up front to get the exact remuxed size, so `NetworkPlaybackCache` stays unchanged and seeking ahead is instant. Cost: one small CDN request per segment before start, 8 in parallel.
9. **Remote readers register by URL scheme** in `NetworkPlaybackCache`. `VespertineAudio` never imports TIDAL code.
10. **Random 1–3 s pause between downloaded tracks** (not in either library). It makes album downloads look less like a script; easy to remove.
11. **Default stream quality `HI_RES_LOSSLESS`.** TIDAL falls back to what the track or subscription allows, and the probed format is what the app shows.
12. **Only the PKCE login is implemented** (in-app web sheet that catches the redirect). The device-code login is skipped because its client can't get hi-res.
13. **Work order and parallel tracks:** see the plan. Track A (pure TIDAL module), Track B (cache registry + library migration) and Track C (UPnP) run in parallel in separate worktrees and are merged into `tidal-integration`.

## Library and UI (sub-project 2)

200. **Settings › TIDAL is its own tab**, between Online and Remote. It holds the account, credentials, quality, downloads folder and sync status.
201. **Login runs in a WKWebView sheet** with a non-persistent data store, so TIDAL's real login page is used and no web cookies are kept.
202. **Source column** after Format, shown only when a TIDAL source exists. TIDAL is shown with a "T" glyph in a rounded square, with a check added once downloaded.
203. **One playability rule** for every view, so the grayed rows match everywhere. It reuses the dimming offline share sources already get.
204. **The Format column shows TIDAL's listed quality with "≈"** until the stream has been probed, so the app never claims a format it hasn't seen.
205. **Albums in both libraries appear as copies** through the existing AlbumCopies grouping. Tracks match by ISRC, then by title and duration within 2 s.
206. **Streamed tracks are analyzed from the transient cache file once it's complete**, before deletion. Only the analysis result is stored, so fake hi-res detection works without keeping audio.
207. **Catalog items play without a database row.** "Add to Library" adds them as `origin = added`, and sync never removes those.
208. **Sync runs at launch, every 6 h, and on demand.**

## Two-way sync (sub-project 3)

300. **A TIDAL-linked playlist accepts only TIDAL tracks.** A dropped local track is matched by ISRC; if there's no match, the drop is refused. Plain playlists mix sources freely.
301. **Conflicts:** TIDAL wins on etag mismatch (412). Pending adds and removes are re-applied, moves are skipped, and skipped ops are reported.
302. **Writes queue persistently** when offline, signed out or backing off. The UI updates optimistically, with a "waiting to sync" clock on affected rows.

## Master switch (owner request, 2026-11-13)

209. **The whole TIDAL integration sits behind one switch, off by default:** Settings › Online › "TIDAL integration". With it off, Vespertine looks and behaves exactly as before:
     - no TIDAL settings tab, sidebar section, Source column or inspector group;
     - no `tidal` reader registered, no sync, no network calls to TIDAL;
     - TIDAL rows (including downloaded ones) are filtered out of every library query, so counts, albums and smart playlists match a TIDAL-free library.

     Turning it off deletes nothing: the rows, tokens and downloaded files stay. Turning it back on restores everything. The database migration still runs, but adds only empty tables.
210. **UPnP output gets the same treatment**, with its own switch: Settings › Playback › "UPnP renderers (beta)", off by default, following the Speaker Groups beta pattern. With it off, no SSDP traffic and nothing new in the output picker.
