//
// Vespertine — filters for every list: facets, chips, counts, and the album facts read from the database.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
@testable import VespertineLibrary

@Suite("Library filters")
struct LibraryFilterTests {
    private func track(_ path: String, codec: String = "FLAC", rate: Double = 96_000, bits: Int? = 24, channels: Int = 2,
                       lossless: Bool = true, dsd: Bool = false, genre: String? = nil, year: Int? = nil,
                       album: String = "A", artist: String = "Artist", number: Int? = nil, verdict: String? = nil) -> Track {
        var t = Track.stub(path: path)
        t.codec = codec; t.sampleRate = rate; t.bitDepth = bits; t.channels = channels; t.isLossless = lossless; t.isDSD = dsd
        t.genre = genre; t.year = year; t.album = album; t.albumArtist = artist; t.trackNumber = number; t.analysisVerdict = verdict
        return t
    }

    @Test("Codecs map to the formats people pick")
    func formatKinds() {
        #expect(FormatKind.of(codec: "FLAC", lossless: true, dsd: false) == .flac)
        #expect(FormatKind.of(codec: "DSF", lossless: true, dsd: true) == .dsd)
        #expect(FormatKind.of(codec: "DSDIFF", lossless: true, dsd: true) == .dsd)
        #expect(FormatKind.of(codec: "Dolby Atmos (TrueHD)", lossless: true, dsd: false) == .dolby)
        #expect(FormatKind.of(codec: "DTS-HD Master Audio", lossless: true, dsd: false) == .dts)
        #expect(FormatKind.of(codec: "DTS", lossless: false, dsd: false) == .dts)
        #expect(FormatKind.of(codec: "TTA", lossless: true, dsd: false) == .otherLossless)
        #expect(FormatKind.of(codec: "Vorbis", lossless: false, dsd: false) == .otherLossy)
    }

    @Test("Choices in one facet widen the match; facets and chips narrow it")
    func orWithinAndAcross() {
        let jazz24 = FilterFacts(track: track("/m/1.flac", genre: "Jazz", year: 1959))
        let blues16 = FilterFacts(track: track("/m/2.flac", rate: 44_100, bits: 16, genre: "Blues", year: 1962))
        let rock5_1 = FilterFacts(track: track("/m/3.flac", channels: 6, genre: "Rock; Blues", year: 1973))
        var f = LibraryFilter()
        #expect(f.isEmpty && f.matches(jazz24))

        f[.genre] = [Genres.key("jazz"), Genres.key("BLUES")]
        #expect(f.matches(jazz24) && f.matches(blues16) && f.matches(rock5_1), "multi-genre tags count under each")
        f[.decade] = ["1950"]
        #expect(f.matches(jazz24) && !f.matches(blues16))
        f[.decade] = []
        f.toggle(.bits24)
        #expect(f.matches(jazz24) && !f.matches(blues16) && f.matches(rock5_1))
        f.toggle(.multichannel)
        #expect(!f.matches(jazz24) && f.matches(rock5_1))
        f.toggle(.favorite)
        #expect(!f.matches(rock5_1, favorite: false) && f.matches(rock5_1, favorite: true))
        #expect(f.matches(rock5_1, favorite: true, ignoring: [.genre]))
    }

    @Test("DSD counts as 24-bit and as 88.2 kHz and up; lossy files have no bit depth")
    func flagsAndDSD() {
        let dsd = FilterFacts(track: track("/m/a.dsf", codec: "DSF", rate: 2_822_400, bits: nil, dsd: true))
        let mp3 = FilterFacts(track: track("/m/b.mp3", codec: "MP3", rate: 44_100, bits: nil, lossless: false))
        #expect(dsd.has(.bits24, favorite: false) && dsd.has(.rate88, favorite: false))
        #expect(dsd.bitDepths == [1] && dsd.verdicts.isEmpty)
        #expect(mp3.bitDepths.isEmpty && mp3.verdicts.isEmpty, "no 'not analyzed' for files analysis never looks at")
        #expect(Facet.sampleRate.name(of: "2822400") == "DSD64")
        #expect(Facet.sampleRate.name(of: "88200") == "88.2 kHz")
        #expect(Facet.bitDepth.name(of: "1") == "1-bit (DSD)")
        #expect(Facet.channels.name(of: "6") == "5.1")
        #expect(Facet.analysis.name(of: "none") == "Not analyzed")
    }

    @Test("Counts per value keep the other facets and never their own")
    func facetCounts() {
        let items = [
            FilterFacts(track: track("/m/1.flac", rate: 96_000, genre: "Jazz")),
            FilterFacts(track: track("/m/2.flac", rate: 44_100, bits: 16, genre: "Jazz")),
            FilterFacts(track: track("/m/3.flac", rate: 192_000, genre: "Rock")),
        ]
        var f = LibraryFilter()
        f[.sampleRate] = ["96000"]
        f[.genre] = [Genres.key("Jazz")]
        #expect(f.counts(of: .sampleRate, in: items) == ["96000": 1, "44100": 1], "Rock's 192 kHz is out because of the genre")
        #expect(f.counts(of: .genre, in: items) == [Genres.key("Jazz"): 1], "only the 96 kHz songs count for genres")
        #expect(f.values(of: .sampleRate, in: items) == ["44100", "96000", "192000"])
        #expect(Facet.decade.sorted(["1960", "2010", "1970"]) == ["2010", "1970", "1960"])
    }

    @Test("Songs without a genre or year of their own take their album's")
    func albumFallbacks() {
        let t = track("/m/1.flac", genre: nil, year: nil)
        let album = Album(key: t.albumKey, title: "A", artist: "Artist", year: 1977, genre: "Soul", trackCount: 1, duration: 1,
                          artworkKey: nil, formatSummary: "", codec: "FLAC", maxBitDepth: 24, maxSampleRate: 96_000, isHiRes: true,
                          isDSD: false, addedAt: .now, totalSize: 0, sourcePath: nil)
        let facts = FilterFacts.of([t], albums: [t.albumKey: album])[0]
        #expect(facts.genres == [Genres.key("Soul")] && facts.decade == 1970)
    }

    @Test("Albums carry every format, rate, depth, layout, verdict and source of their tracks")
    func albumFactsFromDatabase() throws {
        let db = try LibraryDatabase.inMemory()
        let local = try db.addSource(LibrarySource(path: "/m", mode: .reference))
        let share = try db.addSource(LibrarySource(path: "/Volumes/music", mode: .reference))
        var tracks = [
            track("/m/DSOTM/1.flac", rate: 96_000, bits: 24, genre: "Rock", year: 1973, album: "DSOTM", artist: "Pink Floyd", number: 1, verdict: "genuine"),
            track("/m/DSOTM/2.flac", rate: 44_100, bits: 16, genre: "Rock", year: 1973, album: "DSOTM", artist: "Pink Floyd", number: 2),
            track("/Volumes/music/DSOTM/1.dsf", codec: "DSF", rate: 2_822_400, bits: nil, channels: 6, dsd: true, genre: "Progressive Rock",
                  year: 1973, album: "DSOTM", artist: "Pink Floyd", number: 1),
            track("/m/Other/1.mp3", codec: "MP3", rate: 44_100, bits: nil, lossless: false, album: "Other", artist: "Someone"),
        ]
        for i in tracks.indices { tracks[i].sourceId = tracks[i].filePath.hasPrefix("/m/") ? local.id : share.id }
        try db.writer.write { db in for var t in tracks { try t.insert(db) } }

        let albums = try db.albums()
        let dsotm = try #require(albums.first { $0.title == "DSOTM" })
        #expect(dsotm.facts.formats == [.flac, .dsd])
        #expect(dsotm.facts.sampleRates == [96_000, 44_100, 2_822_400])
        #expect(dsotm.facts.bitDepths == [24, 16, 1])
        #expect(dsotm.facts.channels == [2, 6])
        #expect(dsotm.facts.verdicts == ["genuine", "none"])
        #expect(dsotm.facts.sources == Set([local.id, share.id].compactMap { $0 }))
        #expect(dsotm.facts.genres == [Genres.key("Rock"), Genres.key("Progressive Rock")])
        #expect(dsotm.facts.decade == 1970 && dsotm.facts.artist == "pink floyd")
        let other = try #require(albums.first { $0.title == "Other" })
        #expect(other.facts.formats == [.mp3] && other.facts.verdicts.isEmpty && other.facts.bitDepths.isEmpty)

        var f = LibraryFilter()
        f[.format] = [FormatKind.dsd.rawValue]
        #expect(albums.filter { f.matches($0.facts) }.map(\.title) == ["DSOTM"])
    }

    @Test("A filter survives being saved, and what a later version adds is skipped")
    func savedFilters() throws {
        var f = LibraryFilter()
        f[.genre] = [Genres.key("Jazz"), Genres.key("Soul")]
        f[.sampleRate] = ["96000"]
        f.toggle(.bits24)
        f.toggle(.favorite)
        let data = try JSONEncoder().encode(f)
        #expect(try JSONDecoder().decode(LibraryFilter.self, from: data) == f)
        let later = #"{"facets": {"genre": ["jazz"], "mood": ["calm"]}, "flags": ["bits24", "loud"]}"#
        let read = try JSONDecoder().decode(LibraryFilter.self, from: Data(later.utf8))
        #expect(read[.genre] == ["jazz"] && read.flags == [.bits24] && read.activeFacets == [.genre])
        #expect(try JSONDecoder().decode(LibraryFilter.self, from: Data("{}".utf8)).isEmpty)
    }

    @Test("Tracks of several albums come album after album, each in its own order")
    func tracksOfAlbums() throws {
        let db = try LibraryDatabase.inMemory()
        let source = try db.addSource(LibrarySource(path: "/m", mode: .reference))
        var tracks = [
            track("/m/B/2.flac", album: "B", number: 2), track("/m/A/1.flac", album: "A", number: 1),
            track("/m/B/1.flac", album: "B", number: 1), track("/m/A/2.flac", album: "A", number: 2),
        ]
        for i in tracks.indices { tracks[i].sourceId = source.id }
        try db.writer.write { db in for var t in tracks { try t.insert(db) } }
        let keyA = tracks[1].albumKey, keyB = tracks[0].albumKey
        #expect(try db.tracks(albumKeys: [keyB, keyA, keyB]).map(\.filePath) == ["/m/B/1.flac", "/m/B/2.flac", "/m/A/1.flac", "/m/A/2.flac"])
        #expect(try db.tracks(albumKeys: []).isEmpty)
        #expect(try db.tracks(albumKeys: [keyA]) == db.tracks(albumKey: keyA))
    }
}
