//
// Nocturne — genre tags as people mean them.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import NocturneLibrary

@Suite("Genres")
struct GenreTests {
    @Test("Case, accents, hyphens, 'and' and slash order don't make a different genre")
    func sameGenre() {
        #expect(Genres.key("Hip-Hop") == Genres.key("hip hop"))
        #expect(Genres.key("Alternative-Rock") == Genres.key("Alternative Rock"))
        #expect(Genres.key("Alt. Rock") == Genres.key("Alternative Rock"))
        #expect(Genres.key("Alt.Rock") == Genres.key("Alternative Rock"))
        #expect(Genres.key("Rap/Hip Hop") == Genres.key("Hip-Hop/Rap"))
        #expect(Genres.key("Rock and Roll") == Genres.key("Rock & Roll"))
        #expect(Genres.key("Alternativa e indie") == Genres.key("Alternative & Indie"))
        #expect(Genres.key("Alternatif et Indé") == Genres.key("Alternative & Indie"))
        #expect(Genres.key("Pop/Rock") != Genres.key("Pop"))
    }

    @Test("Multi-value tags split; names with slashes stay whole; junk is dropped; ID3 numbers become names")
    func splitting() {
        #expect(Genres.split("Soul, Funk, R&B") == ["Soul", "Funk", "R&B"])
        #expect(Genres.split("Rock; Blues|Jazz") == ["Rock", "Blues", "Jazz"])
        #expect(Genres.split("Pop/Rock") == ["Pop/Rock"])
        #expect(Genres.split("Rock, rock, ROCK") == ["Rock"])
        #expect(Genres.split("& Country") == ["Country"])
        #expect(Genres.split("7.1") == [])
        #expect(Genres.split("13") == ["Pop"])
        #expect(Genres.split("(17)") == ["Rock"])
        #expect(Genres.split(nil) == [])
    }

    @Test("Summaries merge spellings and count albums per genre")
    func summaries() {
        func album(_ key: String, _ genre: String?, year: Int? = nil) -> Album {
            Album(key: key, title: key, artist: "A", year: year, genre: genre, trackCount: 1, duration: 1, artworkKey: nil,
                  formatSummary: "FLAC", codec: "FLAC", maxBitDepth: 16, maxSampleRate: 44_100, isHiRes: false, isDSD: false,
                  addedAt: .now, totalSize: 1, sourcePath: nil)
        }
        let list = Genres.summarize([album("a", "Hip-Hop"), album("b", "Hip Hop"), album("c", "Hip-Hop, Jazz"), album("d", "Jazz")])
        #expect(list.map(\.name) == ["Hip-Hop", "Jazz"])
        #expect(list.map(\.albumCount) == [3, 2])
        #expect(Genres.decade(1977) == 1970 && Genres.decade(nil) == nil)
        // Merged translations are named in English, whatever spelling is most common.
        let indie = Genres.summarize([album("e", "Alternativa e indie"), album("f", "Alternativa e indie"), album("g", "Alternative & Indie")])
        #expect(indie.map(\.name) == ["Alternative & Indie"] && indie.first?.albumCount == 3)
    }
}

@Test("More spellings of the same genre are merged")
func moreGenreAliases() {
    #expect(Genres.key("Hardrock") == Genres.key("Hard Rock"))
    #expect(Genres.key("Pop/Rock") == Genres.key("Pop Rock"))
    #expect(Genres.key("Pop rock") == Genres.key("Pop Rock"))
    #expect(Genres.key("Classique") == Genres.key("Classical"))
    #expect(Genres.key("Classica") == Genres.key("Classical"))
    #expect(Genres.key("Rap/Hip-Hop") == Genres.key("Hip-Hop/Rap"))
    #expect(Genres.split("Soul, Funk, R&B") == ["Soul", "Funk", "R&B"])
}
