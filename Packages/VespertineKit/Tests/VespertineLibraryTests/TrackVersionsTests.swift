//
// Vespertine — stereo and multichannel versions of the same song.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineLibrary

@Suite struct TrackVersionsTests {
    private func track(_ id: Int64, _ n: Int, _ title: String, channels: Int, folder: String = "a") -> Track {
        var t = Track.stub(path: "/m/Pink Floyd/DSOTM/\(folder)/\(n).dsf")
        t.id = id; t.album = "DSOTM"; t.albumArtist = "Pink Floyd"; t.trackNumber = n; t.title = title; t.channels = channels
        return t
    }

    @Test("An SACD's 5.1 and stereo layers pair up song by song")
    func pairsLayers() {
        let tracks = [track(1, 1, "Speak to Me", channels: 6, folder: "mch"), track(2, 1, "Speak To Me", channels: 2, folder: "st"),
                      track(3, 2, "Breathe (5.1 Mix)", channels: 6, folder: "mch"), track(4, 2, "Breathe", channels: 2, folder: "st")]
        let groups = TrackVersions.group(tracks)
        #expect(groups.map { $0.compactMap(\.id) } == [[1, 2], [3, 4]])
        #expect(TrackVersions.choose(groups[0], multichannel: true)?.id == 1)
        #expect(TrackVersions.choose(groups[0], multichannel: false)?.id == 2)
    }

    @Test("Two copies in the same layout stay separate tracks, and a lone version is always chosen")
    func duplicatesStaySeparate() {
        let tracks = [track(1, 1, "Time", channels: 2, folder: "cd"), track(2, 1, "Time", channels: 2, folder: "vinyl")]
        #expect(TrackVersions.group(tracks).count == 2)
        #expect(TrackVersions.choose([tracks[0]], multichannel: true)?.id == 1)
    }
}
