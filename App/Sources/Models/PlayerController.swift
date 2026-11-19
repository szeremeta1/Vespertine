//
// Vespertine: play queue, transport and system integration (Now Playing, media keys, scrobbling, Discord).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import MediaPlayer
import VespertineAudio
import VespertineLibrary
import VespertineStreaming
import VespertineUPnP
import Observation

struct QueueEntry: Identifiable, Hashable {
    let item: PlayableItem
    let track: Track
    /// Every version of this song on its album (stereo and 5.1…), `track` among them; empty when there's one.
    var versions: [Track] = []
    /// Added with Play Next or Add to Queue: listed under Playing Next, ahead of the rest of what was playing.
    var queuedByUser = false
    /// A song a control app sent ("Receive from Other Apps"): not in the library, never kept, counted or scrobbled.
    var received = false
    var id: UUID { item.id }

    /// The same entry (same place in the queue, same flags) playing `track` through `item`.
    func replacing(_ track: Track, item: PlayableItem) -> QueueEntry {
        QueueEntry(item: item, track: track, versions: versions, queuedByUser: queuedByUser, received: received)
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
    /// The channels of the bed decoded beside the output while macOS renders Atmos or a receiver decodes a bitstream.
    private(set) var bedMeters: BedMeterLayout?
    private(set) var outputDevice: OutputDevice?
    private(set) var underruns = 0
    /// A network read stalled; output is paused until enough is buffered (resumes by itself).
    private(set) var buffering = false
    /// Buffering while what has arrived still plays (see `EngineSnapshot.playsWhileBuffering`).
    private(set) var playsWhileBuffering = false
    /// Why the song in Now Playing stopped and is not playing: its music server stopped answering. Said there, where the
    /// song's signal path was, until a song is started; the banner says it too, and goes after a few seconds.
    private(set) var stopReason: String?
    /// While the song is copied from a share before it plays: how much is local (0…1).
    private(set) var bufferingFraction: Double?
    /// While the song waits on a share that has sent nothing for 10 s or more: "“Share” isn’t answering. Still trying…" (the Inspector
    /// shows it under "Buffering from the network…", and the banner says it once). nil when the share is answering or not waited on.
    private(set) var shareNotice: String?
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
    /// The song playing when it is one of the library's (not one a control app sent).
    var currentLibraryTrack: Track? { current.flatMap { $0.received ? nil : $0.track } }
    var isPlaying: Bool { state == .playing }
    /// The song is waited for and nothing of it is heard: a spinner over play. Not while what has arrived still plays (the
    /// share or the server is slow or quiet, the buffer is not empty yet): Now Playing says "Buffering", the button stays pause.
    var loading: Bool {
        (buffering && !playsWhileBuffering && state != .paused) || (requested != nil && current.map { shares.isNetwork($0.track) } == true)
    }
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

    /// Whether `tracks` are an album as it was opened: several songs, all of one album. Its versions on another edition
    /// (the "(Dolby Atmos)" album beside it) then stay out, so an edition played from its own page is the edition that
    /// plays. One song asked for by itself (Play Next on a favorite) is a song, not an album: it follows the output.
    nonisolated static func keepsToOneAlbum(_ tracks: [Track]) -> Bool {
        tracks.count > 1 && Set(tracks.map(\.albumKey)).count == 1
    }

    /// Queue entries for `tracks`, each playing the version of its song that suits the output.
    /// A song whose versions all arrive together (a whole SACD album, a shuffle of the library that has a song in stereo
    /// and in Dolby Atmos) is queued once. With `allowing`, only versions it accepts are considered (a filtered page
    /// asked for multichannel: stereo versions stay out).
    /// `exactly`: tracks (by location) asked for as they are, a copy picked by hand, even on an album whose copies are bundled.
    private func entries(_ tracks: [Track], allowing: ((Track) -> Bool)? = nil, transitions: TransitionOverride? = nil,
                         exactly: Set<String> = []) -> [QueueEntry] {
        // An album whose copies are bundled lets the output pick among them all; elsewhere a song's stereo and surround
        // versions follow the output while they are combined (Settings), and any other copy plays as itself.
        let oneAlbum = Self.keepsToOneAlbum(tracks)
        let songs = library.playbackSongs(of: tracks, acrossEditions: !oneAlbum).enumerated().map { i, song -> LibraryStore.PlaybackSong in
            if exactly.contains(tracks[i].location) { return LibraryStore.PlaybackSong(versions: [tracks[i]]) }
            guard let allowing, song.versions.count > 1 else { return song }
            var song = song
            song.versions = song.versions.filter { $0.location == tracks[i].location || allowing($0) }
            return song
        }
        let wanted = wantsMultichannel()
        // What is queued of each song so far: the layouts of the tracks asked for, and the tracks that play.
        var queued: [String: (layouts: Set<Bool>, playing: Set<String>)] = [:]
        return zip(tracks, songs).compactMap { track, song in
            let versions = song.versions
            let key = versions.count > 1 ? song.key : nil
            // Bundled copies are one entry whichever is asked for. Otherwise only a song's other-layout version
            // is the same entry: two copies in one layout asked for together (both put in a playlist) both play.
            if let key, let before = queued[key], song.mergesCopies || before.layouts.contains(!track.isMultichannel) { return nil }
            // A copy of the same song plays as the best copy; versions follow the output (stereo or surround).
            let isLocal: (Track) -> Bool = { [shares] in !shares.isNetwork($0) }
            let chosen = versions.count > 1 ? TrackVersions.choose(versions, multichannel: wanted ?? track.isMultichannel, isLocal: isLocal,
                                                                   isPreferred: library.isPreferredCopy) ?? track : track
            if let key {
                // Two stereo copies asked for on a surround output would both play the song's one surround version: once.
                if chosen.location != track.location, queued[key]?.playing.contains(chosen.location) == true { return nil }
                queued[key, default: ([], [])].layouts.insert(track.isMultichannel)
                queued[key]?.playing.insert(chosen.location)
            }
            return QueueEntry(item: makeItem(chosen, transitions: transitions), track: chosen, versions: versions.count > 1 ? versions : [])
        }
    }

    /// The output changed (another device, Spatial Audio on or off): upcoming songs switch to the version
    /// that suits it. The song that's playing carries on as it is.
    func resolveVersions() {
        if onKeptQueue({ resolveVersions() }) { return }
        guard let wanted = wantsMultichannel() else { return }
        let start = (currentIndex ?? -1) + 1
        var changed = false
        func resolve(_ entry: QueueEntry) -> QueueEntry {
            guard entry.versions.count > 1,
                  let chosen = TrackVersions.choose(entry.versions, multichannel: wanted, isLocal: { [shares] in !shares.isNetwork($0) },
                                                    isPreferred: library.isPreferredCopy),
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
    /// a Play button does); nil keeps the shuffle setting (double-clicking a song). `allowing`, `exactly`: see `entries`.
    /// `transitions`: the playlist's own transitions, when it's a playlist that has them (they go with its songs).
    func play(_ tracks: [Track], startAt index: Int = 0, shuffled: Bool? = nil, allowing: ((Track) -> Bool)? = nil,
              transitions: TransitionOverride? = nil, exactly: Set<String> = []) {
        guard !tracks.isEmpty else { return }
        let entries = entries(tracks, allowing: allowing, transitions: transitions, exactly: exactly)
        guard !entries.isEmpty else { return }
        // The listener's own play ends a control app's session: the two never mix.
        endReceiverSession(telling: .tookOver, stopping: false)
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

    /// Plays `tracks` right after the current song, ahead of anything else in Playing Next. `exactly`: see `entries`.
    func playNext(_ tracks: [Track], allowing: ((Track) -> Bool)? = nil, exactly: Set<String> = []) {
        if onKeptQueue({ playNext(tracks, allowing: allowing, exactly: exactly) }) { return }
        guard let i = currentIndex else {
            if editingKeptQueue { beginKeptQueue(entries(tracks, allowing: allowing, exactly: exactly)) } else { play(tracks, allowing: allowing, exactly: exactly) }
            return
        }
        let entries = entries(tracks, allowing: allowing, exactly: exactly).map { var e = $0; e.queuedByUser = true; return e }
        queue.insert(contentsOf: entries, at: i + 1)
        originalOrder.append(contentsOf: entries)
        syncMirror()
    }

    /// Adds `tracks` to the end of Playing Next: after the songs already added, before the rest of what was
    /// playing (as Apple Music's Play Last does), so they're heard without first sitting through the whole album.
    /// `exactly`: see `entries`.
    func addToQueue(_ tracks: [Track], allowing: ((Track) -> Bool)? = nil, exactly: Set<String> = []) {
        if onKeptQueue({ addToQueue(tracks, allowing: allowing, exactly: exactly) }) { return }
        guard let i = currentIndex else {
            if editingKeptQueue { beginKeptQueue(entries(tracks, allowing: allowing, exactly: exactly)) } else { play(tracks, allowing: allowing, exactly: exactly) }
            return
        }
        let entries = entries(tracks, allowing: allowing, exactly: exactly).map { var e = $0; e.queuedByUser = true; return e }
        queue.insert(contentsOf: entries, at: i + 1 + playingNext.count)
        originalOrder.append(contentsOf: entries)
        syncMirror()
    }

    func removeFromQueue(_ id: UUID) { removeFromQueue([id]) }

    /// Removes songs from the queue by entry, never the one playing. Entries no longer queued are ignored, so a
    /// request made from a list drawn a moment ago (the song ended meanwhile) can't remove the wrong song.
    func removeFromQueue(_ ids: some Collection<UUID>) {
        if onKeptQueue({ removeFromQueue(ids) }) { return }
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
        if onKeptQueue({ moveUpcoming(ids, before: target, playingNext: playingNext) }) { return }
        guard let c = currentIndex else { return }
        let upcoming = Array(queue[(c + 1)...])
        let byID = Dictionary(upcoming.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<UUID>()
        let moving = ids.filter { byID[$0] != nil && $0 != target && seen.insert($0).inserted }.compactMap { byID[$0] }
        guard !moving.isEmpty else { return }
        var rest = upcoming.filter { !seen.contains($0.id) }
        let at = target.flatMap { t in rest.firstIndex { $0.id == t } } ?? rest.count
        let block = rest.prefix { $0.queuedByUser }.count
        let joins = playingNext ?? (at < block || (at == block && block > 0 && moving.allSatisfy(\.queuedByUser)))
        rest.insert(contentsOf: moving.map { var e = $0; e.queuedByUser = joins; return e }, at: at)
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
        if onKeptQueue({ moveUpcoming(from: source, to: destination) }) { return }
        let shown = Array(upcoming)
        let ids = source.sorted().compactMap { shown.indices.contains($0) ? shown[$0].id : nil }
        moveUpcoming(ids, before: destination < shown.count ? shown[destination].id : nil)
    }

    /// Moves upcoming entries (in the order they play) to the front of Playing Next.
    func playNext(entries ids: [UUID]) {
        if onKeptQueue({ playNext(entries: ids) }) { return }
        let chosen = Set(ids)
        let shown = Array(upcoming)
        let ordered = shown.map(\.id).filter(chosen.contains)
        // Before the first song not moved: a song already at the front stays where it is and joins Playing Next.
        moveUpcoming(ordered, before: shown.first { !chosen.contains($0.id) }?.id, playingNext: true)
    }

    /// Empties Up Next (only the songs that come after the one playing).
    func clearUpcoming() {
        if onKeptQueue({ clearUpcoming() }) { return }
        guard let c = currentIndex else { return }
        removeFromQueue(queue[(c + 1)...].map(\.id))
    }

    /// Empties Playing Next: the rest of what was playing carries on after the current song.
    func clearPlayingNext() {
        if onKeptQueue({ clearPlayingNext() }) { return }
        removeFromQueue(playingNext.map(\.id))
    }

    func jump(to id: UUID) {
        // A song of the listener's own queue, chosen while a control app plays: the control app's session ends.
        if let session = receiverSession, session.queue.contains(where: { $0.id == id }) { endReceiverSession(telling: .tookOver, stopping: false) }
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        currentIndex = i
        start(queue[i])
    }

    /// The last song of what was playing (not one you added) that had its turn before shuffle was turned on: where
    /// the album carries on from when shuffle is turned off during a song you added.
    @ObservationIgnored private var shuffledAfter: UUID?

    /// Shuffling mixes what was playing, never the songs you added to Playing Next: they still come next, in
    /// your order, and the ones that already had their turn stay behind the song playing. Turning shuffle off puts
    /// the rest back in its order, after them.
    private func applyShuffle(keepingCurrent: Bool = true) {
        if onKeptQueue({ applyShuffle(keepingCurrent: keepingCurrent) }) { return }
        guard !queue.isEmpty else { return }
        let current = self.current
        let next = Array(playingNext)
        let nextIDs = Set(next.map(\.id))
        // Songs you added that aren't playing or coming next had their turn: they don't play a second time.
        let passed = queue.filter { $0.queuedByUser && $0.id != current?.id && !nextIDs.contains($0.id) }
        // The last song before (or at) the one playing that you didn't add.
        let lastOwn = currentIndex.flatMap { i in queue.indices.contains(i) ? queue[...i].last { !$0.queuedByUser }?.id : nil }
        if shuffle {
            if let lastOwn { shuffledAfter = lastOwn }
            var rest = queue.filter { !$0.queuedByUser && $0.id != current?.id }
            rest.shuffle()
            queue = passed + (current.map { [$0] } ?? []) + next + rest
            currentIndex = current == nil ? nil : passed.count
        } else if let current {
            // Songs you added sit at the end of `originalOrder` wherever they played, so they can't mark the place.
            // What was playing carries on after the song playing, or, during a song you added, after the last one
            // of its own that had its turn.
            let added = Set(queue.lazy.filter(\.queuedByUser).map(\.id))
            let own = originalOrder.filter { !added.contains($0.id) }
            let place = (lastOwn ?? shuffledAfter).flatMap { id in own.firstIndex { $0.id == id } }
            var before = place.map { Array(own[...$0]) } ?? []
            let after = place.map { Array(own[($0 + 1)...]) } ?? own
            if !current.queuedByUser, before.last?.id == current.id { before.removeLast() }
            queue = before + passed + [current] + next + after
            currentIndex = before.count + passed.count
        } else {
            queue = originalOrder
            currentIndex = nil
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
        // Never a speaker group's aggregate: it has no volume of its own (`GroupVolume`).
        let device = GroupVolume.relayTarget(for: outputDevice, enabled: settings.relayVolumeKeys && !Self.relayOffForQA)
        guard relayedDevice != device else { return }
        relayedDevice = device
        volumeRelay.follow(device)
    }
    nonisolated private static let halQueue = DispatchQueue(label: "org.szeremeta.vespertine.system-output", qos: .userInitiated)
    private func followSystemOutput(to device: OutputDevice) {
        guard settings.systemOutputFollowsPlayback, GroupVolume.mayBecomeSystemOutput(device), signalPath?.applied.exclusive != true, lastFollowed != device.id else { return }
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
        guard !editingKeptQueue else { return }
        // Repeat is the listener's, for the listener's queue: a control app's songs play once, in the order it sends them.
        mirror.update(queue.map(\.item), repeatMode: receiverSession == nil ? repeatMode : .off)
        if let rendererInfo {
            let fresh = queue.map { ($0.id, trackInfo(for: $0.track)) }
            rendererInfo.withLock { map in for (id, info) in fresh where map[id] == nil { map[id] = info } }
        }
        if let renderer { renderer.queueChanged() } else { engine.queueChanged(reloadCurrent: reloadCurrent) }
    }

    // MARK: Network renderer (UPnP renderers, beta)

    /// The network renderer playing in place of the engine, while one is the chosen output; nil: the engine plays, as always.
    @ObservationIgnored private(set) var renderer: (any NetworkPlayback)?

    /// Hands playback to `playback` (a network renderer) or back to the engine (nil). A song that was playing carries on, at
    /// its position, on the new one.
    func useRenderer(_ playback: (any NetworkPlayback)?, missing: String? = nil) {
        let missing = playback == nil ? missing : nil
        guard playback !== renderer || missing != missingRenderer else { return }
        // A control app's song plays on this Mac's own outputs only: handing the output to a network player ends its session.
        if playback != nil || missing != nil { endReceiverSession(telling: .tookOver) }
        let wasActive = state == .playing || requested != nil
        let carried = wasActive ? (pendingRendererStart ?? current) : pendingRendererStart
        let at = pendingRendererStart == nil ? position : 0
        pendingRendererStart = nil
        let hadRenderer = renderer != nil || missingRenderer != nil
        if let old = renderer, old !== playback { old.shutdown() } else if playback != nil || missing != nil { engine.stop() }
        missingRenderer = missing
        if let missing {
            // Nothing plays in its place (not the Mac's DAC, whatever the fallback says).
            renderer = nil
            if wasActive, hadRenderer { lastError = Self.notAnswering(missing) }
            requested = nil
            requestedState = nil
            signalPath = nil
            return
        }
        renderer = playback
        if let playback {
            let mirror = self.mirror
            let cache = shares.cache
            playback.nextItemProvider = { finished in mirror.item(after: finished.id) }
            playback.urlResolver = { @Sendable item in item.cacheKey.flatMap { cache.localURL(forKey: $0) } ?? item.url }
            let info = Locked([UUID: RendererTrackInfo]())
            let all = queue.map { ($0.id, trackInfo(for: $0.track)) }
            info.withLock { map in for (id, described) in all { map[id] = described } }
            rendererInfo = info
            playback.metadataProvider = { item in info.withLock { $0[item.id] } }
            playback.eventHandler = { [weak self] event in self?.handle(event) }
        }
        signalPath = nil
        if let carried {
            if let playback {
                // The renderer reaches the position once it plays (asked while it loads, it refuses).
                start(carried, at: at > 1 ? at : 0)

            } else {
                start(carried)
                if at > 1 { seek(to: at) }
            }
        }
    }

    /// Stops before the chosen network output is let go of because its switch went off. The song is not carried over: music
    /// that was playing in another room never starts on this Mac's own output by itself.
    func stopBeforeLeavingNetworkOutput() {
        guard renderer != nil || missingRenderer != nil || pendingRendererStart != nil else { return }
        stop()
        pendingRendererStart = nil
        state = .stopped
    }

    /// The chosen output is a network renderer that isn't answering: nothing plays anywhere until it is back. Its name.
    @ObservationIgnored private(set) var missingRenderer: String?
    /// The first search for renderers is still running (Play then waits a little for the chosen one). Set by the app model.
    @ObservationIgnored var rendererGrace: () -> Bool = { false }
    /// How long Play waits for a chosen renderer during the first search.
    @ObservationIgnored var rendererGraceSeconds: TimeInterval = 5
    /// The song Play asked for while waiting for the renderer.
    @ObservationIgnored private var pendingRendererStart: QueueEntry?

    nonisolated static func notAnswering(_ name: String) -> String {
        String(localized: "\(name) isn't answering.", comment: "%@ is a network player's name: it is the chosen output and doesn't answer.")
    }

    /// Play with the chosen renderer missing: wait for it during the first search, else say it isn't answering. True when handled.
    private func holdForMissingRenderer(_ entry: QueueEntry?) -> Bool {
        guard let missing = missingRenderer else { return false }
        guard let entry, rendererGrace() else {
            lastError = Self.notAnswering(missing)
            return true
        }
        pendingRendererStart = entry
        let wait = rendererGraceSeconds
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, self.pendingRendererStart?.id == entry.id, let missing = self.missingRenderer else { return }
            self.pendingRendererStart = nil
            self.lastError = Self.notAnswering(missing)
        }
        return true
    }

    /// Titles for the renderer's display, by queue entry (kept current as the queue changes).
    @ObservationIgnored private var rendererInfo: Locked<[UUID: RendererTrackInfo]>?

    /// The key of a song's cover as the app shows it (its own, else its album's), for outputs that are sent the picture.
    @ObservationIgnored var rendererArtworkKey: ((Track) -> String?)?

    private func trackInfo(for track: Track) -> RendererTrackInfo {
        var info = Self.rendererInfo(track)
        info.artworkKey = rendererArtworkKey?(track)
        return info
    }

    nonisolated static func rendererInfo(_ track: Track) -> RendererTrackInfo {
        RendererTrackInfo(title: track.title, artist: track.displayArtist.libraryDisplayName, album: track.displayAlbum.libraryDisplayName,
                          duration: track.duration > 0 ? track.duration : nil)
    }

    /// Files in the queue were moved or renamed (found by a rescan): point their entries at the new
    /// files so the rest of the queue keeps playing. The song that's playing isn't interrupted.
    func tracksMoved(_ moves: [Int64: Int64]) {
        if onKeptQueue({ tracksMoved(moves) }) { return }
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

    /// A share came back mounted at another path and the library repointed its songs: queued entries still name the old
    /// path (and the old offline-copy key), so the rest of the queue would fail to open. Point them at the new files.
    func sourceRelinked(_ sourceID: Int64) {
        if onKeptQueue({ sourceRelinked(sourceID) }) { return }
        let ids = Set((queue + originalOrder).compactMap { $0.track.sourceId == sourceID ? $0.track.id : nil })
        guard !ids.isEmpty else { return }
        tracksMoved(Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) }))
    }

    func refreshReplayGain() {
        if onKeptQueue({ refreshReplayGain() }) { return }
        queue = queue.map { $0.replacing($0.track, item: makeItem($0.track, id: $0.id, transitions: $0.item.context?.override)) }
        originalOrder = originalOrder.map { $0.replacing($0.track, item: makeItem($0.track, id: $0.id, transitions: $0.item.context?.override)) }
        syncMirror(reloadCurrent: true)
    }

    private func makeItem(_ track: Track, id: UUID = UUID(), transitions: TransitionOverride? = nil) -> PlayableItem {
        var context = Self.transitionContext(track)
        context.override = transitions
        // A song on a music server has no file: the engine opens it by its own address, which names the provider, the account
        // and the song and nothing else, and the streaming core hands over the bytes (see StreamingCore).
        if let stream = track.streamRef {
            return PlayableItem(id: id, url: stream.url, trackID: track.id, replayGainDB: replayGain(for: track),
                                cacheKey: stream.cacheKey, context: context)
        }
        return PlayableItem(id: id, url: track.fileURL, trackID: track.id, regionStartFrame: track.cueStartFrame,
                            regionFrameLength: track.cueFrameLength, replayGainDB: replayGain(for: track),
                            cacheKey: shares.isNetwork(track) && !track.isDVDFolderTrack ? NetworkCache.key(for: track) : nil,
                            sacdArea: track.sacdArea, dvd: track.dvdStream, context: context, audioStream: track.audioStream)
    }

    /// How `entry` joins the song before it in the queue, while transitions are on: what the engine planned for the
    /// boundary after the song playing, else what can be told before the songs are opened (albums, genres, playlists).
    func join(before entry: QueueEntry) -> TransitionDecision? {
        guard settings.transitionsOn, let i = queue.firstIndex(where: { $0.id == entry.id }), i > 0 else { return nil }
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

    // MARK: Receive from Other Apps (a control app's session)

    /// What a control app is playing here, and the listener's own queue kept aside meanwhile.
    struct ReceiverSession {
        var app: ReceiverControlApp
        /// The listener's queue as it was when the control app began; it comes back when the control app stops.
        var queue: [QueueEntry]
        var originalOrder: [QueueEntry]
        var currentIndex: Int?
        /// Where the listener's song was.
        var position: TimeInterval
        /// The song of the listener's queue that was current, if there was one.
        var current: QueueEntry? { currentIndex.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }
        var upcoming: ArraySlice<QueueEntry> {
            guard let i = currentIndex, i + 1 < queue.count else { return [] }
            return queue[(i + 1)...]
        }
    }

    /// Set while a control app's songs are the ones in `queue`.
    private(set) var receiverSession: ReceiverSession?
    /// Told what became of a control app's songs; the receiver passes it on to the control app.
    @ObservationIgnored var receiverEvents: ((ReceiverPlayerEvent) -> Void)?
    /// How long a session is kept after its last song ended: a control app that sends one song at a time sends the next at once.
    @ObservationIgnored var receiverLingerTime: Duration = .seconds(10)
    @ObservationIgnored private var receiverLinger: Task<Void, Never>?
    /// Set while a change is being made to the listener's kept queue (see `onKeptQueue`).
    @ObservationIgnored private var editingKeptQueue = false
    /// Where the listener's own song was when a control app took over: Play carries on from there.
    @ObservationIgnored private var resumeAt: (id: UUID, seconds: TimeInterval)?
    /// QA only: a session is on screen for a screenshot (see `showReceiverDemo`).
    @ObservationIgnored private var receiverDemo = false

    static var receiverNeedsThisMac: String {
        String(localized: "Vespertine is playing to a network player. Choose one of this Mac’s outputs to play what other apps send.",
               comment: "A control app sent a song to Receive from Other Apps while the chosen output is a network player or an AirPlay receiver.")
    }

    private static func entry(_ track: ReceiverTrack) -> QueueEntry {
        var entry = QueueEntry(item: track.item, track: .transient(location: track.item.url.absoluteString, title: track.info.title, artist: track.info.artist,
                                                                    album: track.info.album, duration: track.info.duration ?? 0))
        entry.received = true
        return entry
    }

    /// A control app pressed Play: its song plays in place of whatever does, and `next` follows it without a gap. The listener's
    /// own queue is kept as it is, paused, until the control app stops or the listener plays something of their own.
    func receiverPlay(_ track: ReceiverTrack, next: ReceiverTrack?, from app: ReceiverControlApp) {
        receiverLinger?.cancel()
        receiverLinger = nil
        guard renderer == nil, missingRenderer == nil else {
            lastError = Self.receiverNeedsThisMac
            receiverEvents?(.failed(track.id, Self.receiverNeedsThisMac))
            return
        }
        if receiverSession == nil {
            let at = state == .stopped ? (resumeAt.flatMap { $0.id == current?.id ? $0.seconds : nil } ?? 0) : position
            receiverSession = ReceiverSession(app: app, queue: queue, originalOrder: originalOrder, currentIndex: currentIndex, position: at)
        } else {
            receiverSession?.app = app
        }
        let entries = [track, next].compactMap { $0 }.map(Self.entry)
        queue = entries
        originalOrder = entries
        currentIndex = 0
        mirror.update(entries.map(\.item), repeatMode: .off)
        start(entries[0])
    }

    /// What follows the control app's song (nil: nothing).
    func receiverSetNext(_ track: ReceiverTrack?) {
        guard receiverSession != nil, let playing = current, playing.received else { return }
        queue = [playing] + [track].compactMap { $0 }.map(Self.entry)
        originalOrder = queue
        currentIndex = 0
        syncMirror()
    }

    func receiverResume() {
        guard receiverSession != nil, state == .paused else { return }
        request(.playing)
        engine.resume()
    }

    /// The receiver refused what a control app sent (an address it won't fetch, a song that isn't music): the listener sees why.
    func receiverRefused(_ message: String) { lastError = message }

    /// The control app pressed Stop: its songs go, and the listener's queue is back as it was, stopped at its song.
    func receiverStop() { endReceiverSession() }

    /// A picture for a control app's song arrived (kept in memory only): the song shows it from now on.
    func receiverArtwork(_ key: String, for id: UUID) {
        guard receiverSession != nil, let i = queue.firstIndex(where: { $0.id == id && $0.received }) else { return }
        var track = queue[i].track
        track.artworkKey = key
        queue[i] = queue[i].replacing(track, item: queue[i].item)
        originalOrder = queue
        if i == currentIndex { updateNowPlayingInfo() }
    }

    /// QA only (`-VespertineReceiverDemo`, see DeveloperHooks): how a control app's session looks, without a sound. `songs` stand
    /// in for what the app sent and `kept` for the listener's own queue. Nothing is fetched or played and the engine isn't
    /// touched; `poll` leaves what is shown alone until the app quits.
    func showReceiverDemo(from app: ReceiverControlApp, songs: [Track], kept: [Track], artworkKey: String?) {
        guard !songs.isEmpty else { return }
        let own = entries(kept)
        receiverSession = ReceiverSession(app: app, queue: own, originalOrder: own, currentIndex: own.isEmpty ? nil : 0, position: 0)
        let sent = songs.prefix(2).map { song -> QueueEntry in
            let id = UUID()
            var entry = QueueEntry(item: PlayableItem(id: id, url: ReceiverStreams.itemURL(id), cacheKey: ReceiverStreams.cacheKey(id)),
                                   track: .transient(location: ReceiverStreams.itemURL(id).absoluteString, title: song.title, artist: song.displayArtist,
                                                     album: song.displayAlbum, duration: song.duration, artworkKey: artworkKey))
            entry.received = true
            return entry
        }
        queue = sent
        originalOrder = sent
        currentIndex = 0
        receiverDemo = true
        state = .playing
        duration = sent[0].track.duration
        position = min(71, duration / 3)
    }

    /// The control app's last song ended (or failed): the session waits a little for the next one, then the listener's queue returns.
    private func receiverSongsEnded() {
        guard receiverSession != nil, receiverLinger == nil else { return }
        receiverEvents?(.ended)
        let wait = receiverLingerTime
        receiverLinger = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.receiverLinger = nil
            self.endReceiverSession()
        }
    }

    /// Ends a control app's session, if there is one: the listener's queue is back as it was, at its song, not playing. `event`:
    /// what the control app is told. `stopping`: off when something of the listener's is about to play in its place.
    func endReceiverSession(telling event: ReceiverPlayerEvent? = nil, stopping: Bool = true) {
        guard let session = receiverSession else { return }
        receiverLinger?.cancel()
        receiverLinger = nil
        receiverSession = nil
        if stopping {
            stop()
            state = .stopped
        }
        queue = session.queue
        originalOrder = session.originalOrder
        currentIndex = session.currentIndex
        playedToEnd = false
        failedSinceStart = false
        signalPath = nil
        if let current, session.position > 1 {
            resumeAt = (current.id, session.position)
            position = session.position
            duration = current.track.duration
        } else {
            resumeAt = nil
            position = 0
            duration = current?.track.duration ?? 0
        }
        syncMirror()
        updateNowPlayingInfo()
        if let event { receiverEvents?(event) }
    }

    /// While a control app plays, the listener's own queue is the one kept aside: a change to it is made there, and nothing that
    /// is playing is touched. False when no control app plays (the caller then changes `queue` itself).
    private func onKeptQueue(_ change: () -> Void) -> Bool {
        guard var session = receiverSession, !editingKeptQueue else { return false }
        let playing = (queue, originalOrder, currentIndex)
        (queue, originalOrder, currentIndex) = (session.queue, session.originalOrder, session.currentIndex)
        editingKeptQueue = true
        change()
        editingKeptQueue = false
        (session.queue, session.originalOrder, session.currentIndex) = (queue, originalOrder, currentIndex)
        (queue, originalOrder, currentIndex) = playing
        receiverSession = session
        return true
    }

    /// Songs added while a control app plays and the listener had no queue: they wait as the listener's queue.
    private func beginKeptQueue(_ entries: [QueueEntry]) {
        guard !entries.isEmpty else { return }
        queue = entries
        originalOrder = entries
        currentIndex = 0
    }

    // MARK: Transport

    /// The song you asked for, until the engine reports it playing. Meanwhile the engine still describes the
    /// previous one (it may be opening a file on a share), and its position must not show under the new title.
    private var requested: UUID?
    /// Position and time of the last Now Playing update, for drift checks.
    private var nowPlayingAnchor: (position: TimeInterval, at: Date)?
    /// A seek in flight: the position you dragged to, until the engine gets there.
    private var requestedPosition: (seconds: TimeInterval, at: Date)?
    /// The queue played to its end by itself: Play then starts it over from its first song. Cleared by starting a song.
    @ObservationIgnored private var playedToEnd = false
    /// A song failed since the last one started. The engine reports the queue's end after a last song that couldn't
    /// play as well; Play then tries that song again, as before.
    @ObservationIgnored private var failedSinceStart = false

    private func start(_ entry: QueueEntry, at seconds: TimeInterval = 0) {
        if holdForMissingRenderer(entry) { return }
        requested = entry.id
        resumeAt = nil
        requestedState = nil
        seekRestart = nil
        requestedPosition = nil
        playedToEnd = false
        failedSinceStart = false
        stopReason = nil
        position = 0
        duration = entry.track.duration
        // The signal path, meters and Now Playing describe the new song from now on (it's still opening).
        signalPath = nil
        systemRendering = nil
        bedMeters = nil
        channelLevels = []
        shares.skipped(to: entry.track, upcoming: upcoming.map(\.track))
        let described = trackInfo(for: entry.track)
        rendererInfo?.withLock { $0[entry.id] = described }
        if let renderer {
            if seconds > 0 {
                position = seconds
                requestedPosition = (seconds, .now)
            }
            renderer.play(entry.item, at: seconds)
        } else {
            engine.play(entry.item)
        }
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        if canCancelLoading { stop(); return }
        if missingRenderer != nil, state != .playing {
            _ = holdForMissingRenderer(current ?? queue.first)
            return
        }
        // Waiting for the chosen output to reconnect counts as playing: pressing pause cancels it.
        if waitingForDevice != nil { engine.pause(); return }
        switch state {
        case .playing: pause()
        case .paused: request(.playing); if let renderer { renderer.resume() } else { engine.resume() }
        case .stopped:
            // After the queue played to its end, Play starts it from the first song, as Apple Music does.
            if playedToEnd, currentIndex == queue.count - 1, let first = queue.first { currentIndex = 0; start(first) }
            else if let current {
                // After a control app's session, the listener's song carries on from where it was.
                let resume = resumeAt?.id == current.id ? resumeAt?.seconds : nil
                start(current)
                if let resume, renderer == nil { seek(to: resume) }
            }
            else if let first = queue.first { currentIndex = 0; start(first) }
        }
    }

    func pause() {
        if waitingForDevice != nil { engine.pause(); return }
        guard state == .playing else { return }
        request(.paused)
        if let renderer { renderer.pause() } else { engine.pause() }
    }

    private func request(_ target: PlaybackState) {
        requestedState = (target, state, .now)
        state = target
        if receiverSession != nil { receiverEvents?(target == .paused ? .paused : .resumed) }
        updateNowPlayingInfo()
    }

    /// Seconds a song must have played for Next to count as skipping it (Music's rule): quicker than that is moving
    /// through the queue, not passing over a song.
    static let skipAfter: TimeInterval = 2

    func next() {
        guard let i = currentIndex else { return }
        countSkip()
        if i + 1 < queue.count { currentIndex = i + 1; start(queue[i + 1]) }
        else if repeatMode == .all, receiverSession == nil, let first = queue.first { currentIndex = 0; start(first) }
    }

    /// Next pressed on a song heard for a moment, before it counted as a play: one skip more for it, as Music counts them.
    /// Songs from a control app (not the library's) and a song already counted as played aren't counted.
    private func countSkip() {
        guard let entry = current, !entry.received, let id = entry.track.id, listenedEntry == entry.id, scrobbledEntry != entry.id,
              listened >= Self.skipAfter else { return }
        library.markSkipped(id)
    }

    func previous() {
        guard let i = currentIndex else { return }
        if position > 3 || i == 0 { seek(to: 0); return }
        currentIndex = i - 1
        start(queue[i - 1])
    }

    func seek(to seconds: TimeInterval) {
        if let id = current?.id { seekRestart = id }
        if let renderer { renderer.seek(to: seconds) } else { engine.seek(to: seconds) }
        position = seconds
        requestedPosition = (seconds, .now)
    }

    func stop() { requested = nil; requestedPosition = nil; seekRestart = nil; requestedState = nil; if let renderer { renderer.stop() } else { engine.stop() } }

    func clearError() { lastError = nil }

    /// What the phone remote is told went wrong. The banner's message while there is one; after it was dismissed (it goes by
    /// itself in a few seconds), still why playback stopped, for as long as Now Playing on the Mac says so.
    var errorForRemote: String? { lastError ?? (state == .stopped && waitingForDevice == nil ? stopReason : nil) }

    /// Seconds of listening that put a song in the play history.
    static let historyListen: TimeInterval = 10

    // MARK: Engine events & polling

    /// What to say when a song's file is gone: with automatic scanning on its source is being rescanned for it; off, the
    /// song is only hidden (`LibraryStore.rescanForMissingFile`) and Rescan Library looks again.
    private func goneFileMessage(for track: Track) -> String {
        library.automaticScanning()
            ? String(localized: "“\(track.title)” was moved or deleted. Updating the library to find it…")
            : String(localized: "“\(track.title)” was moved or deleted, so it’s hidden from the library. Rescan Library looks for it again.")
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .trackStarted(let item):
            // A song you've already skipped past (the engine reached it before your later skips): ignore it.
            // Following it would move the queue back to it, and the next skip would continue from there.
            if let requested, requested != item.id { return }
            let fresh = requested != nil   // the song just chosen: a new play, even if it was seeked while opening
            requested = nil
            if receiverSession != nil { receiverEvents?(.started(item.id)) }
            playedToEnd = false
            failedSinceStart = false
            stopReason = nil
            // Every start of a song from a music server, the same queue entry played again too, is its server answering.
            answerOwed = queue.first { $0.id == item.id }?.track.isStreamed == true ? item.id : nil
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
            if settings.scrobble, let entry = current, !entry.received {
                let track = entry.track
                Task { try? await ListenBrainzClient.shared.submit(track, kind: .playingNow) }
            }
        case .queueEnded:
            playedToEnd = !failedSinceStart
            seekRestart = nil
            updateNowPlayingInfo()
            receiverSongsEnded()
        case .failed(let item, let message):
            if let requested, let item, requested != item.id { return }   // about a song skipped past
            requested = nil
            failedSinceStart = true
            let failed = queue.first { $0.id == item?.id } ?? current
            if receiverSession != nil, failed?.received == true {
                // A control app's song: there is no file of the listener's to look for. The control app is told why, too.
                lastError = message
                receiverEvents?(.failed(item?.id, message))
                break
            }
            let track = failed?.track
            if let track, track.isStreamed {
                // A song on a music server: there is no file to look for. The reason is the server's or the provider's. A server
                // that stopped answering is named, the way a network player that doesn't answer is.
                lastError = message == StreamingCore.notAnsweringMessage ? serverUnanswered?(track) ?? message : message
                if message == StreamingCore.notAnsweringMessage { stopReason = lastError }
            } else if let track, shares.isNetwork(track), !shares.isReachable(track), !shares.cache.isAvailable(track) {
                lastError = String(localized: "“\(track.title)” is on a network share that isn’t connected. Vespertine reconnects automatically when the server is reachable.")
            } else if let track {
                // Gone only when the file answers "no such file" and its source's folder still lists: a share that timed out or
                // dropped its mount, or a folder the app may not read, is not a deleted song. Even asking can block for as long
                // as a share does, so never on the main thread. Moved or deleted: look again now; moved songs rejoin the queue.
                lastError = message
                let path = track.filePath
                let root = library.sources.first { $0.id == track.sourceId }?.path
                Task { [weak self] in
                    let gone = await NetworkVolume.blocking(timeout: 30, otherwise: false) { LibraryStore.fileIsGone(path, sourceRoot: root) }
                    guard let self, gone else { return }
                    self.library.rescanForMissingFile(track)
                    if self.lastError == message { self.lastError = self.goneFileMessage(for: track) }
                }
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
        case .notice(let message):
            lastError = message
        case .speakerGroupCarriesOn(let group, let without):
            guard !without.isEmpty else { break }
            let names = ListFormatter.localizedString(byJoining: without)
            lastError = without.count == 1
                ? String(localized: "\(names) was disconnected. \(group) plays on without it.", comment: "A speaker group lost one output (%1$@, a DAC's name) and keeps playing on the others. %2$@ is the group's name.")
                : String(localized: "\(names) were disconnected. \(group) plays on without them.", comment: "A speaker group lost several outputs (%1$@, their names joined as a list) and keeps playing on the others. %2$@ is the group's name.")
        }
    }

    /// Library scans of network shares make way for the song you're starting, seeking or playing from a share
    /// (`ShareIOGate`): none start from the moment a song on a share is requested until it plays, and again while
    /// a song streaming live has its buffer under a third full (a staged song's copy reports for itself, in the
    /// engine). Scans resume a few seconds after the buffer is healthy, and go one request at a time while a song
    /// streams. A scan at full width queued the song's reads behind dozens of its own: starting a song took 40 s
    /// with stalls every few seconds after.
    /// The gate library scans of shares wait at (`ShareIOGate.shared`; tests give the player one of its own).
    @ObservationIgnored var shareGate = ShareIOGate.shared

    private func yieldShareToPlayback(_ snap: EngineSnapshot) {
        let active = state == .playing || requested != nil || requestedPosition != nil
        let pending = requested != nil && current.map { shares.isNetwork($0.track) } == true
        let streaming = active && (snap.readingFromShare || pending)
        shareGate.playerState(pending: pending, streaming: streaming,
                                       buffering: snap.isBuffering && snap.readingFromShare, bufferFill: snap.readingFromShare ? snap.bufferFill : 1)
    }

    /// Copies to the network cache give the connection to a song streaming from a share while its buffer is
    /// under a third full (or it's holding for more), and carry on once it's two thirds full again; and to a song whose copy
    /// from the share needs the link, whatever the buffer holds (`ShareIOGate`). On a link
    /// little faster than the music, a copy running alongside took half of it and the song stalled every few
    /// seconds; the copy still finishes when the link has room to spare.
    private func yieldCacheToPlayback(_ snap: EngineSnapshot) {
        let cache = shares.cache
        let yielding: Bool
        // A song's copy from a share holds the scan gate while it needs the link: it is starting, it is behind the playhead, or
        // a read waits on it. The output buffer can be full meanwhile (a start on a prefix), or there is none yet (a song copied
        // whole before its first note): the copies wait too.
        if shareGate.isPaused { yielding = true }
        else if snap.state != .playing || !snap.readingFromShare { yielding = false }
        else if snap.isBuffering || snap.bufferFill < 1.0 / 3 { yielding = true }
        else if snap.bufferFill > 2.0 / 3 { yielding = false }
        else { yielding = cache.yieldsToPlayback }
        if cache.yieldsToPlayback != yielding { cache.yieldsToPlayback = yielding }
    }

    /// The share's silence is a notice, not a failure: it says so once in the banner when it starts, takes that banner down when
    /// the share answers (unless the message has since become another), and leaves the song to the engine to give up on.
    private func updateShareNotice(_ stalled: Bool) {
        guard stalled else {
            if let notice = shareNotice {
                shareNotice = nil
                if lastError == notice { lastError = nil }
            }
            return
        }
        guard shareNotice == nil else { return }
        let name = current.map { shareName(for: $0.track) } ?? ""
        let notice = String(localized: "“\(name)” isn’t answering. Still trying…", comment: "%@ is the name of a network share. A song is waiting for it; the app keeps trying for a while.")
        shareNotice = notice
        lastError = notice
    }

    // MARK: Songs on a music server

    /// Told when a song on a music server has counted as played, with when it started. Set by the app while streaming is on.
    @ObservationIgnored var streamedSongPlayed: ((Track, Date) -> Void)?
    /// Told when a song stopped because its server sent nothing for too long; gives back what to say (the server by name).
    @ObservationIgnored var serverUnanswered: ((Track) -> String?)?
    /// What the listener calls the music server a song is on (the account's name in the sidebar).
    @ObservationIgnored var serverName: ((Track) -> String?)?
    /// Told when a song from a server plays: the server is answering.
    @ObservationIgnored var serverAnswered: ((Track) -> Void)?
    /// The streamed song that started and has not been reported to `serverAnswered` yet: reported once it is heard.
    @ObservationIgnored private var answerOwed: UUID?

    /// A song from a music server started and is playing, not waiting on the network: its server is told to be answering,
    /// once for each start.
    private func reportServerAnswering(_ snap: EngineSnapshot) {
        guard let owed = answerOwed, requested == nil, snap.state == .playing, snap.item?.id == owed, !snap.isBuffering,
              let entry = current, entry.id == owed else { return }
        answerOwed = nil
        serverAnswered?(entry.track)
    }
    /// The queue entry whose stream's format was written to the library, so it is written once.
    @ObservationIgnored private var confirmedStreamEntry: UUID?

    /// A provider was turned off: a song of its that is playing stops, and its songs leave the queue.
    func providerTurnedOff(_ id: String) { dropStreamed { $0.provider == id } }

    /// An account was removed from the library: the same for its songs.
    func accountRemoved(provider: String, account: String) { dropStreamed { $0.provider == provider && $0.account == account } }

    /// The local library was turned off: a file of its that is playing stops, and its files leave the queue. A music server's
    /// songs and what another app sent stay.
    func localLibraryTurnedOff() {
        let isFile: (QueueEntry) -> Bool = { !$0.received && !$0.track.isStreamed }
        if var session = receiverSession {
            // A control app's songs are playing: the listener's own queue waits behind them, and its files leave it there.
            (session.queue, session.originalOrder, session.currentIndex) =
                Self.dropping(isFile, queue: session.queue, originalOrder: session.originalOrder, currentIndex: session.currentIndex)
            receiverSession = session
            return
        }
        guard queue.contains(where: isFile) else { return }
        if current.map(isFile) == true { stop() }
        (queue, originalOrder, currentIndex) = Self.dropping(isFile, queue: queue, originalOrder: originalOrder, currentIndex: currentIndex)
        syncMirror()
    }

    /// A queue without the entries `gone` holds for. The current entry stays current; when it went, the next one that is left
    /// takes its place (stopped: Play starts it), else the last one.
    static func dropping(_ gone: (QueueEntry) -> Bool, queue: [QueueEntry], originalOrder: [QueueEntry], currentIndex: Int?)
        -> (queue: [QueueEntry], originalOrder: [QueueEntry], currentIndex: Int?) {
        let kept = queue.filter { !gone($0) }
        var index: Int?
        if let currentIndex, queue.indices.contains(currentIndex), !kept.isEmpty {
            let next = queue[currentIndex...].first { !gone($0) } ?? kept[kept.count - 1]
            index = kept.firstIndex { $0.id == next.id }
        }
        return (kept, originalOrder.filter { !gone($0) }, index)
    }

    private func dropStreamed(_ gone: (StreamLocation.Ref) -> Bool) {
        let entries = queue.filter { $0.track.streamRef.map(gone) == true }
        guard !entries.isEmpty else { return }
        if current?.track.streamRef.map(gone) == true { stop() }
        removeFromQueue(entries.map(\.id))
    }

    /// The engine's signal path with the one thing the engine can't know: that the song's server sent something other than
    /// the file it lists. Such a song is never called bit-perfect, however cleanly it plays from here.
    private func streamVerdict(_ path: SignalPath?) -> SignalPath? {
        guard var path, let stream = current?.track.streamRef,
              StreamFindings.finding(cacheKey: stream.cacheKey)?.converted == true else { return path }
        path.convertedByServer = true
        return path
    }

    /// Once a streamed song plays, the format that was read replaces the one its server lists, and the "≈" beside it goes.
    private func confirmStreamedFormat() {
        guard let entry = current, confirmedStreamEntry != entry.id, let stream = entry.track.streamRef, let path = signalPath,
              let finding = StreamFindings.finding(cacheKey: stream.cacheKey) else { return }
        confirmedStreamEntry = entry.id
        let source = path.source
        library.confirmStreamedFormat(ConfirmedStreamFormat(codec: source.codec, isLossless: source.encoding != .lossy, isDSD: source.encoding == .dsd,
                                                            sampleRate: source.sampleRate, bitDepth: source.encoding == .pcm ? source.bitDepth : nil,
                                                            channels: source.channels, converted: finding.converted),
                                      location: stream.location)
    }

    /// What the listener calls the share a song is on: its name in Sources, else the folder's, else the volume's in its path.
    private func shareName(for track: Track) -> String {
        // A song on a music server: the server, not the folder its copy is kept in while it plays.
        if track.streamRef != nil, let server = serverName?(track) { return server }
        if let source = library.sources.first(where: { $0.id == track.sourceId }) {
            return source.name ?? URL(fileURLWithPath: source.path).lastPathComponent
        }
        let parts = track.filePath.split(separator: "/")
        if parts.count > 1, parts[0] == "Volumes" { return String(parts[1]) }
        return URL(fileURLWithPath: track.filePath).deletingLastPathComponent().lastPathComponent
    }

    func poll(_ snapshot: EngineSnapshot? = nil) {
        if receiverDemo { return }
        let snap = snapshot ?? renderer?.snapshot ?? engine.snapshot
        if let requestedState, snap.state != requestedState.from
            || requestedState.state == .playing && Date().timeIntervalSince(requestedState.at) > 30 {
            self.requestedState = nil
        }
        let stateChanged = requestedState == nil && state != snap.state
        if requestedState == nil { state = snap.state }
        if stateChanged, receiverSession != nil, requested == nil {
            switch snap.state {
            case .paused: receiverEvents?(.paused)
            case .playing: receiverEvents?(.resumed)
            case .stopped: receiverSongsEnded()
            }
        }
        // Until the engine reports the song you asked for, what it says is about the previous one.
        if let requested {
            if snap.item?.id == requested || snap.state == .stopped && snap.lastError != nil { self.requested = nil }
        }
        if let target = requestedPosition {
            // A seek lands when the engine's position gets there (or after a few seconds, whatever it says).
            if abs(snap.position - target.seconds) < 1.5 || Date().timeIntervalSince(target.at) > 4 { requestedPosition = nil }
        }
        if requested == nil, requestedPosition == nil, !(resumeAt != nil && snap.state == .stopped) {
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
            let path = streamVerdict(snap.signalPath)
            if signalPath != path { signalPath = path }
            confirmStreamedFormat()
            reportServerAnswering(snap)
            if systemRendering != snap.systemRendering { systemRendering = snap.systemRendering }
            if bedMeters != snap.bedMeters { bedMeters = snap.bedMeters }
        }
        if outputDevice?.id != snap.outputDevice?.id || outputDevice?.nominalSampleRate != snap.outputDevice?.nominalSampleRate {
            outputDevice = snap.outputDevice
        }
        if state == .playing, let device = snap.outputDevice { followSystemOutput(to: device) } else if state != .playing { lastFollowed = nil }
        syncVolumeRelay()
        if underruns != snap.underruns { underruns = snap.underruns }
        if buffering != snap.isBuffering { buffering = snap.isBuffering }
        if playsWhileBuffering != snap.playsWhileBuffering { playsWhileBuffering = snap.playsWhileBuffering }
        if bufferingFraction != snap.bufferingFraction { bufferingFraction = snap.bufferingFraction }
        updateShareNotice(snap.shareStalledSeconds != nil)
        if settings.networkCache, let current, current.id == snap.item?.id, adoptedSource != current.id,
           shares.isNetwork(current.track), !current.track.isDVDFolderTrack, let local = snap.localSourceURL,
           shares.cache.adopt(current.track, from: local) {
            adoptedSource = current.id
        }
        yieldShareToPlayback(snap)
        yieldCacheToPlayback(snap)
        // Per-channel meters, only while a multichannel stream plays (cheap, but no need otherwise).
        if state == .playing, requested == nil, let bed = bedMeters, bed.names.count > 2 {
            // macOS renders, or a receiver decodes: the bed decoded beside the output.
            let peaks = engine.takeChannelPeaks()
            if channelLevels.count != peaks.count { channelLevels = peaks }
            else { channelLevels = zip(channelLevels, peaks).map { max($1, $0 * 0.82) } }
        } else if state == .playing, requested == nil, let path = signalPath, path.plan.channels > 2 || path.source.channels > 2 {
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
        if state == .playing, let entry = current, !entry.received, listenedEntry == entry.id, scrobbledEntry != entry.id, duration > 30,
           listened >= min(duration / 2, 240) {
            scrobbledEntry = entry.id
            if let id = entry.track.id { library.markPlayed(id) }
            // Its server is told only when the listener turned that on for its provider (off by default).
            if entry.track.isStreamed { streamedSongPlayed?(entry.track, trackStartedAt) }
            if settings.scrobble {
                // ListenBrainz's `listened_at` is when the song started, not when it has counted as a listen.
                let track = entry.track, startedAt = trackStartedAt
                Task { try? await ListenBrainzClient.shared.submit(track, kind: .single, listenedAt: startedAt) }
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
        // A control app's song is the control app's to announce: nothing about it is looked up or sent anywhere.
        guard state == .playing, !buffering, waitingForDevice == nil, let entry = current, !entry.received else { return nil }
        let track = entry.track
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
        if let key = track.isTransient ? track.artworkKey : track.artworkKey ?? library.album(key: track.albumKey)?.artworkKey,
           let image = ArtworkCache.shared.cached(key, size: 600) ?? ArtworkCache.shared.cached(key, size: 160) {
            info[MPMediaItemPropertyArtwork] = Self.artwork(image)
        }
        center.nowPlayingInfo = info
        nowPlayingAnchor = state == .playing ? (position, .now) : nil
        center.playbackState = state == .playing ? .playing : .paused
    }
}
