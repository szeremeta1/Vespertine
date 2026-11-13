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
        var wantsPlaying = false
        var shutDown = false
    }
    private let state = Locked(State())

    private let commands: AsyncStream<Command>
    private let enqueue: AsyncStream<Command>.Continuation
    private var worker: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    /// Every play, stop and restart counts up, so a slow one that was overtaken drops its result.
    private let generation = Locked(0)

    enum Command { case play(PlayableItem, at: TimeInterval, announce: Bool, generation: Int), pause, resume, seek(TimeInterval), stop, queueChanged, settings(RendererSettings), poll }

    public init(renderer: RendererDevice, transport: any RendererTransport, media: MediaServer, processed: (any ProcessedStreamMaking)? = nil,
                pollInterval: TimeInterval = 0.5) {
        self.renderer = renderer
        self.transport = transport
        self.media = media
        self.processed = processed
        (commands, enqueue) = AsyncStream<Command>.makeStream()
        worker = Task { [weak self, commands] in
            for await command in commands {
                guard let self else { return }
                await self.run(command)
            }
        }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pollInterval))
                guard let self else { return }
                if self.state.withLock({ $0.current != nil && !$0.shutDown }) { self.enqueue.yield(.poll) }
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
            $0.snapshot.state = .playing
            $0.snapshot.item = item
            $0.snapshot.position = seconds
            $0.wantsPlaying = true
            if announce { $0.snapshot.signalPath = nil }
        }
        enqueue.yield(.play(item, at: seconds, announce: announce, generation: g))
    }

    public func pause() { state.withLock { $0.wantsPlaying = false; if $0.snapshot.state == .playing { $0.snapshot.state = .paused } }; enqueue.yield(.pause) }
    public func resume() { state.withLock { $0.wantsPlaying = true; if $0.snapshot.state == .paused { $0.snapshot.state = .playing } }; enqueue.yield(.resume) }
    public func seek(to seconds: TimeInterval) { state.withLock { $0.snapshot.position = seconds; $0.anchor = nil }; enqueue.yield(.seek(seconds)) }
    public func stop() {
        generation.withLock { $0 += 1 }
        state.withLock { $0.wantsPlaying = false; $0.snapshot.state = .stopped }
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
        enqueue.finish()
        poller?.cancel()
    }

    /// The state, with the position moved on since the last poll while playing.
    public var snapshot: EngineSnapshot {
        state.withLock { s in
            var snap = s.snapshot
            if snap.state == .playing, let anchor = s.anchor {
                snap.position = anchor.position + Date().timeIntervalSince(anchor.at)
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
            case .pause: await retrying(String(localized: "pause")) { try await self.transport.pause() }
            case .resume: await retrying(String(localized: "play")) { try await self.transport.play() }
            case .seek(let seconds): await retrying(String(localized: "seek")) { try await self.seek(seconds) }
            case .stop:
                try? await transport.stop()
                let old = state.withLock { s -> [Entry] in
                    defer { s.current = nil; s.next = nil; s.anchor = nil; s.snapshot = EngineSnapshot() }
                    return [s.current, s.next].compactMap { $0 }
                }
                old.forEach(release)
            case .queueChanged: try await replanNext()
            case .settings(let settings): try await apply(settings)
            case .poll: await poll()
            }
        } catch {
            let item = state.withLock { $0.current?.item ?? $0.snapshot.item }
            log.error("Renderer \(self.renderer.name, privacy: .public): \(String(describing: error), privacy: .public)")
            fail(item, error)
        }
    }

    /// Pause, play and seek: a renderer busy changing state refuses them now and then (UPnP 701, "transition not available").
    /// Tried again once after a moment; refused again, the listener is told and the song plays on as it was.
    private func retrying(_ what: String, _ body: @escaping () async throws -> Void) async {
        do { try await body(); return } catch {}
        try? await Task.sleep(for: .milliseconds(300))
        do { try await body() } catch {
            let reason = (error as? UPnPError)?.message ?? error.localizedDescription
            emit(.notice(String(localized: "\(renderer.name) didn't \(what) (\(reason)).", comment: "%1$@ is a network player's name, %2$@ an action (pause, play, seek), %3$@ the reason.")))
        }
    }

    private func fail(_ item: PlayableItem?, _ error: Error) {
        let reason = (error as? UPnPError)?.message ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let message = String(localized: "\(renderer.name) couldn't play the song (\(reason)).", comment: "%1$@ is a network player's name, %2$@ the reason.")
        state.withLock { $0.snapshot.state = .stopped; $0.snapshot.lastError = message; $0.wantsPlaying = false }
        emit(.failed(item, message))
    }

    private func release(_ entry: Entry) {
        let url = entry.mediaURL, media = media
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
        do { current = try await entry(for: item, at: seconds) } catch { fail(item, error); return }
        current.announces = announce
        let next = await nextEntry(after: item)
        guard generation.withLock({ $0 }) == g else { release(current); next.map(release); return }
        try await transport.load(current: current.track, next: next?.track)
        let old = state.withLock { s -> [Entry] in
            defer {
                s.current = current
                s.next = next
                s.anchor = nil
                s.failedPolls = 0
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
    }

    private func seek(_ seconds: TimeInterval) async throws {
        guard let current = state.withLock({ $0.current }) else { return }
        if current.processedFile != nil {
            // A processed stream is written ahead and can't be seeked by the renderer: it starts again at the position.
            play(current.item, at: seconds, announce: false)
        } else {
            try await transport.seek(to: seconds)
            state.withLock { $0.anchor = nil; $0.snapshot.position = seconds }
        }
    }

    private func replanNext() async throws {
        guard let current = state.withLock({ $0.current }) else { return }
        let wanted = nextItemProvider?(current.item)
        let have = state.withLock { $0.next?.item }
        guard wanted?.id != have?.id else { return }
        let next = await nextEntry(after: current.item)
        try await transport.replaceNext(next?.track)
        let old = state.withLock { s -> Entry? in defer { s.next = next }; return s.next }
        old.map(release)
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
            try await transport.replaceNext(next?.track)
            let old = state.withLock { s -> Entry? in defer { s.next = next }; return s.next }
            old.map(release)
        }
    }

    private func poll() async {
        let status: RendererStatus
        do { status = try await transport.status() } catch {
            let lost = state.withLock { s -> Bool in s.failedPolls += 1; return s.failedPolls == 3 }
            if lost {
                let old = state.withLock { s -> [Entry] in
                    defer { s.current = nil; s.next = nil; s.anchor = nil; s.snapshot.state = .stopped; s.wantsPlaying = false }
                    return [s.current, s.next].compactMap { $0 }
                }
                old.forEach(release)
                emit(.deviceLost(renderer.name))
            }
            return
        }
        state.withLock { $0.failedPolls = 0 }
        guard var current = state.withLock({ $0.current }) else { return }
        // The renderer moved on to the next song by itself.
        if let uri = status.currentURI, let next = state.withLock({ $0.next }), uri == next.mediaURL {
            let following = await nextEntry(after: next.item)
            try? await transport.replaceNext(following?.track)
            let old = state.withLock { s -> Entry? in
                defer { s.current = next; s.next = following; s.snapshot.item = next.item; s.snapshot.signalPath = next.path; s.snapshot.duration = next.duration ?? 0 }
                return s.current
            }
            old.map(release)
            current = next
        }
        if status.currentURI == current.mediaURL, !current.announced, status.state == .playing || status.state == .transitioning {
            current.announced = true
            let item = current.item
            state.withLock { $0.current?.announced = true }
            if current.announces { emit(.trackStarted(item)) }
        }
        if let seek = state.withLock({ $0.pendingSeek }), status.state == .playing, status.currentURI == current.mediaURL {
            do {
                try await transport.seek(to: seek)
                state.withLock { $0.pendingSeek = nil }
            } catch {
                // Still settling: tried again at the next polls, then given up on (the song plays from where it is).
                let giveUp = state.withLock { s -> Bool in s.pendingSeekTries += 1; if s.pendingSeekTries >= 5 { s.pendingSeek = nil; return true }; return false }
                if giveUp { emit(.notice(String(localized: "\(renderer.name) didn't seek (\((error as? UPnPError)?.message ?? error.localizedDescription)).", comment: "%1$@ is a network player's name, %2$@ the reason."))) }
            }
            return
        }
        let ended = state.withLock { s -> Bool in
            let position = status.position + current.startOffset
            if let d = status.duration { s.snapshot.duration = d + current.startOffset }
            switch status.state {
            case .playing:
                s.snapshot.position = position
                s.anchor = (position, Date())
                if s.wantsPlaying { s.snapshot.state = .playing }
            case .paused:
                s.snapshot.position = position
                s.anchor = nil
                s.snapshot.state = .paused
            case .transitioning:
                break
            case .stopped, .noMedia:
                s.anchor = nil
                // Played to the end with nothing after it (or stopped on the renderer itself).
                if current.announced, s.next == nil, s.wantsPlaying {
                    s.snapshot.state = .stopped
                    s.wantsPlaying = false
                    return true
                }
            }
            return false
        }
        if ended { emit(.queueEnded) }
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
