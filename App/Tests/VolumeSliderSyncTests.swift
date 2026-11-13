import Foundation
import Testing
import VespertineAudio
@testable import Vespertine

/// Dragging the digital volume slider calls `AppModel.syncEngine()` for every value, and that calls `SystemOutputModel.sync`.
/// In 1.1.0 `sync` asked macOS's service manager about the Sound Helper's launch agent (three or four XPC round trips) on the
/// main thread each time, so the slider stuttered. The helper is only looked at again when what is wanted of it changes.
@Suite("Volume slider and Mac Sound Output", .serialized) @MainActor
struct VolumeSliderSyncTests {
    private func scratch() throws -> (root: URL, defaults: UserDefaults, suite: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-volumesync-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = root.appendingPathComponent("defaults.plist").path
        return (root, try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func group(_ name: String) -> SpeakerGroup {
        let a = SpeakerGroup.Member(deviceUID: "dac-a", name: "Fosi ZD3", channelCount: 2)
        let b = SpeakerGroup.Member(deviceUID: "dac-b", name: "FiiO K11", channelCount: 2)
        return SpeakerGroup(name: name, members: [a, b], clockLeaderUID: "dac-a")
    }

    /// A model that writes only inside `root` and counts what it asks of the helper's registration.
    private func model(root: URL, defaults: UserDefaults, calls: Counter) -> SystemOutputModel {
        let model = SystemOutputModel(defaults: defaults, isolated: false, handOffDirectory: root)
        model.helperRunner = { _ in calls.value += 1 }
        return model
    }

    @MainActor final class Counter { var value = 0 }

    @Test("A drag of the volume slider (the same groups and choices, a new level each time) asks nothing of the helper's registration")
    func dragAsksNothing() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let calls = Counter()
        let output = model(root: root, defaults: defaults, calls: calls)
        let g = group("Living room")
        output.setChoice(SystemOutputChoice(published: true), for: g.id)
        let before = calls.value
        for tick in 0..<200 {
            var settings = EngineSettings()
            settings.speakerGroups = [g]
            settings.digitalVolumeDB = -40 + Double(tick) / 5
            output.sync(groups: [g], settings: settings)
        }
        #expect(calls.value - before <= 1, "200 slider ticks made \(calls.value - before) helper checks")
    }

    @Test("The helper is still looked at when a group is published or taken back, and when the snapshot changes")
    func changesStillReachTheHelper() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let calls = Counter()
        var wanted: [Bool] = []
        let output = SystemOutputModel(defaults: defaults, isolated: false, handOffDirectory: root)
        output.helperRunner = { wanted.append($0); calls.value += 1 }
        let g = group("Study")
        let settings = EngineSettings()
        output.sync(groups: [g], settings: settings)
        let afterFirst = calls.value
        #expect(afterFirst >= 1, "the first sync checks the helper (launch)")
        output.sync(groups: [g], settings: settings)
        #expect(calls.value == afterFirst, "the same inputs again: nothing")
        output.setChoice(SystemOutputChoice(published: true), for: g.id)   // snapshot changes
        #expect(calls.value > afterFirst, "publishing a group reaches the helper")
        let afterPublish = calls.value
        output.setChoice(SystemOutputChoice(published: false), for: g.id)
        #expect(calls.value > afterPublish, "taking it back reaches the helper")
    }
}
