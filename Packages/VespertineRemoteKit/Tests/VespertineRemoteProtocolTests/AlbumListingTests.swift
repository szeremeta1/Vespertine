//
// Vespertine: the Albums page on the phone can be sorted and narrowed as the Mac's can. The Mac does it (it has the whole
// list; the phone has a page), with one rule both the Mac and the demo share.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineRemoteProtocol

private func album(_ title: String, _ artist: String, _ year: Int?, hiRes: Bool = false, dsd: Bool = false, surround: Bool = false) -> AlbumSummary {
    AlbumSummary(key: title, title: title, artist: artist, year: year, trackCount: 1, duration: 1, format: "", artworkKey: nil,
                 hiRes: hiRes, dsd: dsd, multichannel: surround)
}

@Suite struct AlbumListingTests {
    let albums = [album("Harbor", "The Wrens", 2003), album("an Evening", "Élan", 1999, hiRes: true), album("Zenith", "abel", nil, dsd: true),
                  album("Blue", "Zed", 2021, hiRes: true, surround: true)]

    @Test func withNothingAskedTheMacsOwnOrderStays() {
        #expect(AlbumListing.arrange(albums, sort: nil, filter: nil) == albums)
        #expect(AlbumListing.arrange(albums, sort: .library, filter: .all) == albums)
    }

    @Test func sortingIgnoresCaseAndAccentsAndPutsYearlessAlbumsLast() {
        #expect(AlbumListing.arrange(albums, sort: .title, filter: nil).map(\.title) == ["an Evening", "Blue", "Harbor", "Zenith"])
        #expect(AlbumListing.arrange(albums, sort: .artist, filter: nil).map(\.artist) == ["abel", "Élan", "The Wrens", "Zed"])
        #expect(AlbumListing.arrange(albums, sort: .newest, filter: nil).map(\.title) == ["Blue", "Harbor", "an Evening", "Zenith"])
        #expect(AlbumListing.arrange(albums, sort: .oldest, filter: nil).map(\.title) == ["an Evening", "Harbor", "Blue", "Zenith"])
    }

    @Test func narrowingKeepsTheOrder() {
        #expect(AlbumListing.arrange(albums, sort: nil, filter: .hiRes).map(\.title) == ["an Evening", "Blue"])
        #expect(AlbumListing.arrange(albums, sort: nil, filter: .dsd).map(\.title) == ["Zenith"])
        #expect(AlbumListing.arrange(albums, sort: .title, filter: .surround).map(\.title) == ["Blue"])
    }

    @Test func anOlderMacReadsTheSameCommandAndANewerPhoneSaysNothingExtraByDefault() throws {
        let encoder = RemoteProtocol.encoder()
        #expect(String(decoding: try encoder.encode(ClientMessage(id: 1, command: .albums(offset: 0, limit: 5))), as: UTF8.self)
                == #"{"command":{"albums":{"limit":5,"offset":0}},"id":1}"#)
        #expect(String(decoding: try encoder.encode(ClientMessage(id: 1, command: .albums(offset: 0, limit: 5, sort: .newest, filter: .hiRes))), as: UTF8.self)
                == #"{"command":{"albums":{"filter":"hiRes","limit":5,"offset":0,"sort":"newest"}},"id":1}"#)
        let old = try RemoteProtocol.decoder().decode(ClientMessage.self, from: Data(#"{"command":{"albums":{"limit":5,"offset":0}},"id":1}"#.utf8))
        #expect(old.command == .albums(offset: 0, limit: 5, sort: nil, filter: nil))
    }

    @Test func hiResStartsAt88Point2LikeTheSmartPlaylist() {
        // 24-bit at CD-era rates is above CD, but not on the Hi-Res side of the line.
        #expect(!AlbumFilter.countsAsHiRes(aboveCD: true, dsd: false, maxSampleRate: 44_100))
        #expect(!AlbumFilter.countsAsHiRes(aboveCD: true, dsd: false, maxSampleRate: 48_000))
        #expect(AlbumFilter.countsAsHiRes(aboveCD: true, dsd: false, maxSampleRate: 88_200))
        #expect(AlbumFilter.countsAsHiRes(aboveCD: true, dsd: false, maxSampleRate: 192_000))
        #expect(AlbumFilter.countsAsHiRes(aboveCD: true, dsd: true, maxSampleRate: 2_822_400))
        // A lossy file at a high rate isn't hi-res.
        #expect(!AlbumFilter.countsAsHiRes(aboveCD: false, dsd: false, maxSampleRate: 96_000))
    }
}
