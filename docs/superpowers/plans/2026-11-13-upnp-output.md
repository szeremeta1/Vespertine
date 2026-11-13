# UPnP / OpenHome output: implementation plan

Spec: `docs/superpowers/specs/2026-11-13-upnp-output-design.md`. TDD: each task writes its failing tests first
(Swift Testing, `@Suite`/`@Test`/`#expect`), then the code, then `swift test --filter <Suite>`, then a commit.
All new files carry the repo header (`// Vespertine: …` + `// SPDX-License-Identifier: GPL-3.0-or-later`).

Paths: `K = Packages/VespertineKit`, sources `K/Sources/VespertineUPnP`, tests `K/Tests/VespertineUPnPTests`.

## Task 1: target, SSDP parsing and search

- `Package.swift`: product + target `VespertineUPnP` (deps `VespertineAudio`, `SFBAudioEngine`), test target
  `VespertineUPnPTests` (deps `VespertineUPnP`, `VespertineAudio`, `SFBAudioEngine`, resources `Fixtures`).
- `SSDP.swift`
  ```swift
  public struct SSDPResponse: Sendable, Hashable { public var location: URL; public var st: String; public var usn: String
      public var udn: String; public var server: String?; public var maxAge: Int?
      public static func parse(_ data: Data) -> SSDPResponse? }
  public enum SSDP { public static let multicastHost = "239.255.255.250"; public static let port: UInt16 = 1900
      public static let rendererTargets: [String]
      public static func searchMessage(target: String, mx: Int) -> Data }
  public final class SSDPSearcher: Sendable { public init(host: String = SSDP.multicastHost, port: UInt16 = SSDP.port)
      public func search(targets: [String], mx: Int, wait: TimeInterval) async -> [SSDPResponse] }
  ```
- Tests `SSDPTests`: parse upmpdcli-style reply (mixed-case headers, `max-age`), reject NOTIFY/garbage, message format,
  search against a fake UDP responder on 127.0.0.1 (dedup by USN).

## Task 2: description, SCPD, protocol info, capability check

- `DeviceDescription.swift`
  ```swift
  public struct UPnPService: Sendable, Hashable { public var type: String; public var id: String
      public var controlURL: URL; public var eventURL: URL?; public var scpdURL: URL }
  public struct DeviceDescription: Sendable, Hashable { public var udn, friendlyName, manufacturer, modelName: String
      public var modelNumber, modelDescription: String?; public var services: [UPnPService]
      public func service(_ kind: ServiceKind) -> UPnPService?
      public static func parse(_ data: Data, location: URL) throws -> DeviceDescription }
  public enum ServiceKind { case avTransport, renderingControl, connectionManager, ohProduct, ohPlaylist, ohTime, ohInfo, ohVolume
      public func matches(_ type: String) -> Bool }  // any version
  public enum RendererKind: Sendable, Hashable { case openHome; case av(gapless: Bool)
      public static func of(_ d: DeviceDescription, avActions: Set<String>?) -> RendererKind? }
  ```
- `SCPD.swift`: `public enum SCPD { public static func actions(_ data: Data) throws -> Set<String> }`
- `ProtocolInfo.swift`
  ```swift
  public struct ProtocolInfoEntry: Sendable, Hashable { public var proto, network, contentFormat, additional: String
      public var mime: String /* normalised */; public var rate: Int?; public var channels: Int? }
  public struct RendererCapabilities: Sendable, Hashable { public var entries: [ProtocolInfoEntry]
      public static func parse(sink: String) -> RendererCapabilities
      public func accepts(mime: String) -> Bool; public var maxSampleRate: Int?; public var maxChannels: Int?
      public var acceptedFormats: [String] /* short names: FLAC, WAV, … */
      public func warnings(for source: SourceFormat, sending mime: String) -> [CapabilityWarning] }
  public enum CapabilityWarning: Sendable, Hashable { case formatNotAccepted(String); case rateAboveMaximum(source: Double, max: Int)
      case channelsAboveMaximum(source: Int, max: Int); public var message: String }
  public enum MediaType { public static func mime(forExtension: String) -> String? }
  ```
- Tests `DescriptionTests` with fixtures `moode-description.xml` (OpenHome + AV), `av-only-description.xml`,
  `avtransport-scpd.xml` (with/without SetNext), protocol info strings.

## Task 3: HTTP server and media server (byte-exact Range)

- `HTTPMessage.swift`: `HTTPRequest.parse(_ data: Data) -> HTTPRequest?` (method, path, query, headers lowercased,
  body by Content-Length), `ByteRange.parse(_ header: String, size: Int64) -> ByteRangeResult` (`.whole`, `.range(ClosedRange<Int64>)`,
  `.unsatisfiable`), `HTTPResponse(status:headers:body:)` with `Body = .empty | .data(Data) | .file(URL, ClosedRange<Int64>) | .growing(GrowingFile)`.
- `HTTPServer.swift`: `public final class HTTPServer: @unchecked Sendable { public init(handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse)
  public func start() async throws -> UInt16; public func stop() }`.
- `GrowingFile.swift`: `public final class GrowingFile: Sendable { init(url:); func append(_ data: Data); func finish(); func read(from: Int64, max: Int) async -> Data? }`.
- `MediaServer.swift`: `public final class MediaServer { public init(); public func start() async throws;
  public func register(_ r: MediaResource, host: String) -> URL; public func release(_ token: String); }`,
  `public struct MediaResource { case file(URL, mime) | growing(GrowingFile, mime) }`, `LocalAddress.toward(host:) -> String?`.
- Tests `MediaServerTests`: full GET equals file; `bytes=100-199`, `bytes=1000-`, `bytes=-500`, `bytes=size-` (416),
  HEAD headers, unknown token 404, DLNA headers, growing file streamed while written.

## Task 4: SOAP, DIDL, OpenHome and AV transports with a fake renderer

- `SOAP.swift`: `SOAPClient.call(_ service: UPnPService, _ action: String, _ args: [(String, String)]) async throws -> [String: String]`,
  `SOAP.envelope(serviceType:action:args:)`, `SOAP.parseResponse(_:action:)`, `UPnPError`.
- `DIDL.swift`: `RendererTrackInfo` (title, artist, album, artworkURL, duration) + `DIDLLite.item(id:info:url:protocolInfo:size:format:)`.
- `RendererTransport.swift`: protocol (spec), `RendererTrack { id: UUID; uri: URL; metadata: String }`,
  `RendererStatus { state: .playing/.paused/.stopped/.transitioning; position; duration; currentURI: URL? }`.
- `OpenHomeTransport.swift`, `AVTransportControl.swift`.
- Test support `FakeRenderer` (in the test target): HTTPServer-based, `kind: .openHome | .av(setNext: Bool)`, records
  `calls: [(service, action, args)]`, `fetchedBytes[uri]`, `advance()` (simulate the current track ending), `fail(action:code:)`.
- Tests `TransportTests`: OH load → DeleteAll, Insert×2, SeekId, Play; status after advance; replaceNext; AV load with
  SetNext; AV without SetNext reports gapless false; SOAP fault mapping; DIDL escaping.

## Task 5: RendererPlayback (engine-shaped façade) + mode decision + signal path

- VespertineAudio: `EngineSnapshot.init()` public; `DeviceProfile.Kind.networkRenderer` + `DeviceProfile.networkRenderer(protocolName:)`;
  `SignalPath.RendererStage` + `SignalPath.renderer`, `isUntouched`; `statusLine` branch.
- `RendererMode.swift`: `RendererSettings { equalizer: EQPreset?; room: RoomCorrectionPlayback?; digitalVolumeDB: Double? }`,
  `RendererMode.decide(item:resolvedURL:settings:capabilities:) -> RendererModeDecision { passThrough(mime) | processed([Reason]) }`.
- `RendererPlayback.swift` (spec interface).
- Tests `RendererPlaybackTests` through `FakeRenderer`: trackStarted on play, bytes fetched == file, auto-advance emits
  trackStarted(next) and inserts the following, queueChanged replaces next, pause/resume/seek calls, queueEnded,
  renderer gone → deviceLost; `SignalPathRendererTests`: badges.

## Task 6: App integration (pass-through)

- `App/Sources/Models/RendererOutputModel.swift`: owns `RendererDiscovery`, `MediaServer`, the active `RendererPlayback`.
- `PlayerController`: `backend` switch (engine | renderer) for play/pause/resume/seek/stop/queueChanged/snapshot;
  switching output mid-song restarts on the new backend at the current position.
- `AppModel.selectDevice` / `plannedDevice` / `missingChosenOutput` aware of `upnp:` UIDs; `AppSettings.rendererVolumeUnlocked`.
- Build the app.

## Task 7: Views

- `App/Sources/Views/RendererViews.swift`: `RendererRows` (picker section), `RendererDetails`, `RendererVolumeControl`
  (lock), chip detail; inspector signal path rows for `renderer`.

## Task 8: Processed mode

- VespertineAudio `NetworkRender.swift` (spec); visibility of `RoomCorrectionPlayback.install*` stays internal (same module).
- VespertineUPnP `ProcessedStream.swift`: `FLACStreamWriter` (SFBAudioEngine `AudioEncoder`) + `GrowingFile`.
- `RendererPlayback` uses it when `RendererMode` says processed; settings changes mid-song restart at the position.
- Tests: `NetworkRenderTests` (unity exact, gain within dither), `ProcessedStreamTests` (FLAC decodes to the rendered
  samples; served while growing).
