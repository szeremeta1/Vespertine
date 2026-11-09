//
// Vespertine: where the room correction library lives: one file in the app's data folder, written whole and kept
// with its previous version, so a crash or a full disk can't leave the listener with half a library.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Room profile store")
struct RoomProfileStoreTests {
    private func store() throws -> (RoomProfileStore, URL) {
        let dir = try ProfileFixtures.folder()
        return (RoomProfileStore(directory: dir), dir)
    }

    private func book() throws -> RoomProfileBook {
        var book = RoomProfileBook()
        let a = book.add(try ProfileFixtures.profile(name: "Desk"))
        book.add(try ProfileFixtures.profile(name: "Sofa"), makeChosen: false)
        book.setEnabled(true, for: a.deviceUID)
        return book
    }

    @Test("A library saved and loaded again is the same: profiles, the choice per output and what is switched on")
    func roundTrip() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = try book()
        try store.save(saved, unreadable: [])
        let loaded = try #require(store.load())
        #expect(loaded.book == saved && loaded.unreadable.isEmpty)
        #expect(loaded.book.active(for: "zd3")?.name == "Desk")
    }

    @Test("A profile added or copied now loads back exactly as it was kept: its time is held to the second the file stores")
    func wholeSecondTimes() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        var book = RoomProfileBook()
        let desk = book.add(try ProfileFixtures.profile(name: "Desk", at: Date(timeIntervalSince1970: 1_793_000_000.75)))
        let copy = try book.duplicate(desk.id)
        try store.save(book, unreadable: [])
        let loaded = try #require(store.load()).book
        #expect(loaded == book)
        #expect(loaded.profile(desk.id)?.createdAt == desk.createdAt && loaded.profile(copy.id)?.createdAt == copy.createdAt)
    }

    @Test("Nothing saved yet loads as nothing, not as an error")
    func empty() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.load() == nil)
    }

    @Test("Profiles this version can't read are written back untouched")
    func keepsUnreadable() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(try book(), unreadable: [["schemaVersion": 99, "name": "Later"] as [String: Any]])
        let loaded = try #require(store.load())
        #expect(loaded.book.profiles.count == 2 && loaded.unreadable.count == 1)
        try store.save(loaded.book, unreadable: loaded.unreadable)
        #expect(try #require(store.load()).unreadable.count == 1)
    }

    @Test("The previous version is kept: a damaged file is set aside and the last good one is used")
    func recoversFromBackup() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        var first = RoomProfileBook()
        first.add(try ProfileFixtures.profile(name: "First"))
        try store.save(first, unreadable: [])
        var second = first
        second.add(try ProfileFixtures.profile(name: "Second"))
        try store.save(second, unreadable: [])
        // The file is cut short, as a crash during a write elsewhere might leave it.
        try Data("{\"version\":1,\"prof".utf8).write(to: store.fileURL)
        let loaded = try #require(store.load())
        #expect(loaded.book.profiles.map(\.name) == ["First"])
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("damaged") }
        #expect(aside.count == 1)
    }

    @Test("Damaged with no backup: set aside, and the library starts empty rather than crashing")
    func damagedWithoutBackup() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json".utf8).write(to: store.fileURL)
        #expect(store.load() == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.contains("damaged") })
    }

    @Test("A library from before the file existed comes over from the old preferences, once")
    func legacyImport() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try ProfileFixtures.profile(name: "Old")
        let legacy = RoomProfileStore.Legacy(profiles: try RoomCorrectionCoding.encodeProfiles([a]), choices: [:], assignments: ["zd3": a.id.uuidString])
        let loaded = try #require(store.load(legacy: legacy))
        #expect(loaded.book.active(for: "zd3")?.id == a.id)
        try store.save(loaded.book, unreadable: loaded.unreadable)
        // Once the file exists the old preferences are not read again.
        var changed = loaded.book
        try changed.rename(a.id, to: "Renamed")
        try store.save(changed, unreadable: [])
        #expect(try #require(store.load(legacy: legacy)).book.profile(a.id)?.name == "Renamed")
    }

    @Test("Unreadable old preferences are not lost: the unreadable profiles in them are kept too")
    func legacyKeepsUnreadable() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try ProfileFixtures.profile()
        var objects = try #require(JSONSerialization.jsonObject(with: RoomCorrectionCoding.encodeProfiles([a])) as? [Any])
        objects.append(["schemaVersion": 99, "name": "Later"] as [String: Any])
        let legacy = RoomProfileStore.Legacy(profiles: try JSONSerialization.data(withJSONObject: objects), choices: [:], assignments: [:])
        let loaded = try #require(store.load(legacy: legacy))
        #expect(loaded.book.profiles.count == 1 && loaded.unreadable.count == 1)
    }
}
