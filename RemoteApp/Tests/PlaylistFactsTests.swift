//
// Vespertine: a playlist's page says how many songs and how long, and its Play and Shuffle buttons send the whole playlist
// (TestFlight feedback AOf1M7oLiLlxngkwwaWog5Y).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteProtocol
@testable import VespertineRemote

@MainActor
@Suite struct PlaylistFactsTests {
    private func songs(_ lengths: [Double]) -> [TrackSummary] {
        lengths.enumerated().map { index, length in
            TrackSummary(id: Int64(index), title: "\(index)", artist: "", album: "", albumKey: "", duration: length, trackNumber: nil, discNumber: nil,
                         format: "", artworkKey: nil, favorite: false)
        }
    }

    @Test func theLengthIsInHoursAndMinutes() {
        let english = Locale(identifier: "en_US")
        #expect(PlaylistFacts.length(songs([1_800, 1_800, 720]), locale: english) == "1 hr, 12 min")
        #expect(PlaylistFacts.length(songs([200, 214]), locale: english) == "7 min")
        #expect(PlaylistFacts.length(songs([42]), locale: english) == "42 sec")
        // A song whose length the Mac doesn't know counts as nothing, not as an error.
        #expect(PlaylistFacts.length(songs([.nan, 300]), locale: english) == "5 min")
    }

    @Test func playAndShuffleSendTheWholePlaylist() {
        #expect(PlaylistFacts.play(9) == .playPlaylist(id: 9, startAt: nil, shuffled: false))
        #expect(PlaylistFacts.shuffle(9) == .playPlaylist(id: 9, startAt: nil, shuffled: true))
    }
}
