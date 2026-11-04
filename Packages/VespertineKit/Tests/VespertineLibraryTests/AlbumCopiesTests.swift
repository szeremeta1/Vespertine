//
// Vespertine — an album's copies (folders, formats, layouts) and its songs across them, on libraries shaped like
// real ones: a download beside a vinyl transfer and an Atmos mix, a WAV import beside the FLAC on a share, a one-disc
// CD beside a two-disc SACD whose numbers differ, a super deluxe box beside its Blu-ray mixes.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineLibrary

@Suite("Album copies")
struct AlbumCopiesTests {
    private func track(_ folder: String, _ file: String, title: String, n: Int?, disc: Int? = 1, seconds: Double,
                       codec: String = "FLAC", rate: Double = 96_000, bits: Int? = 24, channels: Int = 2,
                       album: String = "Album", artist: String = "Artist", isrc: String? = nil) -> Track {
        var t = Track.stub(path: "\(folder)/\(file)")
        t.id = Self.id(for: t.location)
        t.album = album; t.albumArtist = artist; t.title = title; t.trackNumber = n; t.discNumber = disc
        t.duration = seconds; t.codec = codec; t.sampleRate = rate; t.bitDepth = bits; t.channels = channels; t.isrc = isrc
        if codec == "DSF" { t.isDSD = true; t.bitDepth = nil }
        if codec == "Dolby Atmos" { t.isLossless = false; t.bitDepth = nil; t.bitrate = 768 }
        return t
    }

    private static func id(for location: String) -> Int64 { Int64(abs(location.hashValue) % 1_000_000_000) }

    // MARK: Coldplay: a 24/192 download, a 24/96 vinyl transfer and a Dolby Atmos mix, all tagged the same

    private let rushTitles: [(String, Double)] = [("Politik", 318), ("In My Place", 228.5), ("God Put a Smile upon Your Face", 296.5),
                                                  ("The Scientist", 309), ("Clocks", 307), ("Daylight", 327), ("Green Eyes", 222),
                                                  ("Warning Sign", 331), ("A Whisper", 238), ("A Rush of Blood to the Head", 351),
                                                  ("Amsterdam", 319)]

    private func rush() -> [Track] {
        let base = "/Volumes/music/Coldplay/A Rush of Blood to the Head (2002)"
        let vinyl = "/Volumes/music/Coldplay/A Rush of Blood to the Head (2002) [Vinyl Transfer 24-96 - Dr. Robert]"
        let atmos = "/Volumes/music/_Spatial Extras/Coldplay/A Rush of Blood to the Head (2002) [Dolby Atmos]"
        return rushTitles.enumerated().flatMap { i, s -> [Track] in
            [track(vinyl, "\(i + 1).flac", title: i == 2 ? "God Put a Smile Upon Your Face" : s.0, n: i + 1, seconds: s.1 - 0.4,
                   isrc: "GBAYE02007\(i)"),
             track(base, "\(i + 1).flac", title: s.0, n: i + 1, seconds: s.1, rate: 192_000),
             track(atmos, "\(i + 1).m4a", title: s.0, n: i + 1, seconds: s.1, codec: "Dolby Atmos", rate: 48_000, channels: 6)]
        }
    }

    @Test("Three copies of one album are three copies, each whole, and every song has all three")
    func coldplay() throws {
        let copies = LibraryCopies.analyze(rush())
        #expect(copies.copies.count == 3)
        #expect(copies.songs.count == 11)
        #expect(copies.songs.allSatisfy { $0.tracks.count == 3 && Set($0.copyIDs).count == 3 })
        #expect(copies.copies.allSatisfy { $0.isComplete && $0.tracks.count == 11 })
        #expect(copies.copies[0].format == "FLAC · 24/192", "the best stereo copy leads")
        let vinyl = try #require(copies.copies.first { $0.edition == "Vinyl Transfer 24-96 - Dr. Robert" })
        #expect(vinyl.format == "FLAC · 24/96" && vinyl.layout == .stereo)
        let atmos = try #require(copies.copies.first { $0.layout == .atmos })
        #expect(atmos.summary.hasPrefix("Dolby Atmos"))
        // Every copy reads differently.
        let labels = copies.labels()
        #expect(Set(labels.values).count == 3)
        // Unchosen: the best copy for the output; a stereo output never gets the Atmos copy, a surround one does.
        #expect(copies.bestCopy(multichannel: false)?.format == "FLAC · 24/192")
        #expect(copies.bestCopy(multichannel: true)?.layout == .atmos)
        #expect(copies.selected(.copy(vinyl.id), multichannel: true)?.id == vinyl.id, "a chosen copy plays on any output")
        #expect(copies.selected(.bundled, multichannel: true) == nil)
        #expect(copies.selected(.copy("gone"), multichannel: false)?.format == "FLAC · 24/192", "a copy since removed: the best")
    }

    // MARK: Wilbur Soot / Sparky Deathcap: an imported WAV beside the share's FLAC; some songs only in one

    @Test("A WAV import and the share's FLAC are two copies, told apart by format, and a partial copy says so")
    func importedWAVAndShareFLAC() throws {
        let wav = "/Users/me/Music/Vespertine/Sparky Deathcap/Tear Jerky EP"
        let flac = "/Volumes/music/Sparky Deathcap/Tear Jerky (2009)"
        let songs: [(String, Double)] = [("Glasgow Is a Punk Rock Town", 125.1), ("Winter City Ghosts", 239.5), ("September", 190),
                                         ("Berlin Syndrome", 335.5), ("Send It to Oslo", 182)]
        var tracks = songs.enumerated().map { track(flac, "\($0.offset + 1).flac", title: $0.element.0, n: $0.offset + 1, seconds: $0.element.1, rate: 44_100) }
        tracks += [1, 2, 3].map { track(wav, "\($0 + 1).wav", title: songs[$0].0, n: $0 + 1, seconds: songs[$0].1, codec: "WAV", rate: 44_100) }
        let copies = LibraryCopies.analyze(tracks)
        #expect(copies.copies.count == 2)
        #expect(copies.songs.count == 5)
        #expect(copies.songs.map(\.tracks.count) == [1, 2, 2, 2, 1])
        let wavCopy = try #require(copies.copies.first { $0.format.hasPrefix("WAV") })
        #expect(wavCopy.songCount == 3 && wavCopy.albumSongCount == 5 && !wavCopy.isComplete)
        let labels = copies.labels()
        #expect(labels[wavCopy.id] == "Stereo · WAV · 24/44.1")
        #expect(copies.bestCopy(multichannel: false)?.format == "FLAC · 24/44.1", "the whole album, not the three-song copy")
        // Curly and straight apostrophes are one title.
        #expect(LibraryCopies.match(track(wav, "x.wav", title: "It's All Futile! It's All Pointless!", n: 4, seconds: 236.5),
                                    track(flac, "x.flac", title: "It’s All Futile! It’s All Pointless!", n: 4, seconds: 236.5)) > 0)
    }

    @Test("A WAV and a FLAC of each song in one folder are two copies, not one album with every song twice")
    func twoFormatsInOneFolder() throws {
        let folder = "/Users/me/Music/Wilbur Soot/Maybe I Was Boring"
        let titles = ["Maybe I Was Boring", "For Memories", "White Wine in a Wetherspoons", "It's All Futile! It's All Pointless!"]
        let tracks = titles.enumerated().flatMap { i, title in
            [track(folder, "\(i + 1).wav", title: title, n: i + 1, seconds: 200, codec: "WAV", rate: 48_000),
             track(folder, "\(i + 1).flac", title: title, n: i + 1, seconds: 200, rate: 48_000)]
        }
        let copies = LibraryCopies.analyze(tracks)
        #expect(copies.copies.count == 2 && copies.copies.allSatisfy { $0.tracks.count == 4 })
        #expect(Set(copies.copies.map(\.format)) == ["WAV · 24/48", "FLAC · 24/48"])
        #expect(copies.songs.count == 4 && copies.songs.allSatisfy { $0.tracks.count == 2 })
        #expect(Set(copies.labels().values).count == 2)
    }

    @Test("The same file twice in one folder: a second copy, not a song listed twice in one")
    func duplicateFiles() throws {
        let folder = "/m/Artist/Album"
        let tracks = [track(folder, "01.flac", title: "One", n: 1, seconds: 100), track(folder, "02.flac", title: "Two", n: 2, seconds: 100),
                      track(folder, "01 (1).flac", title: "One", n: 1, seconds: 100)]
        let copies = LibraryCopies.analyze(tracks)
        #expect(copies.copies.count == 2)
        #expect(copies.copies.map(\.tracks.count) == [2, 1])
        #expect(copies.songs.count == 2 && copies.songs[0].tracks.count == 2)
    }

    // MARK: Goodbye Yellow Brick Road: a one-disc MFSL CD, a two-disc SACD stereo layer, a part 5.1 layer

    @Test("A one-disc CD and a two-disc SACD pair up song by song, not by number")
    func discNumberingDiffers() throws {
        let cd = "/Volumes/music/Elton John/Goodbye Yellow Brick Road (1973) [1993 MFSL UDCD 526 Stereo 16-44.1]"
        let sacd = "/Volumes/music/_Spatial Extras/Elton John/Goodbye Yellow Brick Road (1973) [SACD DSD64 Stereo + 5.1 - 2003]"
        let songs: [(String, Double)] = [("Funeral for a Friend / Love Lies Bleeding", 670.5), ("Candle in the Wind", 229.8),
                                         ("Bennie and the Jets", 324.6), ("Goodbye Yellow Brick Road", 193.9), ("This Song Has No Title", 144.2),
                                         ("Grey Seal", 241.6), ("Jamaica Jerk-Off", 219.8), ("I've Seen That Movie Too", 359.5),
                                         ("Sweet Painted Lady", 237.3), ("The Ballad of Danny Bailey (1909-34)", 264.8),
                                         ("Dirty Little Girl", 302.1), ("All the Girls Love Alice", 310.5),
                                         ("Your Sister Can't Twist (But She Can Rock 'n' Roll)", 162), ("Saturday Night's Alright for Fighting", 296.9),
                                         ("Roy Rogers", 248.9), ("Social Disease", 224), ("Harmony", 169.5)]
        var tracks: [Track] = []
        for (i, s) in songs.enumerated() {
            // The CD's tags: other capitals and punctuation, lengths a few seconds off.
            let cdTitle = i == 6 ? "Jamaica Jerk Off" : i == 9 ? "The Ballad Of Danny Bailey (1909–34)" : s.0.capitalized
            tracks.append(track(cd, "\(i + 1).flac", title: cdTitle, n: i + 1, seconds: s.1 + (i == 14 ? -4.3 : 0.4), rate: 44_100, bits: 16,
                                album: "Goodbye Yellow Brick Road", artist: "Elton John"))
            let (disc, n) = i < 8 ? (1, i + 1) : (2, i - 7)
            tracks.append(track(sacd + "/Stereo", "\(disc)-\(n).dsf", title: s.0, n: n, disc: disc, seconds: s.1, codec: "DSF", rate: 2_822_400,
                                album: "Goodbye Yellow Brick Road", artist: "Elton John"))
            if i < 8 {
                tracks.append(track(sacd + "/Multichannel 5.1", "\(disc)-\(n).dsf", title: s.0, n: n, disc: disc, seconds: s.1 - 2,
                                    codec: "DSF", rate: 2_822_400, channels: 6, album: "Goodbye Yellow Brick Road", artist: "Elton John"))
            }
        }
        // SACD bonus songs, only on its stereo disc 2.
        for (j, s) in [("Whenever You're Ready (We'll Go Steady)", 172.3), ("Jack Rabbit", 111), ("Candle in the Wind (acoustic mix)", 233.5)].enumerated() {
            tracks.append(track(sacd + "/Stereo", "2-\(10 + j).dsf", title: s.0, n: 10 + j, disc: 2, seconds: s.1, codec: "DSF", rate: 2_822_400,
                                album: "Goodbye Yellow Brick Road", artist: "Elton John"))
        }
        let copies = LibraryCopies.analyze(tracks)
        #expect(copies.copies.count == 3)
        #expect(copies.songs.count == 20, "17 songs + 3 bonus, not 31 rows")
        #expect(copies.copies[0].format == "DSD64" && copies.copies[0].tracks.count == 20)
        #expect(copies.copies.allSatisfy { $0.folder == sacd || $0.folder == cd }, "Stereo and Multichannel 5.1 are layers of one album folder")
        let cdCopy = try #require(copies.copies.first { $0.format == "FLAC · 16/44.1" })
        #expect(cdCopy.edition == "1993 MFSL UDCD 526 Stereo 16-44.1")
        #expect(cdCopy.songCount == 17, "\(copies.songs.filter { $0.tracks.count == 1 }.map(\.lead.title))")
        let surround = try #require(copies.copies.first { $0.layout == .surround(channels: 6) })
        #expect(surround.songCount == 8 && !surround.isComplete)
        // Every CD song found its SACD song (disc 2's numbers start again at 1).
        for t in cdCopy.tracks { #expect(copies.song(of: t)?.tracks.count ?? 0 >= 2, "\(t.title)") }
        #expect(copies.songs.first { $0.lead.title == "Candle in the Wind (acoustic mix)" }?.tracks.count == 1, "the acoustic mix is its own song")
        // The 5.1 layer has 8 of 20 songs: even a surround output starts on a copy with the whole album.
        #expect(copies.bestCopy(multichannel: true)?.format == "DSD64" && copies.bestCopy(multichannel: true)?.layout == .stereo)
        // And the songs list in album order: disc 1, then disc 2 with its bonus songs.
        #expect(copies.songs.prefix(8).allSatisfy { $0.lead.discNumber == 1 })
        #expect(copies.songs.last?.lead.title == "Candle in the Wind (acoustic mix)")
    }

    // MARK: Let It Be (Super Deluxe): five Digital Media folders, a Blu-ray stereo, 5.1 and Atmos 7.1 bed of disc 1

    @Test("A box set's disc folders are one copy; its Blu-ray mixes match disc 1 by title, mixes of the same song stay apart")
    func superDeluxe() throws {
        let box = "/Volumes/music/The Beatles/Let It Be (1970)"
        let blu = "/Volumes/music/_High-Resolution Extras/The Beatles/Let It Be (1970) [Blu-ray PCM Stereo 24-96 - 2021]"
        let five = "/Volumes/music/_Spatial Extras/The Beatles/Let It Be (1970) [Spatial FLAC 5.1 24-96 - 2021]/Multichannel 5.1"
        let seven = "/Volumes/music/_Spatial Extras/The Beatles/Let It Be (1970) [Dolby Atmos 7.1 bed FLAC 24-48 - 2021]/Multichannel 7.1"
        let album = "Let It Be (Super Deluxe)", artist = "The Beatles"
        let disc1: [(String, Double)] = [("Two of Us", 216.5), ("Dig a Pony", 234), ("Across the Universe", 228), ("I Me Mine", 145),
                                         ("Dig It", 50), ("Let It Be", 243), ("Maggie Mae", 40), ("I've Got a Feeling", 217),
                                         ("One After 909", 174), ("The Long and Winding Road", 217), ("For You Blue", 152), ("Get Back", 188)]
        var tracks: [Track] = []
        for (i, s) in disc1.enumerated() {
            tracks.append(track(box + "/Digital Media 01", "\(i + 1).flac", title: "\(s.0) (2021 mix)", n: i + 1, disc: 1, seconds: s.1, album: album, artist: artist))
            tracks.append(track(blu, "\(i + 1).flac", title: s.0, n: i + 1, disc: 1, seconds: s.1 + 0.3, album: album, artist: artist))
            tracks.append(track(five, "\(i + 1).flac", title: "\(s.0) (5.1 mix)", n: i + 1, disc: 1, seconds: s.1, channels: 6, album: album, artist: artist))
            tracks.append(track(seven, "\(i + 1).flac", title: "\(s.0) (Atmos 7.1 mix)", n: i + 1, disc: 1, seconds: s.1, rate: 48_000, channels: 8,
                                album: album, artist: artist))
        }
        // Disc 2 outtakes and disc 4's 1969 mix: same song names, other recordings.
        tracks.append(track(box + "/Digital Media 02", "1.flac", title: "Morning Camera / Two of Us (take 4)", n: 1, disc: 2, seconds: 222, album: album, artist: artist))
        tracks.append(track(box + "/Digital Media 02", "5.flac", title: "For You Blue (take 4)", n: 5, disc: 2, seconds: 172, album: album, artist: artist))
        tracks.append(track(box + "/Digital Media 04", "1.flac", title: "One After 909 (1969 Glyn Johns mix)", n: 1, disc: 4, seconds: 174.5, album: album, artist: artist))
        for n in 1...10 {
            tracks.append(track(box + "/Digital Media 03", "\(n).flac", title: "Rehearsal \(n)", n: n, disc: 3, seconds: 100, album: album, artist: artist))
        }
        let copies = LibraryCopies.analyze(tracks)
        #expect(copies.copies.count == 4)
        #expect(copies.copies[0].folder == box && copies.copies[0].tracks.count == 25, "the disc folders, one copy")
        #expect(copies.songs.count == 25)
        for song in copies.songs where song.lead.discNumber == 1 { #expect(song.tracks.count == 4, "\(song.lead.title)") }
        let glynJohns = try #require(copies.songs.first { $0.lead.title.contains("Glyn Johns") })
        #expect(glynJohns.tracks.count == 1, "the 1969 mix is not the 2021 mix's copy")
        #expect(Set(copies.copies.map(\.layout)) == [.stereo, .surround(channels: 6), .surround(channels: 8)])
        #expect(copies.copies.first { $0.layout == .surround(channels: 8) }?.edition == "Dolby Atmos 7.1 bed FLAC 24-48 - 2021")
        // The two stereo copies read apart: one is the box, one the Blu-ray.
        let labels = copies.labels()
        #expect(Set(labels.values).count == 4)
        #expect(copies.bestCopy(multichannel: false)?.folder == box)
        #expect(copies.bestCopy(multichannel: true)?.folder == box, "the 5.1 copy has 12 of 25 songs: still the whole box first")
    }

    // MARK: SACD image areas, tagged ids, and things that must stay apart

    @Test("Tagged MusicBrainz recordings and ISRCs pair songs whatever their titles; live and single edits stay apart")
    func identifiers() throws {
        var a = track("/m/A/Album", "1.flac", title: "Song", n: 1, seconds: 200)
        var b = track("/m/A/Album [Japan]", "1.flac", title: "Sōngu (Japanese title)", n: 7, seconds: 260)
        a.musicBrainzRecordingID = "abc"; b.musicBrainzRecordingID = "abc"
        #expect(LibraryCopies.match(a, b) >= 1_000)
        b.musicBrainzRecordingID = nil; b.isrc = "usabc"; a.isrc = "USABC"
        #expect(LibraryCopies.match(a, b) >= 900)
        let live = track("/m/A/Album [Live]", "1.flac", title: "Song (Live)", n: 1, seconds: 200)
        #expect(LibraryCopies.match(a, live) == 0)
        let edit = track("/m/A/Single", "1.flac", title: "Song", n: 1, seconds: 150)
        #expect(LibraryCopies.match(a, edit) == 0, "the same title 50 s shorter is the single edit")
        // Same place and length, titles that start alike: one song under two names, unless the longer one names another recording.
        let a2 = track("/m/A/Album [SACD]", "1.dsf", title: "Dance (Pt. 1)", n: 1, seconds: 263.2)
        #expect(LibraryCopies.match(track("/m/A/Album", "1.flac", title: "Dance", n: 1, seconds: 262.2), a2) > 0)
        #expect(LibraryCopies.match(track("/m/A/Album", "1.flac", title: "Shine On You Crazy Diamond, Parts 1–5", n: 1, seconds: 810.3),
                                    track("/m/A/Album [SACD]", "1.dsf", title: "Shine On You Crazy Diamond (Parts I - V)", n: 1, seconds: 810.7)) > 0)
        #expect(LibraryCopies.match(track("/m/A/Album", "1.flac", title: "Dance", n: 1, seconds: 262.2),
                                    track("/m/A/Album [x]", "1.flac", title: "Dance (Demo)", n: 1, seconds: 262.2)) == 0)
        #expect(LibraryCopies.looseTitle("Time (2011 Remaster)") == "time")
        #expect(LibraryCopies.looseTitle("Here Comes the Sun - 2019 Mix") == "herecomesthesun")
        #expect(LibraryCopies.looseTitle("Candle in the Wind (acoustic mix)") != "candleinthewind")
        #expect(LibraryCopies.looseTitle("Let It Be (Naked Version)") != "letitbe")
    }

    @Test("Untagged files of one folder are one copy, and a large unknown album is quick")
    func largeUntagged() throws {
        let tracks = (1...3000).map { i in
            track("/m/Unknown/\(i % 3)", "\(i).mp3", title: "Track \(i)", n: nil, disc: nil, seconds: Double(100 + i % 50))
        }
        let start = Date()
        let copies = LibraryCopies.analyze(tracks)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(copies.copies.count == 3 && copies.songs.count == 3000)
    }

    @Test("The edition in a folder name, not a year or a disc")
    func editionNames() throws {
        #expect(LibraryCopies.edition(folder: "/m/Coldplay/A Rush of Blood to the Head (2002)") == nil)
        #expect(LibraryCopies.edition(folder: "/m/X/Album (2002) [Dolby Atmos]") == "Dolby Atmos")
        #expect(LibraryCopies.edition(folder: "/m/X/Album (Deluxe Edition)") == "Deluxe Edition")
        #expect(LibraryCopies.edition(folder: "/m/X/Album [CD 2]") == nil)
        #expect(LibraryCopies.edition(folder: "/m/X/Album (2003) [SACD].iso") == "SACD")
    }

    @Test("TrackVersions groups through the copies: the CD and two-disc SACD case no longer interleaves rows")
    func trackVersionsUsesCopies() throws {
        let cd = "/m/E/GYBR [CD]", sacd = "/m/E/GYBR [SACD]"
        let tracks = [track(cd, "9.flac", title: "Sweet Painted Lady", n: 9, seconds: 234.4, rate: 44_100, bits: 16),
                      track(sacd + "/Stereo", "2-1.dsf", title: "Sweet Painted Lady", n: 1, disc: 2, seconds: 237.3, codec: "DSF", rate: 2_822_400),
                      track(cd, "1.flac", title: "Funeral for a Friend", n: 1, seconds: 670.9, rate: 44_100, bits: 16),
                      track(sacd + "/Stereo", "1-1.dsf", title: "Funeral for a Friend", n: 1, disc: 1, seconds: 670.5, codec: "DSF", rate: 2_822_400)]
        let songs = TrackVersions.group(tracks)
        #expect(songs.count == 2 && songs.allSatisfy { $0.count == 2 })
    }
}
