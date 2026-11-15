//
// Vespertine: playing the queue on a network renderer, shaped like PlaybackEngine for the app: the same commands, the same
// `EngineSnapshot` and `EngineEvent`s. The queue stays Vespertine's: the renderer holds the song playing and the next one,
// and is told again whenever the next one changes. Its own clock decides when a song starts; position comes from polling it.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import os
import VespertineAudio

/// Makes the processed stream of a song: Vespertine's chain applied, encoded as 24-bit FLAC at the source rate, from
/// `startSeconds` on. Returns the file being written and the format of what it holds.
public protocol ProcessedStreamMaking: Sendable {
    func makeStream(item: PlayableItem, url: URL, settings: RendererSettings, startSeconds: TimeInterval) throws -> (GrowingFile, SourceFormat)
}

public final class RendererPlayback: @unchecked Sendable {
    public let renderer: RendererDevice
    private let transport: any RendererTransport
    private let media: MediaServer
    private let processed: (any ProcessedStreamMaking)?
    private let log = Logger(subsystem: "org.szeremeta.vespertine.player", category: "renderer")

    /// Called on the worker when a song is playing: the one after it, as for gapless playback.
    public var nextItemProvider: (@Sendable (PlayableItem) -> PlayableItem?)? {
        get { hooks.withLock { $0.next } }
        set { hooks.withLock { $0.next = newValue } }
    }
    /// The file to open for an item (a local copy of a network file), as the engine's.
    public var urlResolver: (@Sendable (PlayableItem) -> URL)? {
        get { hooks.withLock { $0.resolver } }
        set { hooks.withLock { $0.resolver = newValue } }
    }
    /// Title, artist and album for the renderer's display.
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

    /// One song as sent to the renderer.
    struct Entry {
        var item: PlayableItem
        var mediaURL: URL
        var track: RendererTrack
        var path: SignalPath
        var processedFile: GrowingFile?
        /// Where the stream starts in the song (a processed stream restarted at a position).
        var startOffset: TimeInterval
        var duration: TimeInterval?
        /// Became audible (the renderer reported it playing).
        var announced = false
        /// Say so with `trackStarted` (not for a restart of the same song at a position).
        var announces = true
    }

    private struct State {
        var snapshot = EngineSnapshot()
        var settings = RendererSettings()
        var current: Entry?
        var next: Entry?
        var anchor: (position: TimeInterval, at: Date)?
        var pendingSeek: TimeInterval?
        var pendingSeekTries = 0
        var failedPolls = 0
        /// When the polls began to fail (the renderer is lost once they have failed for `lostAfter`).
        var failingSince: Date?
        var wantsPlaying = false
        var shutDown = false
        /// A poll is waiting in the queue or running: the poller adds no other (a slow renderer builds no backlog).
        var pollQueued = false
        /// When the renderer was last told to play a song it hasn't started yet.
        var awaitingStartSince: Date?
        /// Polls in a row that found the renderer stopped.
        var stoppedPolls = 0
        /// The renderer has reported a position past the start of the song playing (some never report one).
        var reportsPosition = false
        /// How long the song playing has been heard, by Vespertine's own clock: what a song's end is judged by on a
        /// renderer that reports no position.
        var heard: TimeInterval = 0
        var lastPlayingPoll: Date?
    }
    private let state = Locked(State())

    private let commands: AsyncStream<Command>
    private let enqueue: AsyncStream<Command>.Continuation
    private var worker: Task<Void, Never>?
    /// Signalled when the worker has run its last command.
    private let workerDone = DispatchSemaphore(value: 0)
    private var poller: Task<Void, Never>?
    /// Every play, stop and restart counts up, so a slow one that was overtaken drops its result.
    private let generation = Locked(0)
    /// Keeps the Mac awake while the renderer is meant to be playing: nothing plays through Core Audio then, so macOS
    /// would otherwise let the Mac sleep in the middle of an album, and the renderer would lose the server it reads from.
    private let activity = PlaybackActivity(reason: "Playing to a network player")
    /// A renderer that hasn't started a song this long after being told to has failed to play it.
    let startTimeout: TimeInterval
    /// Status polls failing for this long (and at least three times) mean the renderer is gone.
    let lostAfter: TimeInterval
    /// The time, for everything judged by how long it has been (a renderer that has stopped answering, a song that hasn't
    /// started). The tests hand in a clock they move themselves.
    private let now: @Sendable () -> Date

    enum Command {
        case play(PlayableItem, at: TimeInterval, announce: Bool, generation: Int), pause, resume, seek(TimeInterval), stop, queueChanged, settings(RendererSettings), poll
        /// A poll a test asked for, which is told when it is done.
        case step(CheckedContinuation<Void, Never>)
    }

    /// `pollInterval` 0: the renderer is asked for its state only when `settleForTests` says so (a test that steps the
    /// polls itself).
    public init(renderer: RendererDevice, transport: any RendererTransport, media: MediaServer, processed: (any ProcessedStreamMaking)? = nil,
                pollInterval: TimeInterval = 0.5, startTimeout: TimeInterval = 15, lostAfter: TimeInterval = 10,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.startTimeout = startTimeout
        self.lostAfter = lostAfter
        self.now = now
        self.renderer = renderer
        self.transport = transport
        self.media = media
        self.processed = processed
        (commands, enqueue) = AsyncStream<Command>.makeStream()
        let done = workerDone
        worker = Task { [weak self, commands] in
            defer { done.signal() }
            for await command in commands {
                guard let self else { return }
                await self.run(command)
            }
        }
        guard pollInterval > 0 else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pollInterval))
                guard let self else { return }
                let due = self.state.withLock { s -> Bool in
                    guard s.current != nil, !s.shutDown, !s.pollQueued else { return false }
                    s.pollQueued = true
                    return true
                }
                if due { self.enqueue.yield(.poll) }
            }
        }
    }

    deinit {
        worker?.cancel()
        poller?.cancel()
    }

    // MARK: Commands (any thread)

    public func play(_ item: PlayableItem) { play(item, at: 0, announce: true) }

    /// Plays `item` from `seconds` in (an output change carrying a song over): the position is reached once the renderer
    /// plays, not asked of it while it is still loading.
    public func play(_ item: PlayableItem, at seconds: TimeInterval) { play(item, at: seconds, announce: true) }

    private func play(_ item: PlayableItem, at seconds: TimeInterval, announce: Bool) {
        let g = generation.withLock { $0 += 1; return $0 }
        state.withLock {
            // A restart of the song at a position (a seek in a processed stream, a change of settings) keeps what the
            // listener asked for: a paused song stays paused.
            if announce { $0.wantsPlaying = true }
            $0.snapshot.state = $0.wantsPlaying ? .playing : .paused
            $0.snapshot.item = item
            $0.snapshot.position = seconds
            if announce { $0.snapshot.signalPath = nil }
        }
        refreshActivity()
        enqueue.yield(.play(item, at: seconds, announce: announce, generation: g))
    }

    private func refreshActivity() {
        activity.set(state.withLock { $0.wantsPlaying && !$0.shutDown })
    }

    public func pause() {
        state.withLock { $0.wantsPlaying = false; if $0.snapshot.state == .playing { $0.snapshot.state = .paused } }
        refreshActivity()
        enqueue.yield(.pause)
    }
    public func resume() {
        state.withLock { s in
            s.wantsPlaying = true
            if s.snapshot.state == .paused { s.snapshot.state = .playing }
            if s.current?.announced == false { s.awaitingStartSince = now() }
        }
        refreshActivity()
        enqueue.yield(.resume)
    }
    public func seek(to seconds: TimeInterval) { state.withLock { $0.snapshot.position = seconds; $0.anchor = nil }; enqueue.yield(.seek(seconds)) }
    public func stop() {
        generation.withLock { $0 += 1 }
        state.withLock { $0.wantsPlaying = false; $0.snapshot.state = .stopped }
        refreshActivity()
        enqueue.yield(.stop)
    }
    public func queueChanged() { enqueue.yield(.queueChanged) }
    /// New settings. While a song plays, changes that restart it are applied 300 ms after the last one (a volume drag restarts
    /// the stream once, not at every step); with nothing playing they apply at once.
    public func update(settings: RendererSettings) {
        let g = settingsGeneration.withLock { $0 += 1; return $0 }
        guard state.withLock({ $0.current != nil }) else { enqueue.yield(.settings(settings)); return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, self.settingsGeneration.withLock({ $0 }) == g else { return }
            self.enqueue.yield(.settings(settings))
        }
    }
    private let settingsGeneration = Locked(0)

    /// Stops and lets go of the renderer (the output changed).
    public func shutdown() {
        stop()
        state.withLock { $0.shutDown = true }
        refreshActivity()
        enqueue.finish()
        poller?.cancel()
    }

    public func stopAndWait(timeout: TimeInterval) {
        shutdown()
        _ = workerDone.wait(timeout: .now() + timeout)
    }

    /// A song is loaded on the renderer and it is answering: the renderer is there, whatever a search on the network says.
    public var isEngaged: Bool { state.withLock { $0.current != nil && !$0.shutDown && $0.failingSince == nil } }

    /// The song playing started again at `seconds`, as a seek in a processed stream or a change of settings does.
    func restartForTests(at seconds: TimeInterval) {
        guard let item = state.withLock({ $0.current?.item }) else { return }
        play(item, at: seconds, announce: false)
    }

    /// Returns once every command asked for before this call has been carried out (a pause with its second try, a song
    /// loaded on the renderer) and the renderer has been asked for its state once more after them. The commands run one
    /// at a time in the order they were asked for, so a test that waits here has seen their whole effect, however slow
    /// the machine.
    func settleForTests() async {
        await withCheckedContinuation { done in
            if case .enqueued = enqueue.yield(.step(done)) {} else { done.resume() }
        }
    }

    /// Vespertine means the player to be playing (not paused or stopped by the listener).
    var wantsPlaying: Bool { state.withLock { $0.wantsPlaying } }

    /// The state, with the position moved on since the last poll while playing.
    public var snapshot: EngineSnapshot {
        state.withLock { s in
            var snap = s.snapshot
            if snap.state == .playing, let anchor = s.anchor {
                snap.position = anchor.position + now().timeIntervalSince(anchor.at)
                if snap.duration > 0 { snap.position = min(snap.position, snap.duration) }
            }
            return snap
        }
    }

    // MARK: Worker

    private func emit(_ event: EngineEvent) {
        guard let handler = eventHandler else { return }
        Task { @MainActor in handler(event) }
    }

    private func run(_ command: Command) async {
        do {
            switch command {
            case .play(let item, let at, let announce, let g):
                guard generation.withLock({ $0 }) == g else { return }   // overtaken by a later skip or stop
                try await start(item, at: at, announce: announce, generation: g)
            case .pause: await retrying(.pause, resync: true) { try await self.transport.pause() }
            case .resume: await retrying(.play, resync: true) { try await self.transport.play() }
            case .seek(let seconds): await retrying(.seek, resync: false) { try await self.seek(seconds) }
            case .stop:
                try? await transport.stop()
                let old = state.withLock { s -> [Entry] in
                    defer { s.current = nil; s.next = nil; s.anchor = nil; s.snapshot = EngineSnapshot() }
                    return [s.current, s.next].compactMap { $0 }
                }
                old.forEach(release)
            case .queueChanged:
                await planNextQuietly()
            case .settings(let settings):
                do { try await apply(settings) } catch {
                    log.error("Renderer \(self.renderer.name, privacy: .public), settings: \(String(describing: error), privacy: .public)")
                }
            case .poll:
                // Let go of (the output changed) before this poll's turn came: nothing more is asked of the renderer.
                let skip = state.withLock { s -> Bool in s.pollQueued = false; return s.shutDown }
                if !skip { await poll() }
            case .step(let done):
                if !state.withLock({ $0.shutDown }) { await poll() }
                done.resume()
            }
        } catch {
            let item = state.withLock { $0.current?.item ?? $0.snapshot.item }
            log.error("Renderer \(self.renderer.name, privacy: .public): \(String(describing: error), privacy: .public)")
            fail(item, error)
        }
    }

    /// Pause, play and seek: a renderer busy changing state refuses them now and then (UPnP 701, "transition not available").
    /// Tried again once after a moment; refused again, the listener is told and the song plays on as it was.
    /// `resync`: pause and play were shown at once (optimistically); refused, the snapshot and what Vespertine wants go back to what
    /// the player is really doing, so the interface doesn't say paused while it plays.
    private func retrying(_ what: RefusedAction, resync: Bool, _ body: @escaping () async throws -> Void) async {
        do { try await body(); return } catch {}
        try? await Task.sleep(for: .milliseconds(300))
        do { try await body() } catch {
            if resync, let status = try? await transport.status() {
                state.withLock { s in
                    switch status.state {
                    case .playing, .transitioning: s.wantsPlaying = true; s.snapshot.state = .playing
                    case .paused: s.wantsPlaying = false; s.snapshot.state = .paused; s.anchor = nil
                    case .stopped, .noMedia: s.wantsPlaying = false; s.snapshot.state = .stopped; s.anchor = nil
                    }
                }
            }
            refreshActivity()
            emit(.notice(what.message(player: renderer.name, reason: (error as? UPnPError)?.message ?? error.localizedDescription)))
        }
    }

    /// What a renderer refused, as a whole sentence for each (a sentence built from a verb can't be translated).
    enum RefusedAction {
        case pause, play, seek

        func message(player: String, reason: String) -> String {
            switch self {
            case .pause: String(localized: "\(player) didn't pause (\(reason)).", comment: "%1$@ is a network player's name, %2$@ the reason it gave.")
            case .play: String(localized: "\(player) didn't carry on playing (\(reason)).", comment: "%1$@ is a network player's name, %2$@ the reason it gave. The listener pressed Play on a paused song.")
            case .seek: String(localized: "\(player) didn't seek (\(reason)).", comment: "%1$@ is a network player's name, %2$@ the reason.")
            }
        }
    }

    private func fail(_ item: PlayableItem?, _ error: Error) {
        let reason = (error as? UPnPError)?.message ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let message = String(localized: "\(renderer.name) couldn't play the song (\(reason)).", comment: "%1$@ is a network player's name, %2$@ the reason.")
        state.withLock { $0.snapshot.state = .stopped; $0.snapshot.lastError = message; $0.wantsPlaying = false; $0.awaitingStartSince = nil }
        refreshActivity()
        emit(.failed(item, message))
    }

    private func release(_ entry: Entry) {
        let url = entry.mediaURL, media = media
        // A processed stream nobody heard (a song skipped while it was being prepared) goes at once: its encoder would
        // otherwise write the whole song for nothing.
        if entry.processedFile != nil, !entry.announced {
            media.release(url)
            return
        }
        // Renderers ask again for a while (a retry, a second range): a grace period before the token goes.
        Task.detached {
            try? await Task.sleep(for: .seconds(30))
            media.release(url)
        }
    }

    /// Preparing a song opens its file (a probe, a decoder, an encoder), which can block on a disk or a share: it runs on a
    /// queue of its own, never on Swift's cooperative pool.
    public static let preparationQueueLabel = "org.szeremeta.vespertine.upnp.prepare"
    private static let preparation = DispatchQueue(label: preparationQueueLabel, qos: .userInitiated)

    func entry(for item: PlayableItem, at seconds: TimeInterval) async throws -> Entry {
        try await withCheckedThrowingContinuation { continuation in
            Self.preparation.async {
                continuation.resume(with: Result { try self.prepareEntry(for: item, at: seconds) })
            }
        }
    }

    /// Prepares `item` to be sent: its media URL, metadata and signal path.
    private func prepareEntry(for item: PlayableItem, at seconds: TimeInterval) throws -> Entry {
        let url = urlResolver?(item) ?? item.url
        let described = try? SourceDescription.describe(item, url: url)
        let settings = state.withLock { $0.settings }
        let decision = RendererMode.decide(item: item, url: url, source: described?.format, settings: settings, capabilities: renderer.capabilities)
        let info = metadataProvider?(item) ?? RendererTrackInfo(title: url.deletingPathExtension().lastPathComponent)
        var processing: [SignalPath.RendererStage.Processing] = []
        let resource: MediaResource
        var sent: SourceFormat? = described?.format
        var file: GrowingFile?
        let mime: String
        switch decision {
        case .unplayable(let reason):
            throw RendererPlaybackError.unplayable(reason)
        case .passThrough(let type):
            mime = type
            resource = .file(url, mime: type)
        case .processed(let reasons):
            guard let processed else { throw RendererPlaybackError.unplayable(String(localized: "Processed streams aren't available.")) }
            processing = reasons
            let (growing, format) = try processed.makeStream(item: item, url: url, settings: settings, startSeconds: seconds)
            file = growing
            sent = format
            mime = "audio/flac"
            resource = .growing(growing, mime: mime)
        }
        guard let mediaURL = media.register(resource, toward: renderer.host) else {
            throw RendererPlaybackError.unplayable(String(localized: "no network interface reaches it"))
        }
        let size = file == nil ? (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil : nil
        let didl = DIDLLite.item(id: item.id.uuidString, info: info, url: mediaURL, mime: mime, size: size, format: sent)
        let source = described?.format ?? SourceFormat(encoding: .pcm, codec: url.pathExtension.uppercased(), sampleRate: 0, bitDepth: nil, channels: 2)
        let warnings = sent.map { renderer.capabilities.warnings(for: $0, sending: mime).map(\.message) } ?? []
        let stage = SignalPath.RendererStage(name: renderer.name, protocolName: renderer.kind.protocolName, processing: processing,
                                             sentCodec: file == nil ? source.codec : "FLAC", sentSampleRate: sent?.sampleRate ?? source.sampleRate,
                                             sentBitDepth: file == nil ? source.bitDepth : 24, sentChannels: sent?.channels ?? source.channels,
                                             gapless: transport.gapless, warnings: warnings)
        let volume: SignalPath.VolumeStage = settings.activeVolumeDB.map { .digital(dB: $0) } ?? .fixed
        let path = SignalPath.renderer(stage, source: source, decoderName: described?.decoderName ?? "", volume: volume,
                                       replayGainDB: processing.contains(.replayGain) ? item.replayGainDB : nil,
                                       equalizer: processing.contains(.equalizer) ? settings.activeEqualizer?.name : nil,
                                       roomCorrection: processing.contains(.roomCorrection) ? settings.activeRoomCorrection?.name : nil)
        return Entry(item: item, mediaURL: mediaURL, track: RendererTrack(uri: mediaURL, metadata: didl), path: path, processedFile: file,
                     startOffset: file == nil ? 0 : seconds, duration: info.duration)
    }

    private func nextEntry(after item: PlayableItem) async -> Entry? {
        guard let next = nextItemProvider?(item) else { return nil }
        do { return try await entry(for: next, at: 0) } catch {
            // Played (and failed) when it's reached, as the engine does with a file that won't open.
            log.error("Next song for \(self.renderer.name, privacy: .public) not prepared: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func start(_ item: PlayableItem, at seconds: TimeInterval, announce: Bool, generation g: Int) async throws {
        var current: Entry
        // The song already prepared as the next one (the listener skipped to it, or the renderer stopped before it) is
        // used as it is: a stream copied whole isn't copied again.
        let prepared = state.withLock { s -> Entry? in
            guard seconds == 0, let next = s.next, next.item.id == item.id else { return nil }
            s.next = nil
            return next
        }
        if let prepared { current = prepared } else {
            do { current = try await entry(for: item, at: seconds) } catch { fail(item, error); return }
        }
        current.announces = announce
        guard generation.withLock({ $0 }) == g else { release(current); return }
        // The song is sent first, alone: the one after it is prepared (a stream is copied whole) while this one plays.
        let next: Entry? = nil
        do {
            do { try await transport.load(current: current.track, next: nil) } catch let error where Self.isTransient(error) {
                // A renderer still changing state refuses now and then (UPnP 701): once more after a moment.
                try await Task.sleep(for: .milliseconds(300))
                try await transport.load(current: current.track, next: nil)
            }
        } catch {
            release(current)
            // What it was playing before isn't what Vespertine shows any more.
            try? await transport.stop()
            throw error
        }
        let old = state.withLock { s -> [Entry] in
            defer {
                s.current = current
                s.next = next
                s.anchor = nil
                s.failedPolls = 0
                s.failingSince = nil
                s.stoppedPolls = 0
                s.reportsPosition = false; s.heard = 0; s.lastPlayingPoll = nil
                s.awaitingStartSince = s.wantsPlaying ? now() : nil
                s.pendingSeek = current.processedFile == nil && seconds > 0 ? seconds : nil
                s.pendingSeekTries = 0
                s.snapshot.item = item
                s.snapshot.signalPath = current.path
                s.snapshot.position = seconds
                s.snapshot.duration = current.duration ?? 0
                s.snapshot.lastError = nil
                s.snapshot.state = s.wantsPlaying ? .playing : .paused
            }
            return [s.current, s.next].compactMap { $0 }.filter { $0.mediaURL != current.mediaURL && $0.mediaURL != next?.mediaURL }
        }
        old.forEach(release)
        if !state.withLock({ $0.wantsPlaying }) { try await transport.pause() }
        await planNextQuietly()
    }

    private func seek(_ seconds: TimeInterval) async throws {
        guard let current = state.withLock({ $0.current }) else { return }
        if current.processedFile != nil {
            // A processed stream is written ahead and can't be seeked by the renderer: it starts again at the position.
            play(current.item, at: seconds, announce: false)
        } else {
            try await transport.seek(to: seconds)
            state.withLock { $0.anchor = nil; $0.snapshot.position = seconds; $0.heard = seconds }
        }
    }

    /// A next song the renderer wasn't told about is no reason to stop the one playing: Vespertine starts it itself when
    /// this one ends.
    private func planNextQuietly() async {
        do { try await replanNext() } catch {
            log.error("Renderer \(self.renderer.name, privacy: .public), next song: \(String(describing: error), privacy: .public)")
        }
    }

    private func replanNext() async throws {
        guard let current = state.withLock({ $0.current }) else { return }
        let wanted = nextItemProvider?(current.item)
        let have = state.withLock { $0.next?.item }
        guard wanted?.id != have?.id else { return }
        let next = await nextEntry(after: current.item)
        do { try await setNext(next) } catch {
            // Not told: the renderer holds no next song, and Vespertine starts it itself when this one ends.
            next.map(release)
            let old = state.withLock { s -> Entry? in defer { s.next = nil }; return s.next }
            old.map(release)
            throw error
        }
        let old = state.withLock { s -> Entry? in defer { s.next = next }; return s.next }
        old.map(release)
    }

    /// "Transition not available": the renderer is between two states and takes the same command a moment later.
    static func isTransient(_ error: Error) -> Bool {
        if case .fault(code: 701, description: _)? = error as? UPnPError { return true }
        return false
    }

    /// Tells the renderer its next song, once more after a moment when it refuses (UPnP 701 while it changes state).
    private func setNext(_ next: Entry?) async throws {
        do { try await transport.replaceNext(next?.track) } catch let error where Self.isTransient(error) {
            try await Task.sleep(for: .milliseconds(300))
            try await transport.replaceNext(next?.track)
        }
    }

    private func apply(_ settings: RendererSettings) async throws {
        let before = state.withLock { s -> RendererSettings in defer { s.settings = settings }; return s.settings }
        guard before != settings, let current = state.withLock({ $0.current }) else { return }
        let url = urlResolver?(current.item) ?? current.item.url
        let decision = RendererMode.decide(item: current.item, url: url, source: current.path.source, settings: settings, capabilities: renderer.capabilities)
        let processing: [SignalPath.RendererStage.Processing] = if case .processed(let r) = decision { r } else { [] }
        // The song playing restarts where it is when what's done to it changes; the next one is prepared again either way.
        if processing != (current.path.renderer?.processing ?? []) || current.processedFile != nil {
            play(current.item, at: snapshot.position, announce: false)
        } else {
            let next = await nextEntry(after: current.item)
            do { try await setNext(next) } catch {
                next.map(release)
                let old = state.withLock { s -> Entry? in defer { s.next = nil }; return s.next }
                old.map(release)
                throw error
            }
            let old = state.withLock { s -> Entry? in defer { s.next = next }; return s.next }
            old.map(release)
        }
    }

    private func poll() async {
        let status: RendererStatus
        do { status = try await transport.status() } catch {
            // Gone once it has failed to answer for a while, not at a moment's trouble on the network: it may well be
            // playing on, and letting go of its songs would cut them off.
            let lostAfter = self.lostAfter
            let lost = state.withLock { s -> Bool in
                s.failedPolls += 1
                s.anchor = nil
                let since = s.failingSince ?? now()
                s.failingSince = since
                return s.failedPolls >= 3 && now().timeIntervalSince(since) >= lostAfter
            }
            if lost {
                let old = state.withLock { s -> [Entry] in
                    defer {
                        s.current = nil; s.next = nil; s.anchor = nil; s.snapshot.state = .stopped; s.wantsPlaying = false
                        s.failedPolls = 0; s.failingSince = nil; s.awaitingStartSince = nil
                    }
                    return [s.current, s.next].compactMap { $0 }
                }
                old.forEach(release)
                refreshActivity()
                emit(.deviceLost(renderer.name))
            }
            return
        }
        state.withLock { $0.failedPolls = 0; $0.failingSince = nil }
        guard var current = state.withLock({ $0.current }) else { return }
        var advanced = false
        // The renderer moved on to the next song by itself.
        if let uri = status.currentURI, let next = state.withLock({ $0.next }), uri == next.mediaURL {
            // The song now playing first; the one after it is prepared and sent by the queue's own step.
            let old = state.withLock { s -> Entry? in
                defer {
                    s.current = next; s.next = nil; s.snapshot.item = next.item; s.snapshot.signalPath = next.path
                    s.snapshot.duration = next.duration ?? 0; s.snapshot.position = 0; s.stoppedPolls = 0
                    s.reportsPosition = false; s.heard = 0; s.lastPlayingPoll = nil
                    s.awaitingStartSince = s.wantsPlaying ? now() : nil
                }
                return s.current
            }
            old.map(release)
            current = next
            advanced = true
        }
        if status.currentURI == current.mediaURL, !current.announced, status.state == .playing || status.state == .transitioning {
            current.announced = true
            let item = current.item
            state.withLock { $0.current?.announced = true; $0.awaitingStartSince = nil }
            if current.announces { emit(.trackStarted(item)) }
        }
        // The song after the one it moved on to is prepared and sent now, while this one plays.
        if advanced { await planNextQuietly() }
        if let seek = state.withLock({ $0.pendingSeek }), status.state == .playing, status.currentURI == current.mediaURL {
            do {
                try await transport.seek(to: seek)
                state.withLock { $0.pendingSeek = nil; $0.heard = seek }
            } catch {
                // Still settling: tried again at the next polls, then given up on (the song plays from where it is).
                let giveUp = state.withLock { s -> Bool in s.pendingSeekTries += 1; if s.pendingSeekTries >= 5 { s.pendingSeek = nil; return true }; return false }
                if giveUp { emit(.notice(String(localized: "\(renderer.name) didn't seek (\((error as? UPnPError)?.message ?? error.localizedDescription)).", comment: "%1$@ is a network player's name, %2$@ the reason."))) }
            }
            return
        }
        // Told to play and still not playing: the renderer couldn't fetch or decode the song, and says nothing about it.
        if !current.announced, let since = state.withLock({ $0.wantsPlaying ? $0.awaitingStartSince : nil }),
           now().timeIntervalSince(since) >= startTimeout {
            let old = state.withLock { s -> [Entry] in
                defer { s.current = nil; s.next = nil; s.anchor = nil; s.awaitingStartSince = nil }
                return [s.current, s.next].compactMap { $0 }
            }
            old.forEach(release)
            try? await transport.stop()
            fail(current.item, RendererPlaybackError.unplayable(String(localized: "it didn't start playing", comment: "The reason a network player couldn't play a song, inside “%1$@ couldn't play the song (%2$@).”: told to play, it never started. Lowercase, no full stop.")))
            return
        }
        enum Outcome { case nothing, ended, stoppedThere }
        let outcome = state.withLock { s -> Outcome in
            let position = status.position + current.startOffset
            if let d = status.duration { s.snapshot.duration = d + current.startOffset }
            switch status.state {
            case .playing:
                s.stoppedPolls = 0
                let at = now()
                if status.position >= 1 { s.reportsPosition = true }
                // A long gap between two polls (the Mac slept, the renderer was slow to answer) isn't counted as heard.
                if let last = s.lastPlayingPoll { s.heard += min(at.timeIntervalSince(last), 2) }
                s.lastPlayingPoll = at
                s.snapshot.position = position
                s.anchor = (position, at)
                if s.wantsPlaying { s.snapshot.state = .playing }
            case .paused:
                s.stoppedPolls = 0
                s.lastPlayingPoll = nil
                s.snapshot.position = position
                s.anchor = nil
                s.snapshot.state = .paused
            case .transitioning:
                // Buffering: the position waits with it.
                s.anchor = nil
                s.lastPlayingPoll = nil
            case .stopped, .noMedia:
                s.anchor = nil
                s.lastPlayingPoll = nil
                guard current.announced, s.wantsPlaying else { break }
                // Twice in a row: a renderer passes through "stopped" for a moment after a seek or between two songs.
                s.stoppedPolls += 1
                guard s.stoppedPolls >= 2 else { break }
                s.stoppedPolls = 0
                // At the song's end (or with no length to judge by) it played to the end. Anywhere else it was stopped
                // on the renderer itself, or lost its stream (the Mac slept): the song stays where it is, paused.
                let duration = s.snapshot.duration
                let reached = s.reportsPosition ? s.snapshot.position : current.startOffset + s.heard
                if duration <= 0 || reached >= duration - 10 { return .ended }
                s.snapshot.state = .paused
                s.wantsPlaying = false
                return .stoppedThere
            }
            return .nothing
        }
        switch outcome {
        case .nothing:
            break
        case .stoppedThere:
            refreshActivity()
        case .ended:
            // The renderer didn't go on by itself (it holds no next song, wasn't told in time, or doesn't join songs):
            // Vespertine starts the next one, and a song that can't be played fails there, as it does on the engine.
            if let following = nextItemProvider?(current.item) {
                play(following, at: 0, announce: true)
            } else {
                state.withLock { $0.snapshot.state = .stopped; $0.wantsPlaying = false }
                refreshActivity()
                emit(.queueEnded)
            }
        }
    }
}

public enum RendererPlaybackError: Error, LocalizedError {
    case unplayable(String)
    public var errorDescription: String? {
        switch self {
        case .unplayable(let reason): reason
        }
    }
}
