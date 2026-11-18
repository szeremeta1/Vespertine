//
// Vespertine: tapping a song in a list plays from that song (TestFlight feedback tf-7adda59b4b: in a playlist it played
// the first song whatever was tapped).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteProtocol
@testable import VespertineRemote

@MainActor
@Suite struct SongTaps {
    @Test func aPlaylistsSongPlaysThePlaylistFromThatSong() {
        let tap = SongTap.playlist(id: 9)
        #expect(tap(0) == .playPlaylist(id: 9, startAt: 0, shuffled: nil))
        #expect(tap(3) == .playPlaylist(id: 9, startAt: 3, shuffled: nil))
        // The last song of a long playlist, and each place of a song the playlist holds twice: the place is what is sent, never the song.
        #expect(tap(1_199) == .playPlaylist(id: 9, startAt: 1_199, shuffled: nil))
        #expect(tap(2) != tap(0))
    }

    @Test func otherListsPlayFromTheSongTapped() {
        let songs = [TrackSummary(id: 4, title: "A", artist: "", album: "", albumKey: "k", duration: 1, trackNumber: 1, discNumber: 1, format: "", artworkKey: nil, favorite: false),
                     TrackSummary(id: 7, title: "B", artist: "", album: "", albumKey: "k", duration: 1, trackNumber: 2, discNumber: 1, format: "", artworkKey: nil, favorite: false)]
        #expect(SongTap.songs(songs)(1) == .playTracks(ids: [4, 7], startAt: 1, shuffled: nil))
        #expect(SongTap.album(key: "k")(1) == .playAlbum(key: "k", startAt: 1, shuffled: false))
    }
}
