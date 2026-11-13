# UPnP / OpenHome renderer output (sub-project 4): design

Status: approved by delegation (owner away; decisions logged in `docs/superpowers/DECISIONS.md` from 100).
Branch: `upnp-output`.

## Goal

Play Vespertine's queue on a network renderer (UPnP MediaRenderer, preferably OpenHome) such as moOde
(upmpdcli + MPD), from any source the engine can play (local files today, TIDAL items later), with honest badges:

- **Bit-perfect pass-through.** No EQ, room correction, digital volume or ReplayGain: Vespertine's HTTP server serves the
  *original file bytes* (Range supported) and the renderer pulls them. Badge: `BIT-PERFECT · 24/192 SENT`.
- **Processed.** Something changes the samples: Vespertine decodes, runs its own render chain (room correction, EQ, gain,
  dither to 24 bits), encodes **24-bit FLAC at the source rate** and serves that. Badge: `PROCESSED · EQ` (etc.), and the
  signal path says it is lossless after processing.

Vespertine's queue stays authoritative. The renderer only ever holds *current + next*.

## Non-goals (this sub-project)

- AirPlay (stays macOS's route), Chromecast, Roon, UPnP *server* (ContentDirectory) functions.
- GENA eventing (polling is used; see "Status").
- Crossfades/transitions on a renderer (each song is its own stream; transitions are off for renderers).
- Spatial Audio, downmix, DoP/bitstream to a renderer.

## Architecture

```
                      ┌────────────────────────────── VespertineUPnP (new target) ──────────────────────────────┐
App (PlayerController)│ RendererDiscovery ── SSDPSearcher (UDP) ── DeviceDescription/SCPD parse ── GetProtocolInfo│
  backend switch ────▶│ RendererPlayback (engine-shaped façade: play/pause/resume/seek/stop/queueChanged/snapshot) │
                      │    ├── RendererTransport: OpenHomeTransport | AVTransportControl   (SOAPClient)            │
                      │    ├── MediaServer (HTTPServer on NWListener): /media/<token>  original bytes or FLAC      │
                      │    └── ProcessedStream: NetworkRender (VespertineAudio) → FLACStreamWriter (SFBAudioEngine)│
                      └──────────────────────────────────────────────────────────────────────────────────────────┘
```

`VespertineUPnP` depends on `VespertineAudio` (PlayableItem, EngineSnapshot, EngineEvent, SignalPath, SourceOpener) and
`SFBAudioEngine` (FLAC encoder). It is a library product linked by the app. `VespertineAudio` never imports it.

### Why a separate façade, not a PlaybackEngine output

`PlaybackEngine` is built around a Core Audio device clock (ring → I/O proc). A renderer has its own clock, pulls the
file itself and reports position over SOAP. Pass-through mode doesn't decode at all. So the renderer gets an
engine-shaped object, `RendererPlayback`, that publishes the same `EngineSnapshot` and `EngineEvent`s the app already
consumes; `PlayerController` sends commands to whichever backend the chosen output needs. Processed mode reuses the
engine's own render pieces offline (the same path `GoldenRender` tests: decoder → `Decoding.convertChunk` → ring →
`nrt_context_render_interleaved` with gain, EQ, room correction and TPDF dither), wrapped as `NetworkRender` inside
`VespertineAudio` so no internals become public.

## Components

### SSDP discovery (`SSDP.swift`, `SSDPSearcher`)

- M-SEARCH (`MAN: "ssdp:discover"`, `MX: 2`) to `239.255.255.250:1900` for `urn:schemas-upnp-org:device:MediaRenderer:1`
  and `urn:av-openhome-org:service:Product:1` from a BSD UDP socket on an ephemeral port; unicast replies are collected
  for `MX + 1` s. The target address is injectable: tests send to a fake responder on `127.0.0.1`.
- Replies parsed by `SSDPResponse.parse` (status line `HTTP/1.1 200 OK`, case-insensitive headers, `LOCATION`, `ST`,
  `USN`, `CACHE-CONTROL max-age`). The UDN is the `uuid:…` part of `USN` before `::`.
- `RendererDiscovery` searches at start, when the output picker opens (`refresh()`), and every 5 minutes. Replies are
  merged by UDN; a renderer missing from 3 consecutive searches, or whose description fails twice, is dropped. NOTIFY
  listening (multicast join on port 1900) is left out: it needs `SO_REUSEPORT` on 1900 shared with mDNSResponder-like
  daemons and buys little over a refresh when the picker opens.

### Description and capability (`DeviceDescription.swift`, `SCPD.swift`, `ProtocolInfo.swift`)

- `DeviceDescription.parse(data:location:)` with `XMLParser`: `friendlyName`, `manufacturer`, `modelName`,
  `modelNumber`, `modelDescription`, `UDN`, and every `<service>` in the device and its embedded devices
  (`serviceType`, `serviceId`, `controlURL`, `eventSubURL`, `SCPDURL`) resolved against `URLBase` or the location.
- `ServiceDescription.parse(data:)` (SCPD): the action names. Used for `SetNextAVTransportURI` (AV gapless) and to
  confirm OpenHome Playlist `Insert`/`DeleteId`/`SeekId`/`Id`.
- `RendererKind`: `.openHome` when Product + Playlist + Time + Info are present; else `.av(gapless:)` when AVTransport +
  ConnectionManager (+ RenderingControl optional) are; else not a usable renderer.
- `ProtocolInfo.parse(sink:)` splits `ConnectionManager.GetProtocolInfo`'s `Sink` (comma list of
  `protocol:network:contentFormat:additionalInfo`). `RendererCapabilities` keeps the http-get MIME types (normalised,
  `audio/x-flac` = `audio/flac`, `audio/wav` = `audio/x-wav` = `audio/wave`), any `rate=`/`channels=` limits on
  `audio/L16`/`audio/L24` and DLNA profile names. Max format = the highest stated rate/depth; **when the renderer states
  none (upmpdcli, most), it is "not stated"**, never assumed.
- `RendererCapabilities.check(source:mime:)` → `[CapabilityWarning]`: MIME not accepted (pass-through then falls back
  to FLAC processed, or fails if FLAC isn't accepted either), rate above the stated maximum, more channels than stated.
  Warnings are shown, never silently "fixed" by resampling (out of scope; logged decision).

### SOAP (`SOAP.swift`)

- `SOAPClient.call(service:action:arguments:) async throws -> [String: String]`: POST to the control URL,
  `Content-Type: text/xml; charset="utf-8"`, `SOAPACTION: "<serviceType>#<action>"`, envelope with ordered, XML-escaped
  arguments. A 500 with `<UPnPError>` becomes `UPnPError.fault(code, description)`; other statuses
  `UPnPError.http(status)`; timeouts 5 s (`UPnPError.timeout`). Response arguments are parsed from the
  `<u:actionResponse>` element's children.
- `DIDLLite.item(...)`: DIDL-Lite metadata (`dc:title`, `upnp:artist`, `upnp:album`, `upnp:albumArtURI`,
  `upnp:class object.item.audioItem.musicTrack`, `<res protocolInfo duration size sampleFrequency bitsPerSample
  nrAudioChannels>`), XML-escaped, then escaped again as an argument value.

### Transport control (`RendererTransport` protocol)

```swift
protocol RendererTransport: Sendable {
    var gapless: Bool { get }                                   // renderer joins current → next itself
    func prepare() async throws                                  // OH: select the Playlist source; AV: nothing
    func load(current: RendererTrack, next: RendererTrack?) async throws   // replaces everything, starts playing
    func replaceNext(_ next: RendererTrack?) async throws        // queue edit / skip planning
    func play() async throws; func pause() async throws; func stop() async throws
    func seek(to seconds: TimeInterval) async throws
    func status() async throws -> RendererStatus                 // state, position, duration, which track (by URI)
}
```

- **OpenHome** (`OpenHomeTransport`): `Product.SourceXml`/`SetSourceIndex` to the Playlist source if it isn't current;
  `Playlist.DeleteAll`, `Insert(AfterId, Uri, Metadata) → NewId` twice, `SeekId(current)` and `Play`. Status:
  `Playlist.Id`, `Playlist.TransportState`, `Time.Time` (`Seconds`, `Duration`). When `Id` becomes the next's id, the
  renderer has moved on: the old id is deleted and the following track inserted after the new current. `replaceNext`:
  `DeleteId(next)` then `Insert(current, …)`. Gapless: OpenHome playlists play through, so `gapless = true` (the
  renderer may still have gaps of its own; the badge never promises a gapless *DAC*).
- **UPnP AV** (`AVTransportControl`): `SetAVTransportURI` + `Play(Speed=1)`, `SetNextAVTransportURI` when the SCPD has
  it (`gapless = true`), `Pause`, `Stop`, `Seek(Unit=REL_TIME, Target=H:MM:SS.mmm)`, `GetPositionInfo` (`TrackURI`,
  `RelTime`, `TrackDuration`), `GetTransportInfo` (`CurrentTransportState`). Without SetNext, the next track is set when
  the current one ends (state `STOPPED`/`NO_MEDIA_PRESENT` after playing, or position within 1 s of the end), and the
  UI says **"Gapless: not guaranteed on this renderer"**.

### Status (polling)

`RendererPlayback` polls `status()` every 500 ms while playing (2 s paused) and interpolates position in between
for the 15 Hz UI poll. GENA is not used in v1: it needs a callback HTTP endpoint per subscription, renewals, and
OpenHome's LastChange-less property sets; polling two cheap actions is reliable on every renderer and good enough
for a 0.5 s position. (Decision 104.)

### Media server (`HTTPServer.swift`, `MediaServer.swift`)

- `HTTPServer`: `NWListener` on an ephemeral port, all interfaces, one request per connection (`Connection: close`),
  64 KiB header limit, request parsing (`HTTPRequest`: method, path, query, headers), response writing with bodies
  `.data(Data)`, `.file(URL, ByteRange?)` (read in 256 KiB chunks, sent with flow control by awaiting each send) and
  `.growingFile(GrowingFile)` (processed FLAC: bytes are sent as they are written; the response is close-delimited).
  Also used by the test fake renderer.
- `MediaServer.register(_ resource: MediaResource) -> URL` returns `http://<local address>:<port>/media/<token>.<ext>`
  where `token` is a random 128-bit hex string; nothing else is served (no paths, no directory listing). The local
  address is the one the OS routes to the renderer (UDP `connect` + `getsockname` toward the renderer's host).
- GET and HEAD. `Range: bytes=a-b | a- | -n` → `206` with `Content-Range`; unsatisfiable → `416` with
  `Content-Range: bytes */size`; multiple ranges → whole file (`200`). Headers: `Content-Type`, `Content-Length`,
  `Accept-Ranges: bytes`, `transferMode.dlna.org: Streaming`, `contentFeatures.dlna.org: DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000`
  (`OP=00` and no `Accept-Ranges` for a growing file).
- Resources are released when they are neither current nor next (with 30 s grace, as renderers re-request).

### Mode decision (`RendererMode.decide`)

Pass-through when **all** hold: no EQ for the renderer, no room correction, volume locked (no digital volume),
ReplayGain off or 0 dB for the item, the item is a whole plain file (no CUE region, SACD area, DVD stream, audio
stream index), the resolved URL is a local `file:` URL, and the renderer accepts the file's MIME type. Otherwise
processed, with reasons (`.equalizer`, `.roomCorrection`, `.volume`, `.replayGain`, `.format(String)`) that name the
badge: `PROCESSED · EQ`, `PROCESSED · ROOM CORRECTION`, `PROCESSED · VOLUME`, `PROCESSED · REPLAYGAIN`,
`PROCESSED · FLAC` (only the format forced it). Toggling any of these mid-song restarts the stream at the current
position (new token, `load(current:next:)` + seek in the stream itself: the processed stream starts at that frame).

### Processed pipeline (`NetworkRender` in VespertineAudio, `ProcessedStream` in VespertineUPnP)

- `NetworkRender(item:url:settings:)` opens the item with `SourceOpener.probe`/`decoder(for:plan:item:)`, plans PCM at
  the source rate (`FormatPlanner` with a virtual 2-…-8 channel device at the source rate, 24-bit integer physical
  format; DSD becomes PCM as the planner does for DSD→PCM), creates the engine's `Decoding`, a ring and render context,
  installs digital volume (`nrt_context_set_gain` with 24-bit dither), EQ (`EQPreset.sections`) and room correction
  (`RoomCorrectionPlayback.install`/`installFilters`), seeks to `startFrame`, and yields interleaved Int32 frames with the
  24-bit sample in the low 24 bits via `next(maxFrames:)`.
- `ProcessedStream` writes those frames through SFBAudioEngine's FLAC encoder (`AudioEncoder`, `.flac`, compression 5)
  to a temp file (`Caches/UPnP/<token>.flac`) on a utility thread, faster than real time; `GrowingFile` lets the HTTP
  response follow the writer. The FLAC STREAMINFO is rewritten at close (total samples, MD5); a renderer that started
  reading earlier saw the placeholder, which FLAC allows for streams.
- 24-bit at the source rate: the render chain's output is dithered to 24 bits, so the FLAC is lossless with respect
  to what Vespertine's chain produced.

### Engine integration: `RendererPlayback`

- `init(renderer: RendererDevice, transport: RendererTransport, server: MediaServer)`; properties like the engine's:
  `nextItemProvider`, `urlResolver`, `eventHandler`, `metadataProvider (PlayableItem) -> RendererTrackInfo?`,
  `settings: RendererSettings` (eq, room, digitalVolumeDB, renderer name).
- `play(item)`, `pause()`, `resume()`, `seek(to:)`, `stop()`, `queueChanged()`, `update(settings:)`; `snapshot:
  EngineSnapshot` (state, item, position, duration, signalPath with `renderer` stage, `outputDevice` nil).
- Events: `.trackStarted(item)` when the renderer reports the item playing (not when loaded), `.queueEnded`,
  `.failed(item, message)` (SOAP fault, 404 from the renderer, unsupported format), `.deviceLost(name)` after 3 failed
  polls in a row (renderer gone; playback stops, the queue keeps its place).
- Work runs on an actor; commands are serialized; the last command wins for rapid skips.

### Signal path and badges (VespertineAudio)

- `DeviceProfile.Kind.networkRenderer`, `DeviceProfile.networkRenderer(protocolName:)`: tag `UPNP` / `OPENHOME`,
  symbol `hifireceiver`, `canBeBitPerfect: false` (Vespertine can't read back what the renderer's DAC gets).
- `SignalPath.renderer: RendererStage?` (`name`, `protocolName`, `processing: [RendererStage.Processing]`,
  `sentCodec`, `sentSampleRate`, `sentBitDepth`, `sentChannels`, `gapless`, `warnings`). When set:
  - `isBitPerfect` is **false** (it is the DAC-level claim, which a renderer path can't make; harness rules unchanged).
  - `isUntouched` (new) is true for pass-through: the UI's brass styling uses `isUntouched` (= `isBitPerfect` for
    local devices).
  - `statusLine` is `BIT-PERFECT · 24/192 SENT` (pass-through) or `PROCESSED · EQ` / … (processed). It never equals
    plain `BIT-PERFECT`, so nothing reads it as DAC-verified.
- The inspector's signal path lists: source, "Sent as original file bytes (FLAC 24/192)" or "Decoded, EQ …, encoded
  as 24-bit FLAC at 192 kHz (lossless after processing)", renderer (protocol, gapless), and the note "What the renderer
  does with it (resampling, volume, ReplayGain) can't be seen from here."

### UI (App)

- **Picker.** A "Network players" section under the Core Audio devices in `DevicePicker`, same `deviceRow` look
  (symbol `hifireceiver`, detail `OPENHOME · GAPLESS` / `UPNP AV · GAPLESS NOT GUARANTEED`), shown when at least one is
  found; a "Searching…" line while the first search runs. UID `upnp:<UDN>` stored as the chosen output; the
  `OutputIdentity` keeps its name for "not found" messages.
- **Chip.** Renderer name; detail `24/192 · SENT` or `24/192 · PROCESSED`; dot brass for `isUntouched`.
- **Details** (`RendererDetails`, in the picker under the list like `DeviceSettings`): model, manufacturer, address,
  services (OpenHome Product/Playlist/Time/Info or AVTransport/RenderingControl/ConnectionManager), gapless support,
  max format ("not stated by the renderer" when absent), accepted formats, capability warnings for the current song,
  and the generic advice: turn off resampling on the renderer, use hardware or no software volume there, turn off
  ReplayGain there, (MPD-based) set its mixer to "hardware" or "none" — worded for any renderer, MPD named as an
  example only. EQ and room correction choices for the renderer reuse `EqualizerChoice`/`RoomCorrectionChoice` keyed
  by the renderer UID.
- **Volume.** In pass-through the volume control shows a lock and `100% · LOCKED` in brass; the renderer's own volume
  is never touched. Clicking the lock opens a popover: "Volume in Vespertine: moving it decodes and re-encodes (lossless
  24-bit FLAC), so the stream is no longer the original file." with an "Unlock volume" button. Unlocked, a copper `DIG`
  slider like the app volume sets digital volume (processed); the lock button re-locks at 100% and returns to
  pass-through. Volume keys follow the same route (`.software` when unlocked, `.fixed` note when locked).

### Errors

- Renderer unreachable at selection: picker row dimmed "NOT RESPONDING"; play reports "<name> isn't answering."
- SOAP fault on load: `.failed(item, "<name> refused the song (UPnP error 714: Illegal MIME-type)")`; the queue moves
  on as for a file that won't play.
- MIME not accepted: processed FLAC; FLAC not accepted either: fail with "<name> doesn't accept FLAC or <type>".
- Media server can't bind: the output is unavailable with the reason.
- Renderer stops on its own (someone pressed stop on it): state becomes stopped; Vespertine doesn't fight it.

### Testing (no real renderer, no network beyond 127.0.0.1)

- Pure parsers: SSDP reply, description (moOde/upmpdcli-like and AV-only fixtures written for the tests), SCPD,
  ProtocolInfo, SOAP envelope/fault, DIDL escaping, Range parsing, mode decision, badges.
- `HTTPServer`/`MediaServer`: real sockets on 127.0.0.1 with `URLSession`; byte-exact full, ranged, suffix, open-ended,
  416, HEAD, unknown token 404, growing file.
- `FakeRenderer` (test support): serves description + SCPDs, implements OpenHome Playlist/Time/Info/Product and AV
  actions as a small state machine, records SOAP calls, and *fetches the media URL it is given* to check the bytes
  equal the source file. Tests drive `RendererPlayback` through it: play, auto-advance to next, skip, reorder
  (replaceNext), pause/resume/seek, queue end, renderer gone, AV without SetNext.
- SSDP: `SSDPSearcher` against a fake UDP responder on 127.0.0.1.
- Processed: `NetworkRender` at unity gain with no EQ reproduces the source's samples exactly (24-bit source);
  with −6 dB gain within dither; the served FLAC decodes (SFBAudioEngine) to the rendered samples exactly.
- Badges: renderer pass-through never yields `isBitPerfect` or plain `BIT-PERFECT`; processed reasons name the badge.
  The verification harness (`verification/harness`) builds `SignalPath` without a renderer stage and is unaffected.
