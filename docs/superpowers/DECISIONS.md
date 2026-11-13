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

## UX pass (2026-11-13, owner asked for a quick overall UX review)

400. **TIDAL UX amendments 1–8** are in the library/UI spec ("UX review amendments"). The main ones: one-flow enable, credentials by file import, a single offline banner, the existing search field reused, and download progress shown in the sidebar.
401. **UPnP UI says "Network Players" everywhere** ("renderer" stays only in code and the technical details). The signal path says "not verified" for what the player does. Clearer empty state.

## "Build everything pending" (owner, 2026-11-13)

500. **Build order:**
     - now, in parallel: core Track D, the UPnP fix round, and Track E (UI pure parts: master switch, playability, album copies; TidalWriter, ISRC lookup);
     - after D merges: Track F (TidalModel, playable items, settings and login, sidebar, inspector, sync queue, app routing);
     - after the UPnP merge: AirPlay phase 1.
501. **AirPlay phase 1 = RAOP sender, ALAC 16/44.1** (per the study), behind its own switch, off by default: Settings › Playback › "AirPlay Players (beta)".
     - It reuses the UPnP output façade, the processed-mode PCM tap, and the badges and views.
     - Badges say what was sent: "BIT-PERFECT · 16/44.1 SENT" only for 16/44.1 sources with no effects, otherwise "CONVERTED · 16/44.1 SENT" with the steps named.
     - Phase 0 (measuring the macOS route on real hardware) needs the owner's moOde and is left for them.
     - AirPlay 2 (phase 2) is not started: it's experimental, and Apple receivers are reported broken for third parties since OS 27.

## UPnP output (sub-project 4)

Made solo on branch `upnp-output` (spec `docs/superpowers/specs/2026-11-13-upnp-output-design.md`, plan `docs/superpowers/plans/2026-11-13-upnp-output.md`).

100. **A separate engine-shaped façade, not a PlaybackEngine output.** `RendererPlayback` (new `VespertineUPnP` target) publishes the same `EngineSnapshot` and `EngineEvent`s and takes the same commands; `PlayerController` sends them to it instead of the engine while a renderer is the chosen output. The engine is built around a Core Audio clock; a renderer has its own and pulls the file, and pass-through doesn't decode at all. `PlaybackEngine.swift` is untouched apart from a public `EngineSnapshot.init()`.
101. **Off by default, behind Settings › Playback › "UPnP Renderers (beta)"**, following the Speaker Groups beta pattern (owner requirement relayed mid-task; decision 210 in the main tree). Off: no `RendererOutputModel` exists, so no SSDP is sent, no media server listens, and nothing new is in the output list or elsewhere (only the switch itself in Settings). `RendererService.setEnabled` is the one gate in the package; tests in both the package (`RendererDiscoveryTests.offByDefault`) and the app (`RendererSwitchTests`) check that off never searches or listens. Turning it off while a renderer is the chosen output lets go of it.
102. **Renderer badges say what was sent: `BIT-PERFECT · 24/192 SENT`**, never plain `BIT-PERFECT`. A renderer path has `SignalPath.renderer` set, `isBitPerfect` is always false for it (that is the DAC-level claim the verification harness and docs/VERIFICATION.md define, which a renderer can't support), and a new `isUntouched` drives the brass styling (equal to `isBitPerfect` for local devices). The verification harness builds paths without a renderer stage, so its rules are unchanged. `DeviceProfile.Kind.networkRenderer` has `canBeBitPerfect: false`.
103. **Processed badges name the strongest reason**: ROOM CORRECTION, EQ, VOLUME, REPLAYGAIN, then FLAC (only the format forced decoding, e.g. a CUE track or a type the renderer doesn't list). Lossy files sent as they are: `LOSSY SOURCE · SENT AS IS` (no brass); DSD files the renderer lists: `NATIVE DSD · DSD64 SENT`.
104. **Polling, not GENA.** Status every 0.5 s (`Playlist.Id`/`TransportState` + `Time.Time`, or `GetTransportInfo` + `GetPositionInfo`), position interpolated between polls. GENA needs a callback server, renewals and per-vendor quirks; polling works on every renderer. Three failed polls in a row = renderer lost (`deviceLost`).
105. **Discovery by M-SEARCH only** (at start, when the output list opens, every 5 minutes), for `MediaRenderer:1` and OpenHome `Product:1`. No NOTIFY listening (would need port 1900 shared with system daemons). A renderer missing from 3 searches, or whose description fails twice, is dropped. IPv4 only.
106. **OpenHome over AV when both exist** (upmpdcli offers both). OpenHome's Playlist source is selected (`Product.SetSourceIndex`) when it isn't current. The playlist holds exactly current + next; when the renderer moves on, everything but the playing id is deleted and the following song inserted.
107. **AV without SetNextAVTransportURI**: the transport itself sets and starts the next URI when it sees the song end (STOPPED after playing, while Vespertine wants it playing). There will be a gap; the list shows "GAPLESS NOT GUARANTEED" and the details "Gapless: not guaranteed on this renderer". Loading a song with nothing after it clears a stale NextURI.
108. **Media server serves only registered tokens** (`/media/<128-bit random hex>.<ext>`), released 30 s after a song is neither current nor next (renderers re-request). Binds all interfaces on an ephemeral port; the URL uses the local address the OS routes toward the renderer (UDP connect + getsockname). Range: single ranges byte-exact (206/416); several ranges answer the whole file, as RFC 9110 allows.
109. **Processed streams use chunked transfer encoding** while being written (close-delimited bodies were not read reliably by URLSession; MPD/curl handle chunked). Once a stream is finished it is served like a file, with length and ranges.
110. **Processed mode reuses the engine's own chain offline** (`NetworkRender` in VespertineAudio: planner at the source rate, `Decoding.convertChunk` with ReplayGain, ring, `nrt_context_render_interleaved` with room correction, EQ, digital volume and TPDF dither at 24 bits), the path `GoldenRender` already tests. Encoded with SFBAudioEngine's FLAC encoder (level 5) on a thread of its own, faster than real time, into `Caches/Vespertine UPnP/` (cleared at launch). Unity gain with nothing on reproduces a 24-bit source exactly; tested through the FLAC too.
111. **Effect, volume or ReplayGain changes restart the processed song at its position** (new stream from that frame; the renderer's own seek isn't used on a stream still being written). A restart is not announced as a new song (no `trackStarted`), so history and scrobbling aren't touched. Seeking in a processed song also restarts the stream there.
112. **Volume UX: a lock.** With a renderer chosen, the volume control shows a lock glyph and `100% · LOCKED` in brass; the renderer's own volume is never touched. Its popover explains and offers "Unlock Volume"; unlocked, a copper `DIG` slider (Vespertine's 64-bit digital volume, stored per renderer like app volume) and the lock button to re-lock at 100%, which returns to pass-through. Volume keys move it only when unlocked; locked, they open the note. Unlocked at exactly 100% (0 dB) still sends the original file.
113. **Capability warnings only where the renderer states a limit for the type being sent.** An LPCM `rate=` limit (upmpdcli lists L16 at 44.1/48 kHz) says nothing about FLAC, so it doesn't warn about a 96 kHz FLAC. Max format is "Not stated by the renderer" when it states none; nothing is resampled to fit (out of scope). A renderer that answers GetProtocolInfo with nothing is assumed to accept everything and left to refuse.
114. **Pass-through conditions**: no EQ/room correction/unlocked volume/ReplayGain, a whole local file (no CUE region, SACD area, DVD stream or stream index), and a MIME type the renderer lists. Anything else is processed if the renderer takes FLAC, else the song fails with a reason. A network-share file is served from its local copy when the cache has one (`urlResolver`), else read from the share as the renderer pulls it.
115. **Room correction for renderers is applied if a profile is assigned to the renderer's UID, but there is no UI to measure or assign one** (measuring needs a Core Audio output). The equalizer has its own choice in the renderer details (`RendererEqualizerChoice`, keyed by the renderer UID).
116. **Renderer metadata**: title, artist, album and duration in DIDL-Lite from the queue's tracks; no artwork URL yet (it would need the media server to serve artwork).
117. **Transitions/crossfades don't apply to renderers** (each song is its own stream); Spatial Audio, downmix, DoP and bitstream don't either.
118. **Local Network usage text** (Info.plist and project.yml) now also mentions network players.

### UPnP output, fix round 1

119. **A chosen network player that isn't answering is never replaced by another output**, whatever "When the chosen output isn't connected" says: Play shows "<name> isn't answering." and nothing plays; during the first search after launch Play waits up to 5 s for it. One that drops mid-song stops there with the same message. Its row in the output list says NOT RESPONDING, dimmed.
120. **Refused pause, play or seek is tried again once after 300 ms**, then reported as a notice (`EngineEvent.notice`, shown like other playback messages) while the song plays on; it is never treated as a failed song. A seek at start (an output change carrying a song over) waits until the player plays and is tried at the next polls, up to 5 times.
121. **The media server answers a malformed request 400 and closes it** (Content-Length not a plain number in 0…1 MiB, headers over 64 KiB). Every connection has 10 s to send its request; at most 32 are open at once, more are closed on arrival. Connections are closed right after the response; the final empty "end of message" write never completed and left them open.
122. **The on/off switch is applied in order** (`RendererService.want`, each change after the last, the wanted state re-read after every await), so a quick off-on-off can't leave a search loop or a listener behind.
123. **Discovery follows a description only on the host that sent the SSDP reply**, keeps only services whose URLs are on the description's host, and reads at most 1 MiB of a description or service description.
124. **Settings changes that restart a processed song are applied 300 ms after the last one**, so a volume drag restarts the stream once. Stopping the media server abandons processed streams and deletes their files.
125. **Songs are prepared (probe, decoder, encoder start) on a dispatch queue of their own**, off Swift's cooperative pool, since opening a file can block on a share.
126. **"Network player" is the interface's word** (Settings switch "Network Players (UPnP, beta)", output-list header "Network players", copy and advice say "player"); "renderer" stays in code and in the technical rows of a player's details (the owner's "Gapless: not guaranteed on this renderer" among them). The signal path's last step says "not verified" for what the player does, as docs/VERIFICATION.md words it.
127. **A pause or play the player refuses twice puts the snapshot back to what the player reports** (playing, paused or stopped), and what Vespertine wants with it, so the interface never says paused while it plays (or the reverse). A refused seek changes nothing.
128. **Redirects are followed only to the host first asked** (a session delegate), so neither a description nor a control URL can send Vespertine's requests to another machine; a redirect elsewhere is answered as the error its 3xx status is.

## AirPlay phase 1

Made solo on branch `airplay-raop` (spec `docs/superpowers/specs/2026-11-13-airplay-raop-design.md`, plan `docs/superpowers/plans/2026-11-13-airplay-raop.md`, requirements from the AirPlay study and decisions 500–501).

600. **A new `VespertineAirPlay` target**, depending on `VespertineAudio` and `VespertineUPnP` (for `RendererSettings`, `RendererTrackInfo` and the shared protocol below). Neither of those imports it.
601. **The player drives every network output through one protocol, `NetworkPlayback`** (in `VespertineUPnP`; `RendererPlayback` conforms as it is). `PlayerController.renderer` is `any NetworkPlayback`, so the "isn't answering" handling (decision 119), the first-search grace, carrying a song over at its position and the event handling are the same code for UPnP players and AirPlay receivers.
602. **Settings › Playback › "AirPlay Players (beta)"**, its own switch (`airPlayPlayersFeature`), off by default, beside "Network Players (UPnP, beta)". Off: no `AirPlayOutputModel` exists, so no `NWBrowser` runs and no socket is opened (sessions are opened only by a playback, which exists only while a receiver is the chosen output); nothing new in the output list. `AirPlayService.want` is the package's one gate, applied in order like `RendererService`. Tested in the package (`AirPlayDiscoveryTests.offByDefault`/`onOff`) and the app (`AirPlaySwitchTests`). macOS's own AirPlay devices (Core Audio) are untouched and still listed with the other devices.
603. **Output list: an "AirPlay players" section after "Network players"**, same `deviceRow`, symbol `airplay.audio`, detail `AIRPLAY · ALAC 16/44.1` (`· ENCRYPTED` for RSA receivers). A separate header rather than mixing them into "Network players": the two behave differently (a player pulls the original file; AirPlay is always 16/44.1), and the header says which is which. Receivers Vespertine can't send to are listed dimmed and not selectable, with the reason as the detail ("AIRPLAY 2 ONLY — NOT SUPPORTED YET", "NEEDS A PASSWORD — NOT SUPPORTED YET", "DOESN'T TAKE ALAC 16-BIT / 44.1 KHZ").
604. **Discovery browses `_raop._tcp` and `_airplay._tcp`** and merges them by device id (the MAC in the RAOP name = `deviceid`), so AirPlay 2-only devices can be listed as such. This Mac's own AirPlay receiver is left out by name (the computer name). `NSBonjourServices` gains both types; the Local Network text mentions AirPlay Players.
605. **What phase 1 sends to**: `et` lists 0 or 1, `cn` lists 1 (or is absent), `tp` lists UDP (or is absent), `ss`/`sr`/`ch` absent or 16/44100/2, no `pw=true`. When 0 is offered it is used (unencrypted, as OwnTone and libraop prefer); RSA only when the receiver offers 1 and not 0. HomePods and Apple TVs that list 0 among FairPlay types are offered, best effort (the study: Apple broke third-party AirPlay 1 audio on OS 27). Password and Apple TV PIN (device verification) aren't supported yet.
606. **ALAC from Apple's own encoder** (AudioConverter, `kAudioFormatAppleLossless`, 352 frames per packet), used only when its magic cookie matches the SDP's fmtp (it does: 352/16/40/10/14/2/255/44100); otherwise the verbatim (uncompressed) ALAC frame, lossless by construction. Both round-trip exactly through Apple's decoder in the tests.
607. **Badges**: `BIT-PERFECT · 16/44.1 SENT` only for a PCM source at 44.1 kHz with 1–16-bit words, one or two channels, and no EQ, room correction, digital volume or ReplayGain; a CUE track counts (it is decoded either way, and its samples are sent unchanged). Mono is copied to both channels, unchanged, and keeps the badge. Everything else is `CONVERTED · 16/44.1 SENT`, effects included (decision 501's wording, rather than UPnP's PROCESSED), with the steps as small badges (ROOM CORRECTION, EQ, VOLUME, REPLAYGAIN, RESAMPLED, DITHERED, DOWNMIX, DSD→PCM) and in the signal path. Lossy sources: `LOSSY SOURCE · 16/44.1 SENT`, never brass. `isBitPerfect` is false on every AirPlay path; the last step of the signal path says "not verified", and the receiver step says it follows this Mac's clock and may apply its own volume.
608. **16 bits with TPDF dither whenever the source isn't already 16-bit words at 44.1 kHz with nothing applied.** `NetworkRender` gains a target (`.airPlay`: a virtual stereo device at 44.1 kHz, 16-bit integer), so resampling (mastering SRC), downmix and DSD→PCM are the engine's own; where the chain processes the samples (gain, EQ, room correction) it dithers at 16 bits itself, otherwise `AirPlayFrames` adds TPDF at the 16-bit LSB before rounding (ReplayGain, 24/32-bit, float, resampled, downmixed, lossy). An untouched song is only rounded, which is exact; the frames count any sample that wasn't (tests: zero). No noise shaping (the study's choice).
609. **Volume: the receiver's own by default** (`SET_PARAMETER volume`, linear over −30…0 dB, −144 for 0), so Vespertine's samples stay as they are and the badge doesn't change; below 0 dB the signal path warns that the receiver lowers the volume itself. The control shows a closed lock and `AIR`. Its popover offers "Use Vespertine's Volume": a copper `DIG` slider, Vespertine's 64-bit digital volume (the song is CONVERTED · VOLUME), the receiver held at 0 dB; and back. The level is the same per-output level either way (`appVolumeLevel(for:)`); the choice is stored per receiver (`airPlayDigitalVolume`). Volume keys move whichever is in use (no "locked" note: receiver volume doesn't touch the samples).
610. **Timing as iTunes and OwnTone do it**: 2 s latency (sync packets say `rtptime − 77175`, flags 7, receivers add 11025), a sync packet on start and about every second, timing requests answered from one monotonic clock (`CLOCK_UPTIME_RAW` as NTP), packets paced at 352 frames of real time with a 250 ms lead, a 1024-packet (8 s) backlog for retransmission requests. Position = the frame heard now (clock − latency) on the song's timeline.
611. **Pause = FLUSH and stop sending** (position kept where it was heard); **resume, seek and changes to what Vespertine applies start the song again at that position** after a FLUSH (new render from that frame). Simpler and exact; the cost is the receiver's 2 s start delay on resume. A restart isn't announced as a new song. Stop = FLUSH + TEARDOWN. OPTIONS every 25 s keeps an idle (paused, ended) session; if it fails the receiver is lost (`deviceLost`).
612. **Gapless: one RTP timeline through the queue.** The next song is opened ahead (on its own queue) and its first frame follows the last of the one before in the same packet; `trackStarted` fires when that frame is heard. Only the very end of the queue is padded with silence to a whole packet.
613. **A receiver that can't be reached or refuses the session** (a refused ANNOUNCE/SETUP/RECORD, 453 = busy with another sender) fails the song with the reason ("… couldn't play the song (it is busy with another sender)"), as a UPnP player's refusal does; nothing plays elsewhere. Gone from Bonjour while chosen: NOT RESPONDING in the list and "<name> isn't answering." on Play, exactly as network players (decision 119).
614. **Titles and progress go as DMAP / `progress:` parameters** when the receiver's `md` lists 0 / 2; artwork isn't sent in phase 1.
615. **RSA receivers**: random AES key and IV per session, the key wrapped with RSA-OAEP (SHA-1) under the AirPort Express public key (modulus from libraop/OwnTone, a public fact), `Apple-Challenge` sent with the ANNOUNCE (as OwnTone, only when encrypting) and its answer not checked. Tests use a generated key pair so the fake receiver can unwrap.
616. **IPv4 only** (as decision 105): the RTSP connection is forced to IPv4, its local address goes in the SDP and the UDP sockets are IPv4.
617. **RTSP requests go one at a time** on the connection (an async lock inside the actor), so a keep-alive can't read another request's answer.
618. **The equalizer and room correction for a receiver are chosen as for a network player** (`RendererEqualizerChoice`, keyed by `raop:<id>`); room correction has no UI to measure for it, as decision 115.
619. **Not done in phase 1, and why**: Phase 0 (measuring macOS's own AirPlay route) needs the owner's moOde; AirPlay 2, pairing and PIN/password receivers are phase 2+; an app-level test with a real AppModel choosing a receiver isn't written (AppModel isn't built in tests); the generic "never fall back" path is the one `RendererMissingTests` covers, and `AppModel.networkOutputChosen` routes AirPlay into it.

### AirPlay phase 1, fix round 1

620. **A SETUP answer without a usable Session** (missing or empty) is a protocol error that fails the song with its reason; it never traps. **An answer naming another request's CSeq** is a protocol error too; one that leaves CSeq out is accepted (OwnTone notes Reflector and Airfoil do).
621. **The sender's clock is signed around its anchor**: packets sent ahead (the 250 ms lead) map to frames before the anchor, so the first sync packet and every later one put the same frame at the same moment (tested within 1 ms).
622. **The next song opened ahead is kept unless it changes**: identical settings (every `syncEngine` sends them), a receiver-volume step, or a queue edit that keeps the same next song leave it alone; only a different next song or changed settings drop it, and it is opened again at once. **No file is ever opened on the pacer's thread**: if the next song isn't open at the boundary, it is opened on the preparation queue while the pacer holds the partly filled packet (nothing is sent and the timeline doesn't move); the packets due then go at once, so within the receiver's two seconds there is no gap.
623. **The session is read behind a lock** (pacer, snapshot, worker); the session's own sockets, connection and keys likewise. The AirPlay tests run clean under ThreadSanitizer.
624. **Receiver volume**: the signal path's note follows a volume change at once (not only when a song opens); a receiver nobody set a level for starts at 100% (0 dB), not at the app's digital volume for other outputs; volume SET_PARAMETERs are coalesced (one in flight, the latest level wins).
625. **A lost session** (keep-alive refused or failing) closes its RTSP connection and sockets before the playback hears of it; the session's deinit cancels the keep-alive and closes the connection. Random AES keys and challenges come from `SecRandomCopyBytes` with its status checked: a failure fails the connect, never a zero key.
626. **A failure is reported only by the play it belongs to** (an overtaken play stays silent), and **a chosen network output whose playback can't be made counts as missing** (`AppModel.missingNetworkOutput`), so it is never handed to the Mac's own output.

### AirPlay phase 1, fix round 2

627. **The pacer holds for a next song at most 1.5 s** (it looks again every 50 ms). Within that, what it then sends late still arrives inside the lead and the receiver's two seconds. Past it, the stream stops after the song before; that song is heard to its end (and announced if it wasn't yet), the receiver is flushed, and the next song starts from its first frame on a fresh stream once it opens, with the notice "Gap before <title>: it took too long to open." Nothing is announced for frames the receiver couldn't play.
628. **A song that doesn't open within 120 s** (the network cache's own no-progress limit), or can't be opened, fails through the normal failure path and the song after it is tried. Opening runs on a concurrent queue, so one stuck on a hung share doesn't hold up the next.
629. **An opening that finishes for a song that is no longer next is dropped**, and a queue change while the old next song is still opening opens the new one at once.
630. **The sender's clock maps nanoseconds to frames in Double**, so it can't overflow however long one stream runs (an Int64 product would after about 58 h).

## Track F

700. **The heart on a TIDAL song is the TIDAL favorite.** Each pull sets the hearts of TIDAL rows to TIDAL's favorite tracks (local songs' hearts are never touched); a heart changed in Vespertine shows at once and goes to TIDAL through the sync queue, with a clock in place of the heart until it is sent. Favorite albums and artists aren't hearted in the library (it has no album or artist hearts).
701. **Every write waits in the library and is sent about 2 s after the last change** (a burst of clicks goes out together), then the account is pulled once nothing waits. A write TIDAL refuses outright (4xx other than 404/412/429) is dropped and named in Settings › TIDAL › Status; a playlist that 404s has its writes dropped and stays here as a plain playlist; anything else (offline, signed out, backoff, 5xx, no etag) keeps the queue for the next drain.
702. **A removal is sent by song, not by place**: the playlist's items are read from TIDAL just before, and the same song nearest its old place is removed; when it is gone already nothing is sent. Edits and deletions that meet a 412 are sent once more after the playlist is pulled; moves are skipped and reported (decision 301).
703. **New TIDAL Playlist…** makes the playlist here at once (with the TIDAL glyph); TIDAL makes it when the queue is sent. Songs added before then follow it.
704. **A local song dropped on a TIDAL playlist** is looked up by ISRC only while TIDAL is reachable; offline, or with no ISRC, it is refused ("Not on TIDAL"). A match is added to the library (as added from the catalog, so a pull keeps it) and to the playlist.
705. **The offline banner sits over every library page while TIDAL is on, the account has a source, and TIDAL can't stream** (signed out, offline or backing off), not only over lists that hold TIDAL rows: those can be any page. It offers Sign In… when signed out and Retry when offline.
706. **TIDAL covers are fetched from TIDAL's image server while TIDAL is on, and kept in memory only.** Off, `tidal:` artwork keys load nothing.
707. **Streamed songs are always analyzed when their staged copy completes** (decision 206), whatever "Analyze new music automatically" says: the file exists only for that moment. A hard link to the complete copy is handed to the analysis, which deletes it when done; the cache's own file goes with the lease as before.
708. **My Mixes is hidden when TIDAL answers `users/<id>/mixes` with an HTTP error** (asked once per sign-in). New Releases are the favorite artists' albums of the last 180 days (first 20 artists, newest first, at most 50).
709. **Settings › TIDAL credentials:** "Import Client File…" or pasted JSON; the four fields only under "Show Details". The tab appears only with the switch on; turning the switch on opens it, and the login sheet when there are credentials and no session.
710. **"Add downloads folder to the library" adds the folder when the first download is queued** (or when the setting is turned on), not at launch, so turning TIDAL on doesn't create `~/Music/Vespertine/TIDAL` by itself. Turning the setting off leaves an added folder in the library.
711. **Remove Download moves the file to the Trash** and the song streams again.
712. **Switching TIDAL off pauses downloads** (the track being written stops and goes back to the queue, leaving no file) and unregisters the stream reader; switching on resumes.
