//
// Vespertine: the phone's own queue, for songs that play on this phone. The rules are the Mac's (`PlayerController`): songs
// added with Play Next or Add to Queue come before the rest of what was playing, shuffle never mixes them, turning shuffle
// off puts the rest back in its order, and Previous restarts a song that is more than three seconds in.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import VespertineRemoteProtocol

public struct PhoneQueue: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        /// The entry's own ID: the same song can be queued twice.
        public let id: String
        public var track: TrackSummary
        /// Added with Play Next or Add to Queue, and not yet demoted by a move.
        public var queuedByUser: Bool

        public init(id: String = UUID().uuidString, track: TrackSummary, queuedByUser: Bool = false) {
            self.id = id
            self.track = track
            self.queuedByUser = queuedByUser
        }
    }

    /// What a step does to the player.
    public enum Step: Sendable, Equatable {
        /// Start this entry from its beginning.
        case start(Entry)
        /// Go back to the start of the song that is playing.
        case restart
        /// Nothing follows: playback ends.
        case end
    }

    /// Seconds into a song after which Previous restarts it instead of going back one.
    public static let previousRestartsAfter: Double = 3

    public private(set) var entries: [Entry] = []
    public private(set) var currentIndex: Int?
    public private(set) var shuffle = false
    public var repeatMode: RepeatModeValue = .off
    public private(set) var revision = 0

    private var originalOrder: [Entry] = []
    /// The last song of what was playing that had its turn before shuffle was turned on.
    private var shuffledAfter: String?

    public init() {}

    public var current: Entry? { currentIndex.flatMap { entries.indices.contains($0) ? entries[$0] : nil } }
    /// Everything after the song playing, in the order it plays.
    public var upcoming: ArraySlice<Entry> { currentIndex.map { entries[($0 + 1)...] } ?? entries[...] }
    /// The songs added with Play Next or Add to Queue that are still to come.
    public var playingNext: ArraySlice<Entry> { upcoming.prefix { $0.queuedByUser } }
    /// The rest of what was started.
    public var continuing: ArraySlice<Entry> { upcoming.dropFirst(playingNext.count) }

    /// What plays when the current song ends by itself (gapless reads this ahead of time).
    public var following: Entry? {
        guard let i = currentIndex else { return nil }
        if repeatMode == .one { return entries[i] }
        if i + 1 < entries.count { return entries[i + 1] }
        return repeatMode == .all ? entries.first : nil
    }

    // MARK: Starting

    /// Replaces the queue with `tracks` and returns the entry to start. `shuffled` turns shuffle on (starting at a random
    /// song) or off; nil keeps the setting and starts at `index`.
    @discardableResult
    public mutating func play(_ tracks: [TrackSummary], startAt index: Int = 0, shuffled: Bool? = nil) -> Entry? {
        var generator = SystemRandomNumberGenerator()
        return play(tracks, startAt: index, shuffled: shuffled, using: &generator)
    }

    @discardableResult
    public mutating func play<G: RandomNumberGenerator>(_ tracks: [TrackSummary], startAt index: Int = 0, shuffled: Bool? = nil,
                                                        using generator: inout G) -> Entry? {
        guard !tracks.isEmpty else { return nil }
        let made = tracks.map { Entry(track: $0) }
        if let shuffled { shuffle = shuffled }
        originalOrder = made
        entries = made
        shuffledAfter = nil
        currentIndex = shuffled == true ? made.indices.randomElement(using: &generator) : min(max(0, index), made.count - 1)
        if shuffle { applyShuffle(using: &generator) } else { revision += 1 }
        return current
    }

    /// Puts `tracks` right after the song playing, ahead of anything else in Playing Next. With nothing playing it starts them.
    @discardableResult
    public mutating func playNext(_ tracks: [TrackSummary]) -> Entry? {
        guard let i = currentIndex else { return play(tracks) }
        let made = tracks.map { Entry(track: $0, queuedByUser: true) }
        entries.insert(contentsOf: made, at: i + 1)
        originalOrder.append(contentsOf: made)
        revision += 1
        return nil
    }

    /// Adds `tracks` to the end of Playing Next: after the songs already added, before the rest of what was playing.
    @discardableResult
    public mutating func addToQueue(_ tracks: [TrackSummary]) -> Entry? {
        guard let i = currentIndex else { return play(tracks) }
        let made = tracks.map { Entry(track: $0, queuedByUser: true) }
        entries.insert(contentsOf: made, at: i + 1 + playingNext.count)
        originalOrder.append(contentsOf: made)
        revision += 1
        return nil
    }

    // MARK: Moving through it

    /// The Next button: the following entry, the first one again under Repeat All, or nothing at the end.
    public mutating func next() -> Step {
        guard let i = currentIndex else { return .end }
        if i + 1 < entries.count { currentIndex = i + 1; revision += 1; return .start(entries[i + 1]) }
        if repeatMode == .all, let first = entries.first { currentIndex = 0; revision += 1; return .start(first) }
        return .end
    }

    /// The song ended by itself: Repeat One plays it again, otherwise as `next()`.
    public mutating func advance() -> Step {
        if repeatMode == .one, let current { return .start(current) }
        return next()
    }

    public mutating func previous(position: Double) -> Step {
        guard let i = currentIndex else { return .end }
        if position > Self.previousRestartsAfter || i == 0 { return .restart }
        currentIndex = i - 1
        revision += 1
        return .start(entries[i - 1])
    }

    public mutating func jump(to id: String) -> Entry? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        currentIndex = i
        revision += 1
        return entries[i]
    }

    // MARK: Editing

    /// Removes entries, never the one playing. Entries no longer queued are ignored.
    public mutating func remove(_ ids: some Collection<String>) {
        var remove = Set(ids)
        if let current { remove.remove(current.id) }
        guard entries.contains(where: { remove.contains($0.id) }) else { return }
        let currentID = current?.id
        entries.removeAll { remove.contains($0.id) }
        originalOrder.removeAll { remove.contains($0.id) }
        currentIndex = currentID.flatMap { id in entries.firstIndex { $0.id == id } }
        revision += 1
    }

    /// Empties everything after the song playing.
    public mutating func clearUpcoming() { remove(upcoming.map(\.id)) }

    /// Moves upcoming entries (in the order given) to just before `target`, or to the end when it is nil. Entries that are
    /// playing, already played or gone are left alone. Landing among Playing Next's songs, they join it.
    public mutating func moveUpcoming(_ ids: [String], before target: String?, playingNext joinsAsked: Bool? = nil) {
        guard let c = currentIndex else { return }
        let shown = Array(entries[(c + 1)...])
        let known = Set(shown.map(\.id))
        var seen = Set<String>()
        let chosen = ids.filter { known.contains($0) && $0 != target && seen.insert($0).inserted }
        guard !chosen.isEmpty else { return }
        let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let moving = chosen.compactMap { byID[$0] }
        var rest = shown.filter { !seen.contains($0.id) }
        let at = target.flatMap { t in rest.firstIndex { $0.id == t } } ?? rest.count
        let block = rest.prefix { $0.queuedByUser }.count
        let joins = joinsAsked ?? (at < block || (at == block && block > 0 && moving.allSatisfy(\.queuedByUser)))
        rest.insert(contentsOf: moving.map { var e = $0; e.queuedByUser = joins; return e }, at: at)
        // Songs left behind Playing Next's last one aren't part of it any more.
        if let firstOther = rest.firstIndex(where: { !$0.queuedByUser }) {
            for i in rest.indices where i > firstOther { rest[i].queuedByUser = false }
        }
        entries = Array(entries[...c]) + rest
        originalOrder = entries
        revision += 1
    }

    // MARK: Shuffle

    public mutating func setShuffle(_ on: Bool) {
        var generator = SystemRandomNumberGenerator()
        setShuffle(on, using: &generator)
    }

    public mutating func setShuffle<G: RandomNumberGenerator>(_ on: Bool, using generator: inout G) {
        guard on != shuffle else { return }
        shuffle = on
        applyShuffle(using: &generator)
    }

    private mutating func applyShuffle<G: RandomNumberGenerator>(using generator: inout G) {
        revision += 1
        guard !entries.isEmpty else { return }
        let current = self.current
        let next = Array(playingNext)
        let nextIDs = Set(next.map(\.id))
        // Songs you added that aren't playing or coming next had their turn: they don't play a second time.
        let passed = entries.filter { $0.queuedByUser && $0.id != current?.id && !nextIDs.contains($0.id) }
        // The last song before (or at) the one playing that you didn't add.
        let lastOwn = currentIndex.flatMap { i in entries[...i].last { !$0.queuedByUser }?.id }
        if shuffle {
            if let lastOwn { shuffledAfter = lastOwn }
            var rest = entries.filter { !$0.queuedByUser && $0.id != current?.id }
            rest.shuffle(using: &generator)
            entries = passed + (current.map { [$0] } ?? []) + next + rest
            currentIndex = current == nil ? nil : passed.count
        } else if let current {
            let added = Set(entries.lazy.filter(\.queuedByUser).map(\.id))
            let own = originalOrder.filter { !added.contains($0.id) }
            let place = (lastOwn ?? shuffledAfter).flatMap { id in own.firstIndex { $0.id == id } }
            var before = place.map { Array(own[...$0]) } ?? []
            let after = place.map { Array(own[($0 + 1)...]) } ?? own
            if !current.queuedByUser, before.last?.id == current.id { before.removeLast() }
            entries = before + passed + [current] + next + after
            currentIndex = before.count + passed.count
        } else {
            entries = originalOrder
            currentIndex = nil
        }
    }

    // MARK: For the screens

    /// The queue in the shape the Mac pushes its own, so the Queue screen draws either with the same code.
    public var state: QueueState {
        func item(_ e: Entry) -> QueueItem { QueueItem(entry: e.id, track: e.track) }
        let rest = continuing
        return QueueState(revision: revision, current: current.map(item), playingNext: playingNext.map(item),
                          continuing: rest.prefix(QueueState.continuingLimit).map(item), continuingTotal: rest.count)
    }
}
