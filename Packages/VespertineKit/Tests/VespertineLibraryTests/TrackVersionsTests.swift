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

    @Test("Copies of a song in one layout are one song, and the best copy plays")
    func copiesAreOneSong() {
        var cd = track(1, 1, "Time", channels: 2, folder: "cd"); cd.sampleRate = 44_100; cd.bitDepth = 16
        var sacd = track(2, 1, "Time (2003 Remaster)", channels: 2, folder: "sacd"); sacd.sampleRate = 2_822_400; sacd.isDSD = true; sacd.bitDepth = nil
        var mp3 = track(3, 1, "Time", channels: 2, folder: "mp3"); mp3.isLossless = false; mp3.sampleRate = 48_000
        let groups = TrackVersions.group([cd, sacd, mp3])
        #expect(groups.count == 1, "a remaster suffix doesn't make another song")
        #expect(TrackVersions.choose(groups[0], multichannel: false)?.id == 2, "DSD over CD over lossy")
        #expect(TrackVersions.choose([mp3, cd], multichannel: true)?.id == 1, "no surround copy: the best stereo one")
        #expect(TrackVersions.choose([cd], multichannel: true)?.id == 1, "a lone version is always chosen")
        let anniversary = track(4, 1, "Time (50th Anniversary Edition)", channels: 2, folder: "flac"), live = track(5, 1, "Time (Live)", channels: 2, folder: "live")
        #expect(TrackVersions.group([cd, anniversary, live]).count == 2, "an edition suffix is the same song; (Live) isn't")
    }

    @Test("Of two identical copies, the local one plays; otherwise the first")
    func localCopyFirst() {
        let share = track(1, 9, "Punky's Dilemma", channels: 2, folder: "share"), local = track(2, 9, "Punky's Dilemma", channels: 2, folder: "local")
        #expect(TrackVersions.choose([share, local], multichannel: false, isLocal: { $0.id == 2 })?.id == 2)
        #expect(TrackVersions.choose([share, local], multichannel: false)?.id == 1)
    }

    @Test("Songs list in disc and track order, so a stray copy can't jump to the top")
    func ordered() {
        var stray = track(1, 9, "Punky's Dilemma", channels: 2, folder: "local")
        stray.discNumber = nil
        var rest = (1...10).map { track(Int64(10 + $0), $0, "Song \($0)", channels: 2, folder: "album") }
        rest[8] = track(19, 9, "Punky's Dilemma", channels: 2, folder: "album")
        for i in rest.indices { rest[i].discNumber = 1 }
        let songs = TrackVersions.group([stray] + rest)
        #expect(songs.map { $0[0].trackNumber } == Array(1...10))
        #expect(songs[8].count == 2)
    }

    @Test("Two editions with different songs on one number keep their folder order")
    func clashingEditionsKeepOrder() {
        let tracks = [track(1, 1, "It's a Long Way to the Top", channels: 2, folder: "a"), track(2, 2, "Rock 'n' Roll Singer", channels: 2, folder: "a"),
                      track(3, 1, "Baby, Please Don't Go", channels: 2, folder: "b"), track(4, 2, "She's Got Balls", channels: 2, folder: "b")]
        #expect(TrackVersions.group(tracks).map { $0[0].id } == [1, 2, 3, 4])
    }
}
