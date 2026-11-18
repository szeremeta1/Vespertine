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
    /// The receiver's password, for one that has one. Called off the main thread, when a session is opened.
    public var passwordProvider: (@Sendable () -> String?)? {
        get { hooks.withLock { $0.password } }
        set { hooks.withLock { $0.password = newValue } }
    }
    /// The receiver refused the session for want of the right password (the song has failed; the listener can be asked).
    public var passwordRefused: (@Sendable () -> Void)? {
        get { hooks.withLock { $0.refused } }
        set { hooks.withLock { $0.refused = newValue } }
    }
    /// What was kept from pairing with a receiver that shows a PIN (nil: never paired). Called off the main thread, when a
    /// session is opened; never for a receiver that asks for no PIN.
    public var pairingProvider: (@Sendable () -> AirPlayPairingKeys?)? {
        get { hooks.withLock { $0.pairing } }
        set { hooks.withLock { $0.pairing = newValue } }
    }
    /// The receiver wants the PIN on its screen typed: this Mac was never paired with it, or it has forgotten this Mac
    /// (the song has failed; the listener can be asked).
    public var pairingRefused: (@Sendable () -> Void)? {
        get { hooks.withLock { $0.unpaired } }
        set { hooks.withLock { $0.unpaired = newValue } }
    }
    /// The cover file (JPEG or PNG) for a song's `RendererTrackInfo.artworkKey`, for receivers that show one. Called off
    /// the main thread.
    public var artworkProvider: (@Sendable (String) -> Data?)? {
        get { hooks.withLock { $0.artwork } }
        set { hooks.withLock { $0.artwork = newValue } }
    }
    private struct Hooks {
        var password: (@Sendable () -> String?)?
        var refused: (@Sendable () -> Void)?
        var pairing: (@Sendable () -> AirPlayPairingKeys?)?
        var unpaired: (@Sendable () -> Void)?
        var artwork: (@Sendable (String) -> Data?)?
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
        /// Its decoder stopped on an error, and that has been said.
        var errorSaid = false
        /// A streamed song's whole copy in the transient playback cache, read by `frames`; deleted when the segment is let go.
        var staged: StagedRemoteFile?

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
        /// What the open session's stream holds, and so what every song is made into: 16-bit at 44.1 kHz unless an
        /// AirPlay 2 receiver said it takes more for the song the session was opened with.
        var streamFormat = AirPlayFormat.cd
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
    /// Tests: SRP's private number when pairing without a PIN (random otherwise).
    var pairingSecret: Data?
    /// This Mac as an AirPlay 2 receiver is told of it.
    var sender = AirPlay2Sender.thisMac
    /// Send a song that 24-bit at 48 kHz serves as a buffered stream, to an AirPlay 2 receiver that says its buffered
    /// streams take it (an Apple TV 4K's do, though its realtime ones stop at 16-bit and 44.1 kHz). Off unless set: no
    /// receiver has been heard playing one from Vespertine yet. A receiver that refuses it gets the realtime stream, and
    /// isn't asked again while this playback lasts.
    public var buffersStreams = false
    /// Tests: the ports the session's clock is made on (0: any free ones) and the ones the receiver takes its messages
    /// on. nil: 319 and 320 for both, as PTP has them.
    var clockPorts: (own: (event: UInt16, general: UInt16), peer: (event: UInt16, general: UInt16))?
    /// A buffered stream was tried and the receiver didn't take it. Only the worker touches it.
    private var bufferedRefused = false
    /// How long a song may take to open before it fails (as long as the network cache waits for a share that sends nothing).
    var openTimeout: TimeInterval = 120
    /// Tests: the next song opened ahead, if any.
    var preparedNext: (item: PlayableItem, segment: AnyObject?)? { state.withLock { $0.prepared.map { ($0.item, $0.segment) } } }

    private let commands: AsyncStream<Command>
    private let enqueue: AsyncStream<Command>.Continuation
    private var worker: Task<Void, Never>?
    /// Signalled when the worker has run its last command.
    private let workerDone = DispatchSemaphore(value: 0)
    private let generation = Locked(0)
    private let settingsGeneration = Locked(0)
    /// Keeps the Mac awake while the receiver is meant to be playing (nothing plays through Core Audio then, so macOS would
    /// let the Mac sleep in the middle of an album and throttle the sender while its window is hidden).
    private let activity = PlaybackActivity(reason: "Playing to an AirPlay receiver")

    private func refreshActivity() {
        activity.set(state.withLock { $0.wantsPlaying && !$0.shutDown })
    }

    /// The session with the receiver is open: it is there, whatever Bonjour says at the moment.
    /// A paused song counts too: its session may have been closed to free the receiver, and is opened again on Play.
    public var isEngaged: Bool {
        let (shutDown, paused) = state.withLock { ($0.shutDown, $0.snapshot.state == .paused) }
        return !shutDown && (paused || session?.isConnected == true)
    }

    /// How long a paused or finished session is kept open. After that the receiver is let go, so other senders can use
    /// it (it answers them "busy" while Vespertine holds it); Play opens a new session where the song was.
    var idleLimit: TimeInterval = 300

    enum Command {
        case play(PlayableItem, at: TimeInterval, announce: Bool, generation: Int)
        case pause, stop, queueChanged, settings(RendererSettings), volume, heard(Segment), lost, ended
        /// Nothing has played since the pause or the queue's end of this generation: the session is closed.
        case idle(generation: Int)
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
        let done = workerDone
        worker = Task { [weak self, commands] in
            defer { done.signal() }
            for await command in commands {
                guard let self else { return }
                await self.run(command)
                // A lost receiver, a failed song or the queue's end stop the sending: the Mac may sleep again.
                self.refreshActivity()
            }
        }
    }

    /// For a device found on Bonjour (its `_raop._tcp` service, or its `_airplay._tcp` one when the session is an AirPlay 2
    /// one), or one with a known address.
    public convenience init?(device: AirPlayDevice, lead: TimeInterval = 0.25) {
        guard case .supported(let encryption) = device.support else { return nil }
        guard let endpoint = Self.endpoint(for: device, airPlay2: device.usesAirPlay2) else { return nil }
        self.init(device: device, endpoint: endpoint, encryption: encryption, lead: lead)
    }

    /// Where a session with `device` connects: the Bonjour service of its kind, or the known address.
    static func endpoint(for device: AirPlayDevice, airPlay2: Bool) -> NWEndpoint? {
        if let service = airPlay2 ? device.airplayService : device.service {
            return .service(name: service.name, type: service.type, domain: service.domain, interface: nil)
        }
        if let host = device.host, let port = device.port.flatMap(NWEndpoint.Port.init(rawValue:)) {
            return .hostPort(host: NWEndpoint.Host(host), port: port)
        }
        return nil
    }

    /// How the session gets past a receiver that must be paired with. One that shows a PIN and was never paired with is
    /// refused here, before anything is sent, the way the receiver itself refuses a Mac it has forgotten.
    private func sessionPairing() throws -> AirPlay2Pairing {
        guard device.usesAirPlay2 else { return .none }
        guard device.airPlay2Entry == .pin else { return .withoutPIN(secret: pairingSecret) }
        guard let keys = pairingProvider?() else { throw PairingError.authentication }
        return .paired(keys.identity, keys.receiver)
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
        refreshActivity()
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
        refreshActivity()
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
        refreshActivity()
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
        refreshActivity()
        enqueue.finish()
    }

    /// Vespertine is quitting: the session is torn down (the receiver stops at once and is free for other senders).
    public func stopAndWait(timeout: TimeInterval) {
        shutdown()
        _ = workerDone.wait(timeout: .now() + timeout)
    }

    /// The frame heard now, on the timeline (nil while nothing is).
    private func heardTimestamp() -> UInt32? {
        guard let session else { return nil }
        let latency = session.format.latencyFrames
        return session.clockTimestamp().map { $0 &- latency }
    }

    public var snapshot: EngineSnapshot {
        let heard = heardTimestamp()
        return state.withLock { s in
            var snap = s.snapshot
            guard snap.state == .playing, let heard else { return snap }
            // The song heard now: the last one whose first frame has been reached.
            guard let segment = s.segments.last(where: { $0.start.map { Int32(bitPattern: heard &- $0) >= 0 } ?? false }) ?? s.segments.first,
                  let start = segment.start else { return snap }
            let into = Double(Int32(bitPattern: heard &- start)) / Double(s.streamFormat.sampleRate)
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
            closeWhenIdle()
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
        case .idle(let g):
            guard generation.withLock({ $0 }) == g, state.withLock({ $0.snapshot.state != .playing }), pacer == nil else { return }
            await session?.teardown()
            session = nil
        case .lost:
            await halt()
            session = nil
            // Lost while paused: the song stays where it is, and Play opens a new session.
            if state.withLock({ $0.snapshot.state == .paused }) { return }
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
            closeWhenIdle()
        }
    }

    private func makeSession(wish: AirPlayWish, clock: PTPClock?) throws -> RAOPSession {
        let made = RAOPSession(name: device.name, endpoint: endpoint, encryption: encryption, rsaKey: rsaKey,
                               authSetup: device.needsAuthSetup, password: device.needsPassword ? passwordProvider?() : nil,
                               pairing: try sessionPairing(), sender: sender, wish: wish, clock: clock)
        if let peer = clockPorts?.peer { made.clockPeerPorts = peer }
        return made
    }

    /// The clock for a session that may carry a buffered stream: only when they are switched on, the receiver is an
    /// AirPlay 2 one that hasn't refused one, and the song has something to gain. nil too when the clock's ports can't
    /// be had; the session is then a realtime one.
    private func sessionClock(for wish: AirPlayWish) -> PTPClock? {
        guard buffersStreams, !bufferedRefused, device.usesAirPlay2, !wish.isPlain else { return nil }
        let address = sender.deviceID.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        let ports = clockPorts?.own ?? (319, 320)
        do {
            return try PTPClock(identity: PTPMessage.identity(address: address), eventPort: ports.event, generalPort: ports.general)
        } catch {
            log.info("AirPlay \(self.device.name, privacy: .public): no clock for a buffered stream (\(String(describing: error), privacy: .public)); sending a realtime one")
            return nil
        }
    }

    private func closeWhenIdle() {
        let g = generation.withLock { $0 }
        let limit = idleLimit
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            self?.enqueue.yield(.idle(generation: g))
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
        // A session still open keeps its stream's format; a new one starts from the format every receiver takes.
        if session?.isConnected != true { state.withLock { $0.streamFormat = .cd } }
        var segment: Segment
        do { segment = try await prepare(item, at: seconds, announces: announce) } catch {
            if generation.withLock({ $0 }) == g { fail(item, error) }
            return
        }
        guard generation.withLock({ $0 }) == g else { return }
        do {
            var open = false
            if let session, session.isConnected {
                // A session the receiver has dropped since (it restarted, or let go of a paused sender) refuses the
                // flush: a new one is opened instead of failing the song.
                do { try await session.flush(); open = true } catch {
                    log.info("AirPlay \(self.device.name, privacy: .public): the open session refused a flush (\(String(describing: error), privacy: .public)); connecting again")
                    await session.teardown()
                    self.session = nil
                }
            }
            if !open {
                let wish = AirPlayConversion.wish(source: segment.frames.source, settings: state.withLock { $0.settings }, replayGainDB: item.replayGainDB)
                let volume = state.withLock { $0.receiverVolumeDB }
                var made = try makeSession(wish: wish, clock: sessionClock(for: wish))
                do { try await made.connect(volumeDB: volume) } catch {
                    // A buffered stream the receiver didn't take: the realtime stream it does, from a session of its
                    // own. Anything else that went wrong stands.
                    guard made.triedBuffered else { throw error }
                    log.info("AirPlay \(self.device.name, privacy: .public) didn't take a buffered stream (\(String(describing: error), privacy: .public)); sending a realtime one")
                    bufferedRefused = true
                    made = try makeSession(wish: wish, clock: nil)
                    try await made.connect(volumeDB: volume)
                }
                made.onLost = { [weak self] in self?.enqueue.yield(.lost) }
                state.withLock { $0.sentVolumeDB = volume }
                session = made
            }
        } catch {
            session = nil
            // Overtaken by a later play or stop: that one decides what is said.
            if generation.withLock({ $0 }) == g {
                fail(item, error)
                if let refusal = error as? RAOPError, case .refused(_, 401) = refusal { passwordRefused?() }
                if device.airPlay2Entry == .pin, (error as? PairingError) == .authentication { pairingRefused?() }
            }
            return
        }
        guard generation.withLock({ $0 }) == g, let session else { return }
        // The stream's format is the session's: a receiver that took more than 16-bit at 44.1 kHz (or a session kept
        // from a song that got it) has the song made again in that format, from the file already opened.
        let format = session.format
        state.withLock { $0.streamFormat = format }
        if segment.frames.format != format {
            do { segment = try await prepare(item, at: seconds, announces: announce, reusing: segment) } catch {
                if generation.withLock({ $0 }) == g { fail(item, error) }
                return
            }
            guard generation.withLock({ $0 }) == g else { return }
        }
        let first = segment
        state.withLock { s in
            s.segments = [first]
            s.prepared = nil
            s.preparing = nil
            s.awaiting = nil
            s.holdSince = nil
            s.queueDone = false
            s.endAnnounced = false
            s.snapshot.item = item
            s.snapshot.signalPath = first.path
            s.snapshot.position = seconds
            s.snapshot.duration = first.duration
            s.snapshot.lastError = nil
            s.snapshot.state = .playing
        }
        let pacer = Pacer(lead: lead, session: session, source: { [weak self] count in self?.frames(count) ?? .frames([], done: true) },
                          tick: { [weak self] in self?.tick() })
        self.pacer = pacer
        pacer.start()
        prepareNext(after: first.item)
    }

    /// Opens `item` for sending, off the cooperative pool (opening a file can block on a share). `reusing`: the same
    /// song opened before in another format, whose staged copy (a stream's) is read again and not fetched again.
    private func prepare(_ item: PlayableItem, at seconds: TimeInterval, announces: Bool, reusing: Segment? = nil) async throws -> Segment {
        try await withCheckedThrowingContinuation { continuation in
            Self.preparation.async {
                continuation.resume(with: Result { try self.makeSegment(item, at: seconds, announces: announces, reusing: reusing) })
            }
        }
    }

    /// Concurrent: a song stuck opening on a hung share mustn't hold up the one after it.
    private static let preparation = DispatchQueue(label: "org.szeremeta.vespertine.airplay.prepare", qos: .userInitiated, attributes: .concurrent)

    private func makeSegment(_ item: PlayableItem, at seconds: TimeInterval, announces: Bool, reusing: Segment? = nil) throws -> Segment {
        onOpen?(Thread.current.name == Pacer.threadName)
        if let delay = openDelay?(item), delay > 0 { Thread.sleep(forTimeInterval: delay) }
        let resolved = urlResolver?(item) ?? item.url
        // A stream is copied whole first: the frames are decoded from a local file.
        let staged = resolved.isFileURL ? nil : try reusing?.staged ?? StagedRemoteFile.stage(item)
        let url = staged?.url ?? resolved
        let (settings, receiverDB, format) = state.withLock { ($0.settings, $0.receiverVolumeDB, $0.streamFormat) }
        let frames = try AirPlayFrames(item: item, url: url, settings: settings, startSeconds: seconds, format: format)
        let info = metadataProvider?(item)
        let warnings = Self.receiverWarnings(receiverDB)
        let stage = SignalPath.RendererStage(name: device.name, protocolName: "AirPlay", processing: frames.steps, sentCodec: "ALAC",
                                             sentSampleRate: Double(frames.format.sampleRate), sentBitDepth: frames.format.bitDepth, sentChannels: 2,
                                             gapless: true, warnings: warnings,
                                             transport: .airPlay)
        let steps = frames.steps
        let path = SignalPath.renderer(stage, source: frames.source, decoderName: frames.decoderName,
                                       volume: settings.activeVolumeDB.map { .digital(dB: $0) } ?? .fixed,
                                       replayGainDB: steps.contains(.replayGain) ? item.replayGainDB : nil,
                                       equalizer: steps.contains(.equalizer) ? settings.activeEqualizer?.name : nil,
                                       roomCorrection: steps.contains(.roomCorrection) ? settings.activeRoomCorrection?.name : nil)
        let segment = Segment(item: item, frames: frames, path: path, offset: seconds, duration: info?.duration ?? 0, announces: announces)
        segment.staged = staged
        return segment
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
        var out: [Int32] = []
        out.reserveCapacity(count * 2)
        while out.count < count * 2 {
            guard let segment = state.withLock({ $0.segments.last }), !state.withLock({ $0.queueDone }) else { break }
            // The pacer may hold part of this packet already (it waited for this song): those frames come first.
            let held = max(0, RAOPTiming.framesPerPacket - count)
            let head = (session?.nextTimestamp ?? 0) &+ UInt32(held + out.count / 2)
            state.withLock { _ in if segment.start == nil { segment.start = head } }
            let chunk = segment.frames.nextSamples(maxFrames: count - out.count / 2)
            if !chunk.isEmpty { out += chunk; continue }
            state.withLock { _ in segment.end = head }
            // A decoder that stopped on an error is the song cut short, not its end: said once, and the queue goes on.
            if let error = segment.frames.error, !state.withLock({ _ -> Bool in defer { segment.errorSaid = true }; return segment.errorSaid }) {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                emit(.failed(segment.item, String(localized: "\(device.name) couldn't play the song (\(reason)).", comment: "%1$@ is an AirPlay receiver's name, %2$@ the reason.")))
            }
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
                guard let wanted else {
                    state.withLock { $0.queueDone = true }
                    break
                }
                // It couldn't be opened. The song before is heard to its end; then this one fails by name and the one
                // after it is tried, on a fresh stream (the worker's step, as after a hold that ran too long).
                enqueue.yield(.gap(after: segment, next: wanted, since: NTPClock.nanosecondsNow(), generation: generation.withLock { $0 }))
                return .gap(out)
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
        guard let session, let start = segment.start else { return }
        let shown = device.metadata
        let info = metadataProvider?(segment.item)
        if shown.contains(0) {
            try? await session.setMetadata(title: info?.title ?? segment.item.url.deletingPathExtension().lastPathComponent,
                                           artist: info?.artist, album: info?.album, rtptime: start)
        }
        // The cover, or word that this song has none (so the last song's doesn't stay up).
        if shown.contains(1) {
            let image = info?.artworkKey.flatMap { key in artworkProvider?(key) }
            try? await session.setArtwork(image, rtptime: start)
        }
        if shown.contains(2), segment.duration > 0 {
            let rate = Double(session.format.sampleRate)
            let songStart = start &- UInt32(segment.offset * rate)
            let end = songStart &+ UInt32(segment.duration * rate)
            try? await session.setProgress(start: songStart, current: start, end: end)
        }
    }
}

/// What the pacer gets for a packet: frames (and whether the queue is done), frames so far while it waits for the next song to
/// open, or frames to send before it stops (a hold that ran too long).
enum PacerFeed {
    case frames([Int32], done: Bool)
    case wait([Int32])
    case gap([Int32])
}

/// Sends a packet every 352 frames of real time at the session's rate (with a lead), sync packets about once a second;
/// stops on request.
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
        let nanosPerPacket = Double(packet) * 1e9 / Double(session.format.sampleRate)
        let anchor = NTPClock.nanosecondsNow() + UInt64(lead * 1e9)
        var index: UInt64 = 0
        var draining = false
        /// Frames of the packet being filled, held while the next song is being opened.
        var pending: [Int32] = []
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
                        pending += [Int32](repeating: 0, count: max(0, packet * 2 - pending.count))
                        session.send(samples: pending, startNanos: anchor)
                    }
                    return
                case .frames(let samples, let isDone):
                    pending += samples
                    done = isDone
                }
                if !pending.isEmpty {
                    if pending.count < packet * 2 { pending += [Int32](repeating: 0, count: packet * 2 - pending.count) }
                    session.send(samples: pending, startNanos: anchor)
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
