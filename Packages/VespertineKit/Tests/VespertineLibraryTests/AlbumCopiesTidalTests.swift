//
// Vespertine: an album in the library and on TIDAL is one album in two copies; songs match across them by ISRC, then by title and length.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineLibrary

@Suite("Album copies: local and TIDAL")
struct AlbumCopiesTidalTests {
    private let titles: [(String, Double)] = [("Intro", 61), ("Wave One", 215), ("Wave Two", 242.5), ("Interlude", 98), ("Closer", 301)]

    private func local(_ i: Int, title: String? = nil, seconds: Double? = nil, isrc: String? = nil, rate: Double = 44_100, bits: Int? = 16) -> Track {
        var t = Track.stub(path: "/Music/Artist/Album/\(i + 1).flac")
        t.id = Int64(100 + i); t.sourceId = 1
        t.album = "Album"; t.albumArtist = "Artist"; t.title = title ?? titles[i].0; t.trackNumber = i + 1; t.discNumber = 1
        t.duration = seconds ?? titles[i].1; t.sampleRate = rate; t.bitDepth = bits; t.isrc = isrc
        return t
    }

    private func tidal(_ i: Int, title: String? = nil, seconds: Double? = nil, isrc: String? = nil, downloaded: String? = nil,
                       number: Int? = nil) -> Track {
        var t = Track.stub(path: "tidal://track/\(9000 + i)")
        t.filePath = downloaded ?? ""
        t.id = Int64(200 + i); t.sourceId = 2
        t.album = "Album"; t.albumArtist = "Artist"; t.title = title ?? titles[i].0; t.trackNumber = number ?? i + 1; t.discNumber = 1
        t.duration = seconds ?? titles[i].1; t.sampleRate = 96_000; t.bitDepth = 24; t.isrc = isrc
        return t
    }

    private func album(local l: [Track], tidal t: [Track]) -> AlbumCopies { LibraryCopies.analyze(l + t) }

    @Test("The same album key, local and on TIDAL: one album with two copies, the TIDAL one labelled TIDAL")
    func twoCopies() throws {
        let copies = album(local: titles.indices.map { local($0) }, tidal: titles.indices.map { tidal($0) })
        #expect(copies.copies.count == 2)
        let streamed = try #require(copies.copies.first { $0.isTidal })
        #expect(streamed.tracks.count == 5 && streamed.isComplete)
        #expect(copies.copies.filter { !$0.isTidal }.count == 1)
        #expect(copies.labels()[streamed.id] == "TIDAL")
        #expect(copies.songs.count == 5 && copies.songs.allSatisfy { $0.tracks.count == 2 })
    }

    @Test("A downloaded TIDAL song stays in the TIDAL copy, not in a copy of its download folder")
    func downloadedStaysInTidalCopy() throws {
        let streamedOnly = album(local: titles.indices.map { local($0) }, tidal: titles.indices.map { tidal($0) })
        let mixed = album(local: titles.indices.map { local($0) },
                          tidal: titles.indices.map { tidal($0, downloaded: $0 < 2 ? "/Music/TIDAL/Artist/Album/\($0 + 1).flac" : nil) })
        #expect(mixed.copies.count == 2)
        let before = try #require(streamedOnly.copies.first { $0.isTidal })
        let after = try #require(mixed.copies.first { $0.isTidal })
        #expect(after.id == before.id, "the copy's id doesn't change when a song is downloaded")
        #expect(after.tracks.count == 5)
    }

    @Test("Songs match by ISRC first, whatever their titles and lengths")
    func byISRC() throws {
        let l = [local(0, isrc: "GB0000000001"), local(1, isrc: "GB0000000002")]
        let t = [tidal(0, title: "Introduction (Remastered)", seconds: 70, isrc: "gb0000000001"), tidal(1, title: "Wave 1", seconds: 100, isrc: "GB0000000002")]
        let copies = album(local: l, tidal: t)
        #expect(copies.songs.count == 2 && copies.songs.allSatisfy { $0.tracks.count == 2 })
    }

    @Test("Without an ISRC, by title, with the lengths within 2 seconds")
    func byTitleAndDuration() throws {
        let close = album(local: [local(1)], tidal: [tidal(1, seconds: 215 + 1.9)])
        #expect(close.songs.count == 1 && close.songs[0].tracks.count == 2)
        let far = album(local: [local(1)], tidal: [tidal(1, seconds: 215 + 3)])
        #expect(far.songs.count == 2, "three seconds apart is another recording of that title")
        // Two files of the library alone keep the library's own, wider tolerance.
        var other = local(1); other.id = 300; other.location = "/Music/Artist/Album [Alt]/2.flac"; other.filePath = other.location; other.duration = 215 + 3
        let files = LibraryCopies.analyze([local(1), other])
        #expect(files.songs.count == 1 && files.songs[0].tracks.count == 2)
    }

    @Test("A different track count still groups: unmatched songs are songs of their own")
    func differentCounts() throws {
        let extra = [tidal(5, title: "Bonus A", seconds: 180, number: 6), tidal(6, title: "Bonus B", seconds: 190, number: 7)]
        let copies = album(local: Array(titles.indices.dropLast().map { local($0) }), tidal: titles.indices.map { tidal($0) } + extra)
        #expect(copies.copies.count == 2)
        let streamed = try #require(copies.copies.first { $0.isTidal })
        let files = try #require(copies.copies.first { !$0.isTidal })
        #expect(streamed.songCount == 7 && files.songCount == 4 && copies.songs.count == 7)
        #expect(!files.isComplete && streamed.isComplete)
    }

    @Test("A TIDAL copy with no local copy is just the album: one copy")
    func tidalAlone() {
        let copies = LibraryCopies.analyze(titles.indices.map { tidal($0) })
        #expect(copies.copies.count == 1 && copies.copies[0].isTidal)
    }

    @Test("The copy a listener chose persists, and is found again after a song is downloaded")
    func choicePersists() throws {
        let db = try LibraryDatabase.inMemory()
        let before = album(local: titles.indices.map { local($0) }, tidal: titles.indices.map { tidal($0) })
        let id = try #require(before.copies.first { $0.isTidal }).id
        try db.setCopyChoice(.copy(id), albumKey: local(0).albumKey)
        let stored = try #require(try db.copyChoices()[local(0).albumKey])
        #expect(stored == .copy(id))
        let after = album(local: titles.indices.map { local($0) },
                          tidal: titles.indices.map { tidal($0, downloaded: "/Music/TIDAL/\($0).flac") })
        #expect(after.selected(stored, multichannel: false)?.isTidal == true)
    }

    @Test("With no choice, a local file beats a stream TIDAL only lists as better; a downloaded copy is judged by its file")
    func automaticCopy() throws {
        let streamed = album(local: titles.indices.map { local($0) }, tidal: titles.indices.map { tidal($0) })
        #expect(streamed.bestCopy(multichannel: false)?.isTidal == false)
        let downloaded = album(local: titles.indices.map { local($0) }, tidal: titles.indices.map { tidal($0, downloaded: "/Music/TIDAL/\($0).flac") })
        #expect(downloaded.bestCopy(multichannel: false)?.isTidal == true, "24/96 on disk beats 16/44.1")
        // The same for one song across copies (bundled albums).
        let song = [local(1), tidal(1)]
        #expect(TrackVersions.choose(song, multichannel: false)?.isTidalTrack == false)
        #expect(TrackVersions.choose([local(1), tidal(1, downloaded: "/Music/TIDAL/1.flac")], multichannel: false)?.isTidalTrack == true)
    }
}
