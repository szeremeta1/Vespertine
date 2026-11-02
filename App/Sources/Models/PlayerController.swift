//
// Vespertine — play queue, transport and system integration (Now Playing, media keys, scrobbling, Discord).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import MediaPlayer
import VespertineAudio
import VespertineLibrary
import Observation

struct QueueEntry: Identifiable, Hashable {
    let item: PlayableItem
    let track: Track
    /// Every version of this song on its album (stereo and 5.1…), `track` among them; empty when there's one.
    var versions: [Track] = []
    /// Added with Play Next or Add to Queue: listed under Playing Next, ahead of the rest of what was playing.
    var queuedByUser = false
    var id: UUID { item.id }

    /// The same entry (same place in the queue, same flags) playing `track` through `item`.
    func replacing(_ track: Track, item: PlayableItem) -> QueueEntry {
        QueueEntry(item: item, track: track, versions: versions, queuedByUser: queuedByUser)
    }
}

nonisolated enum RepeatMode: String, CaseIterable, Sendable {
    case off, all, one
    var symbol: String { self == .one ? "repeat.1" : "repeat" }
    var spokenName: String {
        switch self {
        case .off: String(localized: "Off", comment: "Repeat mode, read by VoiceOver: repeat is off.")
        case .all: String(localized: "All", comment: "Repeat mode, read by VoiceOver: repeat the whole queue.")
        case .one: String(localized: "One", comment: "Repeat mode, read by VoiceOver: repeat the current song.")
        }
    }
}

/// Thread-safe copy of the play order, read by the engine thread for gapless hand-off.
nonisolated final class QueueMirror: Sendable {
    private struct State { var items: [PlayableItem] = []; var repeatMode: RepeatMode = .off }
    private let state = Locked(State())

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
    var shuffle = false { didSet { if !settingShuffle { applyShuffle() } } }
    /// Set while `play` turns shuffle on or off for the queue it's about to build (the old queue stays as it is).
    @ObservationIgnored private var settingShuffle = false
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
    /// Live level (0…1, linear peak with decay) of every channel Vespertine sends, for multichannel meters.
    private(set) var channelLevels: [Float] = []
    private(set) var lastError: String?
    /// The "Waiting for …" message last shown, so it's cleared once the output is back (whatever the language).
    @ObservationIgnored private var waitingMessage: String?
    /// The chosen output playback is waiting for (it starts by itself when the output is back).
    private(set) var waitingForDevice: String?
    /// When the current track started (the Analysis tab follows whichever changed last).
    private(set) var trackStartedAt: Date = .distantPast
    /// Set while the user drags the scrubber.
    var scrubbing: Double?

    private var scrobbledEntry: UUID?
    /// The song last added to the play history, so one listen is added once.
    @ObservationIgnored private var historyEntry: UUID?
    /// Time actually listened to the current song, for counting a play: seeking doesn't add to it.
    @ObservationIgnored private var listened: TimeInterval = 0
    /// The entry `listened` is about: the engine moves on to the next song (gapless) a moment before it reports it.
    @ObservationIgnored private var listenedEntry: UUID?
    @ObservationIgnored private var lastListenTick: Date?
    /// A seek restarts the engine's segment, which reports the song as started again (once it plays, so after
    /// resuming if it was paused): still the same play. Cleared by that report, or by playing something else or stopping,
    /// never by a clock, so a song seeked while paused and resumed minutes later isn't counted twice.
    @ObservationIgnored private var seekRestart: UUID?
    /// A pause or resume the engine hasn't acted on yet: the button shows it right away, and the engine's older state
    /// doesn't undo it. The engine thread can be stuck for a long time in one read from a slow network share after the
    /// audio is already muted, and a second press meanwhile must resume, not pause again. Cleared once the engine
    /// reports that state or anything other than the one it was leaving (it stopped), or when another song is started.
    /// A resume also gives up after half a minute: unlike a pause, the engine can decline it (nothing left to resume).
    @ObservationIgnored private var requestedState: (state: PlaybackState, from: PlaybackState, at: Date)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var adoptedSource: UUID?
    /// The Discord status, while Settings › Online turns it on.
    let discord = DiscordPresence()

    var current: QueueEntry? { currentIndex.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }
    var isPlaying: Bool { state == .playing }
    var loading: Bool { (buffering && state != .paused) || (requested != nil && current.map { shares.isNetwork($0.track) } == true) }
    var canCancelLoading: Bool { loading && requested != nil }
    var upcoming: ArraySlice<QueueEntry> {
        guard let i = currentIndex, i + 1 < queue.count else { return [] }
        return queue[(i + 1)...]
    }
    /// The songs added with Play Next or Add to Queue that come next, before the rest of what was playing.
    var playingNext: ArraySlice<QueueEntry> { upcoming.prefix { $0.queuedByUser } }
    /// What plays after Playing Next: the rest of the album, playlist or list that was started.
    var continuing: ArraySlice<QueueEntry> { upcoming.dropFirst(playingNext.count) }

    init(library: LibraryStore, settings: AppSettings, shares: NetworkShareManager) {
        self.library = library
        self.settings = settings
        self.shares = shares
        let mirror = self.mirror
        let cache = shares.cache
        engine.nextItemProvider = { finished in mirror.item(after: finished.id) }
        // Network files play from their local copy whenever one is complete (cached or kept offline).
        engine.urlResolver = { @Sendable item in item.cacheKey.flatMap { cache.localURL(forKey: $0) } ?? item.url }
        // Smart Mix: what the library has measured of a song's ends (none yet: the engine measures them as it plays).
        let database = library.database
        engine.transitionProfileProvider = { @Sendable item in item.trackID.flatMap { try? database.transitionProfile(trackID: $0) } }
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
    /// A song whose versions all arrive together (a whole SACD album) is queued once. With `allowing`, only
    /// versions it accepts are considered (a filtered page asked for multichannel: stereo versions stay out).
    private func entries(_ tracks: [Track], allowing: ((Track) -> Bool)? = nil, transitions: TransitionOverride? = nil) -> [QueueEntry] {
        let versions = library.versions(of: tracks).enumerated().map { i, versions in
            guard let allowing, versions.count > 1 else { return versions }
            return versions.filter { $0.location == tracks[i].location || allowing($0) }
        }
        let wanted = wantsMultichannel()
        var queued = Set<String>()
        return zip(tracks, versions).compactMap { track, versions in
            if versions.count > 1 {
                let key = versions.map(\.location).sorted().joined(separator: "\u{1F}")
                guard queued.insert(key).inserted else { return nil }
            }
            // A copy of the same song plays as the best copy; versions follow the output (stereo or surround).
            let isLocal: (Track) -> Bool = { [shares] in !shares.isNetwork($0) }
            let chosen = versions.count > 1 ? TrackVersions.choose(versions, multichannel: wanted ?? track.isMultichannel, isLocal: isLocal) ?? track : track
            return QueueEntry(item: makeItem(chosen, transitions: transitions), track: chosen, versions: versions.count > 1 ? versions : [])
        }
    }

    /// The output changed (another device, Spatial Audio on or off): upcoming songs switch to the version
    /// that suits it. The song that's playing carries on as it is.
    func resolveVersions() {
        guard let wanted = wantsMultichannel() else { return }
        let start = (currentIndex ?? -1) + 1
        var changed = false
        func resolve(_ entry: QueueEntry) -> QueueEntry {
            guard entry.versions.count > 1,
                  let chosen = TrackVersions.choose(entry.versions, multichannel: wanted, isLocal: { [shares] in !shares.isNetwork($0) }),
                  chosen.id != entry.track.id else { return entry }
            changed = true
            return entry.replacing(chosen, item: makeItem(chosen, id: entry.id, transitions: entry.item.context?.override))
        }
        let upcomingIDs = Set(queue.indices.filter { $0 >= start }.map { queue[$0].id })
        queue = queue.enumerated().map { $0.offset >= start ? resolve($0.element) : $0.element }
        originalOrder = originalOrder.map { upcomingIDs.contains($0.id) ? resolve($0) : $0 }
        if changed { syncMirror() }
    }

    /// Plays `tracks` from `index`. `shuffled` turns shuffle on (starting at a random song) or off (in order, as
    /// a Play button does); nil keeps the shuffle setting (double-clicking a song). `allowing`: see `entries`.
    /// `transitions`: the playlist's own transitions, when it's a playlist that has them (they go with its songs).
    func play(_ tracks: [Track], startAt index: Int = 0, shuffled: Bool? = nil, allowing: ((Track) -> Bool)? = nil,
              transitions: TransitionOverride? = nil) {
        guard !tracks.isEmpty else { return }
        let entries = entries(tracks, allowing: allowing, transitions: transitions)
        guard !entries.isEmpty else { return }
        if let shuffled, shuffled != shuffle {
            settingShuffle = true
            shuffle = shuffled
            settingShuffle = false
        }
        originalOrder = entries
        queue = entries
        if shuffled == true {
            currentIndex = entries.indices.randomElement()
        } else {
            // Start at the song that was asked for, whichever of its versions it was.
            let asked = tracks[min(max(0, index), tracks.count - 1)]
            currentIndex = entries.firstIndex { $0.track.location == asked.location || $0.versions.contains { $0.location == asked.location } }
                ?? min(max(0, index), entries.count - 1)
        }
        if shuffle { applyShuffle(keepingCurrent: true) }
        // The engine is about to start over, so there's nothing to re-plan.
        mirror.update(queue.map(\.item), repeatMode: repeatMode)
        if let current { start(current) }
    }

    /// Plays `tracks` right after the current song, ahead of anything else in Playing Next.
    func playNext(_ tracks: [Track], allowing: ((Track) -> Bool)? = nil) {
        guard let i = currentIndex else { play(tracks, allowing: allowing); return }
        let entries = entries(tracks, allowing: allowing).map { var e = $0; e.queuedByUser = true; return e }
        queue.insert(contentsOf: entries, at: i + 1)
        originalOrder.append(contentsOf: entries)
        syncMirror()
    }

    /// Adds `tracks` to the end of Playing Next: after the songs already added, before the rest of what was
    /// playing (as Apple Music's Play Last does), so they're heard without first sitting through the whole album.
    func addToQueue(_ tracks: [Track], allowing: ((Track) -> Bool)? = nil) {
        guard let i = currentIndex else { play(tracks, allowing: allowing); return }
        let entries = entries(tracks, allowing: allowing).map { var e = $0; e.queuedByUser = true; return e }
        queue.insert(contentsOf: entries, at: i + 1 + playingNext.count)
        originalOrder.append(contentsOf: entries)
        syncMirror()
    }

    func removeFromQueue(_ id: UUID) { removeFromQueue([id]) }

    /// Removes songs from the queue by entry, never the one playing. Entries no longer queued are ignored, so a
    /// request made from a list drawn a moment ago (the song ended meanwhile) can't remove the wrong song.
    func removeFromQueue(_ ids: some Collection<UUID>) {
        let remove = Set(ids).subtracting(current.map { [$0.id] } ?? [])
        guard queue.contains(where: { remove.contains($0.id) }) else { return }
        let currentID = current?.id
        queue.removeAll { remove.contains($0.id) }
        originalOrder.removeAll { remove.contains($0.id) }
        currentIndex = currentID.flatMap { id in queue.firstIndex { $0.id == id } }
        syncMirror()
    }

    /// Moves upcoming entries (in the order given) to just before `target`, or to the end when it's nil. Entries
    /// that are playing, already played or gone are left alone. `playingNext` says whether they join Playing Next
    /// or play as part of the rest; nil decides by where they land (among Playing Next's songs, they join it).
    func moveUpcoming(_ ids: [UUID], before target: UUID?, playingNext: Bool? = nil) {
        guard let c = currentIndex else { return }
        let upcoming = Array(queue[(c + 1)...])
        let byID = Dictionary(upcoming.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<UUID>()
        let moving = ids.filter { byID[$0] != nil && $0 != target && seen.insert($0).inserted }
        guard !moving.isEmpty else { return }
        var rest = upcoming.filter { !seen.contains($0.id) }
        let at = target.flatMap { t in rest.firstIndex { $0.id == t } } ?? rest.count
        let block = rest.prefix { $0.queuedByUser }.count
        let joins = playingNext ?? (at < block || (at == block && block > 0 && moving.allSatisfy { byID[$0]!.queuedByUser }))
        rest.insert(contentsOf: moving.map { var e = byID[$0]!; e.queuedByUser = joins; return e }, at: at)
        // Songs left behind Playing Next's last one aren't part of it any more (they'd play after the rest started).
        if let firstOther = rest.firstIndex(where: { !$0.queuedByUser }) {
            for i in rest.indices where i > firstOther { rest[i].queuedByUser = false }
        }
        queue = Array(queue[...c]) + rest
        originalOrder = queue
        syncMirror()
    }

    /// Moves upcoming entries by their places in `upcoming` (as a list's drag reports them).
    func moveUpcoming(from source: IndexSet, to destination: Int) {
        let shown = Array(upcoming)
        let ids = source.sorted().compactMap { shown.indices.contains($0) ? shown[$0].id : nil }
        moveUpcoming(ids, before: destination < shown.count ? shown[destination].id : nil)
    }

    /// Moves upcoming entries (in the order they play) to the front of Playing Next.
    func playNext(entries ids: [UUID]) {
        let chosen = Set(ids)
        let shown = Array(upcoming)
        let ordered = shown.map(\.id).filter(chosen.contains)
        // Before the first song not moved: a song already at the front stays where it is and joins Playing Next.
        moveUpcoming(ordered, before: shown.first { !chosen.contains($0.id) }?.id, playingNext: true)
    }

    /// Empties Up Next (only the songs that come after the one playing).
    func clearUpcoming() {
        guard let c = currentIndex else { return }
        removeFromQueue(queue[(c + 1)...].map(\.id))
    }

    /// Empties Playing Next: the rest of what was playing carries on after the current song.
    func clearPlayingNext() { removeFromQueue(playingNext.map(\.id)) }

    func jump(to id: UUID) {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        currentIndex = i
        start(queue[i])
    }

    /// Shuffling mixes what was playing, never the songs you added to Playing Next: they still come next, in
    /// your order. Turning shuffle off puts the rest back in its order, after them.
    private func applyShuffle(keepingCurrent: Bool = true) {
        guard !queue.isEmpty else { return }
        let current = self.current
        let next = Array(playingNext)
        let nextIDs = Set(next.map(\.id))
        if shuffle {
            var rest = queue.filter { $0.id != current?.id && !nextIDs.contains($0.id) }
            rest.shuffle()
            queue = (current.map { [$0] } ?? []) + next + rest
            currentIndex = current == nil ? nil : 0
        } else {
            let ordered = originalOrder.filter { !nextIDs.contains($0.id) }
            if let current, let c = ordered.firstIndex(where: { $0.id == current.id }) {
                queue = Array(ordered[...c]) + next + Array(ordered[(c + 1)...])
                currentIndex = c
            } else {
                queue = originalOrder
                currentIndex = current.flatMap { c in queue.firstIndex { $0.id == c.id } }
            }
        }
        syncMirror()
    }

    /// Volume keys and headphone controls (the AirPods Max crown sends volume keys) act on the Mac's
    /// sound output, not on the device Vespertine plays to. Point the sound output at Vespertine's device
    /// while it plays so they adjust what you hear, and never change some other device's volume.
    /// (macOS never makes a device another app holds exclusively the sound output, so this needs shared mode.)
    private var lastFollowed: AudioObjectID?
    /// With exclusive access the device can't be the sound output; the relay carries the keys to it instead, when
    /// Settings › Playback › Volume allows it.
    let volumeRelay = VolumeRelay()
    /// The device the relay was last told to follow (nil: none).
    private var relayedDevice: AudioObjectID?

    /// QA: `-VespertineVolumeRelay NO` keeps the relay off whatever the setting, so a screenshot run never touches
    /// another output's level.
    nonisolated private static let relayOffForQA = LaunchArguments().string(forKey: "VespertineVolumeRelay") == "NO"

    /// Points the relay at the device Vespertine plays on, or at nothing while the setting is off (checked on every
    /// poll, so turning it off takes effect at once). Turned off while it relays, the sound output standing in gets its
    /// own volume and mute back.
    private func syncVolumeRelay() {
        let device = settings.relayVolumeKeys && !Self.relayOffForQA ? outputDevice?.id : nil
        guard relayedDevice != device else { return }
        relayedDevice = device
        volumeRelay.follow(device)
    }
    nonisolated private static let halQueue = DispatchQueue(label: "org.szeremeta.vespertine.system-output", qos: .userInitiated)
    private func followSystemOutput(to device: OutputDevice) {
        guard settings.systemOutputFollowsPlayback, signalPath?.applied.exclusive != true, lastFollowed != device.id else { return }
        lastFollowed = device.id
        // Off the main thread: this runs as playback starts, while the HAL is busy with the device.
        let id = device.id
        Self.halQueue.async { if DeviceControl.systemOutputDevice() != id { DeviceControl.setSystemOutputDevice(id) } }
    }

    /// Starts copying the current and next network tracks locally (when the cache is on).
    private func prefetchNetworkTracks() {
        // The engine stages current/next before decoding. An independent copy of the same playing file
        // would compete for the connection; explicit Keep Offline jobs remain owned by NetworkCache.
        shares.cache.keepOnly([])
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
            return entry.replacing(track, item: makeItem(track, id: entry.id, transitions: entry.item.context?.override))
        }
        let remapped = queue.map(remap)
        guard remapped != queue else { return }
        queue = remapped
        originalOrder = originalOrder.map(remap)
        syncMirror()
    }

    func refreshReplayGain() {
        queue = queue.map { $0.replacing($0.track, item: makeItem($0.track, id: $0.id, transitions: $0.item.context?.override)) }
        originalOrder = originalOrder.map { $0.replacing($0.track, item: makeItem($0.track, id: $0.id, transitions: $0.item.context?.override)) }
        syncMirror(reloadCurrent: true)
    }

    private func makeItem(_ track: Track, id: UUID = UUID(), transitions: TransitionOverride? = nil) -> PlayableItem {
        var context = Self.transitionContext(track)
        context.override = transitions
        return PlayableItem(id: id, url: track.fileURL, trackID: track.id, regionStartFrame: track.cueStartFrame,
                            regionFrameLength: track.cueFrameLength, replayGainDB: replayGain(for: track),
                            cacheKey: shares.isNetwork(track) && !track.isDVDFolderTrack ? NetworkCache.key(for: track) : nil,
                            sacdArea: track.sacdArea, dvd: track.dvdStream, context: context)
    }

    /// How `entry` joins the song before it in the queue, while transitions are on: what the engine planned for the
    /// boundary after the song playing, else what can be told before the songs are opened (albums, genres, playlists).
    func join(before entry: QueueEntry) -> TransitionDecision? {
        guard settings.transitions.enabled, let i = queue.firstIndex(where: { $0.id == entry.id }), i > 0 else { return nil }
        let previous = queue[i - 1]
        if previous.id == current?.id, let planned = signalPath?.transition?.next { return planned }
        return TransitionPlanner.decide(settings.transitions, from: previous.item, format: .unknown, to: entry.item, format: .unknown)
    }

    /// What transitions need to know about a song: its album (only when it has one: songs without an album tag would
    /// all share the artist's "Unknown Album"), its place on it, and its genre.
    nonisolated static func transitionContext(_ track: Track) -> TransitionContext {
        transitionContext(album: track.album, albumKey: track.albumKey, disc: track.discNumber, track: track.trackNumber, genre: track.genre)
    }

    nonisolated static func transitionContext(album: String?, albumKey: String, disc: Int?, track: Int?, genre: String?) -> TransitionContext {
        let hasAlbum = !(album ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        return TransitionContext(albumKey: hasAlbum ? albumKey : nil, discNumber: disc, trackNumber: track, genre: genre)
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
        requestedState = nil
        seekRestart = nil
        requestedPosition = nil
        position = 0
        duration = entry.track.duration
        // The signal path, meters and Now Playing describe the new song from now on (it's still opening).
        signalPath = nil
        systemRendering = nil
        channelLevels = []
        shares.skipped(to: entry.track, upcoming: upcoming.map(\.track))
        engine.play(entry.item)
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        if canCancelLoading { stop(); return }
        // Waiting for the chosen output to reconnect counts as playing: pressing pause cancels it.
        if waitingForDevice != nil { engine.pause(); return }
        switch state {
        case .playing: pause()
        case .paused: request(.playing); engine.resume()
        case .stopped:
            if let current { start(current) }
            else if let first = queue.first { currentIndex = 0; start(first) }
        }
    }

    func pause() {
        if waitingForDevice != nil { engine.pause(); return }
        guard state == .playing else { return }
        request(.paused)
        engine.pause()
    }

    private func request(_ target: PlaybackState) {
        requestedState = (target, state, .now)
        state = target
        updateNowPlayingInfo()
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
        if let id = current?.id { seekRestart = id }
        engine.seek(to: seconds)
        position = seconds
        requestedPosition = (seconds, .now)
    }

    func stop() { requested = nil; requestedPosition = nil; seekRestart = nil; requestedState = nil; engine.stop() }

    func clearError() { lastError = nil }

    /// Seconds of listening that put a song in the play history.
    static let historyListen: TimeInterval = 10

    // MARK: Engine events & polling

    private func handle(_ event: EngineEvent) {
        switch event {
        case .trackStarted(let item):
            // A song you've already skipped past (the engine reached it before your later skips): ignore it.
            // Following it would move the queue back to it, and the next skip would continue from there.
            if let requested, requested != item.id { return }
            let fresh = requested != nil   // the song just chosen: a new play, even if it was seeked while opening
            requested = nil
            if let i = queue.firstIndex(where: { $0.id == item.id }) { currentIndex = i }
            if !fresh, seekRestart == item.id {
                seekRestart = nil
                updateNowPlayingInfo()
                return
            }
            seekRestart = nil
            resolveVersions()
            trackStartedAt = .now
            scrobbledEntry = nil
            historyEntry = nil
            listened = 0
            listenedEntry = item.id
            prefetchNetworkTracks()
            updateNowPlayingInfo()
            if settings.scrobble, let track = current?.track {
                Task { try? await ListenBrainzClient.shared.submit(track, kind: .playingNow) }
            }
        case .queueEnded:
            seekRestart = nil
            updateNowPlayingInfo()
        case .failed(let item, let message):
            if let requested, let item, requested != item.id { return }   // about a song skipped past
            requested = nil
            let track = queue.first { $0.id == item?.id }?.track ?? current?.track
            if let track, shares.isNetwork(track), !shares.isReachable(track), !shares.cache.isAvailable(track) {
                lastError = String(localized: "“\(track.title)” is on a network share that isn’t connected. Vespertine reconnects automatically when the server is reachable.")
            } else if let track, shares.isNetwork(track) {
                // On a share, even asking whether the file exists can block for seconds: ask off the main thread.
                lastError = message
                let path = track.filePath
                Task { [weak self] in
                    let exists = await Task.detached(priority: .utility) { FileManager.default.fileExists(atPath: path) }.value
                    guard let self, !exists else { return }
                    self.library.rescanForMissingFile(track)
                    self.lastError = String(localized: "“\(track.title)” was moved or deleted. Updating the library to find it…")
                }
            } else if let track, !FileManager.default.fileExists(atPath: track.filePath) {
                // Moved or deleted since the last scan: look again now; moved songs rejoin the queue.
                library.rescanForMissingFile(track)
                lastError = String(localized: "“\(track.title)” was moved or deleted. Updating the library to find it…")
            } else {
                lastError = message
            }
        case .deviceLost(let name):
            lastError = String(localized: "\(name) was disconnected. Playback paused.", comment: "%@ is the name of an audio output device.")
        case .waitingForDevice(let name):
            lastError = String(localized: "Waiting for \(name). Playback continues as soon as it’s ready.", comment: "%@ is the name of an audio output device.")
            waitingMessage = lastError
        case .deviceUnavailable(let name):
            lastError = settings.outputFallback == .waitForChosen
                ? String(localized: "\(name) didn’t come back. Choose another output, or press play once it’s connected.", comment: "%@ is the name of an audio output device.")
                : String(localized: "\(name) didn’t come back. Press play to continue on another output.", comment: "%@ is the name of an audio output device.")
        case .deviceNotResponding(let name):
            lastError = String(localized: "\(name) is connected but won’t start. Quit and reopen Vespertine, then press play.", comment: "%@ is the name of an audio output device.")
        }
    }

    /// Library scans of network shares go one request at a time while the song you're starting, seeking or
    /// playing streams from a share (no complete local copy yet): a scan at full width queues the song's reads
    /// behind dozens of its own, and starting a song took 40 s with stalls every few seconds after.
    private func yieldShareToPlayback(_ snap: EngineSnapshot) {
        let active = state == .playing || requested != nil || requestedPosition != nil
        let streaming = active && (snap.readingFromShare || (requested != nil && current.map { shares.isNetwork($0.track) } == true))
        let limit = streaming ? ShareIOGate.whileStreaming : nil
        if ShareIOGate.shared.maxInFlight != limit { ShareIOGate.shared.maxInFlight = limit }
    }

    /// Copies to the network cache give the connection to a song streaming from a share while its buffer is
    /// under a third full (or it's holding for more), and carry on once it's two thirds full again. On a link
    /// little faster than the music, a copy running alongside took half of it and the song stalled every few
    /// seconds; the copy still finishes when the link has room to spare.
    private func yieldCacheToPlayback(_ snap: EngineSnapshot) {
        let cache = shares.cache
        let yielding: Bool
        if snap.state != .playing || !snap.readingFromShare { yielding = false }
        else if snap.isBuffering || snap.bufferFill < 1.0 / 3 { yielding = true }
        else if snap.bufferFill > 2.0 / 3 { yielding = false }
        else { yielding = cache.yieldsToPlayback }
        if cache.yieldsToPlayback != yielding { cache.yieldsToPlayback = yielding }
    }

    func poll(_ snapshot: EngineSnapshot? = nil) {
        let snap = snapshot ?? engine.snapshot
        if let requestedState, snap.state != requestedState.from
            || requestedState.state == .playing && Date().timeIntervalSince(requestedState.at) > 30 {
            self.requestedState = nil
        }
        let stateChanged = requestedState == nil && state != snap.state
        if requestedState == nil { state = snap.state }
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
            if waitingForDevice == nil, lastError != nil, lastError == waitingMessage { lastError = nil }
        }
        if requested == nil, let id = snap.item?.id, let i = queue.firstIndex(where: { $0.id == id }), currentIndex != i {
            currentIndex = i
            updateNowPlayingInfo()
        }
        if stateChanged { updateNowPlayingInfo() }
        // Until the requested song plays, the engine's signal path is the previous song's.
        if requested == nil {
            if signalPath != snap.signalPath { signalPath = snap.signalPath }
            if systemRendering != snap.systemRendering { systemRendering = snap.systemRendering }
        }
        if outputDevice?.id != snap.outputDevice?.id || outputDevice?.nominalSampleRate != snap.outputDevice?.nominalSampleRate {
            outputDevice = snap.outputDevice
        }
        if state == .playing, let device = snap.outputDevice { followSystemOutput(to: device) } else if state != .playing { lastFollowed = nil }
        syncVolumeRelay()
        if underruns != snap.underruns { underruns = snap.underruns }
        if buffering != snap.isBuffering { buffering = snap.isBuffering }
        if settings.networkCache, let current, current.id == snap.item?.id, adoptedSource != current.id,
           shares.isNetwork(current.track), !current.track.isDVDFolderTrack, let local = snap.localSourceURL,
           shares.cache.adopt(current.track, from: local) {
            adoptedSource = current.id
        }
        yieldShareToPlayback(snap)
        yieldCacheToPlayback(snap)
        // Per-channel meters, only while a multichannel stream plays (cheap, but no need otherwise).
        if state == .playing, requested == nil, let path = signalPath, path.plan.channels > 2 || path.source.channels > 2 {
            let peaks = engine.takeChannelPeaks()
            if channelLevels.count != peaks.count { channelLevels = peaks }
            else { channelLevels = zip(channelLevels, peaks).map { max($1, $0 * 0.82) } }
        } else if !channelLevels.isEmpty, state != .playing {
            channelLevels = []
        }

        // Count a play (and scrobble) after half the track or four minutes of listening, whichever comes first
        // (ListenBrainz's rule): time actually played, so seeking to the middle isn't a listen.
        let now = Date()
        // Waiting on a network share to refill the buffer isn't listening.
        let listening = state == .playing && !buffering
        if listening, let last = lastListenTick { listened += min(now.timeIntervalSince(last), 1) }
        lastListenTick = listening ? now : nil
        // The play history lists a song once it's been heard for a few seconds (or half of it, if it's that short), so
        // skipping through the queue doesn't fill it.
        if state == .playing, let entry = current, listenedEntry == entry.id, historyEntry != entry.id, listened >= min(Self.historyListen, max(1, duration / 2)) {
            historyEntry = entry.id
            if let id = entry.track.id { library.recordHistory(id) }
        }
        if state == .playing, let entry = current, listenedEntry == entry.id, scrobbledEntry != entry.id, duration > 30,
           listened >= min(duration / 2, 240) {
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
        syncDiscord()
    }

    // MARK: Discord

    /// What the Discord status shows now: the song while it plays (not while paused, buffering from a share, or
    /// waiting for the output), with its start set back by the position so Discord's progress bar is right.
    var discordNowPlaying: DiscordNowPlaying? {
        guard state == .playing, !buffering, waitingForDevice == nil, let track = current?.track else { return nil }
        // Until the engine reports this song, its signal path is the previous one's.
        let path = requested == nil ? signalPath : nil
        let length = duration > 0 ? duration : track.duration
        return DiscordNowPlaying(
            title: track.title,
            artist: track.displayArtist.libraryDisplayName,
            album: track.album.map(\.libraryDisplayName),
            format: DiscordStatus.formatLine(track: track, path: path),
            bitPerfect: path?.isBitPerfect == true,
            startedAt: Date().addingTimeInterval(-position),
            duration: length,
            artwork: DiscordArtworkQuery(artist: track.displayAlbumArtist, album: track.album, title: track.title,
                                         musicBrainzReleaseID: track.musicBrainzReleaseID))
    }

    /// Called on every poll and when the setting changes; Discord only hears about changes.
    func syncDiscord() {
        discord.update(enabled: settings.discordPresence, song: discordNowPlaying, lookUpArtwork: settings.discordArtwork)
    }

    // MARK: System Now Playing

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        Self.register(center.playCommand) { [weak self] _ in
            Task { @MainActor in if self?.state != .playing, self?.waitingForDevice == nil { self?.togglePlayPause() } }
        }
        Self.register(center.pauseCommand) { [weak self] _ in Task { @MainActor in self?.pause() } }
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
            MPMediaItemPropertyArtist: track.displayArtist.libraryDisplayName,
            MPMediaItemPropertyAlbumTitle: track.displayAlbum.libraryDisplayName,
            MPMediaItemPropertyPlaybackDuration: duration > 0 ? duration : track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0,
        ]
        if let key = track.artworkKey ?? library.album(key: track.albumKey)?.artworkKey,
           let image = ArtworkCache.shared.cached(key, size: 600) ?? ArtworkCache.shared.cached(key, size: 160) {
            info[MPMediaItemPropertyArtwork] = Self.artwork(image)
        }
        center.nowPlayingInfo = info
        nowPlayingAnchor = state == .playing ? (position, .now) : nil
        center.playbackState = state == .playing ? .playing : .paused
    }
}
