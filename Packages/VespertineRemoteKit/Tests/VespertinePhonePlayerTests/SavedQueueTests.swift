//
// Vespertine: the phone's queue is kept between launches. What was playing comes back paused at its place, nothing is
// fetched until Play, and a file that can't be read is no queue rather than an error.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteProtocol
@testable import VespertinePhonePlayer

private func song(_ id: Int64, seconds: Double = 200) -> TrackSummary {
    TrackSummary(id: id, title: "Song \(id)", artist: "Artist", album: "Album", albumKey: "a", duration: seconds, trackNumber: Int(id), discNumber: 1,
                 format: "FLAC · 16/44.1", artworkKey: nil, favorite: false)
}

private func ids(_ entries: some Sequence<PhoneQueue.Entry>) -> [Int64] { entries.compactMap(\.track.id) }

/// The same every run.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64 = 42
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

@Suite struct QueueShelfTests {
    private func shelf() -> QueueShelf {
        QueueShelf(directory: FileManager.default.temporaryDirectory.appendingPathComponent("queues-\(UUID())", isDirectory: true))
    }

    @Test func aQueueComesBackAsItWasLeft() {
        let shelf = shelf()
        defer { try? FileManager.default.removeItem(at: shelf.directory) }
        var queue = PhoneQueue()
        queue.play((1...5).map { song($0) }, startAt: 1)
        queue.playNext([song(9)])
        queue.repeatMode = .all
        shelf.save(queue: queue, for: "mac")
        shelf.save(entry: queue.current!.id, position: 61.5, for: "mac")
        let back = shelf.load("mac")
        #expect(back?.queue == queue, "entries, their IDs, what was added by hand, repeat and the count of changes")
        #expect(back?.position == 61.5)
        #expect(ids(back?.queue.playingNext ?? []) == [9])
    }

    @Test func shuffleComesBackShuffledAndTurningItOffStillRestoresTheAlbumOrder() {
        let shelf = shelf()
        defer { try? FileManager.default.removeItem(at: shelf.directory) }
        var generator = Seeded()
        var queue = PhoneQueue()
        queue.play((1...8).map { song($0) }, startAt: 2, shuffled: nil, using: &generator)
        queue.setShuffle(true, using: &generator)
        shelf.save(queue: queue, for: "mac")
        var back = shelf.load("mac")!.queue
        #expect(back.shuffle && ids(back.entries) == ids(queue.entries))
        // The order from before the shuffle travelled with it.
        back.setShuffle(false, using: &generator)
        queue.setShuffle(false, using: &generator)
        #expect(ids(back.entries) == ids(queue.entries))
        #expect(ids(back.upcoming) == [4, 5, 6, 7, 8])
    }

    @Test func eachMacAndShareHasItsOwnQueueWhateverItsIDLooksLike() {
        let shelf = shelf()
        defer { try? FileManager.default.removeItem(at: shelf.directory) }
        var one = PhoneQueue(), two = PhoneQueue()
        one.play([song(1)])
        two.play([song(2)])
        // A share's ID has a scheme, slashes and whatever its name holds.
        shelf.save(queue: one, for: "share:smb://nas.local/Music/Ünïcode & more")
        shelf.save(queue: two, for: "share:smb://nas.local/Music/Ünïcode_& more")
        #expect(ids(shelf.load("share:smb://nas.local/Music/Ünïcode & more")?.queue.entries ?? []) == [1])
        #expect(ids(shelf.load("share:smb://nas.local/Music/Ünïcode_& more")?.queue.entries ?? []) == [2])
        #expect(shelf.load("another") == nil)
        // Every file is inside the shelf's own folder.
        let files = try? FileManager.default.contentsOfDirectory(atPath: shelf.directory.path)
        #expect(files?.count == 2)
    }

    @Test func aPlaceWrittenForAnotherSongIsNotUsed() {
        let shelf = shelf()
        defer { try? FileManager.default.removeItem(at: shelf.directory) }
        var queue = PhoneQueue()
        queue.play([song(1), song(2)])
        shelf.save(queue: queue, for: "mac")
        shelf.save(entry: "some entry that is gone", position: 90, for: "mac")
        #expect(shelf.load("mac")?.position == 0)
    }

    @Test func aDamagedFileOrOneInAnotherShapeIsNoQueue() throws {
        let shelf = shelf()
        defer { try? FileManager.default.removeItem(at: shelf.directory) }
        var queue = PhoneQueue()
        queue.play([song(1)])
        shelf.save(queue: queue, for: "mac")
        try Data("{ not json".utf8).write(to: shelf.queueFile("mac"))
        #expect(shelf.load("mac") == nil)
        try Data(#"{"shape":99,"queue":{}}"#.utf8).write(to: shelf.queueFile("mac"))
        #expect(shelf.load("mac") == nil)
        // A queue whose current song points outside it (a file edited or cut short) isn't trusted either.
        shelf.save(queue: queue, for: "mac")
        let text = try #require(String(data: try Data(contentsOf: shelf.queueFile("mac")), encoding: .utf8))
        try Data(text.replacingOccurrences(of: "\"currentIndex\":0", with: "\"currentIndex\":7").utf8).write(to: shelf.queueFile("mac"))
        #expect(shelf.load("mac") == nil)
    }

    @Test func forgettingAMacTakesItsQueueAndAQueueWithNothingPlayingIsNotKept() {
        let shelf = shelf()
        defer { try? FileManager.default.removeItem(at: shelf.directory) }
        var queue = PhoneQueue()
        queue.play([song(1)])
        shelf.save(queue: queue, for: "mac")
        shelf.save(entry: queue.current!.id, position: 3, for: "mac")
        shelf.forget("mac")
        #expect(shelf.load("mac") == nil)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: shelf.directory.path))?.isEmpty == true)
        shelf.save(queue: queue, for: "mac")
        shelf.save(queue: PhoneQueue(), for: "mac")
        #expect(shelf.load("mac") == nil)
    }

    @Test func playPicksUpWhereTheSongWasLeftButNotInItsLastSeconds() {
        var queue = PhoneQueue()
        queue.play([song(1, seconds: 200)])
        #expect(SavedQueue(queue: queue, position: 61.5).resumePosition == 61.5)
        #expect(SavedQueue(queue: queue, position: 199).resumePosition == 0, "left at the very end: from the start")
        #expect(SavedQueue(queue: queue, position: -4).resumePosition == 0)
        #expect(SavedQueue(queue: queue, position: .nan).resumePosition == 0)
        #expect(SavedQueue(queue: queue, position: .infinity).resumePosition == 0)
        // A very short song: its last half, not its last two seconds, or it could never be picked up at all.
        var short = PhoneQueue()
        short.play([song(1, seconds: 1)])
        #expect(SavedQueue(queue: short, position: 0.4).resumePosition == 0.4)
        #expect(SavedQueue(queue: short, position: 0.6).resumePosition == 0)
        // A song whose length the Mac never said keeps its place.
        var unknown = PhoneQueue()
        unknown.play([song(1, seconds: 0)])
        #expect(SavedQueue(queue: unknown, position: 30).resumePosition == 30)
    }
}
