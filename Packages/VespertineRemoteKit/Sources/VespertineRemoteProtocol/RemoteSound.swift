//
// Vespertine: what the Mac tells a remote about the sound of the output it plays to (equalizer, room correction, Spatial
// Audio, balance), for a remote to show and change.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//
// All of it is optional: a Mac from before these says nothing (`PlayerState.sound` is nil) and a remote then offers none of
// them. Each part is nil where the Mac's own output panel wouldn't show it for this output.
//

import Foundation

/// The sound settings of the output the Mac plays to, as its output panel has them.
public struct SoundState: Codable, Sendable, Equatable {
    public var equalizer: EqualizerState?
    public var room: RoomCorrectionState?
    public var spatial: SpatialState?
    public var balance: BalanceState?

    public init(equalizer: EqualizerState? = nil, room: RoomCorrectionState? = nil, spatial: SpatialState? = nil, balance: BalanceState? = nil) {
        self.equalizer = equalizer
        self.room = room
        self.spatial = spatial
        self.balance = balance
    }

    /// Nothing to show.
    public var isEmpty: Bool { equalizer == nil && room == nil && spatial == nil && balance == nil }
}

/// Something a remote picks by `id` and shows by `name` (an equalizer preset, a room profile).
public struct SoundChoice: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// As the listener named it on the Mac.
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct EqualizerState: Codable, Sendable, Equatable {
    /// The Mac's saved presets, in its order. A remote chooses among them; it doesn't edit one.
    public var presets: [SoundChoice]
    /// The preset this output plays with (`SoundChoice.id`); nil: off.
    public var selected: String?
    /// Why the chosen preset isn't in the sound of what is playing now (native DSD, a bitstream), in the Mac's words;
    /// nil while it is, or would be.
    public var bypassed: String?

    public init(presets: [SoundChoice], selected: String?, bypassed: String? = nil) {
        self.presets = presets
        self.selected = selected
        self.bypassed = bypassed
    }
}

public struct RoomCorrectionState: Codable, Sendable, Equatable {
    /// The profiles measured on this output, newest first. None: nothing to switch on (measuring is done at the Mac).
    public var profiles: [SoundChoice]
    /// The profile this output plays with; nil: off.
    public var selected: String?
    /// The profile it would play with switched on (kept while off); nil when none was ever chosen.
    public var chosen: String?

    public init(profiles: [SoundChoice], selected: String?, chosen: String?) {
        self.profiles = profiles
        self.selected = selected
        self.chosen = chosen
    }
}

/// How multichannel music plays on this output.
public enum SpatialModeValue: String, Codable, Sendable, Equatable, CaseIterable {
    /// A standard downmix, or every channel to its own speaker on a multichannel output.
    case off
    /// Virtual speakers fixed in front of the listener.
    case fixed
    /// Virtual speakers that stay put as the listener's head turns.
    case headTracked
}

public struct SpatialState: Codable, Sendable, Equatable {
    public var mode: SpatialModeValue
    /// "Spatialize stereo" (stereo and mono upmixed to 5.1); nil where the switch would do nothing with this output and
    /// mode, as the Mac hides it then.
    public var spatializeStereo: Bool?

    public init(mode: SpatialModeValue, spatializeStereo: Bool?) {
        self.mode = mode
        self.spatializeStereo = spatializeStereo
    }
}

public struct BalanceState: Codable, Sendable, Equatable {
    /// −1 (all left) … 0 (centered) … 1 (all right).
    public var value: Double
    /// Why balance isn't applied to what is playing (DoP, Spatial Audio, not stereo), in the Mac's words; nil while it
    /// is, or would be. The value is kept and shown either way.
    public var bypassed: String?

    public init(value: Double, bypassed: String? = nil) {
        self.value = value
        self.bypassed = bypassed
    }

    /// A value a remote may send: within −1…1, and the center for anything that isn't a number.
    public static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, -1), 1)
    }
}
