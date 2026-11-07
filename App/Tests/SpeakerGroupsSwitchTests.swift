import Foundation
import Testing
import VespertineAudio
@testable import Vespertine

/// The Settings › Playback switch that brings Speaker Groups (beta) into the app, like Transitions': one toggle and one line
/// of explanation, off by default; turning it on shows the groups list and builds the model behind the output list and the
/// engine, turning it off takes them away again, without a restart.
@Suite("Speaker Groups settings switch", .serialized) @MainActor
struct SpeakerGroupsSwitchTests {
    private func scratch() throws -> (root: URL, defaults: UserDefaults, suite: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-groupswitch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = root.appendingPathComponent("defaults.plist").path
        return (root, try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func group(_ name: String) -> SpeakerGroup {
        let a = SpeakerGroup.Member(deviceUID: "dac-a", name: "Fosi ZD3", channelCount: 2)
        let b = SpeakerGroup.Member(deviceUID: "dac-b", name: "FiiO K11", channelCount: 2)
        return SpeakerGroup(name: name, members: [a, b], clockLeaderUID: "dac-a")
    }

    @Test("The switch has a title that says beta and a one-line plain explanation")
    func switchExists() {
        #expect(SpeakerGroupsSwitch.title == "Speaker Groups (beta)")
        let line = SpeakerGroupsSwitch.explanation
        #expect(!line.isEmpty && !line.contains("\n"))
        #expect(line.localizedCaseInsensitiveContains("off"), "it says what off means")
    }

    @Test("Off, Settings shows the switch and its line and no group list; on, the list comes under them")
    func rowsFollowTheSwitch() {
        #expect(SpeakerGroupsSwitch.rows(featureOn: false) == [.toggle, .explanation])
        #expect(SpeakerGroupsSwitch.rows(featureOn: true) == [.toggle, .explanation, .groups])
    }

    @Test("A new install and an upgrade start with it off, and nothing is stored until it is touched")
    func offByDefault() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set(true, forKey: "setupCompleted")
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(!settings.speakerGroupsFeature)
        #expect(SpeakerGroupsSwitch.rows(featureOn: settings.speakerGroupsFeature) == [.toggle, .explanation])
        #expect(defaults.persistentDomain(forName: suite)?["speakerGroupsFeature"] == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Speaker Groups.json").path))
    }

    @Test("Turning it on stores it and builds the groups model; turning it off stores that and drops the model")
    func togglingShowsAndHidesTheGroups() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set(true, forKey: "setupCompleted")
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        var changes = 0

        let on = try #require(SpeakerGroupsSwitch.apply(true, to: settings, current: nil, onChange: { changes += 1 }))
        #expect(settings.speakerGroupsFeature)
        #expect(AppSettings(defaults: defaults, dataDirectory: root).speakerGroupsFeature, "a new launch finds it on")
        #expect(on.groups.isEmpty)
        // A change to the list reaches the owner of the model.
        on.upsert(group("Dorm"))
        #expect(changes == 1)

        // Turning it on again keeps the model it has.
        #expect(SpeakerGroupsSwitch.apply(true, to: settings, current: on, onChange: {}) === on)

        #expect(SpeakerGroupsSwitch.apply(false, to: settings, current: on, onChange: {}) == nil)
        #expect(!settings.speakerGroupsFeature)
        #expect(!AppSettings(defaults: defaults, dataDirectory: root).speakerGroupsFeature, "a new launch finds it off")
        // Off hands the engine no groups, whatever is saved ...
        #expect(settings.engineSettings(groups: on.groups).speakerGroups.isEmpty)
        // ... and the saved groups are still in the file when it goes back on.
        let back = try #require(SpeakerGroupsSwitch.apply(true, to: settings, current: nil, onChange: {}))
        #expect(back.groups.map(\.name) == ["Dorm"])
        #expect(settings.engineSettings(groups: back.groups).speakerGroups.count == 1)
    }

    @Test("Turning it off while a group is the chosen output lets go of that output; any other output stays")
    func offLeavesAChosenGroup() {
        let dorm = group("Dorm")
        #expect(!SpeakerGroupsSwitch.keepsOutput(dorm.outputUID, turningOnTo: false, groups: [dorm]))
        #expect(SpeakerGroupsSwitch.keepsOutput(dorm.outputUID, turningOnTo: true, groups: [dorm]))
        #expect(SpeakerGroupsSwitch.keepsOutput("some-dac", turningOnTo: false, groups: [dorm]))
        #expect(SpeakerGroupsSwitch.keepsOutput(nil, turningOnTo: false, groups: [dorm]))
    }
}
