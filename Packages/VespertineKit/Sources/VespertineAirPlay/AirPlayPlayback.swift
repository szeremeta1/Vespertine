//
// Vespertine: playing the queue on an AirPlay 1 receiver, shaped like PlaybackEngine for the app (NetworkPlayback). Unlike a
// UPnP renderer, the receiver doesn't fetch anything: Vespertine renders each song with its own chain to ALAC 16/44.1 and
// pushes it in real time on this Mac's clock. One RTP timeline runs through the queue, so songs join frame to frame
// (gapless); a song "starts" when its first frame is heard, two seconds (the receiver's latency) after it was sent. Pause,
// seek and changes to what is applied flush the receiver and start the stream again at the position heard.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network
import os
import Security
import VespertineAudio
import VespertineUPnP

public final class AirPlayPlayback: NetworkPlayback, @unchecked Sendable {
    public let device: AirPlayDevice
    public var outputName: String { device.name }
    private let endpoint: NWEndpoint
    private let encryption: RAOPEncryption
    private let rsaKey: SecKey?
    /// How far ahead of the clock packets go out (the receiver holds two seconds).
    private let lead: TimeInterval
    private let log = Logger(subsystem: "org.szeremeta.vespertine.player", category: "airplay")

    public var nextItemProvider: (@Sendable (PlayableItem) -> PlayableItem?)? {
        get { hooks.withLock { $0.next } }
        set { hooks.withLock { $0.next = newValue } }
    }
    public var urlResolver: (@Sendable (PlayableItem) -> URL)? {
        get { hooks.withLock { $0.resolver } }
        set { hooks.withLock { $0.resolver = newValue } }
    }
    public var metadataProvider: (@Sendable (PlayableItem) -> RendererTrackInfo?)? {
        get { hooks.withLock { $0.metadata } }
        set { hooks.withLock { $0.metadata = newValue } }
    }
    public var eventHandler: (@Sendable @MainActor (EngineEvent) -> Void)? {
        get { hooks.withLock { $0.events } }
        set { hooks.withLock { $0.events = newValue } }
    }
    private struct Hooks {
        var next: (@Sendable (PlayableItem) -> PlayableItem?)?
        var resolver: (@Sendable (PlayableItem) -> URL)?
        var metadata: (@Sendable (PlayableItem) -> RendererTrackInfo?)?
        var events: (@Sendable @MainActor (EngineEvent) -> Void)?
    }
    private let hooks = Locked(Hooks())

    /// A song on the timeline.
    final class Segment: @unchecked Sendable {
        let item: PlayableItem
        let frames: AirPlayFrames
        let path: SignalPath
        /// Where in the song the stream starts (a seek, a resume).
        let offset: TimeInterval
        let duration: TimeInterval
        let announces: Bool
        /// RTP time of its first frame, once it is being sent; of the frame after its last, once all of it is.
        var start: UInt32?
        var end: UInt32?
        var heard = false

        init(item: PlayableItem, frames: AirPlayFrames, path: SignalPath, offset: TimeInterval, duration: TimeInterval, announces: Bool) {
            self.item = item
            self.frames = frames
            self.path = path
            self.offset = offset
            self.duration = duration
            self.announces = announces
        }
    }

    private struct State {
        var snapshot = EngineSnapshot()
        var settings = RendererSettings()
        var receiverVolumeDB: Double = 0
        var segments: [Segment] = []
        /// The next song, opened ahead while the one before plays.
        var prepared: (item: PlayableItem, segment: Segment?)?
        var queueDone = false
        var endAnnounced = false
        var wantsPlaying = false
        var shutDown = false
    }
    private let state = Locked(State())
    private var session: RAOPSession?
    private var pacer: Pacer?

    private let commands: AsyncStream<Command>
    private let enqueue: AsyncStream<Command>.Continuation
    private var worker: Task<Void, Never>?
    private let generation = Locked(0)
    private let settingsGeneration = Locked(0)

    enum Command {
        case play(PlayableItem, at: TimeInterval, announce: Bool, generation: Int)
        case pause, stop, queueChanged, settings(RendererSettings), volume(Double), heard(Segment), lost, ended
    }

    public init(device: AirPlayDevice, endpoint: NWEndpoint, encryption: RAOPEncryption, rsaKey: SecKey? = nil, lead: TimeInterval = 0.25) {
        self.device = device
        self.endpoint = endpoint
        self.encryption = encryption
        self.rsaKey = rsaKey
        self.lead = lead
        (commands, enqueue) = AsyncStream<Command>.makeStream()
        worker = Task { [weak self, commands] in
            for await command in commands {
                guard let self else { return }
                await self.run(command)
            }
        }
    }

    /// For a device found on Bonjour (its `_raop._tcp` service), or one with a known address.
    public convenience init?(device: AirPlayDevice, lead: TimeInterval = 0.25) {
        guard case .supported(let encryption) = device.support else { return nil }
        let endpoint: NWEndpoint
        if let service = device.service {
            endpoint = .service(name: service.name, type: service.type, domain: service.domain, interface: nil)
        } else if let host = device.host, let port = device.port.flatMap(NWEndpoint.Port.init(rawValue:)) {
            endpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
        } else { return nil }
        self.init(device: device, endpoint: endpoint, encryption: encryption, lead: lead)
    }

    deinit { worker?.cancel() }

    // MARK: Commands (any thread)

    public func play(_ item: PlayableItem) { play(item, at: 0) }

    public func play(_ item: PlayableItem, at seconds: TimeInterval) { start(item, at: seconds, announce: true) }

    private func start(_ item: PlayableItem, at seconds: TimeInterval, announce: Bool) {
        let g = generation.withLock { $0 += 1; return $0 }
        state.withLock {
            $0.snapshot.state = .playing
            $0.snapshot.item = item
            $0.snapshot.position = seconds
            $0.wantsPlaying = true
            if announce { $0.snapshot.signalPath = nil }
        }
        enqueue.yield(.play(item, at: seconds, announce: announce, generation: g))
    }

    public func pause() {
        generation.withLock { $0 += 1 }
        let position = snapshot.position
        state.withLock {
            $0.wantsPlaying = false
            if $0.snapshot.state == .playing { $0.snapshot.state = .paused }
            $0.snapshot.position = position
        }
        enqueue.yield(.pause)
    }

    public func resume() {
        let (item, position, paused) = state.withLock { ($0.snapshot.item, $0.snapshot.position, $0.snapshot.state == .paused) }
        guard paused, let item else { return }
        start(item, at: position, announce: false)
    }

    public func seek(to seconds: TimeInterval) {
        let (item, playing) = state.withLock { ($0.snapshot.item, $0.snapshot.state == .playing) }
        guard let item else { return }
        if playing { start(item, at: seconds, announce: false) } else { state.withLock { $0.snapshot.position = seconds } }
    }

    public func stop() {
        generation.withLock { $0 += 1 }
        state.withLock { $0.wantsPlaying = false; $0.snapshot.state = .stopped }
        enqueue.yield(.stop)
    }

    public func queueChanged() { enqueue.yield(.queueChanged) }

    /// What Vespertine applies (equalizer, room correction, digital volume). Changes that alter the samples restart the song
    /// at its position, 300 ms after the last one.
    public func update(settings: RendererSettings) {
        let g = settingsGeneration.withLock { $0 += 1; return $0 }
        guard state.withLock({ !$0.segments.isEmpty }) else { enqueue.yield(.settings(settings)); return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, self.settingsGeneration.withLock({ $0 }) == g else { return }
            self.enqueue.yield(.settings(settings))
        }
    }

    /// The receiver's own volume (sent as RAOP metadata; Vespertine's samples are untouched), −144…0 dB.
    public func setReceiverVolume(decibels: Double) {
        state.withLock { $0.receiverVolumeDB = decibels }
        enqueue.yield(.volume(decibels))
    }

    public func shutdown() {
        stop()
        state.withLock { $0.shutDown = true }
        enqueue.finish()
    }

    /// The frame heard now, on the timeline (nil while nothing is).
    private func heardTimestamp() -> UInt32? {
        session?.clockTimestamp().map { $0 &- RAOPTiming.latencyFrames }
    }

    public var snapshot: EngineSnapshot {
        let heard = heardTimestamp()
        return state.withLock { s in
            var snap = s.snapshot
            guard snap.state == .playing, let heard else { return snap }
            // The song heard now: the last one whose first frame has been reached.
            guard let segment = s.segments.last(where: { $0.start.map { Int32(bitPattern: heard &- $0) >= 0 } ?? false }) ?? s.segments.first,
                  let start = segment.start else { return snap }
            let into = Double(Int32(bitPattern: heard &- start)) / Double(RAOPTiming.sampleRate)
            snap.position = segment.offset + max(0, into)
            if segment.duration > 0 { snap.position = min(snap.position, segment.duration) }
            return snap
        }
    }

    // MARK: Worker

    private func emit(_ event: EngineEvent) {
        guard let handler = eventHandler else { return }
        Task { @MainActor in handler(event) }
    }

    private func run(_ command: Command) async {
        switch command {
        case .play(let item, let at, let announce, let g):
            guard generation.withLock({ $0 }) == g else { return }
            await begin(item, at: at, announce: announce, generation: g)
        case .pause:
            await halt()
            try? await session?.flush()
        case .stop:
            await halt()
            await session?.teardown()
            session = nil
            state.withLock { s in
                s.segments = []
                s.prepared = nil
                s.snapshot = EngineSnapshot()
            }
        case .queueChanged:
            let wanted = state.withLock { $0.segments.last }.flatMap { nextItemProvider?($0.item) }
            state.withLock { s in
                if let prepared = s.prepared, prepared.item.id != wanted?.id { s.prepared = nil }
            }
        case .settings(let settings):
            let before = state.withLock { s -> RendererSettings in defer { s.settings = settings }; return s.settings }
            guard before != settings, let heard = state.withLock({ $0.segments.first }), state.withLock({ $0.snapshot.state == .playing }) else {
                state.withLock { $0.prepared = nil }
                return
            }
            let item = state.withLock { $0.snapshot.item } ?? heard.item
            start(item, at: snapshot.position, announce: false)
        case .volume(let db):
            try? await session?.setVolume(db)
        case .heard(let segment):
            await announce(segment)
        case .lost:
            await halt()
            session = nil
            let wasActive = state.withLock { s -> Bool in
                defer { s.snapshot.state = .stopped; s.wantsPlaying = false; s.segments = []; s.prepared = nil }
                return s.snapshot.state != .stopped
            }
            if wasActive { emit(.deviceLost(device.name)) }
        case .ended:
            await halt()
            state.withLock { s in
                s.snapshot.state = .stopped
                s.wantsPlaying = false
                s.segments = []
                s.prepared = nil
            }
            emit(.queueEnded)
        }
    }

    /// Stops sending (and waits for the pacer to be done, so nothing of the old stream follows a FLUSH).
    private func halt() async {
        let p = pacer
        pacer = nil
        await p?.stop()
    }

    private func fail(_ item: PlayableItem, _ error: Error) {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let message = String(localized: "\(device.name) couldn't play the song (\(reason)).", comment: "%1$@ is an AirPlay receiver's name, %2$@ the reason.")
        state.withLock { $0.snapshot.state = .stopped; $0.snapshot.lastError = message; $0.wantsPlaying = false; $0.segments = []; $0.prepared = nil }
        emit(.failed(item, message))
    }

    private func begin(_ item: PlayableItem, at seconds: TimeInterval, announce: Bool, generation g: Int) async {
        await halt()
        let segment: Segment
        do { segment = try await prepare(item, at: seconds, announces: announce) } catch { fail(item, error); return }
        guard generation.withLock({ $0 }) == g else { return }
        do {
            if let session, session.isConnected {
                try await session.flush()
            } else {
                let made = RAOPSession(name: device.name, endpoint: endpoint, encryption: encryption, rsaKey: rsaKey)
                made.onLost = { [weak self] in self?.enqueue.yield(.lost) }
                try await made.connect(volumeDB: state.withLock { $0.receiverVolumeDB })
                session = made
            }
        } catch {
            session = nil
            fail(item, error)
            return
        }
        guard generation.withLock({ $0 }) == g, let session else { return }
        state.withLock { s in
            s.segments = [segment]
            s.prepared = nil
            s.queueDone = false
            s.endAnnounced = false
            s.snapshot.item = item
            s.snapshot.signalPath = segment.path
            s.snapshot.position = seconds
            s.snapshot.duration = segment.duration
            s.snapshot.lastError = nil
            s.snapshot.state = .playing
        }
        let pacer = Pacer(lead: lead, session: session, source: { [weak self] count in self?.frames(count) ?? ([], true) },
                          tick: { [weak self] in self?.tick() })
        self.pacer = pacer
        pacer.start()
        prepareNext(after: segment.item)
    }

    /// Opens `item` for sending, off the cooperative pool (opening a file can block on a share).
    private func prepare(_ item: PlayableItem, at seconds: TimeInterval, announces: Bool) async throws -> Segment {
        try await withCheckedThrowingContinuation { continuation in
            Self.preparation.async {
                continuation.resume(with: Result { try self.makeSegment(item, at: seconds, announces: announces) })
            }
        }
    }

    private static let preparation = DispatchQueue(label: "org.szeremeta.vespertine.airplay.prepare", qos: .userInitiated)

    private func makeSegment(_ item: PlayableItem, at seconds: TimeInterval, announces: Bool) throws -> Segment {
        let url = urlResolver?(item) ?? item.url
        let (settings, receiverDB) = state.withLock { ($0.settings, $0.receiverVolumeDB) }
        let frames = try AirPlayFrames(item: item, url: url, settings: settings, startSeconds: seconds)
        let info = metadataProvider?(item)
        var warnings: [String] = []
        if receiverDB < 0 {
            warnings.append(String(localized: "The receiver lowers the volume itself (\(receiverDB <= -144 ? "−∞" : receiverDB.formatted(.number.precision(.fractionLength(1)))) dB), which changes the samples after they arrive.",
                                   comment: "Signal path: an AirPlay receiver applies its own volume; %@ is in dB."))
        }
        let stage = SignalPath.RendererStage(name: device.name, protocolName: "AirPlay", processing: frames.steps, sentCodec: "ALAC",
                                             sentSampleRate: 44_100, sentBitDepth: 16, sentChannels: 2, gapless: true, warnings: warnings,
                                             transport: .airPlay)
        let steps = frames.steps
        let path = SignalPath.renderer(stage, source: frames.source, decoderName: frames.decoderName,
                                       volume: settings.activeVolumeDB.map { .digital(dB: $0) } ?? .fixed,
                                       replayGainDB: steps.contains(.replayGain) ? item.replayGainDB : nil,
                                       equalizer: steps.contains(.equalizer) ? settings.activeEqualizer?.name : nil,
                                       roomCorrection: steps.contains(.roomCorrection) ? settings.activeRoomCorrection?.name : nil)
        return Segment(item: item, frames: frames, path: path, offset: seconds, duration: info?.duration ?? 0, announces: announces)
    }

    /// Opens the song after `item` ahead of time, so the pacer joins it without a gap.
    private func prepareNext(after item: PlayableItem) {
        guard let next = nextItemProvider?(item) else { return }
        let g = generation.withLock { $0 }
        Self.preparation.async { [weak self] in
            guard let self else { return }
            let segment: Segment?
            do { segment = try self.makeSegment(next, at: 0, announces: true) } catch {
                self.log.error("Next song for \(self.device.name, privacy: .public) not opened: \(String(describing: error), privacy: .public)")
                segment = nil
            }
            guard self.generation.withLock({ $0 }) == g else { return }
            self.state.withLock { s in if s.prepared == nil, s.segments.last?.item.id == item.id { s.prepared = (next, segment) } }
        }
    }

    // MARK: Pacer side (its own thread)

    /// The next `count` stereo frames of the timeline, crossing into the next song; `done` once the queue has none left.
    private func frames(_ count: Int) -> ([Int16], Bool) {
        var out: [Int16] = []
        out.reserveCapacity(count * 2)
        while out.count < count * 2 {
            guard let segment = state.withLock({ $0.segments.last }), !state.withLock({ $0.queueDone }) else { break }
            let head = (session?.nextTimestamp ?? 0) &+ UInt32(out.count / 2)
            state.withLock { _ in if segment.start == nil { segment.start = head } }
            let chunk = segment.frames.next(maxFrames: count - out.count / 2)
            if !chunk.isEmpty { out += chunk; continue }
            state.withLock { _ in segment.end = head }
            // On to the next song: prepared ahead, or opened now.
            var next = state.withLock { s -> Segment?? in
                guard let p = s.prepared else { return .none }
                s.prepared = nil
                return .some(p.segment)
            }
            if next == nil, let item = nextItemProvider?(segment.item) {
                next = .some(try? makeSegment(item, at: 0, announces: true))
            }
            guard let found = next, let following = found else {
                if case .some(.none) = next, let item = nextItemProvider?(segment.item) {
                    emit(.failed(item, String(localized: "\(device.name) couldn't play the song (it couldn't be opened).", comment: "%@ is an AirPlay receiver's name.")))
                }
                state.withLock { $0.queueDone = true }
                break
            }
            state.withLock { $0.segments.append(following) }
            prepareNext(after: following.item)
        }
        let done = state.withLock { $0.queueDone }
        return (out, done)
    }

    /// After each packet: songs that became audible, the end of the queue heard.
    private func tick() {
        guard let heard = heardTimestamp() else { return }
        let (newly, ended) = state.withLock { s -> ([Segment], Bool) in
            var newly: [Segment] = []
            for segment in s.segments where !segment.heard {
                guard let start = segment.start, Int32(bitPattern: heard &- start) >= 0 else { continue }
                segment.heard = true
                newly.append(segment)
            }
            // Songs wholly heard leave the timeline (the one heard now stays first).
            if let current = newly.last, let index = s.segments.firstIndex(where: { $0 === current }), index > 0 {
                s.segments.removeFirst(index)
                s.snapshot.item = current.item
                s.snapshot.signalPath = current.path
                s.snapshot.duration = current.duration
            }
            var ended = false
            if s.queueDone, !s.endAnnounced, let last = s.segments.last, let end = last.end, Int32(bitPattern: heard &- end) >= 0 {
                s.endAnnounced = true
                ended = true
            }
            return (newly, ended)
        }
        for segment in newly { enqueue.yield(.heard(segment)) }
        if ended { enqueue.yield(.ended) }
    }

    /// A song became audible: tell the app (unless it is a restart of the same song) and the receiver's display.
    private func announce(_ segment: Segment) async {
        if segment.announces { emit(.trackStarted(segment.item)) }
        guard let session, let start = segment.start, let raop = device.raop else { return }
        if raop.metadata.contains(0) {
            let info = metadataProvider?(segment.item)
            try? await session.setMetadata(title: info?.title ?? segment.item.url.deletingPathExtension().lastPathComponent,
                                           artist: info?.artist, album: info?.album, rtptime: start)
        }
        if raop.metadata.contains(2), segment.duration > 0 {
            let songStart = start &- UInt32(segment.offset * Double(RAOPTiming.sampleRate))
            let end = songStart &+ UInt32(segment.duration * Double(RAOPTiming.sampleRate))
            try? await session.setProgress(start: songStart, current: start, end: end)
        }
    }
}

/// Sends a packet every 352 frames of real time (with a lead), sync packets about once a second; stops on request.
final class Pacer: @unchecked Sendable {
    private let lead: TimeInterval
    private let session: RAOPSession
    private let source: @Sendable (Int) -> ([Int16], Bool)
    private let tick: @Sendable () -> Void
    private let stopped = Locked(false)
    private let finished = DispatchSemaphore(value: 0)
    private var thread: Thread?

    init(lead: TimeInterval, session: RAOPSession, source: @escaping @Sendable (Int) -> ([Int16], Bool), tick: @escaping @Sendable () -> Void) {
        self.lead = lead
        self.session = session
        self.source = source
        self.tick = tick
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "Vespertine AirPlay pacer"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func stop() async {
        stopped.withLock { $0 = true }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { self.finished.wait(); c.resume() }
        }
    }

    private func run() {
        defer { finished.signal() }
        let packet = RAOPTiming.framesPerPacket
        let nanosPerPacket = Double(packet) * 1e9 / Double(RAOPTiming.sampleRate)
        let anchor = NTPClock.nanosecondsNow() + UInt64(lead * 1e9)
        var index: UInt64 = 0
        var draining = false
        while !stopped.withLock({ $0 }) {
            let due = anchor + UInt64(Double(index) * nanosPerPacket)
            let sendAt = due >= UInt64(lead * 1e9) ? due - UInt64(lead * 1e9) : 0
            let now = NTPClock.nanosecondsNow()
            if now < sendAt {
                usleep(UInt32(min(Double(sendAt - now) / 1000, 4000)))
                continue
            }
            if !draining {
                var (samples, done) = source(packet)
                if !samples.isEmpty {
                    if samples.count < packet * 2 { samples += [Int16](repeating: 0, count: packet * 2 - samples.count) }
                    session.send(samples, startNanos: anchor)
                    if index % 125 == 124 { session.sendSync() }
                }
                if done { draining = true }
            } else if index % 125 == 124 {
                session.sendSync()
            }
            tick()
            index += 1
        }
    }
}
