//
// Vespertine — room correction profiles as a library the listener manages: named for a speaker, room or desk,
// renamed, duplicated, deleted, exported and imported, one chosen per output that switches in with the output, and
// older stored profiles carried over unchanged.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

enum ProfileFixtures {
    static let date = Date(timeIntervalSince1970: 1_793_000_000)

    static func curve(_ shape: (Double) -> Double) throws -> RoomCurve {
        let n = Int((log2(16_000.0 / 25) * 48).rounded(.down)) + 1
        let f = (0..<n).map { 25 * pow(2, Double($0) / 48) }
        return try RoomCurve(frequencies: f, db: f.map(shape))
    }

    static func mode(_ f0: Double, _ gain: Double, _ q: Double) -> (Double) -> Double {
        let preset = EQPreset(name: "", bands: [EQBand(kind: .peak, frequency: f0, gainDB: gain, q: q)])
        return { preset.responseDB(at: [$0], sampleRate: 48_000)[0] }
    }

    /// A stereo profile designed from a synthetic room with a 120 Hz mode and a broad dip at 300 Hz.
    static func profile(name: String = "Desk", device: String = "zd3", at created: Date = date) throws -> RoomProfile {
        let left = try curve { mode(120, 12, 4)($0) + mode(300, -4, 1.2)($0) }
        let right = try curve { mode(90, 9, 3)($0) }
        let options = RoomFilterDesignOptions(target: .flat)
        let design = try RoomFilterDesigner.design(channels: [.left: left, .right: right], options: options)
        var p = design.profile(name: name, sessionID: UUID(), deviceUID: device, channelMap: .standard(.stereo), micSerial: "7001234",
                               calibrationSHA256: nil, createdAt: created)
        p.measured = [.left: left, .right: right]
        p.designOptions = options
        p.source = .measured
        p.alignment = [.left: RoomSpeakerAlignment(delayMs: 0.4, levelDB: -1.5)]
        return p
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("room-profiles-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite("Room profile library")
struct RoomProfileBookTests {
    @Test("A profile is added under its own name; a name already used on that output gets a number")
    func uniqueNames() throws {
        var book = RoomProfileBook()
        let a = book.add(try ProfileFixtures.profile(name: "Desk"))
        let b = book.add(try ProfileFixtures.profile(name: "desk"))
        let c = book.add(try ProfileFixtures.profile(name: "Desk", device: "other"))
        #expect(a.name == "Desk" && b.name == "desk 2" && c.name == "Desk")
        #expect(book.profiles(for: "zd3").count == 2 && book.profiles(for: "other").count == 1)
    }

    @Test("Adding a profile whose id is already there keeps both: the newcomer gets a fresh id")
    func idCollision() throws {
        var book = RoomProfileBook()
        let first = book.add(try ProfileFixtures.profile(name: "Desk"))
        var again = try ProfileFixtures.profile(name: "Desk")
        again = RoomProfileBookTests.withID(first.id, again)
        let second = book.add(again)
        #expect(second.id != first.id)
        #expect(book.profiles.count == 2)
        #expect(book.profile(first.id)?.name == "Desk")
    }

    static func withID(_ id: UUID, _ p: RoomProfile) -> RoomProfile {
        var q = RoomProfile(id: id, name: p.name, createdAt: p.createdAt, sessionID: p.sessionID, deviceUID: p.deviceUID, layout: p.layout,
                            channelMap: p.channelMap, micSerial: p.micSerial, calibrationSHA256: p.calibrationSHA256, target: p.target, filters: p.filters)
        q.measured = p.measured; q.designOptions = p.designOptions; q.alignment = p.alignment; q.source = p.source
        return q
    }

    @Test("Rename trims the name, refuses an empty or taken one, and keeps everything else")
    func rename() throws {
        var book = RoomProfileBook()
        let a = book.add(try ProfileFixtures.profile(name: "Desk"))
        _ = book.add(try ProfileFixtures.profile(name: "Living room"))
        try book.rename(a.id, to: "  Studio monitors, near field  ")
        #expect(book.profile(a.id)?.name == "Studio monitors, near field")
        #expect(book.profile(a.id)?.filters == a.filters)
        #expect(throws: RoomProfileError.nameEmpty) { try book.rename(a.id, to: "   \n") }
        #expect(throws: RoomProfileError.nameTaken("Living room")) { try book.rename(a.id, to: "living ROOM") }
        #expect(throws: RoomProfileError.nameTooLong(RoomProfileBook.maxNameLength)) {
            try book.rename(a.id, to: String(repeating: "x", count: RoomProfileBook.maxNameLength + 1))
        }
        #expect(throws: RoomProfileError.notFound) { try book.rename(UUID(), to: "Nope") }
        // Renaming to what it already is (even in another case) is fine.
        try book.rename(a.id, to: "STUDIO MONITORS, NEAR FIELD")
        #expect(book.profile(a.id)?.name == "STUDIO MONITORS, NEAR FIELD")
    }

    @Test("A name with control characters is cleaned, one that is only control characters is empty")
    func renameControlCharacters() throws {
        var book = RoomProfileBook()
        let a = book.add(try ProfileFixtures.profile(name: "Desk"))
        try book.rename(a.id, to: "Bedroom\u{0}\u{7}\tL/R")
        #expect(book.profile(a.id)?.name == "Bedroom L/R")
        #expect(throws: RoomProfileError.nameEmpty) { try book.rename(a.id, to: "\u{0}\u{1}") }
    }

    @Test("Tags for speakers, room and position are kept, trimmed, and empty ones disappear")
    func tags() throws {
        var book = RoomProfileBook()
        let a = book.add(try ProfileFixtures.profile())
        try book.update(a.id) { $0.tags = RoomProfileTags(speakers: " KEF LS50 ", room: "Study", position: "") }
        #expect(book.profile(a.id)?.tags == RoomProfileTags(speakers: "KEF LS50", room: "Study", position: ""))
        #expect(book.profile(a.id)?.tags?.summary == "KEF LS50 · Study")
        try book.update(a.id) { $0.tags = RoomProfileTags(speakers: " ", room: "", position: "") }
        #expect(book.profile(a.id)?.tags == nil)
        let long = RoomProfileTags(speakers: String(repeating: "s", count: 500), room: "", position: "")
        #expect(long.speakers.count == RoomProfileTags.maxLength)
    }

    @Test("Duplicate makes an independent copy with its own id and a free name")
    func duplicate() throws {
        var book = RoomProfileBook()
        let a = book.add(try ProfileFixtures.profile(name: "Desk"))
        let copy = try book.duplicate(a.id)
        #expect(copy.id != a.id && copy.name == "Desk copy" && copy.filters == a.filters && copy.measured == a.measured)
        #expect(copy.deviceUID == a.deviceUID && copy.alignment == a.alignment)
        let second = try book.duplicate(a.id)
        #expect(second.name == "Desk copy 2")
        try book.update(copy.id) { $0.strength = 0.4 }
        #expect(book.profile(a.id)?.strength == nil)
        #expect(throws: RoomProfileError.notFound) { _ = try book.duplicate(UUID()) }
    }

    @Test("Delete removes the profile, switches the output off if it was playing it, and says which filter files nobody else uses")
    func delete() throws {
        var book = RoomProfileBook()
        let shared = RoomImpulse(file: "shared.f32", name: "s", sampleRate: 48_000, frames: 10)
        let own = RoomImpulse(file: "own.f32", name: "o", sampleRate: 48_000, frames: 10)
        var a = try ProfileFixtures.profile(name: "A"), b = try ProfileFixtures.profile(name: "B")
        a.impulses = [.left: shared, .right: own]
        b.impulses = [.left: shared]
        let pa = book.add(a), pb = book.add(b)
        book.choose(pa.id, for: "zd3")
        book.setEnabled(true, for: "zd3")
        let orphans = book.delete(pa.id)
        #expect(Set(orphans.map(\.file)) == ["own.f32"])
        #expect(book.profile(pa.id) == nil && book.profile(pb.id) != nil)
        #expect(book.active(for: "zd3") == nil && !book.isEnabled("zd3"))
        #expect(book.chosenID(for: "zd3") == nil)
        #expect(book.delete(UUID()).isEmpty)
    }

    @Test("Each output plays its own chosen profile, and the right one is in force when that output is selected")
    func perOutput() throws {
        var book = RoomProfileBook()
        let a = book.add(try ProfileFixtures.profile(name: "Desk", device: "zd3"))
        let b = book.add(try ProfileFixtures.profile(name: "Sofa", device: "zd3"))
        let c = book.add(try ProfileFixtures.profile(name: "Kitchen", device: "airplay"))
        book.choose(a.id, for: "zd3"); book.setEnabled(true, for: "zd3")
        book.choose(c.id, for: "airplay"); book.setEnabled(true, for: "airplay")
        #expect(book.active(for: "zd3")?.id == a.id && book.active(for: "airplay")?.id == c.id)
        book.choose(b.id, for: "zd3")
        #expect(book.active(for: "zd3")?.id == b.id)
        // Off keeps the choice for when it is switched back on, and other outputs are untouched.
        book.setEnabled(false, for: "zd3")
        #expect(book.active(for: "zd3") == nil && book.chosenID(for: "zd3") == b.id && book.active(for: "airplay")?.id == c.id)
        book.setEnabled(true, for: "zd3")
        #expect(book.active(for: "zd3")?.id == b.id)
        // A profile for another output can't be chosen here.
        book.choose(c.id, for: "zd3")
        #expect(book.chosenID(for: "zd3") == b.id)
    }

    @Test("Switching on with nothing chosen picks the newest profile for the output; with no profile it stays off")
    func switchOnDefaults() throws {
        var book = RoomProfileBook()
        book.setEnabled(true, for: "zd3")
        #expect(!book.isEnabled("zd3"))
        _ = book.add(try ProfileFixtures.profile(name: "Old", at: Date(timeIntervalSince1970: 1_000)), makeChosen: false)
        let newer = book.add(try ProfileFixtures.profile(name: "New", at: Date(timeIntervalSince1970: 9_000)), makeChosen: false)
        book.setEnabled(true, for: "zd3")
        #expect(book.active(for: "zd3")?.id == newer.id)
    }

    @Test("A new profile becomes the one chosen for its output but doesn't switch correction on by itself")
    func addChooses() throws {
        var book = RoomProfileBook()
        let a = book.add(try ProfileFixtures.profile())
        #expect(book.chosenID(for: "zd3") == a.id && !book.isEnabled("zd3") && book.active(for: "zd3") == nil)
    }

    @Test("An output's profiles follow it to its new UID")
    func moveDevice() throws {
        var book = RoomProfileBook()
        let a = book.add(try ProfileFixtures.profile(device: "old"))
        book.setEnabled(true, for: "old")
        book.moveDevice(from: "old", to: "new")
        #expect(book.profile(a.id)?.deviceUID == "new" && book.active(for: "new")?.id == a.id)
        #expect(book.profiles(for: "old").isEmpty)
    }

    @Test("Profiles saved before the library existed come over unchanged, with the one that was on still on")
    func migrateLegacyAssignments() throws {
        let a = try ProfileFixtures.profile(name: "A"), b = try ProfileFixtures.profile(name: "B")
        let book = RoomProfileBook.migrated(profiles: [a, b], assignments: ["zd3": b.id.uuidString, "gone": UUID().uuidString])
        #expect(book.profiles == [a, b])
        #expect(book.active(for: "zd3")?.id == b.id)
        #expect(book.chosenID(for: "gone") == nil && !book.isEnabled("gone"))
        #expect(book.assignments == ["zd3": b.id.uuidString])
    }

    @Test("The library's stored form survives a save and reload, and a profile it can't read is kept, not dropped")
    func storedFormKeepsUnreadable() throws {
        let a = try ProfileFixtures.profile(name: "A")
        let stored = try RoomCorrectionCoding.encodeProfiles([a])
        var objects = try #require(JSONSerialization.jsonObject(with: stored) as? [[String: Any]])
        objects.append(["schemaVersion": 99, "name": "From the future", "id": UUID().uuidString])
        let data = try JSONSerialization.data(withJSONObject: objects)
        let (profiles, unreadable) = try RoomCorrectionCoding.decodeProfilesKeepingUnreadable(data)
        #expect(profiles == [a] && unreadable.count == 1)
        let again = try RoomCorrectionCoding.encodeProfiles(profiles, keeping: unreadable)
        let (back, stillThere) = try RoomCorrectionCoding.decodeProfilesKeepingUnreadable(again)
        #expect(back == [a] && stillThere.count == 1)
        let future = try #require(stillThere.first as? [String: Any])
        #expect(future["name"] as? String == "From the future")
    }
}

@Suite("Room profile schema 4")
struct RoomProfileSchemaTests {
    @Test("A schema-3 profile loads with every value intact and the new fields at their defaults")
    func schema3Loads() throws {
        let p = try ProfileFixtures.profile()
        var object = try #require(JSONSerialization.jsonObject(with: RoomCorrectionCoding.encode(p)) as? [String: Any])
        object["schemaVersion"] = 3
        let back = try RoomCorrectionCoding.decodeProfile(try JSONSerialization.data(withJSONObject: object))
        #expect(back.schemaVersion == RoomCorrectionCoding.currentSchema)
        var expected = p
        expected.schemaVersion = RoomCorrectionCoding.currentSchema
        #expect(back == expected)
        #expect(back.tags == nil && back.strength == nil && back.effectiveStrength == 1)
        #expect(back.filters == p.filters && back.measured == p.measured && back.alignment == p.alignment && back.designOptions == p.designOptions)
    }

    @Test("A schema-2 profile (no alignment, impulses or source) also loads, and its filters are exactly as saved")
    func schema2Loads() throws {
        let p = try ProfileFixtures.profile()
        var object = try #require(JSONSerialization.jsonObject(with: RoomCorrectionCoding.encode(p)) as? [String: Any])
        object["schemaVersion"] = 2
        object["alignment"] = nil
        object["source"] = nil
        let back = try RoomCorrectionCoding.decodeProfile(try JSONSerialization.data(withJSONObject: object))
        #expect(back.filters == p.filters && back.origin == .measured && back.alignment == nil)
    }

    @Test("Stored design options from before custom targets load with no custom curve")
    func oldTargetDecodes() throws {
        let json = #"{"name":"Warm","tiltDBPerOctave":-1,"bassLiftDB":3,"bassCornerHz":100}"#
        let target = try JSONDecoder().decode(RoomTargetCurve.self, from: Data(json.utf8))
        #expect(target == .warm && target.anchors.isEmpty)
    }

    @Test("A profile with tags, strength and edited flags round-trips")
    func roundTrip() throws {
        var p = try ProfileFixtures.profile()
        p.tags = RoomProfileTags(speakers: "Genelec 8030", room: "Dorm", position: "Desk")
        p.strength = 0.6
        p.filtersEdited = true
        p.excludedPositions = [2]
        p.positionCurves = [.left: [try ProfileFixtures.curve { _ in 0 }, try ProfileFixtures.curve { _ in 3 }]]
        let data = try RoomCorrectionCoding.encode(p)
        let back = try RoomCorrectionCoding.decodeProfile(data)
        #expect(back == p)
        #expect(try RoomCorrectionCoding.encode(back) == data)
    }

    @Test("A newer schema is refused rather than half-read")
    func newerRefused() throws {
        var object = try #require(JSONSerialization.jsonObject(with: RoomCorrectionCoding.encode(ProfileFixtures.profile())) as? [String: Any])
        object["schemaVersion"] = RoomCorrectionCoding.currentSchema + 1
        #expect(throws: RoomCorrectionError.newerSchema(RoomCorrectionCoding.currentSchema + 1)) {
            try RoomCorrectionCoding.decodeProfile(try JSONSerialization.data(withJSONObject: object))
        }
    }
}

@Suite("Room profile export and import")
struct RoomProfileArchiveTests {
    @Test("A profile with no measured filters exports as the plain profile file older versions read too")
    func plainExport() throws {
        let p = try ProfileFixtures.profile()
        let dir = try ProfileFixtures.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = try RoomProfileArchive.encode(p, impulseDirectory: dir)
        #expect(data == (try RoomCorrectionCoding.encode(p)))
        #expect(try RoomProfileArchive.decode(data, into: dir) == p)
    }

    @Test("A profile with impulse responses exports with their samples and imports them into another folder")
    func archiveCarriesImpulses() throws {
        let source = try ProfileFixtures.folder(), target = try ProfileFixtures.folder()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        let samples: [Float] = (0..<64).map { Float($0 % 7) * 0.01 - 0.02 }
        let impulse = RoomImpulse(file: "left.f32", name: "left", sampleRate: 48_000, frames: samples.count)
        try samples.withUnsafeBytes { try Data($0).write(to: source.appendingPathComponent("left.f32")) }
        var p = try ProfileFixtures.profile()
        p.impulses = [.left: impulse]
        let data = try RoomProfileArchive.encode(p, impulseDirectory: source)
        let back = try RoomProfileArchive.decode(data, into: target)
        let restored = try #require(back.impulses?[.left])
        #expect(restored.frames == samples.count && restored.sampleRate == 48_000)
        #expect(restored.samples(in: target) == samples)
        #expect(back.filters == p.filters && back.name == p.name)
    }

    @Test("An export whose filter files are gone is refused with a plain message, not written half-empty")
    func exportMissingFilters() throws {
        let dir = try ProfileFixtures.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        var p = try ProfileFixtures.profile()
        p.impulses = [.left: RoomImpulse(file: "nothere.f32", name: "x", sampleRate: 48_000, frames: 10)]
        #expect(throws: RoomProfileError.missingFilters) { _ = try RoomProfileArchive.encode(p, impulseDirectory: dir) }
        // A plain file naming filters that aren't here is refused on the way in.
        let plain = try RoomCorrectionCoding.encode(p)
        #expect(throws: RoomProfileError.missingFilters) { _ = try RoomProfileArchive.decode(plain, into: dir) }
    }

    @Test("A damaged archive is refused, and nothing is left behind in the filter folder")
    func damagedArchive() throws {
        let source = try ProfileFixtures.folder(), target = try ProfileFixtures.folder()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target) }
        let samples = [Float](repeating: 0.1, count: 32)
        try samples.withUnsafeBytes { try Data($0).write(to: source.appendingPathComponent("a.f32")) }
        var p = try ProfileFixtures.profile()
        p.impulses = [.left: RoomImpulse(file: "a.f32", name: "a", sampleRate: 48_000, frames: 32)]
        var object = try #require(JSONSerialization.jsonObject(with: RoomProfileArchive.encode(p, impulseDirectory: source)) as? [String: Any])
        object["impulses"] = ["a.f32": "AAAA"]   // far too short for 32 frames
        #expect(throws: RoomProfileError.missingFilters) {
            _ = try RoomProfileArchive.decode(try JSONSerialization.data(withJSONObject: object), into: target)
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: target.path)).isEmpty)
        #expect(throws: RoomProfileError.unreadable) { _ = try RoomProfileArchive.decode(Data("nonsense".utf8), into: target) }
    }

    @Test("A profile imported for an output is bound to it, and refused if the output has too few channels")
    func retarget() throws {
        let p = try ProfileFixtures.profile(device: "someone-elses-dac")
        let here = try p.retargeted(toDevice: "my-dac", outputChannels: 2)
        #expect(here.deviceUID == "my-dac" && here.filters == p.filters && here.id == p.id)
        #expect(throws: RoomProfileError.notOnThisOutput(needed: 2, available: 1)) { _ = try p.retargeted(toDevice: "mono", outputChannels: 1) }
        var surround = p
        surround.layout = .surround51
        surround.channelMap = .standard(.surround51)
        #expect(throws: RoomProfileError.notOnThisOutput(needed: 6, available: 2)) { _ = try surround.retargeted(toDevice: "x", outputChannels: 2) }
    }
}
