# AirPlay phase 1 (RAOP): implementation plan

Spec: `docs/superpowers/specs/2026-11-13-airplay-raop-design.md`. Each task: failing test first, then code, then
`swift test --filter <Suite>` green, commit. Package commands from `Packages/VespertineKit`; `Package.resolved` restored
before each commit. The app must build at every commit.

## Task 1: target and shared protocol

- `Package.swift`: product + target `VespertineAirPlay` (deps `VespertineAudio`, `VespertineUPnP`; frameworks
  `AudioToolbox`, `Security`, `Network`), test target `VespertineAirPlayTests`.
- `VespertineUPnP/NetworkPlayback.swift`: `public protocol NetworkPlayback` (spec), `RendererPlayback: NetworkPlayback`
  (`outputName = renderer.name`).
- App: `PlayerController.renderer: (any NetworkPlayback)?`, `useRenderer(_ playback: (any NetworkPlayback)?, missing:)`.
- Test: `NetworkPlaybackTests.rendererConforms` (a `RendererPlayback` used as `any NetworkPlayback`).

## Task 2: RAOP records and support

- `RAOPRecord.parse(serviceName: String, txt: [String: String]) -> RAOPRecord?`; `AirPlayRecord.parse(txt:)`;
  `AirPlayDevice.make(raop: RAOPRecord?, airplay: AirPlayRecord?, ...) -> AirPlayDevice`;
  `AirPlayDevice.Support { case supported(Encryption), unsupported(String) }`, `Encryption { case none, rsa }`.
- Tests: moOde/shairport TXT (et=0,1 → .none), AirPort Express (et=1 → .rsa), HomePod-like (et=0,4: .none), Apple TV
  (et=0,3,5 + pw=false: .none), et=3,5 only → AirPlay 2 only, pw=true → password, ss=24 → format, `_airplay` only →
  AirPlay 2 only, MAC parsing.

## Task 3: discovery and service switch

- `BonjourBrowsing` protocol: `func start(onChange: @escaping @Sendable ([BonjourResult]) -> Void)`, `func stop()`,
  `BonjourResult { type, name, txt, endpoint: NWEndpoint? }`; `NWBonjourBrowser(types:)`.
- `AirPlayDiscovery(browser:excludedName:)`: `start/stop/isRunning/devices/onChange`; merge by id.
- `AirPlayService(discovery:)`: `want/settled/setEnabled/isEnabled`.
- Tests: off by default nothing started; on/off; merge; own Mac excluded; quick on-off-on settles on.

## Task 4: packets, clock, DMAP, SDP, RTSP messages

- `NTPClock.now() -> UInt64` (NTP 32.32), `RTPPacket.audio(seq:timestamp:ssrc:payload:first:)`,
  `RTPPacket.sync(rtpNow:latency:ntp:first:)`, `RTPPacket.timingReply(request:receive:transmit:)`,
  `RTPPacket.resendRequest(_ data) -> (seq: UInt16, count: UInt16)?`, `RTPPacket.resend(_ packet)`.
- `DMAP.item(title:artist:album:) -> Data`, `RAOPVolume.decibels(level: Double) -> Double`, `RAOPVolume.parameter`.
- `SDP.announce(sessionID:local:remote:aes:)`; `RTSPRequest`/`RTSPResponse` encode + `RTSPParser` (incremental).
- Tests: byte layouts, round trips, parse of partial input.

## Task 5: crypto

- `AESCBC.encryptPacket(_ data: inout Data, key:iv:)` / `decryptPacket`, `RSAWrap.airPortExpressKey`,
  `RSAWrap.encrypt(_ data, key: SecKey) throws -> Data`.
- Tests: SP 800-38A F.2.1 vector; tail left clear; RSA wrap/unwrap with a generated key; AirPort key is 2048-bit.

## Task 6: ALAC

- `ALACConfig` (fmtp, cookie), `ALACEncoder()` (`encode(_ frames: [Int16]) throws -> Data`, 352×2 samples),
  `ALACVerbatim.encode`, `ALACDecoder(config:)` (`decode(_ packet: Data) throws -> [Int16]`).
- Tests: round trips exact for both encoders; cookie matches fmtp.

## Task 7: target format in NetworkRender, AirPlayFrames, conversion decision

- `NetworkRender.Target { case sourceRate24, airPlay }`, `init(..., target: .sourceRate24)`; `ditherBits`, `plan`.
- `AirPlayConversion.steps(source:settings:replayGainDB:) -> [Processing]`; `AirPlayFrames(item:url:settings:startSeconds:)`
  with `next() -> [Int16]?` (352 stereo frames, last packet padded, `framesInSong`).
- `SignalPath.RendererStage.transport`, new `Processing` cases, AirPlay badges, `stepBadges`, `DeviceProfile` AirPlay.
- Tests: exact 16/44.1 stereo + mono; 24-bit dithered; 48 kHz resampled; badges; isBitPerfect false.

## Task 8: UDP and RTSP client, fake receiver

- `UDPSocket` (bind 0.0.0.0:0, `send(_:to:port:)`, `receive` on a reader thread); `RTSPClient` actor.
- Test support `FakeRAOPReceiver` (in the test target).
- Tests: RTSP request/response against the fake; timing exchange answered.

## Task 9: RAOPSession

- `RAOPSession(device:host:port:rsaKey:)`: `connect()`, `send(frames:)`, `flush()`, `setVolume(_:)`,
  `setMetadata(_:)`, `setProgress(...)`, `teardown()`; backlog + retransmit; sync; keep-alive.
- Tests (fake): handshake order and headers; ALAC decoded exactly; encrypted session decoded exactly; retransmit answered;
  volume parameter; flush; teardown.

## Task 10: AirPlayPlayback

- Façade per spec, conforms to `NetworkPlayback`.
- Tests (fake): end to end sample-exact; gapless two songs; trackStarted; pause/resume/seek FLUSH; stop TEARDOWN;
  unreachable → notice; signal path badge.

## Task 11: app

- `AppSettings.airPlayPlayersFeature`, `airPlayDigitalVolume: Set<String>`; `AirPlayOutputModel`, `AirPlaySwitch`;
  `AppModel` (chosen AirPlay device, syncEngine, missing, volume keys, selectDevice); views (Settings section, output list
  section, details, volume control, chip, inspector steps); Info.plist/project.yml Bonjour types + usage text.
- App tests: `AirPlaySwitchTests` (off by default: no model, nothing browsed; on/off), missing device never falls back.

## Task 12: decisions, verification doc, report
