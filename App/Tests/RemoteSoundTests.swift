import Foundation
import Testing
import VespertineAudio
import VespertineRemoteProtocol
@testable import Vespertine

/// The sound of an output as a phone sees and sets it: the same presets, profiles and choices the output panel has, kept
/// in the same settings, and nothing a phone sends can choose what this Mac doesn't have.
@Suite("Remote sound settings", .serialized) @MainActor
struct RemoteSoundTests {
    private func scratch() throws -> (root: URL, defaults: UserDefaults, suite: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-remote-sound-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = root.appendingPathComponent("defaults.plist").path
        return (root, try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func profile(_ name: String, device: String) -> RoomProfile {
        let filters = RoomFilterSet(version: 1, channels: [.left: [EQBand(kind: .peak, frequency: 60, gainDB: -6, q: 3)], .right: []], preampDB: 0)
        return RoomProfile(id: UUID(), name: name, createdAt: Date(timeIntervalSince1970: 1_793_000_000), sessionID: UUID(), deviceUID: device,
                           layout: .stereo, channelMap: .standard(.stereo), micSerial: "1", calibrationSHA256: nil, target: .flat, filters: filters)
    }

    @Test("The equalizer lists the saved presets, and a phone's choice is the output's own, kept like one made at the Mac")
    func equalizer() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let warm = EQPreset(name: "Warm", bands: [EQBand()]), night = EQPreset(name: "Late Night", bands: [EQBand()])
        settings.eqPresets = [warm, night]

        let start = RemoteSound.equalizer(for: "dac", settings: settings)
        #expect(start.presets == [SoundChoice(id: warm.id.uuidString, name: "Warm"), SoundChoice(id: night.id.uuidString, name: "Late Night")])
        #expect(start.selected == nil)

        #expect(RemoteSound.setEqualizer(night.id.uuidString, for: "dac", settings: settings))
        #expect(settings.eqPreset(for: "dac")?.id == night.id)
        #expect(RemoteSound.equalizer(for: "dac", settings: settings).selected == night.id.uuidString)
        // Each output has its own: the other one is untouched.
        #expect(RemoteSound.equalizer(for: "headphones", settings: settings).selected == nil)
        #expect(AppSettings(defaults: defaults, dataDirectory: root).eqPreset(for: "dac")?.id == night.id)

        // A preset this Mac doesn't have (deleted since the phone listed it) is refused and the choice stays.
        #expect(!RemoteSound.setEqualizer(UUID().uuidString, for: "dac", settings: settings))
        #expect(!RemoteSound.setEqualizer("not an id", for: "dac", settings: settings))
        #expect(settings.eqPreset(for: "dac")?.id == night.id)

        #expect(RemoteSound.setEqualizer(nil, for: "dac", settings: settings))
        #expect(settings.eqPreset(for: "dac") == nil)
    }

    @Test("Why the equalizer isn't in the sound is said only while a preset is chosen")
    func equalizerBypass() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let warm = EQPreset(name: "Warm", bands: [EQBand()])
        settings.eqPresets = [warm]
        #expect(RemoteSound.equalizer(for: "dac", settings: settings, bypassed: "Not applied").bypassed == nil)
        settings.setEQPreset(warm.id, for: "dac")
        #expect(RemoteSound.equalizer(for: "dac", settings: settings, bypassed: "Not applied").bypassed == "Not applied")
    }

    @Test("Room correction offers only the profiles measured on that output; off keeps the choice")
    func roomCorrection() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let desk = settings.saveRoomProfile(profile("Desk", device: "dac")), sofa = settings.saveRoomProfile(profile("Sofa", device: "dac"))
        let kitchen = settings.saveRoomProfile(profile("Kitchen", device: "speakers"))

        let start = RemoteSound.room(for: "dac", settings: settings)
        #expect(Set(start.profiles.map(\.id)) == [desk.id.uuidString, sofa.id.uuidString])
        #expect(start.selected == nil)
        #expect(RemoteSound.room(for: "headphones", settings: settings).profiles.isEmpty)

        #expect(RemoteSound.setRoom(sofa.id.uuidString, for: "dac", settings: settings))
        #expect(settings.roomProfile(for: "dac")?.id == sofa.id)
        let on = RemoteSound.room(for: "dac", settings: settings)
        #expect(on.selected == sofa.id.uuidString && on.chosen == sofa.id.uuidString)

        // A profile measured on another output, or one this Mac doesn't have, is refused and nothing changes.
        #expect(!RemoteSound.setRoom(kitchen.id.uuidString, for: "dac", settings: settings))
        #expect(!RemoteSound.setRoom(UUID().uuidString, for: "dac", settings: settings))
        #expect(settings.roomProfile(for: "dac")?.id == sofa.id)
        #expect(settings.roomProfile(for: "speakers") == nil)

        #expect(RemoteSound.setRoom(nil, for: "dac", settings: settings))
        let off = RemoteSound.room(for: "dac", settings: settings)
        #expect(off.selected == nil && off.chosen == sofa.id.uuidString)
        #expect(AppSettings(defaults: defaults, dataDirectory: root).chosenRoomProfile(for: "dac")?.id == sofa.id)
    }
}
