//
// Vespertine: one song across the editions of an album (the stereo album and its Dolby Atmos edition).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineLibrary

@Suite("Song versions across editions")
struct SongVersionsTests {
    private func track(_ id: Int64, album: String, _ n: Int, _ title: String, channels: Int = 2, seconds: Double = 200, codec: String = "FLAC") -> Track {
        // Every track its own file: the same song twice on an album is in two folders, as copies are.
        var t = Track.stub(path: "/m/The Lanterns/\(album)/copy \(id) \(channels)ch/\(n) \(title).flac")
        t.id = id; t.album = album; t.albumArtist = "The Lanterns"; t.artist = "The Lanterns"
        t.trackNumber = n; t.discNumber = 1; t.title = title; t.channels = channels; t.duration = seconds; t.codec = codec
        return t
    }

    private func album(_ title: String, artist: String = "The Lanterns", channels: Int = 2) -> Album {
        var probe = Track.stub(path: "/m/x.flac")
        probe.album = title; probe.albumArtist = artist
        return Album(key: probe.albumKey, title: title, artist: artist, year: 2002, genre: nil, trackCount: 2, duration: 400,
                     artworkKey: nil, formatSummary: "FLAC", codec: "FLAC", maxBitDepth: 24, maxSampleRate: 96_000, isHiRes: true,
                     isDSD: false, addedAt: .now, totalSize: 1, sourcePath: nil, maxChannels: channels)
    }

    @Test("An album and its Dolby Atmos edition are editions of one album; another album and a compilation are not")
    func editions() {
        let albums = [album("Night Ferry"), album("Night Ferry (Dolby Atmos)", channels: 6), album("Low Tide"),
                      album("The Best of The Lanterns")]
        let editions = SongVersions.editions(albums)
        #expect(editions[albums[0].key] == [albums[0].key, albums[1].key])
        #expect(editions[albums[1].key] == [albums[0].key, albums[1].key])
        #expect(editions[albums[2].key] == nil && editions[albums[3].key] == nil)
    }

    @Test("A stereo song and its Dolby Atmos version on the album's Atmos edition are one song")
    func stereoAndAtmosAcrossEditions() {
        let stereo = [track(1, album: "Night Ferry", 1, "Harbour Lights"), track(2, album: "Night Ferry", 2, "Ninth Street", seconds: 240)]
        let atmos = [track(3, album: "Night Ferry (Dolby Atmos)", 1, "Harbour Lights", channels: 6, seconds: 201, codec: "Dolby Atmos"),
                     track(4, album: "Night Ferry (Dolby Atmos)", 2, "Ninth Street (Atmos Mix)", channels: 6, seconds: 243, codec: "Dolby Atmos")]
        let songs = SongVersions.group(stereo + atmos)
        #expect(songs.map { $0.compactMap(\.id) } == [[1, 3], [2, 4]])
        // The output picks: Atmos where it can be heard, the stereo file elsewhere.
        #expect(TrackVersions.choose(songs[0], multichannel: true)?.id == 3)
        #expect(TrackVersions.choose(songs[0], multichannel: false)?.id == 1)
    }

    @Test("Two stereo editions stay two songs unless an ID says they are one recording")
    func sameLayoutNeedsAnID() {
        let original = track(1, album: "Night Ferry", 1, "Harbour Lights")
        let remaster = track(2, album: "Night Ferry (2019 Remaster)", 1, "Harbour Lights")
        #expect(SongVersions.group([original, remaster]).count == 2, "a remaster may be another master: not merged on its title")

        var a = original, b = remaster
        a.isrc = "GBAYE0200001"; b.isrc = "gbaye0200001"
        #expect(SongVersions.group([a, b]).count == 1, "the same ISRC is the same recording")
        var c = original, d = remaster
        c.musicBrainzRecordingID = "5b11f4ce-a62d-471e-81fc-a69a8278c7da"; d.musicBrainzRecordingID = "5B11F4CE-A62D-471E-81FC-A69A8278C7DA"
        #expect(SongVersions.group([c, d]).count == 1, "the same MusicBrainz recording is the same recording")
    }

    @Test("A live take, a demo, a song of another length and a song only one edition has stay their own songs")
    func differentRecordingsStayApart() {
        let stereo = [track(1, album: "Night Ferry", 1, "Harbour Lights"), track(2, album: "Night Ferry", 2, "Ninth Street", seconds: 240),
                      track(3, album: "Night Ferry", 3, "Slow Tide", seconds: 180)]
        let atmos = [track(4, album: "Night Ferry (Dolby Atmos)", 1, "Harbour Lights (Live)", channels: 6),
                     track(5, album: "Night Ferry (Dolby Atmos)", 2, "Ninth Street", channels: 6, seconds: 320),
                     track(6, album: "Night Ferry (Dolby Atmos)", 3, "Slow Tide (Demo)", channels: 6, seconds: 180),
                     track(7, album: "Night Ferry (Dolby Atmos)", 4, "Lamplighter", channels: 6)]
        let songs = SongVersions.group(stereo + atmos)
        #expect(songs.count == 7, "none of these is the same recording as a stereo song")
        #expect(songs.allSatisfy { $0.count == 1 })
    }

    @Test("A song takes one song of each edition, and an edition's own stereo and 5.1 layers stay together")
    func oneSongPerEdition() {
        // The stereo album, an SACD edition with both layers, and an Atmos edition.
        let plain = track(1, album: "Night Ferry", 1, "Harbour Lights")
        let sacdStereo = track(2, album: "Night Ferry [SACD]", 1, "Harbour Lights")
        let sacdSurround = track(3, album: "Night Ferry [SACD]", 1, "Harbour Lights", channels: 6)
        let atmos = track(4, album: "Night Ferry (Dolby Atmos)", 1, "Harbour Lights", channels: 6, codec: "Dolby Atmos")
        let songs = SongVersions.group([plain, sacdStereo, sacdSurround, atmos])
        // The SACD's song has a stereo layer, as the plain album does, and no ID: it stays its own song, both layers
        // together. The Atmos version joins the first song it differs from in layout.
        #expect(songs.map { $0.compactMap(\.id) } == [[1, 4], [2, 3]])
    }

    @Test("Asked for a track, playback may pick it or its song's versions in the other layout, never another copy in its own")
    func followingOutput() {
        let vinyl = track(1, album: "Night Ferry", 1, "Harbour Lights"), download = track(2, album: "Night Ferry", 1, "Harbour Lights")
        let surround = track(3, album: "Night Ferry", 1, "Harbour Lights", channels: 6)
        let song = [download, vinyl, surround]
        #expect(SongVersions.followingOutput(vinyl, in: song).compactMap(\.id) == [1, 3])
        #expect(SongVersions.followingOutput(surround, in: song).compactMap(\.id) == [3, 2, 1])
        // On a stereo output the copy asked for plays as itself; on a surround one, the surround version.
        #expect(TrackVersions.choose(SongVersions.followingOutput(vinyl, in: song), multichannel: false)?.id == 1)
        #expect(TrackVersions.choose(SongVersions.followingOutput(vinyl, in: song), multichannel: true)?.id == 3)
    }

    @Test("Combined, a heart on the stereo song is a heart on its Atmos version on the other edition, and only while combined")
    func heartsAcrossEditions() throws {
        let db = try LibraryDatabase.inMemory()
        let source = try db.addSource(LibrarySource(path: "/m", mode: .reference))
        let tracks = [track(0, album: "Night Ferry", 1, "Harbour Lights"),
                      track(0, album: "Night Ferry (Dolby Atmos)", 1, "Harbour Lights", channels: 6, codec: "Dolby Atmos"),
                      track(0, album: "Night Ferry (2019 Remaster)", 1, "Harbour Lights"),
                      track(0, album: "Night Ferry", 2, "Ninth Street", seconds: 240)]
        let ids = try db.writer.write { db in
            try tracks.map { t -> Int64 in var t = t; t.id = nil; t.sourceId = source.id; try t.insert(db); return t.id! }
        }
        let date = Date(timeIntervalSince1970: 3_000_000)
        try db.setFavorite(true, trackIDs: [ids[0]], at: date)

        // Not combined: a favorite is the copy hearted.
        #expect(try db.favoriteEveryVersion() == 1)
        #expect(Set(try db.favoriteTracks().compactMap(\.id)) == [ids[0]])

        // Combined: the Atmos version is the same favorite, from the same day; the remaster (another stereo album) is not.
        #expect(try db.favoriteEveryVersion(combiningVersions: true) == 1, "one song, however many versions")
        #expect(Set(try db.favoriteTracks().compactMap(\.id)) == [ids[0], ids[1]])
        let dates = try db.writer.read { db in try Date.fetchAll(db, sql: "SELECT favoritedAt FROM favorite") }
        #expect(dates == [date, date])
        #expect(try db.favoriteEveryVersion(combiningVersions: true) == 1, "nothing more to add")
        #expect(try db.favoriteTracks().count == 2)

        // Switched off again: exactly the copy that was hearted is left.
        #expect(try db.favoriteEveryVersion() == 1)
        #expect(Set(try db.favoriteTracks().compactMap(\.id)) == [ids[0]], "the Atmos version's heart was only borrowed")

        // Unhearting the song takes the borrowed heart with it.
        try db.favoriteEveryVersion(combiningVersions: true)
        try db.setFavorite(false, trackIDs: [ids[0]])
        #expect(try db.favoriteEveryVersion(combiningVersions: true) == 0)
        #expect(try db.favoriteTracks().isEmpty)

        // Hearted in Atmos on the speakers: the stereo song is the favorite on headphones.
        try db.setFavorite(true, trackIDs: [ids[1]], at: date)
        #expect(try db.favoriteEveryVersion(combiningVersions: true) == 1)
        #expect(Set(try db.favoriteTracks().compactMap(\.id)) == [ids[0], ids[1]])
    }
}
