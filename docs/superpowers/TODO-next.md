# Open issues (reported by the owner, 2026-11-14)

## 1. TIDAL never streams above 16/44.1, even with "Hi-Res Lossless" selected

Observed: every TIDAL track plays as FLAC 16/44.1 (local output and network players), whatever the quality setting.

Leads to check first, in order:
- **The client behind the session.** python-tidal says only the PKCE client gets HI_RES_LOSSLESS (`session.py` `login_pkce`, `client_enable_hires`). Check:
  - that the token was obtained with `pkceClientId`;
  - that refresh (`TidalAuth`) uses the PKCE pair, not `clientId`/`clientSecret`. A refresh with the other client would silently downgrade the session.
- **The quality parameter.** Check that the setting (`AppSettings.tidalQuality`) actually reaches `TidalStreamResolver(quality:)`, both at registration (`TidalModel.makeResolver`) and after a change. Log the `audioquality` sent and the `audioQuality`/`manifestMimeType` in the `playbackinfopostpaywall` answer.
- **The manifest type.** Hi-res arrives as `application/dash+xml`; BTS is 16/44.1 at most. If the answer is always BTS, the request or the client is the cause, not the player.
- **The track.** Confirm on a track TIDAL lists as HIRES_LOSSLESS (`mediaMetadata.tags`). Many tracks are only LOSSLESS.

## 2. Search results show "96 AAC" for tracks that then stream as FLAC

Observed: in TIDAL search lists the Format column reads "96 AAC" (or similar), but playback is FLAC.

Leads:
- Search results are transient rows (no database row). Their technical fields come from a different mapping than `upsertTidalTracks`'s `listedQuality` mapping (HI_RES_LOSSLESS → FLAC 96/24 placeholder, LOSSLESS → FLAC 44.1/16, HIGH/LOW → AAC). Find where transient `Track`s are built for search (`TidalBrowseViews` / `TidalModel`) and check how `audioQuality` maps to codec and rate. "96" plus "AAC" suggests the 96 kHz placeholder rate combined with the AAC codec branch.
- The "≈" (listed, not yet probed) marker should show on these rows. Check that it does.
- After a song plays, its probed format should replace the listed one. Transient rows have nothing to record into; decide whether to update the row on screen.
