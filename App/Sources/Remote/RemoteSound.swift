//
// Vespertine: the sound of an output as a remote sees and changes it: its equalizer preset, its room correction and its
// Spatial Audio mode, read from and written to the same settings the output panel uses. (Balance needs what is playing,
// so the bridge builds it from the app model.)
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio
import VespertineRemoteProtocol

@MainActor
enum RemoteSound {
    /// The saved presets and the one `uid` plays with. `bypassed`: why it isn't in the sound of what is playing.
    static func equalizer(for uid: String, settings: AppSettings, bypassed: String? = nil) -> EqualizerState {
        let selected = settings.eqPreset(for: uid)
        return EqualizerState(presets: settings.eqPresets.map { SoundChoice(id: $0.id.uuidString, name: $0.name) },
                              selected: selected?.id.uuidString, bypassed: selected == nil ? nil : bypassed)
    }

    /// Chooses a saved preset for `uid`, or none (nil). False for a preset this Mac doesn't have: nothing changes.
    static func setEqualizer(_ preset: String?, for uid: String, settings: AppSettings) -> Bool {
        guard let preset else { settings.setEQPreset(nil, for: uid); return true }
        guard let found = settings.eqPresets.first(where: { $0.id.uuidString == preset }) else { return false }
        settings.setEQPreset(found.id, for: uid)
        return true
    }

    /// The profiles measured on `uid`, the one it plays with, and the one it would.
    static func room(for uid: String, settings: AppSettings) -> RoomCorrectionState {
        RoomCorrectionState(profiles: settings.roomProfiles(for: uid).map { SoundChoice(id: $0.id.uuidString, name: $0.name) },
                            selected: settings.roomProfile(for: uid)?.id.uuidString,
                            chosen: settings.chosenRoomProfile(for: uid)?.id.uuidString)
    }

    /// Switches room correction on for `uid` with one of its own profiles, or off (nil), which keeps the choice. False
    /// for a profile that wasn't measured on this output: nothing changes.
    static func setRoom(_ profile: String?, for uid: String, settings: AppSettings) -> Bool {
        guard let profile else { settings.setRoomProfile(nil, for: uid); return true }
        guard let found = settings.roomProfiles(for: uid).first(where: { $0.id.uuidString == profile }) else { return false }
        settings.setRoomProfile(found.id, for: uid)
        return true
    }

    /// The Spatial Audio mode `device` plays multichannel music with, and its Spatialize stereo switch where the output
    /// panel shows one.
    static func spatial(for device: OutputDevice, settings: AppSettings) -> SpatialState {
        let mode = settings.engineSettings().spatialMode(for: device)
        let offered = FormatPlanner.canSpatializeStereo(on: device.capabilities, spatial: mode)
        return SpatialState(mode: SpatialModeValue(rawValue: mode.rawValue) ?? .off,
                            spatializeStereo: offered ? settings.spatializeStereoUIDs.contains(device.uid) : nil)
    }

    static func setSpatialMode(_ mode: SpatialModeValue, for device: OutputDevice, settings: AppSettings) {
        settings.spatialModes[device.uid] = mode.rawValue
    }

    /// False where the output panel shows no such switch for `device` now: nothing changes.
    static func setSpatializeStereo(_ on: Bool, for device: OutputDevice, settings: AppSettings) -> Bool {
        guard spatial(for: device, settings: settings).spatializeStereo != nil else { return false }
        if on { settings.spatializeStereoUIDs.insert(device.uid) } else { settings.spatializeStereoUIDs.remove(device.uid) }
        return true
    }
}
