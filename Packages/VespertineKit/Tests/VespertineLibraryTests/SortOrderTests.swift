//
// Vespertine: artists and albums with accents sort with their plain letter, not after Z.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
@testable import VespertineLibrary

@Suite("Sort order")
struct SortOrderTests {
    private func library(_ artists: [String]) throws -> LibraryDatabase {
        let db = try LibraryDatabase.inMemory()
        let source = try db.addSource(LibrarySource(path: "/m", mode: .reference))
        try db.writer.write { dbw in
            for (i, name) in artists.enumerated() {
                var t = Track.stub(path: "/m/\(i).flac")
                t.sourceId = source.id
                t.artist = name
                t.album = "Album"
                try t.insert(dbw)
            }
        }
        return db
    }

    @Test("Accented first letters sit with the plain letter in the album, artist and song lists")
    func accentsSortWithTheirLetter() throws {
        let names = ["Zappa", "Édith Piaf", "Abba", "Ólafur Arnalds", "Björk", "Çigdem", "Ørjan", "Beyoncé", "BEYONCE Live", "Aa", "Æon", "东京事变"]
        let db = try library(names)
        let expected = ["Aa", "Abba", "Æon", "Beyoncé", "BEYONCE Live", "Björk", "Çigdem", "Édith Piaf", "Ólafur Arnalds", "Ørjan", "Zappa", "东京事变"]
        // Beyoncé and BEYONCE (no accent) are the same letters: either order between them is fine, so compare with them folded.
        func folded(_ list: [String]) -> [String] { list.map { $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) } }
        #expect(folded(try db.albums(sort: .artist).map(\.artist)) == folded(expected))
        #expect(folded(try db.artists().map(\.name)) == folded(expected))
        #expect(folded(try db.allTracks().compactMap(\.artist)) == folded(expected))
        let order = try db.albums(sort: .artist).map(\.artist)
        #expect(order.last == "东京事变" && order.first == "Aa")
    }

    @Test("Plain ASCII names keep their order, and case doesn't matter")
    func asciiUnchanged() throws {
        let db = try library(["b-side", "B Team", "a-ha", "Abba", "10cc", "2Pac", "The Beatles"])
        #expect(try db.albums(sort: .artist).map(\.artist) == ["10cc", "2Pac", "a-ha", "Abba", "B Team", "b-side", "The Beatles"])
    }

    @Test("The fold is what the key is: accents, case and letters that aren't accents")
    func fold() {
        #expect(LibraryDatabase.sortFold("édith piaf") == "edith piaf")
        #expect(LibraryDatabase.sortFold("ÓLAFUR") == "olafur")
        #expect(LibraryDatabase.sortFold("ørjan æon straße") == "orjan aeon strasse")
        #expect(LibraryDatabase.sortFold("abba 10cc") == "abba 10cc")
        #expect(LibraryDatabase.sortFold("") == "")
    }

    @Test("Smart playlists in album order use it too")
    func smartPlaylistOrder() throws {
        let db = try library(["Zappa", "Édith Piaf", "Abba"])
        let playlist = try db.createPlaylist(name: "All", rules: SmartRules(match: .all, rules: [SmartRule(field: .codec, op: .equals, value: "FLAC")]))
        #expect(try db.tracks(in: playlist).compactMap(\.artist) == ["Abba", "Édith Piaf", "Zappa"])
    }

    @Test("The substring search for Japanese, Chinese and Thai lists in the same order")
    func substringSearchOrder() throws {
        let db = try library(["Zappa 夜", "Édith 夜", "Abba 夜", "Ólafur 夜"])
        #expect(try db.search("夜").compactMap(\.artist) == ["Abba 夜", "Édith 夜", "Ólafur 夜", "Zappa 夜"])
    }
}
