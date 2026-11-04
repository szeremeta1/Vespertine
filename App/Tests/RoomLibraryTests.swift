import Foundation
import Testing
import VespertineAudio
@testable import Vespertine

/// The room correction library in the app: profiles saved by earlier versions carry over, the choice per output is
/// kept and applied to the engine, and a profile from a newer Vespertine isn't thrown away by saving.
@Suite("Room correction library", .serialized) @MainActor
struct RoomLibraryTests {
    private func scratch() throws -> (root: URL, defaults: UserDefaults, suite: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-room-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = root.appendingPathComponent("defaults.plist").path
        return (root, try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func profile(_ name: String, device: String = "zd3") -> RoomProfile {
        let filters = RoomFilterSet(version: 1, channels: [.left: [EQBand(kind: .peak, frequency: 60, gainDB: -6, q: 3)], .right: []], preampDB: 0)
        return RoomProfile(id: UUID(), name: name, createdAt: Date(timeIntervalSince1970: 1_793_000_000), sessionID: UUID(), deviceUID: device,
                           layout: .stereo, channelMap: .standard(.stereo), micSerial: "1", calibrationSHA256: nil, target: .flat, filters: filters)
    }

    @Test("Profiles and the one switched on, saved in the old preferences, come over and are written to the library file")
    func migratesPreferences() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let a = profile("Desk"), b = profile("Sofa")
        defaults.set(try RoomCorrectionCoding.encodeProfiles([a, b]), forKey: "roomProfiles")
        defaults.set(["zd3": b.id.uuidString], forKey: "roomAssignments")
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(settings.roomProfiles(for: "zd3").count == 2)
        #expect(settings.roomProfile(for: "zd3")?.id == b.id)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Room Profiles.json").path))
        // From here the file is the library: the preferences aren't read again.
        defaults.removeObject(forKey: "roomProfiles")
        let again = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(again.roomProfile(for: "zd3")?.id == b.id)
    }

    @Test("Each output plays its own choice, and the engine is given only the outputs that are on")
    func perOutputAndEngine() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let desk = settings.saveRoomProfile(profile("Desk")), kitchen = settings.saveRoomProfile(profile("Kitchen", device: "airplay"))
        settings.setRoomProfile(desk.id, for: "zd3")
        #expect(settings.roomProfile(for: "zd3")?.id == desk.id && settings.roomProfile(for: "airplay") == nil)
        settings.chooseRoomProfile(kitchen.id, for: "airplay")
        settings.setRoomProfile(nil, for: "zd3")
        #expect(settings.chosenRoomProfile(for: "zd3")?.id == desk.id, "off keeps the choice")
        let reloaded = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(reloaded.roomProfile(for: "zd3") == nil && reloaded.chosenRoomProfile(for: "zd3")?.id == desk.id)
        #expect(reloaded.chosenRoomProfile(for: "airplay")?.id == kitchen.id)
    }

    @Test("After a restart the engine gets exactly the corrections it had, per output, at the strength set; other outputs none")
    func engineAfterRestart() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let desk = settings.saveRoomProfile(profile("Desk")), sofa = settings.saveRoomProfile(profile("Sofa", device: "k11"))
        let copy = try settings.duplicateRoomProfile(desk.id)
        try settings.updateRoomProfile(copy.id) { $0.strength = 0.5 }
        settings.setRoomProfile(copy.id, for: "zd3")
        settings.setRoomProfile(sofa.id, for: "k11")
        let before = settings.engineSettings().roomCorrections
        #expect(before.count == 2 && before["zd3"]?.profileID == copy.id && before["k11"]?.profileID == sofa.id)
        #expect(before["zd3"]?.channels.first?.bands.first?.gainDB == -3, "half of the -6 dB band")
        let restarted = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(restarted.roomBook == settings.roomBook)
        #expect(restarted.engineSettings().roomCorrections == before)
        #expect(restarted.engineSettings().roomCorrections["airplay"] == nil)
    }

    @Test("Saving never drops a profile written by a newer Vespertine")
    func keepsNewerProfiles() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var objects = try #require(JSONSerialization.jsonObject(with: RoomCorrectionCoding.encodeProfiles([profile("Desk")])) as? [Any])
        objects.append(["schemaVersion": 99, "name": "Later"] as [String: Any])
        defaults.set(try JSONSerialization.data(withJSONObject: objects), forKey: "roomProfiles")
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        _ = settings.saveRoomProfile(profile("Another"))
        let text = try String(contentsOf: root.appendingPathComponent("Room Profiles.json"), encoding: .utf8)
        #expect(text.contains("Later") && text.contains("Another"))
    }

    @Test("A profile renamed or removed in the library is renamed or removed for good")
    func renameAndDelete() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let a = settings.saveRoomProfile(profile("Desk"))
        try settings.renameRoomProfile(a.id, to: "Desk, near field")
        let copy = try settings.duplicateRoomProfile(a.id)
        settings.deleteRoomProfile(a.id)
        let reloaded = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(reloaded.roomProfiles(for: "zd3").map(\.id) == [copy.id])
        #expect(reloaded.roomProfiles(for: "zd3").first?.name == "Desk, near field copy")
    }
}
