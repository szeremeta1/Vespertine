import Foundation
import Testing
import VespertineAudio
@testable import Vespertine

/// The group editor's hardware/software volume choice, the default for a new group, and the Controls menu's volume commands on
/// Vespertine's own volume.
@Suite("Volume controls", .serialized) @MainActor
struct VolumeControlsAppTests {
    private func scratch() throws -> (root: URL, defaults: UserDefaults, suite: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-volumecontrols-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = root.appendingPathComponent("defaults.plist").path
        return (root, try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func group(_ name: String = "Quad") -> SpeakerGroup {
        let a = SpeakerGroup.Member(deviceUID: "dac-a", name: "Fosi ZD3", channelCount: 2)
        let b = SpeakerGroup.Member(deviceUID: "dac-b", name: "FiiO K11", channelCount: 2)
        return SpeakerGroup(name: name, members: [a, b], clockLeaderUID: "dac-a")
    }

    @Test("A new group starts on software volume; a choice already stored for it is kept")
    func newGroupDefault() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let fresh = group()
        #expect(!settings.usesAppVolume(fresh.outputUID))
        settings.startVolume(ofNew: fresh)
        #expect(settings.usesAppVolume(fresh.outputUID))
        #expect(settings.engineSettings().deviceDigitalVolumes[fresh.outputUID] == .some(0))

        let existing = group("Existing")
        settings.setUsesAppVolume(false, for: existing.outputUID)
        settings.startVolume(ofNew: existing)
        #expect(!settings.usesAppVolume(existing.outputUID), "a stored choice is never overwritten")
    }

    @Test("Creating or duplicating a group through the model gives it the software default; groups already saved are untouched")
    func modelHook() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let saved = group("Saved")
        let before = SpeakerGroupsModel(directory: root)
        before.upsert(saved)

        let groups = try #require(SpeakerGroupsSwitch.apply(true, to: settings, current: nil, onChange: {}))
        #expect(groups.groups.map(\.id) == [saved.id])
        #expect(!settings.usesAppVolume(saved.outputUID), "loading an existing group changes nothing")

        var draft = SpeakerGroupDraft(name: "New")
        for (uid, name) in [("dac-a", "Fosi ZD3"), ("dac-b", "FiiO K11")] {
            draft.toggle(GroupCandidate(uid: uid, name: name, channels: 2, transport: .usb, eligibility: .ok))
        }
        let created = try #require(groups.create(draft))
        #expect(settings.usesAppVolume(created.outputUID))
        groups.duplicate(saved.id)
        let copy = try #require(groups.groups.first { $0.id != saved.id && $0.id != created.id })
        #expect(settings.usesAppVolume(copy.outputUID))
        #expect(!settings.usesAppVolume(saved.outputUID))

        // A copy starts as the group it is a copy of, when that one has a choice stored.
        settings.setUsesAppVolume(false, for: created.outputUID)
        groups.duplicate(created.id)
        let second = try #require(groups.groups.first { $0.id != saved.id && $0.id != created.id && $0.id != copy.id })
        #expect(!settings.usesAppVolume(second.outputUID) && settings.appVolumeChoices[second.outputUID] == false)
    }

    @Test("The editor's two choices write the same per-output setting the transport bar uses")
    func choiceWritesSetting() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let g = group()
        #expect(GroupVolumeChoice.current(in: settings, for: g) == .hardware)
        GroupVolumeChoice.software.apply(to: settings, for: g)
        #expect(settings.appVolumeChoices[g.outputUID] == true && GroupVolumeChoice.current(in: settings, for: g) == .software)
        GroupVolumeChoice.hardware.apply(to: settings, for: g)
        #expect(settings.appVolumeChoices[g.outputUID] == false && GroupVolumeChoice.current(in: settings, for: g) == .hardware)
        #expect(settings.engineSettings().deviceDigitalVolumes[g.outputUID] == .some(nil))
        #expect(AppSettings(defaults: defaults, dataDirectory: root).appVolumeChoices[g.outputUID] == false)
    }

    @Test("Volume Up and Down move Vespertine's level for that output, mute remembers it, and it all survives a relaunch")
    func softwareSteps() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        settings.setUsesAppVolume(true, for: "HDMI")
        settings.setAppVolumeLevel(0.5, for: "HDMI")
        settings.applyVolume(.down, for: "HDMI")
        #expect(settings.appVolumeLevel(for: "HDMI") == 0.4375)
        #expect(settings.appVolumeLevel(for: "Other") == 1, "another output keeps its own level")

        settings.applyVolume(.mute, for: "HDMI")
        #expect(settings.appVolumeLevel(for: "HDMI") == 0 && settings.isMuted("HDMI"))
        #expect(settings.engineSettings().deviceDigitalVolumes["HDMI"] == .some(-120))
        let reloaded = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(reloaded.isMuted("HDMI"))
        reloaded.applyVolume(.mute, for: "HDMI")
        #expect(reloaded.appVolumeLevel(for: "HDMI") == 0.4375 && !reloaded.isMuted("HDMI"))
    }

    @Test("Moving the slider by hand after a mute forgets the old level")
    func sliderForgets() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        settings.setAppVolumeLevel(0.8, for: "HDMI")
        settings.applyVolume(.mute, for: "HDMI")
        settings.setAppVolumeLevel(0.2, for: "HDMI")
        #expect(!settings.isMuted("HDMI"))
        settings.applyVolume(.up, for: "HDMI")
        #expect(settings.appVolumeLevel(for: "HDMI") == 0.25)
    }
}
