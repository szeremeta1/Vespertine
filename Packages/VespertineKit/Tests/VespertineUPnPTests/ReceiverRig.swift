//
// Vespertine: what the receiver's tests are built from, all on 127.0.0.1: a music host that serves songs by byte range, the
// real engine on a simulated output as the receiver's player, and a control point that hears the receiver's events.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
@testable import VespertineAudio
@testable import VespertineUPnP

/// Waits for something that will happen, without a deadline it could miss on a busy machine. The long stop only ends a run that
/// would never end.
enum ReceiverPatience {
    static func until(giveUpAfter: TimeInterval = 90, _ condition: @Sendable () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(giveUpAfter)
        while !(await condition()) {
            if Date() > end { return await condition() }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

/// Songs made for the tests: noise, so that every frame is sound and any frame lost or added shows.
enum TestSong {
    static let rate = 96_000

    /// `frames` of stereo noise as 24-bit integers, interleaved.
    static func noise(frames: Int, seed: UInt32) -> [Int32] {
        var state = seed
        var samples = [Int32](repeating: 0, count: frames * 2)
        for index in samples.indices {
            state = state &* 1_664_525 &+ 1_013_904_223
            // Half scale, and never zero: a zero sample would read as silence.
            let value = Int32(bitPattern: state) >> 9
            samples[index] = value == 0 ? 1 : value
        }
        return samples
    }

    /// A 24-bit stereo WAV file of `samples`.
    static func wav(_ samples: [Int32], rate: Int = TestSong.rate) -> Data {
        var data = Data()
        func le32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 3
        data.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + bytes)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(2); le32(UInt32(rate)); le32(UInt32(rate * 6)); le16(6); le16(24)
        data.append(contentsOf: Array("data".utf8)); le32(UInt32(bytes))
        data.reserveCapacity(44 + bytes)
        var body = [UInt8](repeating: 0, count: bytes)
        for (index, sample) in samples.enumerated() {
            body[index * 3] = UInt8(truncatingIfNeeded: sample)
            body[index * 3 + 1] = UInt8(truncatingIfNeeded: sample >> 8)
            body[index * 3 + 2] = UInt8(truncatingIfNeeded: sample >> 16)
        }
        data.append(contentsOf: body)
        return data
    }

    /// What the output carries for `samples` when nothing touches them.
    static func floats(_ samples: [Int32]) -> [Float] { samples.map { Float($0) / 8_388_608 } }

    /// The WAV at `wav` encoded as a 24-bit FLAC, as bytes.
    static func flac(fromWAV wav: Data, in directory: URL) throws -> Data {
        let source = directory.appendingPathComponent("\(UUID().uuidString).wav")
        try wav.write(to: source)
        let reader = try AVAudioFile(forReading: source)
        let url = source.deletingPathExtension().appendingPathExtension("flac")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: reader.fileFormat.sampleRate,
                                       AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 24]
        do {
            let out = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 96_000)!
            while reader.framePosition < reader.length {
                try reader.read(into: buffer)
                try out.write(from: buffer)
            }
        }
        return try Data(contentsOf: url)
    }

    static func didl(title: String, artist: String = "Test Artist", album: String = "Test Album", url: URL, mime: String) -> String {
        DIDLLite.item(id: "1", info: RendererTrackInfo(title: title, artist: artist, album: album), url: url, mime: mime, size: nil, format: nil)
    }
}

/// A music host on 127.0.0.1: what a control app points the receiver at.
final class MusicHost: @unchecked Sendable {
    struct File {
        var data: Data
        var type: String
        /// Answers byte ranges (off: sends the whole file whatever is asked).
        var ranges = true
    }

    private let lock = NSLock()
    private var files: [String: File] = [:]
    private var redirects: [String: String] = [:]
    private var quietFrom: [String: Int64] = [:]
    private var quietReached: Set<String> = []
    private var released = false
    private var asked: [String] = []
    private var server: HTTPServer!
    private(set) var port: UInt16 = 0

    init() async throws {
        server = HTTPServer(maximumConnections: 64) { [weak self] request in await self?.handle(request) ?? .status(503) }
        port = try await server.start()
    }

    func stop() {
        lock.withLock { released = true }
        server.stop()
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func add(_ path: String, _ file: File) { lock.withLock { files[path] = file } }
    func redirect(_ path: String, to target: String) { lock.withLock { redirects[path] = target } }
    /// From byte `offset` on, `path` is asked for and nothing comes back (the stream has stopped answering).
    func goQuiet(_ path: String, from offset: Int64) { lock.withLock { quietFrom[path] = offset } }
    /// A read of `path` is waiting in the quiet part.
    func reachedQuiet(_ path: String) -> Bool { lock.withLock { quietReached.contains(path) } }
    var paths: [String] { lock.withLock { asked } }

    private func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let (file, target, quiet) = lock.withLock { () -> (File?, String?, Int64?) in
            asked.append(request.path)
            return (files[request.path], redirects[request.path], quietFrom[request.path])
        }
        if let target { return HTTPResponse(status: 302, headers: [("Location", target), ("Content-Length", "0")]) }
        guard let file else { return .status(404) }
        let size = Int64(file.data.count)
        guard file.ranges, case .range(let range) = ByteRange.parse(request.headers["range"], size: size) else {
            return HTTPResponse(status: 200, headers: [("Content-Type", file.type), ("Content-Length", "\(size)")], body: .data(file.data))
        }
        if let quiet, range.upperBound >= quiet {
            lock.withLock { _ = quietReached.insert(request.path) }
            while !lock.withLock({ released }) { try? await Task.sleep(for: .milliseconds(20)) }
            return .status(503)
        }
        let part = file.data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound) + 1)
        return HTTPResponse(status: 206, headers: [("Content-Type", file.type), ("Content-Length", "\(part.count)"), ("Accept-Ranges", "bytes"),
                                                   ("Content-Range", "bytes \(range.lowerBound)-\(range.upperBound)/\(size)")], body: .data(part))
    }
}

/// The receiver's player in the tests: the real engine, playing into a simulated output whose every sample is kept.
final class EnginePlayer: ReceiverPlayer, @unchecked Sendable {
    struct State {
        var receiver: UPnPReceiver?
        var next: ReceiverTrack?
        var volume = 0.8
        var muted = false
        var started: [UUID] = []
        var failures: [String] = []
        var ended = 0
        var apps: [ReceiverControlApp] = []
        var volumesSet: [Double] = []
    }

    let directory: URL
    let cache: NetworkPlaybackCache
    let engine: PlaybackEngine
    let outputs = Locked<[SimulatedOutput]>([])
    let state = Locked(State())

    init(noProgressLimit: TimeInterval? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("receiver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cacheDirectory = directory.appendingPathComponent("cache")
        cache = noProgressLimit.map { NetworkPlaybackCache(directory: cacheDirectory, budget: 256 << 20, chunk: 1 << 16, noProgressLimit: $0) }
            ?? NetworkPlaybackCache(directory: cacheDirectory, budget: 256 << 20, chunk: 1 << 16)
        let device = OutputDevice(id: 4343, uid: "sim-receiver", name: "Simulated output", manufacturer: "", modelUID: nil, transport: .usb,
                                  nominalSampleRate: Double(TestSong.rate),
                                  capabilities: DeviceCapabilities(sampleRates: [44_100, 48_000, 96_000], physicalFormats: [], outputChannels: 2, supportsDoP: false),
                                  hasHardwareVolume: false, isDefault: false)
        engine = PlaybackEngine()
        engine.cacheOverride = cache
        engine.outputListing = { [device] }
        let outputs = outputs
        engine.sessionFactory = { _, plan in
            let session = try OutputSession(simulating: plan, rate: plan.deviceSampleRate)
            session.simulated!.captures = true
            outputs.withLock { $0.append(session.simulated!) }
            return session
        }
        var settings = EngineSettings()
        settings.deviceUID = device.uid
        settings.exclusive = true
        engine.update(settings: settings)
        let state = state
        engine.nextItemProvider = { finished in
            state.withLock { state in
                guard let next = state.next, next.id != finished.id else { return nil }
                return next.item
            }
        }
        engine.eventHandler = { event in
            let receiver = state.withLock { state -> UPnPReceiver? in
                switch event {
                case .trackStarted(let item): state.started.append(item.id)
                case .failed(_, let message): state.failures.append(message)
                case .queueEnded: state.ended += 1
                default: break
                }
                return state.receiver
            }
            switch event {
            case .trackStarted(let item): receiver?.playerEvent(.started(item.id))
            case .failed(let item, let message): receiver?.playerEvent(.failed(item?.id, message))
            case .queueEnded: receiver?.playerEvent(.ended)
            default: break
            }
        }
    }

    deinit {
        engine.stopAndWait()
        try? FileManager.default.removeItem(at: directory)
    }

    func attach(_ receiver: UPnPReceiver) { state.withLock { $0.receiver = receiver } }

    /// Every sample that came out, in order, without the silence before the first sound and after the last.
    var heard: [Float] {
        let all = outputs.withLock { $0.flatMap(\.captured) }
        guard let first = all.firstIndex(where: { $0 != 0 }), let last = all.lastIndex(where: { $0 != 0 }) else { return [] }
        // Whole frames: a frame begins on an even index.
        return Array(all[(first - first % 2)...(last | 1)])
    }

    func receiverPlay(_ track: ReceiverTrack, next: ReceiverTrack?, from app: ReceiverControlApp) async {
        state.withLock { $0.next = next; $0.apps.append(app) }
        engine.play(track.item)
    }

    func receiverSetNext(_ track: ReceiverTrack?) async {
        state.withLock { $0.next = track }
        engine.queueChanged()
    }

    func receiverPause() async { engine.pause() }
    func receiverResume() async { engine.resume() }
    func receiverStop() async {
        state.withLock { $0.next = nil }
        engine.stop()
    }
    func receiverSeek(to seconds: TimeInterval) async { engine.seek(to: seconds) }
    func receiverPosition() async -> ReceiverPosition {
        let snapshot = engine.snapshot
        return ReceiverPosition(position: snapshot.position, duration: snapshot.duration > 0 ? snapshot.duration : nil)
    }
    func receiverVolume() async -> (level: Double, muted: Bool) { state.withLock { ($0.volume, $0.muted) } }
    func receiverSetVolume(_ level: Double) async { state.withLock { $0.volume = level; $0.volumesSet.append(level) } }
    func receiverSetMuted(_ muted: Bool) async { state.withLock { $0.muted = muted } }
}

/// The part of a control point the app's own renderer client doesn't have: it subscribes to the receiver's events and keeps
/// what they say.
final class EventListener: @unchecked Sendable {
    struct Event: Sendable { var path: String; var sid: String; var sequence: Int; var variables: [String: String] }

    private let lock = NSLock()
    private var received: [Event] = []
    private var server: HTTPServer!
    private(set) var port: UInt16 = 0

    init() async throws {
        server = HTTPServer { [weak self] request in
            guard request.method == "NOTIFY", let self else { return .status(405) }
            let variables = ReceiverEventBody.variables(inLastChange: request.body)
            self.lock.withLock {
                self.received.append(Event(path: request.path, sid: request.headers["sid"] ?? "", sequence: Int(request.headers["seq"] ?? "") ?? -1,
                                           variables: variables))
            }
            return .status(200)
        }
        port = try await server.start()
    }

    func stop() { server.stop() }

    var events: [Event] { lock.withLock { received } }
    /// Every value `variable` has been said to have, in order.
    func values(of variable: String, path: String = "/avt") -> [String] { events.filter { $0.path == path }.compactMap { $0.variables[variable] } }
    func latest(_ variable: String, path: String = "/avt") -> String? { values(of: variable, path: path).last }

    /// Waits until an event has said `variable` is `value`.
    func heard(_ variable: String, _ value: String, path: String = "/avt") async -> Bool {
        await ReceiverPatience.until { self.values(of: variable, path: path).contains(value) }
    }

    /// Subscribes `path` here to `service` of the receiver on `receiverPort`; the status and the subscription's id.
    func subscribe(_ service: ReceiverService, receiverPort: UInt16, path: String, callback: String? = nil) async throws -> (status: Int, sid: String?) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(receiverPort)\(service.eventPath)")!)
        request.httpMethod = "SUBSCRIBE"
        request.setValue(callback ?? "<http://127.0.0.1:\(port)\(path)>", forHTTPHeaderField: "CALLBACK")
        request.setValue("upnp:event", forHTTPHeaderField: "NT")
        request.setValue("Second-300", forHTTPHeaderField: "TIMEOUT")
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        return (http?.statusCode ?? 0, http?.value(forHTTPHeaderField: "SID"))
    }

    static func request(_ method: String, _ service: ReceiverService, receiverPort: UInt16, sid: String) async throws -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(receiverPort)\(service.eventPath)")!)
        request.httpMethod = method
        request.setValue(sid, forHTTPHeaderField: "SID")
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

/// A receiver with its player, its music host and a listener for its events, started and ready.
final class ReceiverScene: @unchecked Sendable {
    let host: MusicHost
    let player: EnginePlayer
    let receiver: UPnPReceiver
    let listener: EventListener
    let refusals = Locked<[String]>([])
    let udn = "uuid:\(UUID().uuidString.lowercased())"

    /// `fromLoopback`: songs may come from 127.0.0.1, where the tests' music host is (the receiver itself never allows that).
    init(fromLoopback: Bool = true, noProgressLimit: TimeInterval? = nil, configure: (inout UPnPReceiver.Configuration) -> Void = { _ in }) async throws {
        host = try await MusicHost()
        player = try EnginePlayer(noProgressLimit: noProgressLimit)
        listener = try await EventListener()
        var configuration = UPnPReceiver.Configuration(udn: udn, name: "Vespertine on test-mac", version: "1.1.0")
        if fromLoopback { configuration.streamPolicy = StreamAddressPolicy(allowsLoopback: true, allowsLinkLocal: false) }
        configuration.listenOn = ("127.0.0.1", 0)
        configuration.responseDelay = { _ in 0 }
        let refusals = refusals
        configuration.onRefusal = { message, _ in refusals.withLock { $0.append(message) } }
        configure(&configuration)
        receiver = UPnPReceiver(configuration, player: player)
        player.attach(receiver)
        try await receiver.start()
    }

    func close() async {
        await receiver.stop()
        listener.stop()
        host.stop()
    }

    var port: UInt16 { get async { await receiver.port } }

    func service(_ service: ReceiverService) async -> UPnPService {
        let base = "http://127.0.0.1:\(await port)"
        return UPnPService(type: service.type, id: service.id, controlURL: URL(string: base + service.controlPath)!, scpdURL: URL(string: base + service.scpdPath)!)
    }

    /// Calls an action as a control app would, with a User-Agent of its own.
    func call(_ service: ReceiverService, _ action: String, _ arguments: [(String, String)] = []) async throws -> [String: String] {
        try await SOAPClient().call(await self.service(service), action, arguments)
    }

    /// The UPnP error an action is refused with (nil when it is accepted).
    func fault(_ service: ReceiverService, _ action: String, _ arguments: [(String, String)]) async -> (code: Int, description: String)? {
        do {
            _ = try await call(service, action, arguments)
            return nil
        } catch UPnPError.fault(let code, let description) {
            return (code, description)
        } catch {
            return (-1, "\(error)")
        }
    }

    func setURI(_ url: String, metadata: String = "") async -> (code: Int, description: String)? {
        await fault(.avTransport, "SetAVTransportURI", [("InstanceID", "0"), ("CurrentURI", url), ("CurrentURIMetaData", metadata)])
    }
}
