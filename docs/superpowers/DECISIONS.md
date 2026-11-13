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
