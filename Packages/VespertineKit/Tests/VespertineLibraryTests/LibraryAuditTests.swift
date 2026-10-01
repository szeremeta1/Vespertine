//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineLibrary

@Suite("Library audit and numbering")
struct LibraryAuditTests {
    private func t(_ id: Int64, _ path: String, album: String, artist: String = "Artist", albumArtist: String? = nil,
                   n: Int?, disc: Int? = nil, title: String, size: Int64 = 1000, duration: Double = 200) -> Track {
        var x = Track.stub(path: path)
        x.id = id; x.album = album; x.artist = artist; x.albumArtist = albumArtist; x.trackNumber = n; x.discNumber = disc
        x.title = title; x.fileSize = size + id; x.duration = duration
        return x
    }

    @Test("Track numbers come from file names only when they can't be part of a name")
    func fileNameNumbers() {
        func n(_ name: String) -> Int? { MetadataReader.trackNumber(fromFileName: URL(fileURLWithPath: "/m/\(name).flac")) }
        #expect(n("The Killers - Hot Fuss - 01 - Jenny Was a Friend of Mine") == 1)
        #expect(n("05 Title") == 5)
        #expect(n("05. Title") == 5)
        #expect(n("7. Title") == 7)
        #expect(n("12 - Title") == 12)
        #expect(n("50 Cent - In da Club") == nil)
        #expect(n("1989 - Welcome to New York") == nil)
        #expect(n("Song Without Number") == nil)
    }

    @Test("Numbered disc folders give a disc number; layer folders don't")
    func discFolders() {
        #expect(ArtworkStore.discNumber(fromFolder: "CD 01") == 1)
        #expect(ArtworkStore.discNumber(fromFolder: "Disc 2") == 2)
        #expect(ArtworkStore.discNumber(fromFolder: "SHM-CD 02") == 2)
        #expect(ArtworkStore.discNumber(fromFolder: "12\" Vinyl 03") == 3)
        #expect(ArtworkStore.discNumber(fromFolder: "Stereo") == nil)
        #expect(ArtworkStore.discNumber(fromFolder: "Multichannel 5.1") == nil)
        #expect(ArtworkStore.discNumber(fromFolder: "Bookends (1968)") == nil)
    }

    @Test("Splits, merged editions, duplicate files and missing numbers are found")
    func findings() {
        let tracks = [
            // One album split by a featured artist's credit, in one folder.
            t(1, "/m/Eminem/Slim Shady/01.flac", album: "Slim Shady", artist: "Eminem", n: 1, title: "Renaissance"),
            t(2, "/m/Eminem/Slim Shady/17.flac", album: "Slim Shady", artist: "Eminem, Big Sean", n: 17, title: "Tobey"),
            // One album split by disc markers in the title.
            t(3, "/m/EJ/Elton John/CD 01/01.flac", album: "Elton John (Deluxe Edition) [CD-01]", artist: "Elton John", n: 1, disc: 1, title: "Your Song"),
            t(4, "/m/EJ/Elton John/CD 02/01.flac", album: "Elton John (Deluxe Edition) [CD-02]", artist: "Elton John", n: 1, disc: 2, title: "Your Song (demo)"),
            // Two editions with one title and different track lists.
            t(5, "/m/ACDC/High Voltage (1975)/01.flac", album: "High Voltage", artist: "AC/DC", n: 1, title: "Baby, Please Don't Go"),
            t(6, "/m/ACDC/High Voltage (1976)/01.flac", album: "High Voltage", artist: "AC/DC", n: 1, title: "It's a Long Way to the Top"),
            // The same file twice.
            t(7, "/Users/me/Music/S&G/Bookends/09.flac", album: "Bookends", artist: "S&G", n: 9, title: "Punky's Dilemma", size: 500),
            t(8, "/Volumes/music/S&G/Bookends (1968)/09.flac", album: "Bookends", artist: "S&G", n: 9, title: "Punky's Dilemma", size: 499),
            // Missing numbers and a title that is a file name.
            t(9, "/m/Killers/Hot Fuss/01.flac", album: "Hot Fuss", artist: "The Killers", n: 0, title: "Jenny Was a Friend of Mine"),
            t(10, "/m/Killers/Hot Fuss/02.flac", album: "Hot Fuss", artist: "The Killers", n: 0, title: "The Killers - Hot Fuss - 02 - Mr. Brightside"),
            // Not a problem: two different albums sharing a folder.
            t(11, "/m/Weezer/Weezer (2019)/01.flac", album: "Weezer (Teal Album)", artist: "Weezer", n: 1, title: "Africa"),
            t(12, "/m/Weezer/Weezer (2019)/02.flac", album: "Weezer (Black Album)", artist: "Weezer", n: 1, title: "Can't Knock the Hustle"),
        ]
        let found = LibraryAudit.run(tracks)
        func has(_ kind: LibraryAudit.Finding.Kind, _ album: String) -> Bool { found.contains { $0.kind == kind && $0.albums.contains { $0.contains(album) } } }
        #expect(has(.splitAlbum, "Slim Shady"))
        #expect(has(.splitAlbum, "Elton John (Deluxe Edition) [CD-01]"))
        #expect(has(.mergedEditions, "High Voltage"))
        #expect(has(.duplicateFiles, "Bookends"))
        #expect(has(.missingNumbers, "Hot Fuss"))
        #expect(has(.fileNameTitles, "Hot Fuss"))
        #expect(!found.contains { $0.albums.contains { $0.contains("Weezer") } }, "different albums in one folder are fine")
        #expect(!has(.mergedEditions, "Bookends"), "a copy isn't a second edition")
    }
}
