//
// Vespertine: whatever is typed in the search field reaches SQLite as a plain search for words, never as search syntax or SQL.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
@testable import VespertineLibrary

@Suite("Search input")
struct SearchInputTests {
    private static let titles = [
        "Étude in Blue", "Café del Mar", "東京の夜", "Björk Jóga", "Ångström", "naïve", "Straße", "Σίγμα", "Привет",
        "Plain", "Rock AND Roll", "Near Death", "Don't Stop", "Say \"Hello\"", "50% Off", "a-b-c", "C++ Song", "😀 Smile",
        "x*y", "Bobby Tables", "NOT a song", "OR else", "col:umn", "(parens)", "back\\slash",
    ]

    private func library() throws -> LibraryDatabase {
        let db = try LibraryDatabase.inMemory()
        let source = try db.addSource(LibrarySource(path: "/m", mode: .reference))
        try db.writer.write { db in
            for (i, title) in Self.titles.enumerated() {
                var t = Track.stub(path: "/m/\(i).flac")
                t.sourceId = source.id
                t.title = title
                t.artist = "Artist \(i)"
                try t.insert(db)
            }
        }
        return db
    }

    private func titles(_ db: LibraryDatabase, _ query: String) throws -> Set<String> {
        Set(try db.search(query).map(\.title))
    }

    @Test("Accents, case and width are folded; other scripts are found by their words")
    func unicode() throws {
        let db = try library()
        #expect(try titles(db, "etude") == ["Étude in Blue"])
        #expect(try titles(db, "ÉTUDE") == ["Étude in Blue"])
        #expect(try titles(db, "cafe") == ["Café del Mar"])
        #expect(try titles(db, "bjork") == ["Björk Jóga"])
        #expect(try titles(db, "angstrom") == ["Ångström"])
        #expect(try titles(db, "naive") == ["naïve"])
        #expect(try titles(db, "σίγμα") == ["Σίγμα"])
        #expect(try titles(db, "привет") == ["Привет"])
        #expect(try titles(db, "東京") == ["東京の夜"], "the start of a CJK run is found")
    }

    @Test("Scripts written without spaces are found by any part of a word, in any field")
    func unspacedScripts() throws {
        let db = try library()
        try db.writer.write { db in
            var t = Track.stub(path: "/m/jp.flac")
            t.title = "月光"
            t.artist = "坂本龍一"
            t.album = "千のナイフ"
            t.sourceId = try Int64.fetchOne(db, sql: "SELECT id FROM source")
            try t.insert(db)
            var thai = Track.stub(path: "/m/th.flac")
            thai.title = "เพลงรัก"
            thai.sourceId = t.sourceId
            try thai.insert(db)
        }
        #expect(try titles(db, "夜") == ["東京の夜"], "the end of a run")
        #expect(try titles(db, "京の") == ["東京の夜"], "the middle of a run")
        #expect(try titles(db, "東京") == ["東京の夜"])
        #expect(try titles(db, "光") == ["月光"])
        #expect(try titles(db, "龍一") == ["月光"], "an artist")
        #expect(try titles(db, "ナイフ") == ["月光"], "an album")
        #expect(try titles(db, "月 龍") == ["月光"], "every word has to be there")
        #expect(try titles(db, "月 夜").isEmpty)
        #expect(try titles(db, "รัก") == ["เพลงรัก"])
        #expect(try titles(db, "月%").isEmpty, "a percent sign is a percent sign")
        #expect(try titles(db, "月_").isEmpty, "and so is an underscore")
        #expect(try titles(db, "plain 夜").isEmpty, "a word that isn't there ends the search")
    }

    @Test("Empty, blank and punctuation-only queries find nothing and don't throw")
    func empty() throws {
        let db = try library()
        for query in ["", " ", "   \t\n", "\"", "\"\"", "*", "**", "-", "()", "(", ")", "^", ":", "'", "\\", "%", "_", ";"] {
            #expect(try db.search(query).isEmpty, "query \(query.debugDescription)")
        }
    }

    @Test("One character is a prefix search, not everything")
    func oneCharacter() throws {
        let db = try library()
        #expect(try titles(db, "p").isSuperset(of: ["Plain", "(parens)"]))
        let all = try titles(db, "p")
        #expect(all.count < Self.titles.count)
        #expect(try titles(db, "é").contains("Étude in Blue"))
    }

    @Test("FTS operators typed as words are words: AND, OR, NOT, NEAR, quotes, stars, minus, column filters")
    func operators() throws {
        let db = try library()
        #expect(try titles(db, "Rock AND Roll") == ["Rock AND Roll"])
        #expect(try titles(db, "AND") == ["Rock AND Roll"])
        #expect(try titles(db, "NOT") == ["NOT a song"])
        #expect(try titles(db, "OR") == ["OR else"])
        #expect(try titles(db, "NEAR") == ["Near Death"])
        #expect(try titles(db, "NEAR(a b)").isEmpty, "NEAR( ) is three words, not a proximity search")
        #expect(try titles(db, "\"Hello\"") == ["Say \"Hello\""])
        #expect(try titles(db, "say \"hello") == ["Say \"Hello\""], "an unbalanced quote")
        #expect(try titles(db, "hel*") == ["Say \"Hello\""])
        #expect(try titles(db, "-hello") == ["Say \"Hello\""], "a minus is not NOT")
        #expect(try titles(db, "title:plain").isEmpty, "a column filter is two words, not a filter")
        #expect(try titles(db, "col:umn") == ["col:umn"])
        #expect(try titles(db, "a-b-c") == ["a-b-c"])
        #expect(try titles(db, "C++").contains("C++ Song"), "punctuation is dropped like the index drops it")
        #expect(try titles(db, "don't") == ["Don't Stop"])
        #expect(try titles(db, "50%") == ["50% Off"])
        #expect(try titles(db, "back\\slash") == ["back\\slash"])
        #expect(try titles(db, "😀").count <= 1)
    }

    @Test("SQL-shaped input is just words, and the library is untouched")
    func injection() throws {
        let db = try library()
        let before = try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM track") }
        for query in ["'; DROP TABLE track; --", "\" OR 1=1 --", "bobby'); DELETE FROM track; --", "x' UNION SELECT * FROM source --",
                      "1; PRAGMA writable_schema=1", "%' OR '1'='1", "\\\" OR \\\"1\\\"=\\\"1"] {
            let found = try db.search(query)
            #expect(found.count < Self.titles.count, "query \(query.debugDescription) must not match everything")
        }
        #expect(try db.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM track") } == before)
        #expect(try titles(db, "bobby") == ["Bobby Tables"])
    }

    @Test("A very long query doesn't throw")
    func long() throws {
        let db = try library()
        _ = try db.search(String(repeating: "plain ", count: 5_000))
        _ = try db.search(String(repeating: "é", count: 100_000))
    }
}
