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
        var path: SignalPath
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
        /// The next song, opened ahead while the one before plays (segment nil: it couldn't be opened).
        var prepared: (item: PlayableItem, segment: Segment?)?
        /// The next song being opened now (its id), so it isn't opened twice.
        var preparing: UUID?
        /// The song a gap waits for (after a hold that ran too long), whose opening is kept though it isn't after the last song.
        var awaiting: UUID?
        /// Since when the pacer has been holding for the next song (nanoseconds); nil when it isn't.
        var holdSince: UInt64?
        /// The receiver volume last sent, and whether a send is queued (volume changes are coalesced: the latest wins).
        var sentVolumeDB: Double?
        var volumeQueued = false
        var queueDone = false
        var endAnnounced = false
        var wantsPlaying = false
        var shutDown = false
    }
    private let state = Locked(State())
    /// The session: set by the worker, read by the pacer and by `snapshot` on any thread, so behind a lock.
    private let sessionBox = Locked<RAOPSession?>(nil)
    private var session: RAOPSession? {
        get { sessionBox.withLock { $0 } }
        set { sessionBox.withLock { $0 = newValue } }
    }
    /// Only the worker touches it.
    private var pacer: Pacer?
    /// Tests: called on every song opened, with whether it was on the pacer's thread (it never should be).
    var onOpen: (@Sendable (_ onPacer: Bool) -> Void)?
    /// Tests: how long opening the next song ahead takes at least.
    var preparationDelay: TimeInterval = 0
    /// Tests: an extra delay before a given song opens (a slow or hung share).
    var openDelay: (@Sendable (PlayableItem) -> TimeInterval)?
    /// How long the pacer holds for a next song that isn't open yet: within the lead and the receiver's latency (2.25 s) what
    /// it sends late still plays; past this it stops, lets the song before be heard to its end, and starts the next on a
    /// fresh stream when it opens (a gap, said so).
    static let holdLimit: TimeInterval = 1.5
    /// How long a song may take to open before it fails (as long as the network cache waits for a share that sends nothing).
    var openTimeout: TimeInterval = 120
    /// Tests: the next song opened ahead, if any.
    var preparedNext: (item: PlayableItem, segment: AnyObject?)? { state.withLock { $0.prepared.map { ($0.item, $0.segment) } } }

    private let commands: AsyncStream<Command>
    private let enqueue: AsyncStream<Command>.Continuation
    private var worker: Task<Void, Never>?
    private let generation = Locked(0)
    private let settingsGeneration = Locked(0)

    enum Command {
        case play(PlayableItem, at: TimeInterval, announce: Bool, generation: Int)
        case pause, stop, queueChanged, settings(RendererSettings), volume, heard(Segment), lost, ended
        /// The hold for `next` ran too long: the stream starts again with it once it opens.
        case gap(after: Segment, next: PlayableItem, since: UInt64, generation: Int)
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
        let queue = state.withLock { s -> Bool in
            guard s.receiverVolumeDB != decibels else { return false }
            s.receiverVolumeDB = decibels
            // The signal path's note about the receiver's own volume follows at once, for the songs already open too.
            let warnings = Self.receiverWarnings(decibels)
            s.snapshot.signalPath?.renderer?.warnings = warnings
            for segment in s.segments { segment.path.renderer?.warnings = warnings }
            s.prepared?.segment?.path.renderer?.warnings = warnings
            guard !s.volumeQueued else { return false }
            s.volumeQueued = true
            return true
        }
        if queue { enqueue.yield(.volume) }
    }

    static func receiverWarnings(_ db: Double) -> [String] {
        guard db < 0 else { return [] }
        let value = db <= -144 ? "−∞" : db.formatted(.number.precision(.fractionLength(1)))
        return [String(localized: "The receiver lowers the volume itself (\(value) dB), which changes the samples after they arrive.",
                       comment: "Signal path: an AirPlay receiver applies its own volume; %@ is in dB.")]
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
            // Only a different next song drops the one opened ahead.
            guard let last = state.withLock({ $0.segments.last }) else { return }
            let wanted = nextItemProvider?(last.item)
            let reopen = state.withLock { s -> Bool in
                if let prepared = s.prepared {
                    guard prepared.item.id != wanted?.id else { return false }
                    s.prepared = nil
                    return true
                }
                // Still opening the old next song: the new one is opened now (the old one's result is dropped when it comes).
                if let preparing = s.preparing, preparing != wanted?.id { s.preparing = nil; return true }
                return false
            }
            if reopen { prepareNext(after: last.item) }
        case .settings(let settings):
            let before = state.withLock { s -> RendererSettings in defer { s.settings = settings }; return s.settings }
            // The same settings again (every syncEngine sends them) change nothing: the next song stays as it was opened.
            guard before != settings else { return }
            if let heard = state.withLock({ $0.segments.first }), state.withLock({ $0.snapshot.state == .playing }) {
                let item = state.withLock { $0.snapshot.item } ?? heard.item
                start(item, at: snapshot.position, announce: false)
            } else if let last = state.withLock({ $0.segments.last }) {
                state.withLock { $0.prepared = nil }
                prepareNext(after: last.item)
            }
        case .volume:
            // At most one send in flight; the latest level wins.
            while true {
                let db = state.withLock { s -> Double? in
                    guard s.sentVolumeDB != s.receiverVolumeDB else { s.volumeQueued = false; return nil }
                    s.sentVolumeDB = s.receiverVolumeDB
                    return s.receiverVolumeDB
                }
                guard let db else { break }
                guard let session, session.isConnected else { state.withLock { $0.sentVolumeDB = nil; $0.volumeQueued = false }; break }
                try? await session.setVolume(db)
            }
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
        case .gap(let previous, let next, let since, let g):
            guard generation.withLock({ $0 }) == g else { return }
            await recover(after: previous, next: next, since: since, generation: g)
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
        do { segment = try await prepare(item, at: seconds, announces: announce) } catch {
            if generation.withLock({ $0 }) == g { fail(item, error) }
            return
        }
        guard generation.withLock({ $0 }) == g else { return }
        do {
            if let session, session.isConnected {
                try await session.flush()
            } else {
                let made = RAOPSession(name: device.name, endpoint: endpoint, encryption: encryption, rsaKey: rsaKey)
                made.onLost = { [weak self] in self?.enqueue.yield(.lost) }
                let volume = state.withLock { $0.receiverVolumeDB }
                try await made.connect(volumeDB: volume)
                state.withLock { $0.sentVolumeDB = volume }
                session = made
            }
        } catch {
            session = nil
            // Overtaken by a later play or stop: that one decides what is said.
            if generation.withLock({ $0 }) == g { fail(item, error) }
            return
        }
        guard generation.withLock({ $0 }) == g, let session else { return }
        state.withLock { s in
            s.segments = [segment]
            s.prepared = nil
            s.preparing = nil
            s.awaiting = nil
            s.holdSince = nil
            s.queueDone = false
            s.endAnnounced = false
            s.snapshot.item = item
            s.snapshot.signalPath = segment.path
            s.snapshot.position = seconds
            s.snapshot.duration = segment.duration
            s.snapshot.lastError = nil
            s.snapshot.state = .playing
        }
        let pacer = Pacer(lead: lead, session: session, source: { [weak self] count in self?.frames(count) ?? .frames([], done: true) },
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

    /// Concurrent: a song stuck opening on a hung share mustn't hold up the one after it.
    private static let preparation = DispatchQueue(label: "org.szeremeta.vespertine.airplay.prepare", qos: .userInitiated, attributes: .concurrent)

    private func makeSegment(_ item: PlayableItem, at seconds: TimeInterval, announces: Bool) throws -> Segment {
        onOpen?(Thread.current.name == Pacer.threadName)
        if let delay = openDelay?(item), delay > 0 { Thread.sleep(forTimeInterval: delay) }
        let url = urlResolver?(item) ?? item.url
        let (settings, receiverDB) = state.withLock { ($0.settings, $0.receiverVolumeDB) }
        let frames = try AirPlayFrames(item: item, url: url, settings: settings, startSeconds: seconds)
        let info = metadataProvider?(item)
        let warnings = Self.receiverWarnings(receiverDB)
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
        open(next, after: item)
    }

    /// Opens `next` (the song after `item`, or the one a gap waits for) on the preparation queue into `prepared`. A result for
    /// a song that is no longer the next one is dropped.
    private func open(_ next: PlayableItem, after item: PlayableItem?) {
        let g = generation.withLock { $0 }
        let go = state.withLock { s -> Bool in
            guard s.prepared == nil, s.preparing != next.id else { return false }
            s.preparing = next.id
            return true
        }
        guard go else { return }
        let delay = preparationDelay
        Self.preparation.async { [weak self] in
            guard let self else { return }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let segment: Segment?
            do { segment = try self.makeSegment(next, at: 0, announces: true) } catch {
                self.log.error("Next song for \(self.device.name, privacy: .public) not opened: \(String(describing: error), privacy: .public)")
                segment = nil
            }
            let current = item.flatMap { self.nextItemProvider?($0) }
            self.state.withLock { s in
                if s.preparing == next.id { s.preparing = nil }
                guard self.generation.withLock({ $0 }) == g, s.prepared == nil else { return }
                let stillNext = s.awaiting == next.id || (item != nil && s.segments.last?.item.id == item?.id && current?.id == next.id)
                guard stillNext else { return }
                s.prepared = (next, segment)
            }
        }
    }

    // MARK: Pacer side (its own thread)

    /// The next `count` stereo frames of the timeline, crossing into the next song; `done` once the queue has none left;
    /// `waiting` while the next song is still being opened (never here: this is the pacer's real-time thread).
    private func frames(_ count: Int) -> PacerFeed {
        var out: [Int16] = []
        out.reserveCapacity(count * 2)
        while out.count < count * 2 {
            guard let segment = state.withLock({ $0.segments.last }), !state.withLock({ $0.queueDone }) else { break }
            // The pacer may hold part of this packet already (it waited for this song): those frames come first.
            let held = max(0, RAOPTiming.framesPerPacket - count)
            let head = (session?.nextTimestamp ?? 0) &+ UInt32(held + out.count / 2)
            state.withLock { _ in if segment.start == nil { segment.start = head } }
            let chunk = segment.frames.next(maxFrames: count - out.count / 2)
            if !chunk.isEmpty { out += chunk; continue }
            state.withLock { _ in segment.end = head }
            // On to the next song, opened ahead. Not ready yet: wait for it (the pacer holds the packet; the receiver's two
            // seconds cover the wait), opening it off this thread if nobody has started to.
            let wanted = nextItemProvider?(segment.item)
            let next = state.withLock { s -> Segment?? in
                guard let p = s.prepared, p.item.id == wanted?.id else { return .none }
                s.prepared = nil
                return .some(p.segment)
            }
            guard let found = next else {
                guard let wanted else {
                    state.withLock { $0.queueDone = true }
                    break
                }
                let now = NTPClock.nanosecondsNow()
                let since = state.withLock { s -> UInt64 in
                    if s.prepared != nil { s.prepared = nil }
                    if s.holdSince == nil { s.holdSince = now }
                    return s.holdSince!
                }
                if Double(now - since) / 1e9 > Self.holdLimit {
                    // Too long: what would be sent now would come too late to play. The stream stops here.
                    state.withLock { $0.holdSince = nil }
                    enqueue.yield(.gap(after: segment, next: wanted, since: since, generation: generation.withLock { $0 }))
                    return .gap(out)
                }
                prepareNext(after: segment.item)
                return .wait(out)
            }
            state.withLock { $0.holdSince = nil }
            guard let following = found else {
                if let wanted {
                    emit(.failed(wanted, String(localized: "\(device.name) couldn't play the song (it couldn't be opened).", comment: "%@ is an AirPlay receiver's name.")))
                }
                state.withLock { $0.queueDone = true }
                break
            }
            state.withLock { $0.segments.append(following) }
            prepareNext(after: following.item)
        }
        let done = state.withLock { $0.queueDone }
        return .frames(out, done: done)
    }

    /// After a hold that ran too long: the song before is heard to its end, the receiver is flushed, and `next` starts from
    /// its beginning on a fresh stream once it opens (with a notice about the gap). A song that doesn't open within
    /// `openTimeout`, or can't be opened, fails as any song does and the one after it is tried.
    private func recover(after previous: Segment, next: PlayableItem, since: UInt64, generation g: Int) async {
        await halt()
        // Let what was sent be heard.
        while generation.withLock({ $0 }) == g, let end = previous.end, let heard = heardTimestamp(), Int32(bitPattern: heard &- end) < 0 {
            tick()   // the song before still becomes audible (and is announced) while it plays out
            try? await Task.sleep(for: .milliseconds(50))
        }
        tick()
        guard generation.withLock({ $0 }) == g, let session else { return }
        do { try await session.flush() } catch { enqueue.yield(.lost); return }
        var wanted = next
        var began = since
        var gapNotice = true
        while generation.withLock({ $0 }) == g {
            let found = state.withLock { s -> Segment?? in
                s.awaiting = wanted.id
                guard let p = s.prepared, p.item.id == wanted.id else { return .none }
                s.prepared = nil
                return .some(p.segment)
            }
            if found == nil, state.withLock({ $0.preparing != wanted.id }) { open(wanted, after: nil) }
            let timedOut = Double(NTPClock.nanosecondsNow() - began) / 1e9 > openTimeout
            if let found, let segment = found {
                state.withLock { $0.awaiting = nil }
                if gapNotice {
                    let title = metadataProvider?(wanted)?.title ?? wanted.url.deletingPathExtension().lastPathComponent
                    emit(.notice(String(localized: "Gap before \(title): it took too long to open.", comment: "%@ is a song's title, sent to an AirPlay receiver.")))
                }
                restart(with: segment, session: session)
                return
            }
            if found != nil || timedOut {
                // Couldn't be opened, or not in time: that song fails, the one after is tried.
                let reason = timedOut ? String(localized: "it took too long to open") : String(localized: "it couldn't be opened")
                emit(.failed(wanted, String(localized: "\(device.name) couldn't play the song (\(reason)).", comment: "%1$@ is an AirPlay receiver's name, %2$@ the reason.")))
                state.withLock { s in s.awaiting = nil; if s.prepared?.item.id == wanted.id { s.prepared = nil } }
                guard let after = nextItemProvider?(wanted) else {
                    state.withLock { s in s.snapshot.state = .stopped; s.wantsPlaying = false; s.segments = []; s.prepared = nil }
                    emit(.queueEnded)
                    return
                }
                wanted = after
                began = NTPClock.nanosecondsNow()
                gapNotice = false
                continue
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        state.withLock { $0.awaiting = nil }
    }

    /// A fresh stream starting with `segment` (the receiver has been flushed).
    private func restart(with segment: Segment, session: RAOPSession) {
        state.withLock { s in
            s.segments = [segment]
            s.prepared = nil
            s.queueDone = false
            s.endAnnounced = false
            s.holdSince = nil
        }
        let pacer = Pacer(lead: lead, session: session, source: { [weak self] count in self?.frames(count) ?? .frames([], done: true) },
                          tick: { [weak self] in self?.tick() })
        self.pacer = pacer
        pacer.start()
        prepareNext(after: segment.item)
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

/// What the pacer gets for a packet: frames (and whether the queue is done), frames so far while it waits for the next song to
/// open, or frames to send before it stops (a hold that ran too long).
enum PacerFeed {
    case frames([Int16], done: Bool)
    case wait([Int16])
    case gap([Int16])
}

/// Sends a packet every 352 frames of real time (with a lead), sync packets about once a second; stops on request.
final class Pacer: @unchecked Sendable {
    private let lead: TimeInterval
    private let session: RAOPSession
    static let threadName = "Vespertine AirPlay pacer"
    private let source: @Sendable (Int) -> PacerFeed
    private let tick: @Sendable () -> Void
    private let stopped = Locked(false)
    private let finished = DispatchSemaphore(value: 0)
    private var thread: Thread?

    init(lead: TimeInterval, session: RAOPSession, source: @escaping @Sendable (Int) -> PacerFeed, tick: @escaping @Sendable () -> Void) {
        self.lead = lead
        self.session = session
        self.source = source
        self.tick = tick
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = Self.threadName
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
        /// Frames of the packet being filled, held while the next song is being opened.
        var pending: [Int16] = []
        while !stopped.withLock({ $0 }) {
            let due = anchor + UInt64(Double(index) * nanosPerPacket)
            let sendAt = due >= UInt64(lead * 1e9) ? due - UInt64(lead * 1e9) : 0
            let now = NTPClock.nanosecondsNow()
            if now < sendAt {
                usleep(UInt32(min(Double(sendAt - now) / 1000, 4000)))
                continue
            }
            if !draining {
                let done: Bool
                switch source(packet - pending.count / 2) {
                case .wait(let samples):
                    // Held: nothing is sent and the timeline doesn't move on; once the song is open, the packets due go at once.
                    // Looked at again every 50 ms.
                    pending += samples
                    tick()
                    usleep(50_000)
                    continue
                case .gap(let samples):
                    // The end of the song before goes out, then this stream stops (the playback starts a fresh one).
                    pending += samples
                    if !pending.isEmpty {
                        pending += [Int16](repeating: 0, count: max(0, packet * 2 - pending.count))
                        session.send(pending, startNanos: anchor)
                    }
                    return
                case .frames(let samples, let isDone):
                    pending += samples
                    done = isDone
                }
                if !pending.isEmpty {
                    if pending.count < packet * 2 { pending += [Int16](repeating: 0, count: packet * 2 - pending.count) }
                    session.send(pending, startNanos: anchor)
                    pending = []
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
