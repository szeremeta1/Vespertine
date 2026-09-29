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
    /// Every version of this song on its album (stereo and 5.1…), `track` among them; empty when there's one.
    var versions: [Track] = []
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
    /// Set while macOS renders the track itself (Dolby Atmos).
    private(set) var systemRendering: SystemRendering?
    private(set) var outputDevice: OutputDevice?
    private(set) var underruns = 0
    /// A network read stalled; output is paused until enough is buffered (resumes by itself).
    private(set) var buffering = false
    /// Live level (0…1, linear peak with decay) of every channel Nocturne sends, for multichannel meters.
    private(set) var channelLevels: [Float] = []
    private(set) var lastError: String?
    /// The chosen output playback is waiting for (it starts by itself when the output is back).
    private(set) var waitingForDevice: String?
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

    /// Whether the output wants a song's multichannel version over its stereo one (nil: can't tell now,
    /// e.g. the chosen output is reconnecting). Set by the app model.
    var wantsMultichannel: () -> Bool? = { nil }

    /// Queue entries for `tracks`, each playing the version of its song that suits the output.
    /// A song whose versions all arrive together (a whole SACD album) is queued once.
    private func entries(_ tracks: [Track]) -> [QueueEntry] {
        let versions = library.versions(of: tracks)
        let wanted = wantsMultichannel()
        var queued = Set<String>()
        return zip(tracks, versions).compactMap { track, versions in
            if versions.count > 1 {
                let key = versions.map(\.location).sorted().joined(separator: "\u{1F}")
                guard queued.insert(key).inserted else { return nil }
            }
            let chosen = wanted.flatMap { TrackVersions.choose(versions, multichannel: $0) } ?? track
            return QueueEntry(item: makeItem(chosen), track: chosen, versions: versions.count > 1 ? versions : [])
        }
    }

    /// The output changed (another device, Spatial Audio on or off): upcoming songs switch to the version
    /// that suits it. The song that's playing carries on as it is.
    func resolveVersions() {
        guard let wanted = wantsMultichannel() else { return }
        let start = (currentIndex ?? -1) + 1
        var changed = false
        func resolve(_ entry: QueueEntry) -> QueueEntry {
            guard entry.versions.count > 1, let chosen = TrackVersions.choose(entry.versions, multichannel: wanted),
                  chosen.id != entry.track.id else { return entry }
            changed = true
            return QueueEntry(item: makeItem(chosen, id: entry.id), track: chosen, versions: entry.versions)
        }
        let upcomingIDs = Set(queue.indices.filter { $0 >= start }.map { queue[$0].id })
        queue = queue.enumerated().map { $0.offset >= start ? resolve($0.element) : $0.element }
        originalOrder = originalOrder.map { upcomingIDs.contains($0.id) ? resolve($0) : $0 }
        if changed { syncMirror() }
    }

    func play(_ tracks: [Track], startAt index: Int = 0) {
        guard !tracks.isEmpty else { return }
        let entries = entries(tracks)
        guard !entries.isEmpty else { return }
        originalOrder = entries
        queue = entries
        // Start at the song that was asked for, whichever of its versions it was.
        let asked = tracks[min(max(0, index), tracks.count - 1)]
        currentIndex = entries.firstIndex { $0.track.location == asked.location || $0.versions.contains { $0.location == asked.location } }
            ?? min(max(0, index), entries.count - 1)
        if shuffle { applyShuffle(keepingCurrent: true) }
        // The engine is about to start over, so there's nothing to re-plan.
        mirror.update(queue.map(\.item), repeatMode: repeatMode)
        if let current { start(current) }
    }

    func playNext(_ tracks: [Track]) {
        let entries = entries(tracks)
        guard let i = currentIndex else { play(tracks); return }
        queue.insert(contentsOf: entries, at: i + 1)
        originalOrder.append(contentsOf: entries)
        syncMirror()
    }

    func addToQueue(_ tracks: [Track]) {
        let entries = entries(tracks)
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
        start(queue[i])
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

    /// Volume keys and headphone controls (the AirPods Max crown sends volume keys) act on the Mac's
    /// sound output, not on the device Nocturne plays to. Point the sound output at Nocturne's device
    /// while it plays so they adjust what you hear, and never change some other device's volume.
    /// (macOS never makes a device another app holds exclusively the sound output, so this needs shared mode.)
    private var lastFollowed: AudioObjectID?
    private func followSystemOutput(to device: OutputDevice) {
        guard settings.systemOutputFollowsPlayback, signalPath?.applied.exclusive != true, lastFollowed != device.id else { return }
        lastFollowed = device.id
        if DeviceControl.systemOutputDevice() != device.id { DeviceControl.setSystemOutputDevice(device.id) }
    }

    /// Starts copying the current and next network tracks locally (when the cache is on).
    private func prefetchNetworkTracks() {
        shares.prefetch(current: current?.track, upcoming: upcoming.map(\.track))
    }

    private func syncMirror(reloadCurrent: Bool = false) {
        mirror.update(queue.map(\.item), repeatMode: repeatMode)
        engine.queueChanged(reloadCurrent: reloadCurrent)
    }

    /// Files in the queue were moved or renamed (found by a rescan): point their entries at the new
    /// files so the rest of the queue keeps playing. The song that's playing isn't interrupted.
    func tracksMoved(_ moves: [Int64: Int64]) {
        let moved = library.tracks(ids: Array(Set(moves.values)))
        let byID = Dictionary(moved.compactMap { t in t.id.map { ($0, t) } }, uniquingKeysWith: { a, _ in a })
        func remap(_ entry: QueueEntry) -> QueueEntry {
            guard let old = entry.track.id, let new = moves[old], let track = byID[new] else { return entry }
            return QueueEntry(item: makeItem(track, id: entry.id), track: track, versions: entry.versions)
        }
        let remapped = queue.map(remap)
        guard remapped != queue else { return }
        queue = remapped
        originalOrder = originalOrder.map(remap)
        syncMirror()
    }

    func refreshReplayGain() {
        queue = queue.map { QueueEntry(item: makeItem($0.track, id: $0.id), track: $0.track, versions: $0.versions) }
        originalOrder = originalOrder.map { QueueEntry(item: makeItem($0.track, id: $0.id), track: $0.track, versions: $0.versions) }
        syncMirror(reloadCurrent: true)
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

    /// The song you asked for, until the engine reports it playing. Meanwhile the engine still describes the
    /// previous one (it may be opening a file on a share), and its position must not show under the new title.
    private var requested: UUID?
    /// Position and time of the last Now Playing update, for drift checks.
    private var nowPlayingAnchor: (position: TimeInterval, at: Date)?
    /// A seek in flight: the position you dragged to, until the engine gets there.
    private var requestedPosition: (seconds: TimeInterval, at: Date)?

    private func start(_ entry: QueueEntry) {
        requested = entry.id
        requestedPosition = nil
        position = 0
        duration = entry.track.duration
        engine.play(entry.item)
    }

    func togglePlayPause() {
        // Waiting for the chosen output to reconnect counts as playing: pressing pause cancels it.
        if waitingForDevice != nil { engine.pause(); return }
        switch state {
        case .playing: engine.pause()
        case .paused: engine.resume()
        case .stopped:
            if let current { start(current) }
            else if let first = queue.first { currentIndex = 0; start(first) }
        }
    }

    func next() {
        guard let i = currentIndex else { return }
        if i + 1 < queue.count { currentIndex = i + 1; start(queue[i + 1]) }
        else if repeatMode == .all, let first = queue.first { currentIndex = 0; start(first) }
    }

    func previous() {
        guard let i = currentIndex else { return }
        if position > 3 || i == 0 { seek(to: 0); return }
        currentIndex = i - 1
        start(queue[i - 1])
    }

    func seek(to seconds: TimeInterval) {
        engine.seek(to: seconds)
        position = seconds
        requestedPosition = (seconds, .now)
    }

    func stop() { requested = nil; requestedPosition = nil; engine.stop() }

    func clearError() { lastError = nil }

    // MARK: Engine events & polling

    private func handle(_ event: EngineEvent) {
        switch event {
        case .trackStarted(let item):
            if requested == item.id { requested = nil }
            if let i = queue.firstIndex(where: { $0.id == item.id }) { currentIndex = i }
            resolveVersions()
            trackStartedAt = .now
            scrobbledEntry = nil
            prefetchNetworkTracks()
            updateNowPlayingInfo()
            if settings.scrobble, let track = current?.track {
                Task { try? await ListenBrainzClient.shared.submit(track, kind: .playingNow) }
            }
        case .queueEnded:
            updateNowPlayingInfo()
        case .failed(let item, let message):
            requested = nil
            let track = queue.first { $0.id == item?.id }?.track ?? current?.track
            if let track, shares.isNetwork(track), !shares.isReachable(track), !shares.cache.isAvailable(track) {
                lastError = "“\(track.title)” is on a network share that isn’t connected. Nocturne reconnects automatically when the server is reachable."
            } else if let track, !FileManager.default.fileExists(atPath: track.filePath) {
                // Moved or deleted since the last scan: look again now; moved songs rejoin the queue.
                library.rescanForMissingFile(track)
                lastError = "“\(track.title)” was moved or deleted. Updating the library to find it…"
            } else {
                lastError = message
            }
        case .deviceLost(let name):
            lastError = "\(name) was disconnected. Playback paused."
        case .waitingForDevice(let name):
            lastError = "Waiting for \(name) to reconnect. Playback continues as soon as it’s back."
        case .deviceUnavailable(let name):
            lastError = "\(name) didn’t come back. Choose another output, or press play once it’s connected."
        }
    }

    private func poll() {
        let snap = engine.snapshot
        let stateChanged = state != snap.state
        state = snap.state
        // Until the engine reports the song you asked for, what it says is about the previous one.
        if let requested {
            if snap.item?.id == requested || snap.state == .stopped && snap.lastError != nil { self.requested = nil }
        }
        if let target = requestedPosition {
            // A seek lands when the engine's position gets there (or after a few seconds, whatever it says).
            if abs(snap.position - target.seconds) < 1.5 || Date().timeIntervalSince(target.at) > 4 { requestedPosition = nil }
        }
        if requested == nil, requestedPosition == nil {
            if abs(position - snap.position) > 0.02 { position = snap.position }
            if duration != snap.duration, snap.duration > 0 || snap.item == nil { duration = snap.duration }
        }
        if waitingForDevice != snap.waitingForDevice {
            waitingForDevice = snap.waitingForDevice
            if waitingForDevice == nil, lastError?.hasPrefix("Waiting for ") == true { lastError = nil }
        }
        if requested == nil, let id = snap.item?.id, let i = queue.firstIndex(where: { $0.id == id }), currentIndex != i {
            currentIndex = i
            updateNowPlayingInfo()
        }
        if stateChanged { updateNowPlayingInfo() }
        if signalPath != snap.signalPath { signalPath = snap.signalPath }
        if systemRendering != snap.systemRendering { systemRendering = snap.systemRendering }
        if outputDevice?.id != snap.outputDevice?.id || outputDevice?.nominalSampleRate != snap.outputDevice?.nominalSampleRate {
            outputDevice = snap.outputDevice
        }
        if state == .playing, let device = snap.outputDevice { followSystemOutput(to: device) } else if state != .playing { lastFollowed = nil }
        if underruns != snap.underruns { underruns = snap.underruns }
        if buffering != snap.isBuffering { buffering = snap.isBuffering }
        // Per-channel meters, only while a multichannel stream plays (cheap, but no need otherwise).
        if state == .playing, let path = signalPath, path.plan.channels > 2 || path.source.channels > 2 {
            let peaks = engine.takeChannelPeaks()
            if channelLevels.count != peaks.count { channelLevels = peaks }
            else { channelLevels = zip(channelLevels, peaks).map { max($1, $0 * 0.82) } }
        } else if !channelLevels.isEmpty, state != .playing {
            channelLevels = []
        }

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
        // macOS extrapolates the elapsed time from the rate; tell it again only when that drifts (a seek, a stall).
        if state == .playing, let anchor = nowPlayingAnchor,
           abs(anchor.position + Date().timeIntervalSince(anchor.at) - position) > 1 { updateNowPlayingInfo() }
    }

    // MARK: System Now Playing

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        Self.register(center.playCommand) { [weak self] _ in
            Task { @MainActor in if self?.state != .playing, self?.waitingForDevice == nil { self?.togglePlayPause() } }
        }
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
        nowPlayingAnchor = state == .playing ? (position, .now) : nil
        center.playbackState = state == .playing ? .playing : .paused
    }
}
