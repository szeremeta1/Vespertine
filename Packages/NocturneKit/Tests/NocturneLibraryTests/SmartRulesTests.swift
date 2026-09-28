//
// Nocturne — smart playlist rules match what people type.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import NocturneLibrary

@Suite("Smart playlist rules")
struct SmartRulesTests {
    /// A library with 48 kHz/24-bit, 44.1 kHz/16-bit and 96 kHz/24-bit files.
    func library() async throws -> (LibraryDatabase, URL) {
        let dir = try tempDir()
        try makeWAV(dir.appendingPathComponent("a48.wav"), rate: 48_000, bits: 24)
        try makeWAV(dir.appendingPathComponent("b441.wav"), rate: 44_100, bits: 16)
        try makeWAV(dir.appendingPathComponent("c96.wav"), rate: 96_000, bits: 24)
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        try await scanner.scan(try db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        return (db, dir)
    }

    func names(_ db: LibraryDatabase, _ rules: SmartRules) throws -> [String] {
        try db.tracks(in: Playlist(name: "t", smartRules: rules)).map { ($0.filePath as NSString).lastPathComponent }.sorted()
    }

    @Test("Sample rates are kHz as shown everywhere (48, 44.1, 48 kHz), and old rules in Hz still work")
    func sampleRates() async throws {
        let (db, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }
        func rate(_ op: SmartRule.Operator, _ v: String) throws -> [String] { try names(db, SmartRules(rules: [SmartRule(field: .sampleRate, op: op, value: v)])) }
        #expect(try rate(.equals, "48") == ["a48.wav"])
        #expect(try rate(.equals, "44.1") == ["b441.wav"])
        #expect(try rate(.equals, "48 kHz") == ["a48.wav"])
        #expect(try rate(.equals, "48k") == ["a48.wav"])
        #expect(try rate(.equals, "48000") == ["a48.wav"])
        #expect(try rate(.greaterOrEqual, "88.2") == ["c96.wav"])
        #expect(try rate(.greaterOrEqual, "88200") == ["c96.wav"])      // the built-in Hi-Res playlist's saved rule
        #expect(try rate(.notEquals, "48") == ["b441.wav", "c96.wav"])
        // The rule from the bug report: 24-bit and 48 kHz.
        let airpods = SmartRules(match: .all, rules: [SmartRule(field: .bitDepth, op: .equals, value: "24"),
                                                      SmartRule(field: .sampleRate, op: .equals, value: "48")])
        #expect(try names(db, airpods) == ["a48.wav"])
    }

    @Test("A rule that can't be understood matches nothing instead of being dropped")
    func invalidRules() async throws {
        let (db, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = SmartRules(match: .all, rules: [SmartRule(field: .sampleRate, op: .contains, value: "48")])
        #expect(try names(db, bad).isEmpty)
        let empty = SmartRules(match: .all, rules: [SmartRule(field: .bitDepth, op: .equals, value: "")])
        #expect(try names(db, empty).isEmpty)
        #expect(SmartRule.Field.sampleRate.operators == [.equals, .notEquals, .greaterOrEqual, .lessOrEqual])
        #expect(SmartRule.Field.isDSD.operators == [.isTrue, .isFalse])
        #expect(SmartRule.number("24-bit") == 24 && SmartRule.number("1,000") == 1000)
    }
}
