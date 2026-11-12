//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineLibrary

@Suite("ListenBrainz submissions")
struct ListenBrainzSubmissionTests {
    private var track: Track {
        var t = Track.stub(path: "/Music/The Vesper Quartet/Nocturnes/01 Dusk.flac")
        t.title = "Dusk"; t.artist = "The Vesper Quartet"; t.album = "Nocturnes"; t.duration = 300
        return t
    }

    @Test("A listen is dated when the song started, whenever it is sent")
    func listenCarriesTheStartTime() throws {
        // Sent halfway through, or four minutes in: the time given is the start's.
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let body = ListenBrainzClient.submission(track, kind: .single, listenedAt: started)
        #expect(body["listen_type"] as? String == "single")
        let payload = try #require(body["payload"] as? [[String: Any]])
        #expect(payload.count == 1)
        #expect(payload[0]["listened_at"] as? Int == 1_700_000_000)
        let metadata = try #require(payload[0]["track_metadata"] as? [String: Any])
        #expect(metadata["track_name"] as? String == "Dusk")
        #expect(metadata["artist_name"] as? String == "The Vesper Quartet")
        #expect(metadata["release_name"] as? String == "Nocturnes")
        let info = try #require(metadata["additional_info"] as? [String: Any])
        #expect(info["duration"] as? Int == 300)
        #expect(info["media_player"] as? String == "Vespertine")
        #expect(info["submission_client"] as? String == "Vespertine")
    }

    @Test("A playing-now notice carries no time")
    func playingNowHasNoTime() throws {
        let body = ListenBrainzClient.submission(track, kind: .playingNow, listenedAt: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(body["listen_type"] as? String == "playing_now")
        let payload = try #require(body["payload"] as? [[String: Any]])
        #expect(payload[0]["listened_at"] == nil)
    }
}
