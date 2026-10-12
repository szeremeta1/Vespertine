//
// Vespertine — album editions are one card while the tagged releases remain separate.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineLibrary

@Suite("Album families")
struct AlbumFamiliesTests {
    private func album(_ title: String, artist: String = "Bob Dylan", year: Int? = 1964) -> Album {
        Album(key: "\(artist)|\(title)", title: title, artist: artist, year: year, genre: nil, trackCount: 10,
              duration: 2400, artworkKey: nil, formatSummary: "DSD64", codec: "DSF", maxBitDepth: 1,
              maxSampleRate: 2_822_400, isHiRes: true, isDSD: true, addedAt: .now, totalSize: 1,
              sourcePath: nil)
    }

    @Test("Stereo, mono and surround releases of the same album have one card")
    func editions() {
        let items = [album("Another Side of Bob Dylan (1964) [MoFi 2012 SACD DSD64]"),
                     album("Another Side of Bob Dylan (1964) [MoFi 2012 Mono SACD DSD64]", year: 2010),
                     album("Another Side of Bob Dylan (1964) [Sony 2003 SACD DSD64]")]
        let groups = AlbumFamilies.group(items)
        #expect(groups.count == 1)
        #expect(groups[0].title == "Another Side of Bob Dylan")
        #expect(groups[0].year == 1964)
        #expect(groups[0].editions.map(\.key) == items.map(\.key))
    }

    @Test("A standard album and a co-credited SACD are editions of one album")
    func plainAndCredited() {
        let groups = AlbumFamilies.group([album("Planet Waves", year: 1974),
                                          album("Planet Waves (1974) [MoFi 2016 SACD DSD64]", artist: "Bob Dylan & The Band", year: 1974)])
        #expect(groups.count == 1)
        #expect(groups[0].title == "Planet Waves")
        #expect(groups[0].artist == "Bob Dylan")
    }

    @Test("Punctuation variants join, but unrelated artists, years and live albums stay separate")
    func boundaries() {
        let groups = AlbumFamilies.group([album("The Times They Are A-Changin' (1964) [MoFi 2015 SACD DSD64]"),
                                          album("The Times They Are A‐Changin’"),
                                          album("The Times They Are A-Changin' (1974) [Live Edition]", year: 1974),
                                          album("The Times They Are A-Changin' (1964) [SACD DSD64]", artist: "Another Artist")])
        #expect(groups.count == 3)
        #expect(groups.map { $0.editions.count } == [2, 1, 1])
    }

    @Test("Parenthesized editions join the original despite a remaster-year tag")
    func remasterYear() {
        let groups = AlbumFamilies.group([album("Desire (2019 Remaster)", year: 2019),
                                          album("Desire", year: 1976),
                                          album("Desire (Mono Mix)", year: 1976)])
        #expect(groups.count == 1)
        #expect(groups[0].title == "Desire")
        #expect(groups[0].year == 1976)
        #expect(groups[0].editions.count == 3)
    }

    @Test("A filtered page keeps one card when the matching editions have different joint credits")
    func filteredJointCredits() {
        let plain = album("Planet Waves", year: 1974)
        let stereo = album("Planet Waves (1974) [SACD Stereo]", artist: "Bob Dylan & The Band", year: 1974)
        let mono = album("Planet Waves (1974) [Mono Mix]", artist: "Bob Dylan feat. The Band", year: 1974)
        let groups = AlbumFamilies.visibleGroups([mono, stereo], among: [plain, stereo, mono])
        #expect(groups.count == 1)
        #expect(groups[0].representative.key == mono.key)
        #expect(groups[0].editions.count == 3)
        #expect(groups[0].title == "Planet Waves")
        #expect(AlbumFamilies.visibleGroups([], among: [plain, stereo, mono]).isEmpty)
    }
}
