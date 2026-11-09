//
// Vespertine: where the speaker groups live: one file in the app's data folder, written whole and kept with its previous
// version, with the room profile library's safety rules.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Speaker group store")
struct SpeakerGroupStoreTests {
    private func store() throws -> (SpeakerGroupStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-groups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SpeakerGroupStore(directory: dir), dir)
    }

    private func damagedFiles(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("damaged") }
    }

    @Test("Groups saved and loaded again are the same, in the same order")
    func roundTrip() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let groups = [GroupFixtures.quad(name: "Downstairs quad"), GroupFixtures.quad(name: "Desk")]
        try store.save(groups, unreadable: [])
        let loaded = try #require(store.load())
        #expect(loaded.groups == groups && loaded.unreadable.isEmpty)
        #expect(store.fileURL.lastPathComponent == "Speaker Groups.json")
    }

    @Test("Nothing saved yet loads as nothing, not as an error")
    func empty() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.load() == nil)
    }

    @Test("Saving an empty list is a real save: the groups that were there are gone, not brought back")
    func emptyListSaved() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save([GroupFixtures.quad()], unreadable: [])
        try store.save([], unreadable: [])
        let loaded = try #require(store.load())
        #expect(loaded.groups.isEmpty)
    }

    @Test("Groups from a newer Vespertine, or that can't be read, are kept as they were and written back with the rest")
    func keepsUnreadable() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let later: [String: Any] = ["schemaVersion": 99, "name": "Later", "newThing": ["a", 1]]
        let odd: [String: Any] = ["schemaVersion": 1, "name": "No id"]
        try store.save([GroupFixtures.quad()], unreadable: [later, odd])
        let loaded = try #require(store.load())
        #expect(loaded.groups.count == 1 && loaded.unreadable.count == 2)
        try store.save(loaded.groups, unreadable: loaded.unreadable)
        let again = try #require(store.load())
        #expect(again.unreadable.count == 2)
        let kept = try #require(again.unreadable.compactMap { $0 as? [String: Any] }.first { $0["name"] as? String == "Later" })
        #expect(kept["schemaVersion"] as? Int == 99 && (kept["newThing"] as? [Any])?.count == 2)
    }

    @Test("The previous version is kept: a damaged file is set aside and the last good one is used")
    func recoversFromBackup() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = [GroupFixtures.quad(name: "First")]
        try store.save(first, unreadable: [])
        try store.save(first + [GroupFixtures.quad(name: "Second")], unreadable: [])
        try Data("{\"version\":1,\"gro".utf8).write(to: store.fileURL)
        let loaded = try #require(store.load())
        #expect(loaded.groups.map(\.name) == ["First"])
        #expect(try damagedFiles(dir).count == 1)
    }

    @Test("A file that can't be read doesn't become the previous version: two bad saves in a row can't wipe the last good one")
    func damagedFileIsNotBackedUp() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save([GroupFixtures.quad(name: "Good")], unreadable: [])
        try store.save([GroupFixtures.quad(name: "Good"), GroupFixtures.quad(name: "Better")], unreadable: [])
        try Data("garbage".utf8).write(to: store.fileURL)
        try store.save([GroupFixtures.quad(name: "Fresh")], unreadable: [])
        try Data("garbage".utf8).write(to: store.fileURL)
        #expect(try #require(store.load()).groups.map(\.name) == ["Good"])
    }

    @Test("Damaged with no backup: set aside, and the list starts empty rather than crashing")
    func damagedWithoutBackup() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json".utf8).write(to: store.fileURL)
        #expect(store.load() == nil)
        #expect(try damagedFiles(dir).count == 1)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("A file from a newer store format is set aside, not overwritten, and not read")
    func newerFormat() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"version":2,"groups":[]}"#.utf8).write(to: store.fileURL)
        #expect(store.load() == nil)
        #expect(try damagedFiles(dir).count == 1)
    }
}

@Suite("Speaker group book")
struct SpeakerGroupBookTests {
    @Test("Groups are added, found by id or by output UID, replaced in place and removed")
    func basics() throws {
        var book = SpeakerGroupBook()
        let a = GroupFixtures.quad(name: "A"), b = GroupFixtures.quad(name: "B")
        book.upsert(a)
        book.upsert(b)
        #expect(book.groups.map(\.name) == ["A", "B"])
        #expect(book.group(a.id) == a && book.group(outputUID: b.outputUID) == b)
        #expect(book.group(outputUID: GroupFixtures.fosi) == nil)
        var renamed = a
        renamed.name = "A2"
        book.upsert(renamed)
        #expect(book.groups.map(\.name) == ["A2", "B"])
        book.remove(a.id)
        #expect(book.groups.map(\.name) == ["B"])
        book.remove(UUID())
        #expect(book.groups.count == 1)
    }

    @Test("A copy is a new group: its own id and speaker ids, 'copy' in the name, no alignment profile of the original's")
    func duplicate() throws {
        var book = SpeakerGroupBook()
        var original = GroupFixtures.quad(name: "Downstairs quad")
        original.alignmentProfileID = UUID()
        book.upsert(original)
        let made = book.duplicate(original.id)
        let copy = try #require(made)
        #expect(copy.id != original.id && copy.outputUID != original.outputUID)
        #expect(copy.name == "Downstairs quad copy")
        #expect(Set(copy.speakers.map(\.id)).isDisjoint(with: original.speakers.map(\.id)))
        #expect(copy.alignmentProfileID == nil)
        #expect(copy.members == original.members && copy.speakers.map(\.role) == original.speakers.map(\.role))
        #expect(book.groups.count == 2)
        let again = book.duplicate(original.id)
        let second = try #require(again)
        #expect(second.name == "Downstairs quad copy 2")
        #expect(book.duplicate(UUID()) == nil)
    }

    @Test("Names are made unique in the list, so two groups can't be told apart only by their id")
    func uniqueName() {
        var book = SpeakerGroupBook()
        book.upsert(GroupFixtures.quad(name: "Downstairs"))
        #expect(book.availableName("Downstairs") == "Downstairs 2")
        #expect(book.availableName("Desk") == "Desk")
        book.upsert(GroupFixtures.quad(name: "Downstairs 2"))
        #expect(book.availableName("Downstairs") == "Downstairs 3")
        #expect(book.availableName("  ") == "Speaker group")
    }
}
