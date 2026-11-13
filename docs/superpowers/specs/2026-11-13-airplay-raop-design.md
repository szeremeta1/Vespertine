# AirPlay phase 1 (RAOP sender, ALAC 16/44.1): design

Status: approved by delegation (owner away; decisions logged in `docs/superpowers/DECISIONS.md` from 600).
Branch: `airplay-raop` (on the integration branch with the UPnP output merged).
Requirements: `docs/superpowers/research/2026-11-13-airplay-study.md` §1, §4, §5, §6.1 phase 1; decisions 500–501.

## Goal

Play Vespertine's queue on AirPlay 1 (RAOP) receivers (shairport-sync/moOde, AirPort Express, most third-party AirPlay
speakers and AVRs) as a new output beside "Network players", sending **ALAC 16-bit / 44.1 kHz stereo** that Vespertine
encodes itself, with honest badges:

- **`BIT-PERFECT · 16/44.1 SENT`**: a 16-bit / 44.1 kHz PCM source (mono or stereo) with no EQ, room correction, digital
  volume or ReplayGain. The frames sent are the decoded source samples, unchanged (tested end to end through a fake
  receiver that decodes the ALAC it got).
- **`CONVERTED · 16/44.1 SENT`** for everything else, with the steps named (RESAMPLED, DITHERED, DOWNMIX, DSD→PCM, EQ,
  ROOM CORRECTION, VOLUME, REPLAYGAIN) in the signal path and as small badges.
- **`LOSSY SOURCE · 16/44.1 SENT`** for AAC/MP3/Opus sources (decoded, requantised; never brass).

`SignalPath.isBitPerfect` stays **false** on every AirPlay path: the receiver follows this Mac's clock by adding or
dropping frames and may apply its own volume. The last step of the signal path says "not verified".

## Non-goals (phase 1)

- AirPlay 2 (pairing, PTP, buffered 24/48), HomePod/Apple TV support, FairPlay (never), multi-room grouping.
- Password-protected receivers and Apple TV "device verification" PINs (listed, not selectable).
- Artwork over DAAP (title/artist/album and progress are sent).
- Phase 0 (measuring the macOS Core Audio AirPlay route on real hardware): the owner's, needs the moOde box.
- macOS's own AirPlay Core Audio devices: unchanged, still listed as Core Audio outputs.

## Architecture

```
                     ┌──────────────────────── VespertineAirPlay (new target) ─────────────────────────┐
App (PlayerController│ AirPlayDiscovery ── BonjourBrowsing (NWBrowser _raop._tcp + _airplay._tcp) ── RAOPRecord │
  NetworkPlayback) ─▶│ AirPlayPlayback (engine-shaped façade, NetworkPlayback)                                    │
                     │    ├── AirPlayFrames: NetworkRender(target 44.1/16/2) → Int16 frames, TPDF where needed     │
                     │    ├── Pacer thread: 352 frames / 7.98 ms, gapless across songs, track boundaries            │
                     │    └── RAOPSession: RTSPClient (NWConnection TCP) + UDP audio/control/timing (BSD sockets)   │
                     │          ALACEncoder (AudioConverter) · RAOPCrypto (RSA-OAEP + AES-128-CBC) · DMAP           │
                     └──────────────────────────────────────────────────────────────────────────────────────────────┘
```

`VespertineAirPlay` depends on `VespertineAudio` (PlayableItem, EngineSnapshot/Event, SignalPath, NetworkRender) and
`VespertineUPnP` (`RendererSettings`, `RendererTrackInfo`, and the new `NetworkPlayback` protocol). Neither of those
imports it. The app links it as a library product.

### NetworkPlayback (VespertineUPnP)

`PlayerController` today holds a concrete `RendererPlayback`. It becomes `any NetworkPlayback`:

```swift
public protocol NetworkPlayback: AnyObject, Sendable {
    var outputName: String { get }
    var nextItemProvider: (@Sendable (PlayableItem) -> PlayableItem?)? { get set }
    var urlResolver: (@Sendable (PlayableItem) -> URL)? { get set }
    var metadataProvider: (@Sendable (PlayableItem) -> RendererTrackInfo?)? { get set }
    var eventHandler: (@Sendable @MainActor (EngineEvent) -> Void)? { get set }
    var snapshot: EngineSnapshot { get }
    func play(_ item: PlayableItem, at seconds: TimeInterval)
    func pause(); func resume(); func seek(to seconds: TimeInterval); func stop()
    func queueChanged()
    func shutdown()
}
```

`RendererPlayback` conforms unchanged. The "chosen output isn't answering" logic (decision 119), the first-search grace,
carrying a song over at its position, and the event handling are shared as they are.

### Discovery (`RAOPRecord.swift`, `AirPlayDiscovery.swift`)

- `BonjourBrowsing` protocol (`start(types:onChange:)`, `stop()`); `NWBonjourBrowser` implements it with one
  `NWBrowser(for: .bonjourWithTXTRecord(type:domain: "local."))` per type. Tests inject a fake.
- `RAOPRecord.parse(serviceName:txt:)`: the service name is `<12 hex MAC>@<Name>`; TXT keys `et` (encryption types),
  `cn` (codecs), `sr`, `ss`, `ch`, `am` (model), `pk`, `tp` (transports), `vn`, `vs`, `md` (metadata types), `pw`, `sv`,
  `da`. `_airplay._tcp` records give `deviceid`, `model`, `features`, `pk`.
- `AirPlayDevice`: `id` (MAC, upper-case hex without colons), `name`, `model`, `endpoint` (Bonjour service), the record,
  and `support`:
  - `.supported(encryption: .none | .rsa)`: `et` has 0 (preferred) or 1; `cn` has 1 or is absent; `tp` has UDP or is
    absent; `ss`/`sr`/`ch` absent or 16/44100/2; `pw` not true.
  - `.unsupported(reason)`: "AirPlay 2 only — not supported yet" (only `_airplay._tcp`, or `et` without 0/1),
    "Needs a password — not supported yet" (`pw=true`), "Format not supported" (other ss/sr/ch/codecs).
- Records from both types are merged by device id. This Mac's own AirPlay receiver is left out (name equals the
  computer name). UID stored as the chosen output: `raop:<id>`.
- `AirPlayService` (like `RendererService`): `want(_:)`/`settled()`/`setEnabled(_:)` applied in order. Off: no browser,
  no sockets. The browser starts only when the service is enabled.

### RTSP (`RTSP.swift`)

- `RTSPMessage` encodes requests (`<METHOD> <url> RTSP/1.0`, `CSeq`, `User-Agent: Vespertine/1`, `Client-Instance`,
  `DACP-ID`, `Active-Remote`, `Session` once known, `Content-Type`/`Content-Length`) and parses responses (status line,
  case-insensitive headers, body by Content-Length). Same parser serves the test fake (requests).
- `RTSPClient` (actor) over one `NWConnection` (TCP, IPv4, 5 s timeouts). After it is ready it knows the receiver's
  IPv4 address and the local one (for SDP and UDP).
- Session URL `rtsp://<local ip>/<session id>`.

### Session (`RAOPSession.swift`)

1. `OPTIONS *` (with `Apple-Challenge` when RSA; the answer is not verified).
2. `ANNOUNCE` SDP:
   ```
   v=0 / o=iTunes <sid> 0 IN IP4 <local> / s=iTunes / c=IN IP4 <receiver> / t=0 0
   m=audio 0 RTP/AVP 96 / a=rtpmap:96 AppleLossless / a=fmtp:96 352 0 16 40 10 14 2 255 0 0 44100
   [a=rsaaeskey:<base64 RSA-OAEP(aes key)> / a=aesiv:<base64 iv>]   (no padding '=')
   ```
3. `SETUP` with `Transport: RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;control_port=<c>;timing_port=<t>`; the
   reply's `Transport` gives `server_port`, `control_port`, `timing_port`; `Session` is kept.
4. `RECORD` with `Range: npt=0-` and `RTP-Info: seq=<s>;rtptime=<t>`.
5. `SET_PARAMETER` `text/parameters` `volume: <dB>` (−30…0, −144 mute), `progress: <start>/<now>/<end>` when `md` has 2;
   `application/x-dmap-tagged` DMAP `mlit{minm,asar,asal}` with `RTP-Info: rtptime=` when `md` has 0.
6. `FLUSH` with `RTP-Info: seq=<next>;rtptime=<next>` (pause, seek, stop).
7. `TEARDOWN` on shutdown, output change or when stopped.
8. `OPTIONS` keep-alive every 25 s.

UDP (BSD sockets bound to ephemeral ports, one reader thread):

- **Audio** to `server_port`: 12-byte RTP header `0x80, 0x60` (`0xE0` on the first packet after RECORD/FLUSH), seq,
  rtptime, SSRC; payload one ALAC packet of 352 frames, AES-128-CBC encrypted (whole 16-byte blocks, IV restarting each
  packet, the tail in clear) when RSA.
- **Sync** to `control_port`, about once a second and on start: `0x90`/`0x80`, `0xD4`, `0x0007`, `rtptime − 77175`
  (2 s latency, receivers add 11025), NTP now, `rtptime now`.
- **Timing**: answers `0x80 0xD2` requests with `0x80 0xD3`, the request's transmit time as reference, receive and
  transmit times from the same NTP clock (mach continuous time + an epoch offset).
- **Retransmit**: `0x80 0xD5` requests (seq, count) are answered from a 1024-packet backlog as `0x80 0xD6 0x00 0x01`
  + the original packet.

### ALAC (`ALAC.swift`)

- `ALACEncoder`: `AudioConverter` from 16-bit interleaved stereo LPCM to `kAudioFormatAppleLossless`
  (`kAppleLosslessFormatFlag_16BitSourceData`, 352 frames per packet); one packet per call. Its magic cookie must match
  the SDP fmtp (352, 16, 40/10/14, 2 ch, 44100) or the encoder isn't used.
- `ALACVerbatim.encode`: the uncompressed ALAC frame (OwnTone's form), used when the converter can't be made.
- `ALACDecoder`: `AudioConverter` the other way, with a cookie built from the fmtp; used by the fake receiver and tests.
- Tests: encode → decode equals the input exactly (random, silence, full-scale, one packet of each kind), both encoders.

### Crypto (`RAOPCrypto.swift`)

- AES-128-CBC via CommonCrypto (no padding, partial last block untouched).
- RSA-OAEP (SHA-1) via `SecKeyCreateEncryptedData` with the AirPort Express public key (modulus as published in libraop
  and OwnTone, exponent 65537), built as a PKCS#1 DER. The key is injectable: tests use a generated key pair so the fake
  receiver can unwrap the AES key.

### Frames (`AirPlayFrames.swift`; `NetworkRender` gets a target)

- `NetworkRender(item:url:…, target: .airPlay)`: the planner sees a virtual 2-channel device at 44100 Hz only, 16-bit
  integer; SRC (AVAudioConverter mastering, max quality), downmix and DSD→PCM are the engine's own; the chain's TPDF dither
  uses 16 bits as word length when gain, EQ or room correction process the samples.
- `AirPlayFrames` turns its float frames into interleaved Int16 stereo:
  - **untouched** source (PCM, 44100 Hz, 16-bit, 1–2 channels, no effects, no ReplayGain): plain rounding, which is
    exact (each float is a 16-bit value); mono is copied to both channels.
  - **converted**: TPDF dither at the 16-bit LSB before rounding, unless the chain already dithered at 16 bits.
- `AirPlayConversion.decide(source:settings:replayGainDB:)` → the steps; `[]` means untouched.

### Playback (`AirPlayPlayback.swift`)

- One RTP stream for the queue: songs follow one another frame-exactly (gapless). The next song's `AirPlayFrames` is
  opened when the current one runs out; a track boundary is the rtptime of its first frame. `trackStarted` fires when the
  clock passes `boundary + latency` (when it is heard).
- **Pacer**: a thread sends packet *n* when `now ≥ start + n·352/44100` (with a 250 ms lead), the RTP timeline starting
  at a random rtptime. Position = `(clockRTP − latency − songStartRTP) / 44100 + songOffset`.
- Commands: `play(item, at:)` connects if needed (OPTIONS → … → RECORD, volume), FLUSHes when already streaming and
  starts the item at the position. `pause()` FLUSHes and stops sending; the position stays where it was heard.
  `resume()` restarts the render at that position. `seek` = FLUSH + restart at the position. `stop()` FLUSH + TEARDOWN.
  `queueChanged()` drops a prepared next song that is no longer next. Settings change (EQ, digital volume) restarts the
  current song at its position (300 ms debounce, as renderers); receiver volume changes only send `SET_PARAMETER`.
- Errors: no connection, refused ANNOUNCE/SETUP/RECORD (453 = busy with another sender) → `notice("<name> isn't
  answering." / "<name> is busy…")`, state stopped. A failing RTSP connection mid-song → `deviceLost(name)`. Never falls
  back to a Core Audio device.

### Signal path and badges (VespertineAudio)

- `SignalPath.RendererStage` gains `transport: .pull | .airPlay` and `Processing` cases `.resampled`, `.dithered`,
  `.downmix`, `.dsdToPCM` (in that order after the effect reasons). With `.airPlay`, `badge` is
  `BIT-PERFECT · 16/44.1 SENT` / `LOSSY SOURCE · 16/44.1 SENT` / `CONVERTED · 16/44.1 SENT`; `stepBadges` names the steps.
- `DeviceProfile.networkRenderer(protocolName: "AirPlay")`: tag `AIRPLAY`, symbol `airplay.audio`, `canBeBitPerfect`
  false, and a note about clock and receiver volume.
- Warnings in the stage: "The receiver follows this Mac's clock by adding or dropping samples…" always; "The receiver
  lowers the volume itself (−x dB)" when receiver volume is below 0 dB.

### UI (App)

- **Settings › Playback**: "AirPlay Players (beta)" switch with its caption, off by default (`airPlayPlayersFeature`).
  Off: no `AirPlayOutputModel`, nothing browsed, no socket, nothing new in the output list.
- **Output list**: an "AirPlay players" section after "Network players", same `deviceRow`, symbol `airplay.audio`,
  detail `AIRPLAY · ALAC 16/44.1` (with ` · ENCRYPTED` for RSA); unsupported devices dimmed and not selectable with
  `AIRPLAY 2 ONLY · NOT SUPPORTED YET` etc. Chosen and gone: `NOT RESPONDING`, dimmed, as network players.
- **Details** (`AirPlayDetails`): model, address, encryption, codecs, metadata, version; what is sent ("ALAC 16-bit /
  44.1 kHz"); the equalizer choice; advice (shairport-sync: `ignore_volume_control` or a hardware mixer,
  `disable_synchronization`/pipe backend to check, read `sdsc`/`odsc`).
- **Volume**: receiver volume by default (slider, `AIR` label, lock glyph closed: Vespertine leaves the samples alone).
  The popover offers "Use Vespertine's Volume" (digital, the song is CONVERTED · VOLUME; receiver at 0 dB) and back.
  Volume keys follow the mode.
- **Chip**: device name, `16/44.1 · SENT` or `16/44.1 · CONVERTED`, `AIRPLAY · IDLE` when nothing plays.

### Testing (no hardware, nothing beyond 127.0.0.1)

- Pure: TXT/record parsing and support classes; SDP; RTSP encode/parse; RTP/sync/timing/resend packets; DMAP; volume
  mapping; conversion decision and badges; AES vectors (FIPS-197/SP 800-38A) and RSA wrap with a test key.
- ALAC round trips (AudioConverter and verbatim).
- `AirPlayFrames`: a 16/44.1 stereo and mono WAV come out sample-exact; 24/44.1 dithered within 1 LSB; 48 kHz resampled
  (length ≈ ×44.1/48).
- `FakeRAOPReceiver` (test support): RTSP server on 127.0.0.1, UDP server/control/timing ports, records the requests,
  sends timing requests, decrypts (test key), decodes ALAC, can drop a packet and ask for it again. End to end: play a
  16/44.1 file through `AirPlayPlayback` → decoded frames equal the file's samples exactly, encrypted and not; two songs
  gapless; pause/resume/seek send FLUSH; volume SET_PARAMETER; TEARDOWN at shutdown; a closed port → "isn't answering".
- Switch: off by default, nothing browsed; on starts the browser; off stops it (package and app).
