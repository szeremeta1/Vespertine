//
// Vespertine — speaker groups: volume. A group plays through a private aggregate, which has no volume of its own and which only this
// app can see, so two things that follow "the output" must skip it: the relay that carries the volume keys to a device held with
// exclusive access (it would read and write a device that has no volume, and move the Mac's volume and alert volume for nothing), and
// making the output the Mac's sound output (macOS would be handed a device other apps cannot see). Each DAC's own hardware volume
// is set once, by hand; the speakers' trims and an optional master volume are digital.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation

public enum GroupVolume {
    /// The device the volume-key relay should follow: `device`, when the relay is on and it is an ordinary output; never a group.
    public static func relayTarget(for device: OutputDevice?, enabled: Bool) -> AudioObjectID? {
        guard enabled, let device, !GroupOutput.isGroupOutput(device) else { return nil }
        return device.id
    }

    /// Whether playing on `device` may make it the Mac's sound output. A group may not.
    public static func mayBecomeSystemOutput(_ device: OutputDevice) -> Bool { !GroupOutput.isGroupOutput(device) }

    /// A level held to 0...1; nil for a number that isn't one.
    public static func clamped(_ level: Float) -> Float? { level.isFinite ? max(0, min(1, level)) : nil }

    public struct Member: Equatable, Identifiable, Sendable {
        public var uid: String
        public var name: String
        /// The DAC's own volume, 0...1; nil when it isn't connected or has no volume Core Audio can set.
        public var level: Float?
        public var id: String { uid }
    }

    /// Each member's own volume as the DAC has it now.
    public static func members(of group: SpeakerGroup) -> [Member] {
        group.members.map { Member(uid: $0.deviceUID, name: $0.name, level: level(ofDeviceUID: $0.deviceUID)) }
    }

    public static func level(ofDeviceUID uid: String) -> Float? {
        GroupAggregateDevice.deviceID(uid: uid).flatMap { DeviceControl.hardwareVolume($0) }
    }

    /// Sets a DAC's own volume. False when it isn't connected, has no volume Core Audio can set, or the level isn't a number.
    @discardableResult
    public static func setLevel(_ level: Float, ofDeviceUID uid: String) -> Bool {
        guard let value = clamped(level), let device = GroupAggregateDevice.deviceID(uid: uid), DeviceControl.hardwareVolume(device) != nil else { return false }
        DeviceControl.setHardwareVolume(device, value)
        return true
    }

    public static let note = "Each DAC's own volume is set once, here or on the DAC, and Vespertine never changes it by itself. The speakers' level trims and a master volume are digital: they stop playback being bit-perfect. The Mac's volume keys do not control a group."
}
