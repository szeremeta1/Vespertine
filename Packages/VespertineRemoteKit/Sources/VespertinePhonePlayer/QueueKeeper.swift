//
// Vespertine: keeps the phone's queue for the next launch as it changes. The queue is written when it changes (off the main
// thread: it can be thousands of songs), the place in the song when it is news (a pause, a seek, another song) and every
// few seconds while it plays, so an app ended mid-song comes back within a few seconds of where it was.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Network) && canImport(AVFAudio)
import Foundation
import Observation
import VespertineRemoteProtocol

@MainActor
public final class QueueKeeper {
    public let playback: PhonePlayback
    public let shelf: QueueShelf
    /// The Mac or share the queue belongs to.
    public let owner: String
    /// How often the place is written while a song plays.
    public var interval: Duration = .seconds(10)

    private var running = false
    /// What the queue file was last written from: the queue's own count of changes, and the two settings that don't count.
    private struct Stamp: Equatable {
        var revision: Int
        var shuffle: Bool
        var repeatMode: RepeatModeValue
        var current: String?
    }
    private var written: Stamp?
    private var waiting: PhoneQueue?
    private var writer: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var placed: QueueShelf.Place?

    public init(playback: PhonePlayback, shelf: QueueShelf, owner: String) {
        self.playback = playback
        self.shelf = shelf
        self.owner = owner
    }

    /// Puts back the queue kept for this Mac, if the player has none yet, and keeps it from here on.
    public func start() {
        guard !running else { return }
        running = true
        if let saved = shelf.load(owner), playback.restore(saved) {
            // What is on the shelf is what the player holds: nothing to write until it changes.
            written = stamp()
            placed = saved.queue.current.map { .init(entry: $0.id, position: playback.position) }
        }
        track()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.interval else { return }
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                if playback.player.state == .playing { savePlace() }
            }
        }
    }

    /// Stops keeping, with what there is now written first.
    public func stop() {
        guard running else { return }
        saveNow()
        running = false
        clock?.cancel()
        clock = nil
    }

    /// Writes the queue and the place before returning: for when the app is about to be put away.
    public func saveNow() {
        guard running else { return }
        waiting = nil
        let now = stamp()
        if now != written {
            written = now
            shelf.save(queue: playback.queue, for: owner)
        }
        savePlace()
    }

    /// The queue file is as the queue was when this was called (tests wait on it instead of on a clock).
    public func settled() async {
        while let writer { await writer.value }
    }

    private func stamp() -> Stamp {
        let queue = playback.queue
        return Stamp(revision: queue.revision, shuffle: queue.shuffle, repeatMode: queue.repeatMode, current: queue.current?.id)
    }

    /// Follows the player: runs `changed` whenever the queue, the song or the place in it is news.
    private func track() {
        guard running else { return }
        withObservationTracking {
            changed()
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
    }

    private func changed() {
        // Read so that a seek, a pause and a song starting from a place of its own bring this back.
        _ = playback.anchor
        _ = playback.resumeAt
        _ = playback.nowPlaying
        let now = stamp()
        if now != written {
            written = now
            waiting = playback.queue
            write()
        }
        savePlace()
    }

    /// Writes the queue off the main thread. Changes that arrive while one is being written wait as one: the latest.
    private func write() {
        guard writer == nil else { return }
        writer = Task { [weak self] in
            while let self, let next = waiting {
                waiting = nil
                let shelf = shelf, owner = owner
                await Task.detached(priority: .utility) { shelf.save(queue: next, for: owner) }.value
            }
            self?.writer = nil
        }
    }

    private func savePlace() {
        guard let entry = playback.queue.current else { return }
        let place = QueueShelf.Place(entry: entry.id, position: playback.livePosition)
        guard place != placed else { return }
        placed = place
        shelf.save(entry: place.entry, position: place.position, for: owner)
    }
}
#endif
