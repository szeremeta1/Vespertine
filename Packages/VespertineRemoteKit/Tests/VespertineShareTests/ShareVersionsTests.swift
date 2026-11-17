//
// Vespertine: a share's song in stereo and in surround is one song: listed once, one heart, each version told of the
// other so the phone's output picks the one that plays. Kept narrow, so nothing that is its own recording is hidden.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteProtocol
@testable import VespertineShare

private func song(_ id: Int64, _ folder: String, _ title: String, album: String, track: Int, channels: Int = 2, duration: Double = 240,
                  artist: String = "The Vesper Quartet") -> ShareSong {
    var tags = SongTags(codec: channels > 2 ? "ALAC" : "FLAC", sampleRate: channels > 2 ? 48_000 : 96_000, bitDepth: 24, channels: channels, duration: duration)
    tags.title = title
    tags.artist = artist
    tags.albumArtist = artist
    tags.album = album
    tags.track = track
    return ShareSong(id: id, path: "\(artist)/\(folder)/\(String(format: "%02d", track)) \(title).\(channels > 2 ? "m4a" : "flac")", size: 1000,
                     modified: Date(timeIntervalSince1970: 1_700_000_000), tags: tags)
}

/// "Evening" in stereo, its Dolby Atmos edition as an album of its own, and "Tide" in both layouts on the stereo album.
private let evening: [ShareSong] = [
    song(1, "Evening", "Harbor", album: "Evening", track: 1),
    song(2, "Evening", "Lanterns", album: "Evening", track: 2, duration: 300),
    song(3, "Evening", "Tide", album: "Evening", track: 3, duration: 200),
    song(4, "Evening", "Tide (5.1 Mix)", album: "Evening", track: 4, channels: 6, duration: 201),
    song(5, "Evening", "Harbor (Live)", album: "Evening", track: 5, duration: 241),
    song(101, "Evening Atmos", "Harbor", album: "Evening (Dolby Atmos)", track: 1, channels: 6, duration: 242),
    song(102, "Evening Atmos", "Lanterns", album: "Evening (Dolby Atmos)", track: 2, channels: 6, duration: 340),
    song(201, "Best Of", "Harbor", album: "The Best of the Quartet", track: 7, channels: 6),
]

@Suite struct ShareVersionsTests {
    @Test func aLayoutLabelIsDroppedFromATitleAndNothingElseIs() {
        #expect(ShareVersions.base("Evening (Dolby Atmos)") == "evening")
        #expect(ShareVersions.base("Évening [5.1 Mix]") == "evening")
        #expect(ShareVersions.base("Tide (Live) (Surround)") == "tide (live)")
        #expect(ShareVersions.base("Harbor (Live)") == "harbor (live)")
        #expect(ShareVersions.base("Evening (Deluxe Edition)") == "evening (deluxe edition)")
        #expect(ShareVersions.base("(Stereo)") == "(stereo)", "a title that is only a label stays a title")
    }

    @Test func aSongInBothLayoutsIsOneSongOnItsAlbumAndAcrossItsSurroundEdition() {
        let catalog = ShareCatalog(ShareLibrary(songs: evening))
        #expect(catalog.otherLayout == [1: 101, 101: 1, 3: 4, 4: 3])
        #expect(catalog.unlisted == [101, 4])
        // Each version is told of the other, for the phone's output to pick.
        #expect(catalog.tracks[1]?.surround == false && catalog.tracks[1]?.otherLayout?.id == 101)
        #expect(catalog.tracks[1]?.otherLayout?.album == "Evening (Dolby Atmos)" && catalog.tracks[1]?.otherLayout?.duration == 242)
        #expect(catalog.tracks[101]?.surround == true && catalog.tracks[101]?.otherLayout?.id == 1)
        #expect(catalog.tracks[1]?.asOtherLayout?.id == 101)
        // Its own recordings stay: the live take, the song whose lengths are too far apart, the one on a compilation.
        #expect(catalog.tracks[5]?.otherLayout == nil)
        #expect(catalog.tracks[2]?.otherLayout == nil && catalog.tracks[102]?.otherLayout == nil)
        #expect(catalog.tracks[201]?.otherLayout == nil)
    }

    @Test func listsOfSongsShowTheSongOnceWithBothVersionsBesideIt() {
        let catalog = ShareCatalog(ShareLibrary(songs: evening))
        #expect(Set(catalog.listedTracks.compactMap(\.id)) == [1, 2, 3, 5, 102, 201])
        #expect(catalog.songs(offset: 0, limit: 50).total == 6)
        #expect(catalog.search("harbor", limit: 50).compactMap(\.id).sorted() == [1, 5, 201])
        let harbor = catalog.listedTracks.first { $0.id == 1 }
        #expect(harbor?.copies?.map(\.id) == [1, 101])
        #expect(harbor?.copies?.map(\.format) == ["FLAC · 24/96", "ALAC · 24/48 · 5.1"])
        #expect(catalog.listedTracks.first { $0.id == 2 }?.copies == nil)
        // An album's page still lists the album's own files.
        #expect(catalog.albums.first { $0.summary.title == "Evening (Dolby Atmos)" }?.tracks == [101, 102])
    }

    @Test func aHeartOnOneVersionIsAHeartOnTheSong() {
        var catalog = ShareCatalog(ShareLibrary(songs: evening), favorites: [101])
        #expect(catalog.tracks[1]?.favorite == true && catalog.tracks[101]?.favorite == true)
        #expect(catalog.listedTracks.filter(\.favorite).compactMap(\.id) == [1], "Favorites lists it once")
        #expect(catalog.withVersions([1, 2]) == [1, 2, 101])
        catalog.setFavorite([1], false)
        #expect(catalog.tracks[1]?.favorite == false && catalog.tracks[101]?.favorite == false)
        catalog.setFavorite([4], true)
        #expect(catalog.tracks[3]?.favorite == true && catalog.tracks[4]?.favorite == true)
    }

    @Test func switchedOffEveryFileIsItsOwnSong() {
        let catalog = ShareCatalog(ShareLibrary(songs: evening), favorites: [101], combinesVersions: false)
        #expect(catalog.otherLayout.isEmpty && catalog.unlisted.isEmpty)
        #expect(catalog.listedTracks.count == evening.count)
        #expect(catalog.tracks[1]?.favorite == false && catalog.tracks[1]?.otherLayout == nil)
        #expect(catalog.tracks[101]?.surround == true, "a file's layout is still said")
    }

    @Test func aSongTakesOneVersionTheNearestFirst() {
        func candidate(_ id: Int64, album: String, number: Int, duration: Double, surround: Bool) -> ShareVersions.Candidate {
            .init(id: id, artist: "A", album: album, albumKey: album, title: "Tide", disc: 1, number: number, duration: duration, surround: surround)
        }
        // Two stereo copies and one 5.1: the 5.1 goes with the copy on its own album.
        let pairs = ShareVersions.pairs([candidate(1, album: "Evening", number: 3, duration: 200, surround: false),
                                         candidate(2, album: "Evening (Surround)", number: 3, duration: 200, surround: false),
                                         candidate(3, album: "Evening (Surround)", number: 3, duration: 201, surround: true)])
        #expect(pairs.count == 1 && pairs.first?.stereo == 2 && pairs.first?.surround == 3)
        // Two stereo tracks alone are never matched, nor a length that is unknown.
        #expect(ShareVersions.pairs([candidate(1, album: "E", number: 1, duration: 200, surround: false),
                                     candidate(2, album: "E", number: 1, duration: 200, surround: false)]).isEmpty)
        #expect(ShareVersions.pairs([candidate(1, album: "E", number: 1, duration: 0, surround: false),
                                     candidate(2, album: "E", number: 1, duration: 0, surround: true)]).isEmpty)
    }
}
