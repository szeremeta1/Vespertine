//
// Nocturne — play queue, transport and system integration (Now Playing, media keys, scrobbling).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import MediaPlayer
import NocturneAudio
import NocturneLibrary
import Observation
import Synchronization

struct QueueEntry: Identifiable, Hashable {
    let item: PlayableItem
    let track: Track
    var id: UUID { item.id }
}

nonisolated enum RepeatMode: String, CaseIterable, Sendable {
    case off, all, one
    var symbol: String { self == .one ? "repeat.1" : "repeat" }
}

/// Thread-safe copy of the play order, read by the engine thread for gapless hand-off.
nonisolated final class QueueMirror: Sendable {
    private struct State { var items: [PlayableItem] = []; var repeatMode: RepeatMode = .off }
    private let state = Mutex(State())

    func update(_ items: [PlayableItem], repeatMode: RepeatMode) {
        state.withLock { $0 = State(items: items, repeatMode: repeatMode) }
    }

    func item(after id: UUID) -> PlayableItem? {
        state.withLock { s in
            guard let index = s.items.firstIndex(where: { $0.id == id }) else { return nil }
            if s.repeatMode == .one { return s.items[index] }
            if index + 1 < s.items.count { return s.items[index + 1] }
            return s.repeatMode == .all ? s.items.first : nil
        }
    }
}

@Observable
@MainActor
final class PlayerController {
    let engine = PlaybackEngine()
    private let mirror = QueueMirror()
    private let library: LibraryStore
    private let settings: AppSettings
    private let shares: NetworkShareManager

    private(set) var queue: [QueueEntry] = []
    private var originalOrder: [QueueEntry] = []
    private(set) var currentIndex: Int?
    var shuffle = false { didSet { applyShuffle() } }
    var repeatMode: RepeatMode = .off { didSet { syncMirror() } }

    // Mirrors of the engine snapshot, updated ~15×/s only when they change.
    private(set) var state: PlaybackState = .stopped
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var signalPath: SignalPath?
    private(set) var outputDevice: OutputDevice?
    private(set) var underruns = 0
    private(set) var lastError: String?
    /// When the current track started (the Analysis tab follows whichever changed last).
    private(set) var trackStartedAt: Date = .distantPast
    /// Set while the user drags the scrubber.
    var scrubbing: Double?

    private var scrobbledEntry: UUID?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    var current: QueueEntry? { currentIndex.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }
    var isPlaying: Bool { state == .playing }
    var upcoming: ArraySlice<QueueEntry> {
        guard let i = currentIndex, i + 1 < queue.count else { return [] }
        return queue[(i + 1)...]
    }

    init(library: LibraryStore, settings: AppSettings, shares: NetworkShareManager) {
        self.library = library
        self.settings = settings
        self.shares = shares
        let mirror = self.mirror
        let cache = shares.cache
        engine.nextItemProvider = { finished in mirror.item(after: finished.id) }
        // Network files play from their local copy whenever one is complete (cached or kept offline).
        engine.urlResolver = { @Sendable item in item.cacheKey.flatMap { cache.localURL(forKey: $0) } ?? item.url }
        engine.eventHandler = { [weak self] event in self?.handle(event) }
        setupRemoteCommands()
        pollTask = Task { [weak self] in
            while !Task.isCancelled, self != nil {
                self?.poll()
                try? await Task.sleep(for: .milliseconds(66))
            }
        }
    }

    deinit { pollTask?.cancel() }

    // MARK: Queue

    func play(_ tracks: [Track], startAt index: Int = 0) {
        guard !tracks.isEmpty else { return }
        let entries = tracks.map { QueueEntry(item: makeItem($0), track: $0) }
        originalOrder = entries
        queue = entries
        currentIndex = min(max(0, index), entries.count - 1)
        if shuffle { applyShuffle(keepingCurrent: true) }
        syncMirror()
        if let current { engine.play(current.item) }
    }

    func playNext(_ tracks: [Track]) {
        let entries = tracks.map { QueueEntry(item: makeItem($0), track: $0) }
        guard let i = currentIndex else { play(tracks); return }
        queue.insert(contentsOf: entries, at: i + 1)
        originalOrder.append(contentsOf: entries)
        syncMirror()
    }

    func addToQueue(_ tracks: [Track]) {
        let entries = tracks.map { QueueEntry(item: makeItem($0), track: $0) }
        guard currentIndex != nil else { play(tracks); return }
        queue.append(contentsOf: entries)
        originalOrder.append(contentsOf: entries)
        syncMirror()
    }

    func removeFromQueue(_ id: UUID) {
        guard let i = queue.firstIndex(where: { $0.id == id }), i != currentIndex else { return }
        queue.remove(at: i)
        originalOrder.removeAll { $0.id == id }
        if let c = currentIndex, i < c { currentIndex = c - 1 }
        syncMirror()
    }

    func moveUpcoming(from source: IndexSet, to destination: Int) {
        guard let c = currentIndex else { return }
        var upcoming = Array(queue[(c + 1)...])
        upcoming.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue[...c]) + upcoming
        originalOrder = queue
        syncMirror()
    }

    func clearUpcoming() {
        guard let c = currentIndex else { return }
        queue = Array(queue[...c])
        let retained = Set(queue.map(\.id))
        originalOrder.removeAll { !retained.contains($0.id) }
        syncMirror()
    }

    func jump(to id: UUID) {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        currentIndex = i
        engine.play(queue[i].item)
    }

    private func applyShuffle(keepingCurrent: Bool = true) {
        guard !queue.isEmpty else { return }
        let current = self.current
        if shuffle {
            var rest = queue.filter { $0.id != current?.id }
            rest.shuffle()
            queue = (current.map { [$0] } ?? []) + rest
            currentIndex = current == nil ? nil : 0
        } else {
            queue = originalOrder
            currentIndex = current.flatMap { c in queue.firstIndex { $0.id == c.id } }
        }
        syncMirror()
    }

    /// Starts copying the current and next network tracks locally (when the cache is on).
    private func prefetchNetworkTracks() {
        shares.prefetch(current: current?.track, upcoming: upcoming.map(\.track))
    }

    private func syncMirror() {
        mirror.update(queue.map(\.item), repeatMode: repeatMode)
        engine.queueChanged()
    }

    func refreshReplayGain() {
        queue = queue.map { QueueEntry(item: makeItem($0.track, id: $0.id), track: $0.track) }
        originalOrder = originalOrder.map { QueueEntry(item: makeItem($0.track, id: $0.id), track: $0.track) }
        syncMirror()
    }

    private func makeItem(_ track: Track, id: UUID = UUID()) -> PlayableItem {
        PlayableItem(id: id, url: track.fileURL, trackID: track.id, regionStartFrame: track.cueStartFrame,
                     regionFrameLength: track.cueFrameLength, replayGainDB: replayGain(for: track),
                     cacheKey: shares.isNetwork(track) ? NetworkCache.key(for: track) : nil)
    }

    /// ReplayGain adjustment with peak protection (never pushes the peak over 0 dBFS).
    private func replayGain(for track: Track) -> Double? {
        let gain: Double?
        let peak: Double?
        switch settings.replayGain {
        case .off: return nil
        case .track: gain = track.rgTrackGain ?? track.rgAlbumGain; peak = track.rgTrackPeak ?? track.rgAlbumPeak
        case .album: gain = track.rgAlbumGain ?? track.rgTrackGain; peak = track.rgAlbumPeak ?? track.rgTrackPeak
        }
        guard let gain else { return nil }
        var db = gain + settings.replayGainPreampDB
        if let peak, peak > 0 { db = min(db, -20 * log10(peak)) }
        return db
    }

    // MARK: Transport

    func togglePlayPause() {
        switch state {
        case .playing: engine.pause()
        case .paused: engine.resume()
        case .stopped:
            if let current { engine.play(current.item) }
            else if let first = queue.first { currentIndex = 0; engine.play(first.item) }
        }
    }

    func next() {
        guard let i = currentIndex else { return }
        if i + 1 < queue.count { currentIndex = i + 1; engine.play(queue[i + 1].item) }
        else if repeatMode == .all, let first = queue.first { currentIndex = 0; engine.play(first.item) }
    }

    func previous() {
        guard let i = currentIndex else { return }
        if position > 3 || i == 0 { engine.seek(to: 0); return }
        currentIndex = i - 1
        engine.play(queue[i - 1].item)
    }

    func seek(to seconds: TimeInterval) {
        engine.seek(to: seconds)
        position = seconds
    }

    func stop() { engine.stop() }

    func clearError() { lastError = nil }

    // MARK: Engine events & polling

    private func handle(_ event: EngineEvent) {
        switch event {
        case .trackStarted(let item):
            if let i = queue.firstIndex(where: { $0.id == item.id }) { currentIndex = i }
            trackStartedAt = .now
            scrobbledEntry = nil
            prefetchNetworkTracks()
            updateNowPlayingInfo()
            if settings.scrobble, let track = current?.track {
                Task { try? await ListenBrainzClient.shared.submit(track, kind: .playingNow) }
            }
        case .queueEnded:
            updateNowPlayingInfo()
        case .failed(_, let message):
            if let track = current?.track, shares.isNetwork(track), !shares.isReachable(track), !shares.cache.isAvailable(track) {
                lastError = "“\(track.title)” is on a network share that isn’t connected. Nocturne reconnects automatically when the server is reachable."
            } else {
                lastError = message
            }
        case .deviceLost(let name):
            lastError = "\(name) was disconnected. Playback paused."
        }
    }

    private func poll() {
        let snap = engine.snapshot
        let stateChanged = state != snap.state
        state = snap.state
        if abs(position - snap.position) > 0.02 { position = snap.position }
        if duration != snap.duration { duration = snap.duration }
        if let id = snap.item?.id, let i = queue.firstIndex(where: { $0.id == id }), currentIndex != i {
            currentIndex = i
            updateNowPlayingInfo()
        }
        if stateChanged { updateNowPlayingInfo() }
        if signalPath != snap.signalPath { signalPath = snap.signalPath }
        if outputDevice?.id != snap.outputDevice?.id || outputDevice?.nominalSampleRate != snap.outputDevice?.nominalSampleRate {
            outputDevice = snap.outputDevice
        }
        if underruns != snap.underruns { underruns = snap.underruns }

        // Count a play (and scrobble) at half the track or four minutes, whichever comes first.
        if state == .playing, let entry = current, scrobbledEntry != entry.id, duration > 30,
           position >= min(duration / 2, 240) {
            scrobbledEntry = entry.id
            if let id = entry.track.id { library.markPlayed(id) }
            if settings.scrobble {
                let track = entry.track
                Task { try? await ListenBrainzClient.shared.submit(track, kind: .single) }
            }
        }
        if state == .playing { MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position }
    }

    // MARK: System Now Playing

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        Self.register(center.playCommand) { [weak self] _ in Task { @MainActor in if self?.state != .playing { self?.togglePlayPause() } } }
        Self.register(center.pauseCommand) { [weak self] _ in Task { @MainActor in self?.engine.pause() } }
        Self.register(center.togglePlayPauseCommand) { [weak self] _ in Task { @MainActor in self?.togglePlayPause() } }
        Self.register(center.nextTrackCommand) { [weak self] _ in Task { @MainActor in self?.next() } }
        Self.register(center.previousTrackCommand) { [weak self] _ in Task { @MainActor in self?.previous() } }
        Self.register(center.changePlaybackPositionCommand) { [weak self] position in
            guard let position else { return }
            Task { @MainActor in self?.seek(to: position) }
        }
    }

    /// Handlers may be invoked on any queue; keep them nonisolated and hop to the main actor.
    nonisolated private static func register(_ command: MPRemoteCommand, _ action: @escaping @Sendable (TimeInterval?) -> Void) {
        command.addTarget { event in
            action((event as? MPChangePlaybackPositionCommandEvent)?.positionTime)
            return .success
        }
    }

    /// MediaPlayer calls the request handler on its own queue, so it must not be main-actor isolated.
    nonisolated private static func artwork(_ image: NSImage) -> MPMediaItemArtwork {
        return MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    private func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = current?.track, state != .stopped else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.displayArtist,
            MPMediaItemPropertyAlbumTitle: track.displayAlbum,
            MPMediaItemPropertyPlaybackDuration: duration > 0 ? duration : track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0,
        ]
        if let key = track.artworkKey, let image = ArtworkCache.shared.cached(key, size: 600) ?? ArtworkCache.shared.cached(key, size: 160) {
            info[MPMediaItemPropertyArtwork] = Self.artwork(image)
        }
        center.nowPlayingInfo = info
        center.playbackState = state == .playing ? .playing : .paused
    }
}
