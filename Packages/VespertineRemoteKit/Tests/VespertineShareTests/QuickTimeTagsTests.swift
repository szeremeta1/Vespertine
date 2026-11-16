//
// Vespertine: MPEG-4 files tagged the QuickTime way (a `keys` box of names and items numbered into it) instead of the
// iTunes way. FFmpeg writes them with `-movflags use_metadata_tags`; Apple's apps write them in movies.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteProtocol
@testable import VespertineShare

private enum QuickTimeFixtures {
    /// 20 ms of Apple Lossless, 16/48, written by FFmpeg 6.1:
    /// ffmpeg -f lavfi -i sine=frequency=440:sample_rate=48000:duration=0.02 -c:a alac -sample_fmt s16p
    ///   -metadata title="Harbor Lights" ... -metadata REPLAYGAIN_TRACK_GAIN="-7.31 dB" ... -movflags use_metadata_tags
    static let named = SongFixtures.data("""
        AAAAHGZ0eXBNNEEgAAACAE00QSBpc29taXNvMgAAAAhmcmVlAAAB8m1kYXQAABAAAAeAAAANCgEr/04ACf/eACIP+A6v/Adb+c/lulAAYFBABQgMECDh0gAA
        KQKEEGQYiCIJA0DEtZTU2WMIYgKQdnQxKTJkpZpgDE1SUpCY0NOGQo1koui9/dP17glCoVXV1HGqVzO76vEqevaDtw3+jRpqi9/qWjk91AJ0QxFcuAMVXda6
        LZz9ozW/swmKhZOvj1eHm6AjaY3zSgOVF1p5+nhUOZdXUaq9/ZiVKVIrVW4zK0JZzduoy6VSlV4qlKr391OtpaGcSRHhWVAdUG7AcaCrz7aesuo07pGXl0Rq
        lndaYs1RWk4wrtx3n3SaacpUmsjFV79USgWW2TG6WnoHHKsaqzLcqVz/GNNOUjPVF0q5UTSqclPQ0b736ycq0ra9p0ni+c7TznnPDABWNDBKgYUISaacM9OG
        /01SGs1ltOO8S3rNOtKrpJoN6ehb5lyrz4cMTvLyYXiomTO87NwHBxnTLE00UnKNNPW/1UMhl1F79SgjjjQNNNPWmTHfQqF13vm+Uri9oJ0lo6U0tlSsp0h2
        NnBkFVTZHKttLffWlOG/4ZDNKio00zn5KjmaCpKRXITE45Rbfr36xOk7VxPE7Qine0I5PVSU2dDI41HYTO6tjurHBzLcqOZrJmuv1Koeam0kMmg4AAAE/m1v
        b3YAAABsbXZoZAAAAAAAAAAAAAAAAAAAA+gAAAAUAAEAAAEAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAIAAAHVdHJhawAAAFx0a2hkAAAAAwAAAAAAAAAAAAAAAQAAAAAAAAAUAAAAAAAAAAAAAAABAQAAAAABAAAAAAAAAAAAAAAA
        AAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAJGVkdHMAAAAcZWxzdAAAAAAAAAABAAAAFAAAAAAAAQAAAAABTW1kaWEAAAAgbWRoZAAAAAAAAAAA
        AAAAAAAAu4AAAAPAVcQAAAAAAC1oZGxyAAAAAAAAAABzb3VuAAAAAAAAAAAAAAAAU291bmRIYW5kbGVyAAAAAPhtaW5mAAAAEHNtaGQAAAAAAAAAAAAAACRk
        aW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAALxzdGJsAAAAWHN0c2QAAAAAAAAAAQAAAEhhbGFjAAAAAAAAAAEAAAAAAAAAAAABABAAAAAAu4AA
        AAAAACRhbGFjAAAAAAAAEAAAECgKDgEAAAAAIAQAC7gAAAC7gAAAABhzdHRzAAAAAAAAAAEAAAABAAADwAAAABxzdHNjAAAAAAAAAAEAAAABAAAAAQAAAAEA
        AAAUc3RzegAAAAAAAAHqAAAAAQAAABRzdGNvAAAAAAAAAAEAAAAsAAACtXVkdGEAAAKtbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWR0YQAAAAAAAAAAAAAA
        AAAAAADya2V5cwAAAAAAAAAMAAAADW1kdGF0aXRsZQAAAA5tZHRhYXJ0aXN0AAAAFG1kdGFhbGJ1bV9hcnRpc3QAAAANbWR0YWFsYnVtAAAADW1kdGFnZW5y
        ZQAAAAxtZHRhZGF0ZQAAAA1tZHRhdHJhY2sAAAAMbWR0YWRpc2MAAAAdbWR0YVJFUExBWUdBSU5fVFJBQ0tfR0FJTgAAAB1tZHRhUkVQTEFZR0FJTl9UUkFD
        S19QRUFLAAAAHW1kdGFSRVBMQVlHQUlOX0FMQlVNX0dBSU4AAAAdbWR0YVJFUExBWUdBSU5fQUxCVU1fUEVBSwAAAY5pbHN0AAAAJQAAAAEAAAAdZGF0YQAA
        AAEAAAAASGFyYm9yIExpZ2h0cwAAACEAAAACAAAAGWRhdGEAAAABAAAAAE1hcmEgVm9zcwAAACkAAAADAAAAIWRhdGEAAAABAAAAAE1hcmEgVm9zcyBRdWFy
        dGV0AAAAIwAAAAQAAAAbZGF0YQAAAAEAAAAAVGlkZSBUYWJsZXMAAAAcAAAABQAAABRkYXRhAAAAAQAAAABKYXp6AAAAIgAAAAYAAAAaZGF0YQAAAAEAAAAA
        MjAyMS0wNi0xMQAAABsAAAAHAAAAE2RhdGEAAAABAAAAADMvOQAAABsAAAAIAAAAE2RhdGEAAAABAAAAADEvMgAAACAAAAAJAAAAGGRhdGEAAAABAAAAAC03
        LjMxIGRCAAAAIAAAAAoAAAAYZGF0YQAAAAEAAAAAMC45MTIzNDUAAAAgAAAACwAAABhkYXRhAAAAAQAAAAAtNi44MCBkQgAAACAAAAAMAAAAGGRhdGEAAAAB
        AAAAADAuOTc3MDAw
        """)

    static func be32(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
    static func box(_ type: [UInt8], _ body: [UInt8]) -> [UInt8] { be32(body.count + 8) + type + body }
    static func box(_ type: String, _ body: [UInt8]) -> [UInt8] { box(Array(type.utf8), body) }

    /// A value's `data` box: what kind of value it is, four bytes of locale, the value.
    static func text(_ value: String) -> [UInt8] { box("data", be32(1) + be32(0) + Array(value.utf8)) }
    static func number(_ value: UInt8) -> [UInt8] { box("data", be32(22) + be32(0) + [value]) }

    /// A `meta` box of QuickTime-named tags. `plain` leaves out the four bytes of version and flags, as QuickTime's
    /// own files do. `values` are whole `data` boxes.
    static func meta(_ tags: [(key: String, value: [UInt8])], plain: Bool = false, namespace: String = "mdta") -> [UInt8] {
        let handler = box("hdlr", be32(0) + be32(0) + Array("mdta".utf8) + [UInt8](repeating: 0, count: 13))
        var keys = be32(0) + be32(tags.count)
        var items: [UInt8] = []
        for (index, tag) in tags.enumerated() {
            keys += be32(8 + tag.key.utf8.count) + Array(namespace.utf8) + Array(tag.key.utf8)
            items += box(be32(index + 1), tag.value)
        }
        return box("meta", (plain ? [] : be32(0)) + handler + box("keys", keys) + box("ilst", items))
    }

    /// `file` with its `moov` box changed: `udta` dropped if `keepingTags` is false, and `extra` put at the end of it.
    static func file(_ file: Data, keepingTags: Bool, adding extra: [UInt8]) -> Data {
        let b = [UInt8](file)
        func size(_ at: Int) -> Int { Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3]) }
        func type(_ at: Int) -> String { String(decoding: b[(at + 4)..<(at + 8)], as: UTF8.self) }
        var out: [UInt8] = []
        var at = 0
        while at + 8 <= b.count {
            let length = size(at)
            precondition(length >= 8 && at + length <= b.count)
            if type(at) == "moov" {
                var body: [UInt8] = []
                var inner = at + 8
                while inner + 8 <= at + length {
                    let innerLength = size(inner)
                    precondition(innerLength >= 8 && inner + innerLength <= at + length)
                    if keepingTags || type(inner) != "udta" { body += b[inner..<(inner + innerLength)] }
                    inner += innerLength
                }
                out += box("moov", body + extra)
            } else {
                out += b[at..<(at + length)]
            }
            at += length
        }
        return Data(out)
    }
}

@Suite struct QuickTimeTagsTests {
    @Test func aFileFFmpegTaggedTheQuickTimeWayGivesItsTags() throws {
        let tags = try #require(try CountedFile(QuickTimeFixtures.named).tags(named: "03 Harbor Lights.m4a"))
        #expect(tags.codec == "ALAC" && tags.sampleRate == 48_000 && tags.bitDepth == 16 && tags.channels == 1)
        #expect(tags.title == "Harbor Lights" && tags.artist == "Mara Voss" && tags.albumArtist == "Mara Voss Quartet")
        #expect(tags.album == "Tide Tables" && tags.genre == "Jazz")
        #expect(tags.track == 3 && tags.disc == 1 && tags.year == 2021)
        #expect(tags.replayGain == ReplayGain(trackGain: -7.31, trackPeak: 0.912345, albumGain: -6.8, albumPeak: 0.977))
    }

    @Test func aQuickTimeFilesOwnNamesAndPlaceAreRead() throws {
        // Beside the tracks, not in `udta`; no version bytes; Apple's long names; the track number as a number;
        // names in capitals, as FFmpeg carries them over from a FLAC file.
        let meta = QuickTimeFixtures.meta([
            ("com.apple.quicktime.title", QuickTimeFixtures.text("Slow Ferry")),
            ("com.apple.quicktime.artist", QuickTimeFixtures.text("Odile Marsh")),
            ("ALBUM", QuickTimeFixtures.text("Crossings")),
            ("ALBUMARTIST", QuickTimeFixtures.text("Odile Marsh Band")),
            ("com.apple.quicktime.genre", QuickTimeFixtures.text("Folk")),
            ("com.apple.quicktime.creationdate", QuickTimeFixtures.text("2019-03-08T10:00:00Z")),
            ("track", QuickTimeFixtures.number(7)),
            ("DISCNUMBER", QuickTimeFixtures.text("2/2")),
            ("replaygain_album_gain", QuickTimeFixtures.text("+0.40 dB")),
        ], plain: true)
        let file = QuickTimeFixtures.file(QuickTimeFixtures.named, keepingTags: false, adding: meta)
        let tags = try #require(try CountedFile(file).tags(named: "a.m4a"))
        #expect(tags.title == "Slow Ferry" && tags.artist == "Odile Marsh" && tags.albumArtist == "Odile Marsh Band")
        #expect(tags.album == "Crossings" && tags.genre == "Folk")
        #expect(tags.track == 7 && tags.disc == 2 && tags.year == 2019)
        #expect(tags.replayGain == ReplayGain(trackGain: nil, trackPeak: nil, albumGain: 0.4, albumPeak: nil))
    }

    @Test func iTunesTagsComeFirstAndQuickTimeOnesFillTheGaps() throws {
        let meta = QuickTimeFixtures.meta([
            ("title", QuickTimeFixtures.text("Some Other Title")),
            ("genre", QuickTimeFixtures.text("Soul")),
            ("REPLAYGAIN_TRACK_GAIN", QuickTimeFixtures.text("-3.00 dB")),
        ])
        let file = CountedFile(QuickTimeFixtures.file(SongFixtures.aac, keepingTags: true, adding: meta))
        let tags = try #require(try file.tags(named: "a.m4a"))
        #expect(tags.title == "Coffee Rings" && tags.artist == "June Okafor" && tags.album == "Velvet Hours")
        #expect(tags.genre == "Soul")
        #expect(tags.replayGain == ReplayGain(trackGain: -3, trackPeak: nil, albumGain: nil, albumPeak: nil))
        #expect(file.picture(tags) == SongFixtures.cover)
    }

    @Test func aQuickTimeCoverIsFound() throws {
        let jpeg = [UInt8](SongFixtures.cover)
        let meta = QuickTimeFixtures.meta([
            ("com.apple.quicktime.artwork", QuickTimeFixtures.box("data", QuickTimeFixtures.be32(13) + QuickTimeFixtures.be32(0) + jpeg)),
        ])
        let file = CountedFile(QuickTimeFixtures.file(QuickTimeFixtures.named, keepingTags: false, adding: meta))
        let tags = try #require(try file.tags(named: "a.m4a"))
        #expect(file.picture(tags) == SongFixtures.cover)
        #expect(tags.title == nil)
    }

    @Test func namesFromAnotherNamespaceAndItemsWithNoNameAreLeftAlone() throws {
        let foreign = QuickTimeFixtures.meta([("title", QuickTimeFixtures.text("Not Ours"))], namespace: "udta")
        var tags = try #require(try CountedFile(QuickTimeFixtures.file(QuickTimeFixtures.named, keepingTags: false, adding: foreign)).tags(named: "a.m4a"))
        #expect(tags.title == nil && tags.codec == "ALAC")

        // Items numbered 0 and 9, with one name to count into: neither has a name.
        let handler = QuickTimeFixtures.box("hdlr", [UInt8](repeating: 0, count: 8) + Array("mdta".utf8) + [UInt8](repeating: 0, count: 13))
        let keys = QuickTimeFixtures.box("keys", QuickTimeFixtures.be32(0) + QuickTimeFixtures.be32(0x7FFF_FFFF) + QuickTimeFixtures.be32(13) + Array("mdtatitle".utf8))
        let items = QuickTimeFixtures.box(QuickTimeFixtures.be32(0), QuickTimeFixtures.text("Zero")) + QuickTimeFixtures.box(QuickTimeFixtures.be32(9), QuickTimeFixtures.text("Nine"))
        let meta = QuickTimeFixtures.box("meta", QuickTimeFixtures.be32(0) + handler + keys + QuickTimeFixtures.box("ilst", items))
        tags = try #require(try CountedFile(QuickTimeFixtures.file(QuickTimeFixtures.named, keepingTags: false, adding: meta)).tags(named: "a.m4a"))
        #expect(tags.title == nil && tags.replayGain == nil)

        // A `meta` box too short to hold anything.
        let stub = QuickTimeFixtures.box("meta", [0, 0])
        tags = try #require(try CountedFile(QuickTimeFixtures.file(QuickTimeFixtures.named, keepingTags: false, adding: stub)).tags(named: "a.m4a"))
        #expect(tags.title == nil)
    }

    @Test func aFileAnEarlierScanFoundNoTagsInIsReadAgain() throws {
        let share = FakeShare()
        share.put("Mara Voss/03 Harbor Lights.m4a", QuickTimeFixtures.named)
        share.put("Mara Voss/04 Aurora Line.m4a", SongFixtures.alac)
        var first = try ShareScanner.scan(share, now: FakeShare.day)
        // As a version that could not read these tags left it.
        let at = try #require(first.songs.firstIndex { $0.path.hasSuffix("Harbor Lights.m4a") })
        let id = first.songs[at].id
        first.songs[at].tags.title = nil
        first.songs[at].tags.artist = nil
        first.songs[at].tags.albumArtist = nil
        first.songs[at].tags.album = nil
        share.forgetCounts()

        let second = try ShareScanner.scan(share, previous: first, now: FakeShare.day)
        #expect(Set(share.readPaths) == ["Mara Voss/03 Harbor Lights.m4a"])
        let song = try #require(second.songs.first { $0.path.hasSuffix("Harbor Lights.m4a") })
        #expect(song.tags.title == "Harbor Lights" && song.tags.album == "Tide Tables" && song.id == id)
    }

    @Test func cutShortAnywhereItIsNeverACrash() throws {
        for length in stride(from: 0, to: QuickTimeFixtures.named.count, by: 13) {
            _ = try CountedFile(QuickTimeFixtures.named.prefix(length)).tags(named: "a.m4a")
        }
    }
}
