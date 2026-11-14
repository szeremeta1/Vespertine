# Open issues (reported by the owner, 2026-11-14)

## 1. TIDAL never streams above 16/44.1, even with "Hi-Res Lossless" selected (diagnosed, display fixed)

Findings:
- Auth is right: login and refresh both use the PKCE client (the hi-res one). The resolver gets the setting's quality.
- The library shows hi-res does stream: "Loveland" (tagged HIRES_LOSSLESS) was probed as FLAC 24/44.1 when played. BTS is 16-bit at most, so that came over DASH. 24/44.1 is a real TIDAL "Max" master; many are 24/44.1 or 24/48, not 96 or 192.
- The cause of "everything is 16/44.1": TIDAL's v1 `audioQuality` is LOSSLESS even for hi-res tracks. Only `mediaMetadata.tags` (HIRES_LOSSLESS) says hi-res. The listed format came from `audioQuality` alone, so every unplayed hi-res track read "FLAC · 16/44.1 ≈".

Fixed: `TidalTrackInput.listedFormat` uses the tags first (HIRES_LOSSLESS → hi-res placeholder, LOSSLESS → 16/44.1) and falls back to `audioQuality` when there are none. Rows that are already synced pick it up at the next sync (rows with a probed format keep it).

Still open: confirm the rate of a track TIDAL serves at 24/96 or higher. If that one also plays at 44.1, log the `playbackinfopostpaywall` answer (`audioQuality`, `manifestMimeType`, the MPD's `audioSamplingRate`).

## 2. Search results show "96 AAC" for tracks that then stream as FLAC (fixed)

- "AAC · 96k" is the `LOW` mapping: search results list `audioQuality` LOW for tracks whose tags say LOSSLESS/HIRES_LOSSLESS. The tag-first mapping above fixes it.
- Catalog rows (no library row) now show "≈" as well.
- After a catalog song plays, its probed format replaces the listed one on screen for the rest of the run (`PlayerController.catalogFormats`, applied in `AppModel.tracks(forCatalog:)`).
