//
// Vespertine: the phone's queue follows the Mac's rules (Playing Next before the rest, shuffle leaves your additions alone,
// Previous restarts after three seconds, Repeat One and Repeat All).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteProtocol
@testable import VespertinePhonePlayer

private func song(_ id: Int64) -> TrackSummary {
    TrackSummary(id: id, title: "Song \(id)", artist: "Artist", album: "Album", albumKey: "a", duration: 200,
                 trackNumber: Int(id), discNumber: 1, format: "FLAC · 16/44.1", artworkKey: nil, favorite: false)
}

private func ids(_ entries: some Sequence<PhoneQueue.Entry>) -> [Int64] { entries.compactMap(\.track.id) }

/// A generator with a fixed sequence, so a shuffle in a test is the same every run.
private struct Fixed: RandomNumberGenerator {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

@Suite("Phone queue")
struct PhoneQueueTests {
    @Test func playingAnAlbumStartsAtTheSongAskedForAndListsTheRest() {
        var queue = PhoneQueue()
        let first = queue.play((1...5).map(song), startAt: 2)
        #expect(first?.track.id == 3)
        #expect(ids(queue.upcoming) == [4, 5])
        #expect(queue.playingNext.isEmpty)
        #expect(ids(queue.continuing) == [4, 5])
    }

    @Test func anEmptyListStartsNothing() {
        var queue = PhoneQueue()
        #expect(queue.play([]) == nil)
        #expect(queue.current == nil)
        #expect(queue.next() == .end)
    }

    @Test func nextWalksToTheEndAndStopsThere() {
        var queue = PhoneQueue()
        queue.play((1...2).map(song))
        guard case .start(let second) = queue.next() else { Issue.record("no second song"); return }
        #expect(second.track.id == 2)
        #expect(queue.next() == .end)
        #expect(queue.current?.track.id == 2)
    }

    @Test func repeatAllWrapsToTheFirstSong() {
        var queue = PhoneQueue()
        queue.play((1...2).map(song), startAt: 1)
        queue.repeatMode = .all
        #expect(queue.following?.track.id == 1)
        guard case .start(let again) = queue.next() else { Issue.record("did not wrap"); return }
        #expect(again.track.id == 1)
    }

    @Test func repeatOnePlaysTheSongAgainWhenItEndsButNextStillMovesOn() {
        var queue = PhoneQueue()
        queue.play((1...3).map(song))
        queue.repeatMode = .one
        #expect(queue.following?.track.id == 1)
        guard case .start(let same) = queue.advance() else { Issue.record("did not repeat"); return }
        #expect(same.track.id == 1)
        guard case .start(let moved) = queue.next() else { Issue.record("Next did nothing"); return }
        #expect(moved.track.id == 2)
    }

    @Test func previousRestartsASongMoreThanThreeSecondsInAndGoesBackBeforeThat() {
        var queue = PhoneQueue()
        queue.play((1...3).map(song), startAt: 1)
        #expect(queue.previous(position: 3.5) == .restart)
        #expect(queue.current?.track.id == 2)
        guard case .start(let back) = queue.previous(position: 1) else { Issue.record("did not go back"); return }
        #expect(back.track.id == 1)
        // The first song has nothing before it.
        #expect(queue.previous(position: 0.5) == .restart)
    }

    @Test func playNextGoesAheadOfEarlierAdditionsAndAddToQueueGoesBehindThem() {
        var queue = PhoneQueue()
        queue.play((1...3).map(song))
        queue.addToQueue([song(10)])
        queue.playNext([song(20)])
        queue.addToQueue([song(30)])
        #expect(ids(queue.playingNext) == [20, 10, 30])
        #expect(ids(queue.continuing) == [2, 3])
        #expect(ids(queue.upcoming) == [20, 10, 30, 2, 3])
    }

    @Test func addingWithNothingPlayingStartsTheSongs() {
        var queue = PhoneQueue()
        #expect(queue.addToQueue([song(7), song(8)])?.track.id == 7)
        var other = PhoneQueue()
        #expect(other.playNext([song(9)])?.track.id == 9)
    }

    @Test func theSameSongQueuedTwiceIsTwoEntries() {
        var queue = PhoneQueue()
        queue.play([song(1)])
        queue.addToQueue([song(1), song(1)])
        #expect(Set(queue.entries.map(\.id)).count == 3)
    }

    @Test func removingNeverTakesTheSongPlaying() {
        var queue = PhoneQueue()
        queue.play((1...4).map(song), startAt: 1)
        let all = queue.entries.map(\.id)
        queue.remove(all)
        #expect(ids(queue.entries) == [2])
        #expect(queue.current?.track.id == 2)
    }

    @Test func clearUpcomingKeepsWhatAlreadyPlayed() {
        var queue = PhoneQueue()
        queue.play((1...4).map(song), startAt: 1)
        queue.clearUpcoming()
        #expect(ids(queue.entries) == [1, 2])
        #expect(queue.current?.track.id == 2)
    }

    @Test func jumpingMakesAnEntryCurrentAndAGoneEntryDoesNothing() {
        var queue = PhoneQueue()
        queue.play((1...4).map(song))
        let target = queue.entries[2].id
        #expect(queue.jump(to: target)?.track.id == 3)
        #expect(queue.jump(to: "gone") == nil)
        #expect(queue.current?.track.id == 3)
    }

    @Test func shuffleLeavesPlayingNextAloneAndKeepsTheSongPlaying() {
        var queue = PhoneQueue()
        var generator = Fixed()
        queue.play((1...8).map(song), startAt: 2)
        queue.playNext([song(50), song(51)])
        queue.setShuffle(true, using: &generator)
        #expect(queue.current?.track.id == 3)
        #expect(ids(queue.playingNext) == [50, 51])
        #expect(Set(ids(queue.continuing)) == [1, 2, 4, 5, 6, 7, 8])
        #expect(ids(queue.continuing) != [1, 2, 4, 5, 6, 7, 8])
    }

    @Test func turningShuffleOffPutsTheRestBackInOrderAfterTheSongPlaying() {
        var queue = PhoneQueue()
        var generator = Fixed()
        queue.play((1...6).map(song), startAt: 2)
        queue.playNext([song(50)])
        queue.setShuffle(true, using: &generator)
        queue.setShuffle(false, using: &generator)
        #expect(queue.current?.track.id == 3)
        #expect(ids(queue.playingNext) == [50])
        #expect(ids(queue.continuing) == [4, 5, 6])
        #expect(ids(queue.entries.prefix(2)) == [1, 2])
    }

    @Test func playShuffledStartsSomewhereAndPlaysEverySongOnce() {
        var queue = PhoneQueue()
        var generator = Fixed()
        let first = queue.play((1...10).map(song), shuffled: true, using: &generator)
        #expect(queue.shuffle)
        #expect(queue.currentIndex == 0)
        var heard = [first?.track.id].compactMap { $0 }
        while case .start(let entry) = queue.next() { heard.append(entry.track.id ?? -1) }
        #expect(heard.count == 10)
        #expect(Set(heard) == Set(1...10))
    }

    @Test func movingAnAlbumSongAmongPlayingNextMakesItPartOfIt() {
        var queue = PhoneQueue()
        queue.play((1...4).map(song))
        queue.addToQueue([song(10), song(11)])
        let four = queue.entries.first { $0.track.id == 4 }!.id
        let eleven = queue.entries.first { $0.track.id == 11 }!.id
        queue.moveUpcoming([four], before: eleven)
        #expect(ids(queue.playingNext) == [10, 4, 11])
        #expect(ids(queue.continuing) == [2, 3])
    }

    @Test func movingToTheEndLeavesPlayingNext() {
        var queue = PhoneQueue()
        queue.play((1...3).map(song))
        queue.addToQueue([song(10), song(11)])
        let ten = queue.entries.first { $0.track.id == 10 }!.id
        queue.moveUpcoming([ten], before: nil)
        #expect(ids(queue.playingNext) == [11])
        #expect(ids(queue.continuing) == [2, 3, 10])
    }

    @Test func theStateForTheQueueScreenMatchesTheMacsShape() {
        var queue = PhoneQueue()
        queue.play((1...3).map(song))
        queue.addToQueue([song(10)])
        let state = queue.state
        #expect(state.current?.track.id == 1)
        #expect(state.playingNext.map(\.track.id) == [10])
        #expect(state.continuing.map(\.track.id) == [2, 3])
        #expect(state.continuingTotal == 2)
        let before = state.revision
        queue.clearUpcoming()
        #expect(queue.state.revision > before)
    }
}
