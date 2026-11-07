import Foundation
import Testing
import VespertineAudio
@testable import Vespertine

/// Speaker groups in the app: behind a switch (Settings › Playback) that is off for everyone, nothing read or written until it is on, and a
/// small model over the saved groups for the settings list.
@Suite("Speaker groups switch and list", .serialized) @MainActor
struct SpeakerGroupsFlagTests {
    private func scratch() throws -> (root: URL, defaults: UserDefaults, suite: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-groups-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = root.appendingPathComponent("defaults.plist").path
        return (root, try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func group(_ name: String) -> SpeakerGroup {
        let a = SpeakerGroup.Member(deviceUID: "dac-a", name: "Fosi ZD3", channelCount: 2)
        let b = SpeakerGroup.Member(deviceUID: "dac-b", name: "FiiO K11", channelCount: 2)
        return SpeakerGroup(name: name, members: [a, b], clockLeaderUID: "dac-a")
    }

    @Test("Off for a new install and for an upgrade, and turning the app on and off writes nothing by itself")
    func offByDefault() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set(true, forKey: "setupCompleted")
        defaults.set(true, forKey: "exclusiveMode")
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(!settings.speakerGroupsFeature)
        #expect(defaults.persistentDomain(forName: suite)?["speakerGroupsFeature"] == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Speaker Groups.json").path))
        // The engine settings are exactly what they were without the feature.
        settings.speakerGroupsFeature = true
        #expect(AppSettings(defaults: defaults, dataDirectory: root).speakerGroupsFeature)
        settings.speakerGroupsFeature = false
        #expect(!AppSettings(defaults: defaults, dataDirectory: root).speakerGroupsFeature)
    }

    @Test("The list starts empty, keeps what is added, duplicates and removes, and a new launch finds them")
    func listPersists() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = SpeakerGroupsModel(directory: root)
        #expect(model.groups.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Speaker Groups.json").path))
        let dorm = group("Dorm")
        model.upsert(dorm)
        #expect(model.groups.map(\.name) == ["Dorm"])
        model.duplicate(dorm.id)
        #expect(model.groups.map(\.name).count == 2)
        #expect(Set(model.groups.map(\.id)).count == 2)
        let again = SpeakerGroupsModel(directory: root)
        #expect(again.groups.map(\.id) == model.groups.map(\.id))
        again.remove(dorm.id)
        #expect(SpeakerGroupsModel(directory: root).groups.count == 1)
        #expect(model.lastError == nil && again.lastError == nil)
    }

    @Test("Groups from a newer version are kept in the file when this version saves")
    func keepsUnreadable() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = SpeakerGroupStore(directory: root)
        try store.save([group("Dorm")], unreadable: [["schemaVersion": 99, "name": "From the future"]])
        let model = SpeakerGroupsModel(directory: root)
        #expect(model.groups.count == 1 && model.unreadableCount == 1)
        model.upsert(group("Second"))
        #expect(SpeakerGroupsModel(directory: root).unreadableCount == 1)
    }

    @Test("A row says what the group is made of and whether it is ready")
    func summary() {
        let ready = group("Dorm")
        #expect(SpeakerGroupsModel.summary(ready) == "Fosi ZD3 + FiiO K11 · 4 channels")
        #expect(SpeakerGroupsModel.problem(ready) == nil)
        var bad = group("Dorm")
        bad.members.removeLast()
        #expect(SpeakerGroupsModel.problem(bad) == "A group needs at least two outputs.")
    }

    @Test("A finished draft becomes a saved group, an unfinished one saves nothing, and a new launch finds it")
    func createFromDraft() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = SpeakerGroupsModel(directory: root)
        var draft = SpeakerGroupDraft(name: "Dorm quad")
        #expect(model.create(draft) == nil && model.groups.isEmpty)
        func candidate(_ uid: String, _ name: String) -> GroupCandidate {
            GroupCandidate(uid: uid, name: name, channels: 2, transport: .usb, eligibility: .ok)
        }
        draft.toggle(candidate("dac-a", "Fosi ZD3"))
        draft.toggle(candidate("dac-b", "FiiO K11"))
        let made = try #require(model.create(draft))
        #expect(model.groups.map(\.id) == [made.id] && made.isValid)
        #expect(SpeakerGroupsModel(directory: root).groups.map(\.name) == ["Dorm quad"])
    }

    @Test("The engine hears of saved groups only while the switch is on, and a group can be the chosen output")
    func engineSettingsGate() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set(true, forKey: "setupCompleted")
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let dorm = group("Dorm")
        #expect(settings.engineSettings(groups: [dorm]).speakerGroups.isEmpty, "off: none reach the engine, whatever is saved")
        #expect(settings.engineSettings().speakerGroups.isEmpty)
        settings.speakerGroupsFeature = true
        settings.selectedDeviceUID = dorm.outputUID
        let engine = settings.engineSettings(groups: [dorm])
        #expect(engine.speakerGroups == [dorm] && engine.deviceUID == dorm.outputUID)
        #expect(engine.group(forOutputUID: engine.deviceUID)?.name == "Dorm")
    }

    @Test("A change to the list tells the engine's owner after it is written")
    func changeNotifies() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = SpeakerGroupsModel(directory: root)
        var calls = 0
        model.onChange = { calls += 1 }
        model.upsert(group("Dorm"))
        model.remove(model.groups[0].id)
        #expect(calls == 2)
    }
}
