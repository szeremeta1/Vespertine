//
// Vespertine: reading a song file's tags and format through small ranged reads, against real files FFmpeg wrote
// (SongFixtures), and counting how much of each file had to be fetched.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineShare

/// Reads `data` as the tag reader reads a file on a share, and keeps count of what was asked for.
final class CountedFile: @unchecked Sendable {
    let data: Data
    private(set) var reads = 0
    private(set) var bytes = 0

    init(_ data: Data) { self.data = data }

    func tags(named name: String) throws -> SongTags? {
        try SongTagReader.read(name: name, size: Int64(data.count)) { offset, length in
            self.reads += 1
            let end = min(self.data.count, Int(offset) + length)
            self.bytes += end - Int(offset)
            return self.data.subdata(in: Int(offset)..<end)
        }
    }

    func picture(_ tags: SongTags) -> Data? {
        guard let offset = tags.pictureOffset, let length = tags.pictureLength else { return nil }
        return data.subdata(in: Int(offset)..<(Int(offset) + length))
    }
}

@Suite struct SongTagsTests {
    @Test func aFlacFileGivesItsTagsItsFormatAndItsCover() throws {
        let file = CountedFile(SongFixtures.flac2496)
        let tags = try #require(try file.tags(named: "02 Nocturne.FLAC"))
        #expect(tags.title == "Nocturne No. 2" && tags.artist == "Ilse Brandt" && tags.albumArtist == "Ilse Brandt Trio")
        #expect(tags.album == "Nocturnes for a Small Room" && tags.genre == "Classical")
        #expect(tags.track == 2 && tags.disc == 1 && tags.year == 2023)
        #expect(tags.codec == "FLAC" && tags.sampleRate == 96_000 && tags.bitDepth == 24 && tags.channels == 2 && tags.lossless)
        #expect(tags.frames == 1920 && abs(tags.duration - 0.02) < 1e-9)
        #expect(file.picture(tags) == SongFixtures.cover)
        #expect(ShareCatalog.format(tags) == "FLAC · 24/96")
    }

    @Test func aSurroundFlacFileSaysHowManyChannelsItHas() throws {
        let tags = try #require(try CountedFile(SongFixtures.surroundFlac).tags(named: "a.flac"))
        #expect(tags.channels == 6 && tags.sampleRate == 48_000 && tags.bitDepth == 16 && tags.title == "Allegro")
        #expect(tags.artist == nil && tags.album == nil && tags.pictureOffset == nil)
        #expect(ShareCatalog.format(tags) == "FLAC · 16/48 · 5.1")
    }

    @Test func anAppleLosslessFileGivesItsRealRateAndDepth() throws {
        // 192 kHz does not fit the MPEG-4 field for the rate (16 bits): the codec's own description has it.
        let tags = try #require(try CountedFile(SongFixtures.alac).tags(named: "x.m4a"))
        #expect(tags.codec == "ALAC" && tags.sampleRate == 192_000 && tags.bitDepth == 24 && tags.channels == 1)
        #expect(tags.title == "Aurora Line" && tags.artist == "Kestrel Park" && tags.albumArtist == "Kestrel Park" && tags.album == "Northern Signal")
        #expect(tags.track == 4 && tags.disc == 2 && tags.year == 2018 && tags.genre == "Electronic")
        #expect(abs(tags.duration - 0.02) < 1e-9 && tags.frames == 3840)
        #expect(ShareCatalog.format(tags) == "ALAC · 24/192")
    }

    @Test func anAacFileIsLossyAndHasItsCover() throws {
        let file = CountedFile(SongFixtures.aac)
        let tags = try #require(try file.tags(named: "x.m4a"))
        #expect(tags.codec == "AAC" && tags.sampleRate == 44_100 && tags.bitDepth == nil && !tags.lossless && tags.channels == 2)
        #expect(tags.title == "Coffee Rings" && tags.artist == "June Okafor" && tags.album == "Velvet Hours")
        #expect(tags.duration > 0.19 && tags.duration < 0.26)
        #expect(tags.bitRate != nil)
        #expect(file.picture(tags) == SongFixtures.cover)
    }

    @Test func anMp3WithAVersion3TagAndAConstantBitRate() throws {
        let tags = try #require(try CountedFile(SongFixtures.cbrMP3).tags(named: "x.mp3"))
        #expect(tags.codec == "MP3" && tags.sampleRate == 44_100 && tags.channels == 1 && tags.bitDepth == nil)
        #expect(tags.title == "Chrome Horses" && tags.artist == "Highway Saints" && tags.album == "Dust and Chrome")
        #expect(tags.track == 7 && tags.year == 2016 && tags.genre == "Rock")
        // FFmpeg's own answer for this file is 0.235 s.
        #expect(abs(tags.duration - 0.235) < 0.03)
        #expect(tags.bitRate.map { abs($0 - 128) < 20 } == true)
    }

    @Test func anMp3WithAVersion4TagInUnicodeAndAVariableBitRate() throws {
        let file = CountedFile(SongFixtures.vbrMP3)
        let tags = try #require(try file.tags(named: "x.mp3"))
        #expect(tags.title == "Ünïcödé Tïtle 夜" && tags.artist == "Mina Okonkwo" && tags.album == "Salt Flats")
        #expect(tags.sampleRate == 48_000 && tags.channels == 2)
        #expect(abs(tags.duration - 0.24) < 0.03)
        #expect(file.picture(tags) == SongFixtures.cover)
    }

    @Test func aWaveFileGivesItsFormatAndItsInfoTags() throws {
        let tags = try #require(try CountedFile(SongFixtures.wav).tags(named: "x.wav"))
        #expect(tags.codec == "WAV" && tags.sampleRate == 48_000 && tags.bitDepth == 24 && tags.channels == 1 && tags.frames == 960)
        #expect(tags.title == "Wave Title" && tags.artist == "Wave Artist" && tags.album == "Wave Album")
    }

    @Test func anAiffFileGivesItsFormatAndItsID3Tags() throws {
        let tags = try #require(try CountedFile(SongFixtures.aiff).tags(named: "x.aiff"))
        #expect(tags.codec == "AIFF" && tags.sampleRate == 44_100 && tags.bitDepth == 16 && tags.channels == 1 && tags.frames == 882)
        #expect(tags.title == "Aiff Title" && tags.artist == "Aiff Artist" && tags.album == "Aiff Album")
    }

    @Test func aFileThatIsNotWhatItsNameSaysIsNotASong() throws {
        #expect(try CountedFile(Data("junk\n".utf8)).tags(named: "broken.flac") == nil)
        #expect(try CountedFile(SongFixtures.flac2496).tags(named: "really-flac.m4a") == nil)
        #expect(try CountedFile(SongFixtures.wav).tags(named: "really-wav.mp3") == nil)
        #expect(try CountedFile(SongFixtures.flac2496).tags(named: "notes.txt") == nil)
        // Cut short anywhere, a file is either read as far as it goes or not a song: never a crash.
        for fixture in [SongFixtures.flac2496, SongFixtures.alac, SongFixtures.aac, SongFixtures.cbrMP3, SongFixtures.vbrMP3, SongFixtures.wav, SongFixtures.aiff] {
            for name in ["a.flac", "a.m4a", "a.mp3", "a.wav", "a.aiff"] {
                for length in stride(from: 0, to: fixture.count, by: 97) {
                    _ = try CountedFile(fixture.prefix(length)).tags(named: name)
                }
            }
        }
    }

    @Test func aLargeFileIsReadInAFewSmallPieces() throws {
        // The fixture's tags and cover, then 40 MB of sound the reader has no business fetching.
        var big = SongFixtures.flac2496
        big.append(Data(count: 40 << 20))
        let file = CountedFile(big)
        let tags = try #require(try file.tags(named: "a.flac"))
        #expect(tags.title == "Nocturne No. 2")
        #expect(file.reads <= 3)
        #expect(file.bytes <= 200 << 10)
    }

    @Test func fileNamesGiveATitleAndANumberWhenThereAreNoTags() {
        #expect(ShareCatalog.titleAndNumber(fileName: "03 Night Ferry.flac") == ("Night Ferry", 3))
        #expect(ShareCatalog.titleAndNumber(fileName: "07. Untagged Song.wav") == ("Untagged Song", 7))
        #expect(ShareCatalog.titleAndNumber(fileName: "1-07 - Lanterns.m4a") == ("Lanterns", 7))
        #expect(ShareCatalog.titleAndNumber(fileName: "Lanterns.m4a") == ("Lanterns", nil))
        #expect(ShareCatalog.titleAndNumber(fileName: "1999.flac") == ("1999", nil))
    }
}
