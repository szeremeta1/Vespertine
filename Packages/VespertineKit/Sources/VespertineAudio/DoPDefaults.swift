//
// Vespertine: DACs known to take DoP, so DSD plays natively on them without a trip to Settings.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// DoP stays a per-device choice; this only sets the starting point. A device on the known-DoP list has DoP on until the
/// user turns it off (an explicit off is remembered and wins). Devices not listed stay off until switched on, or until
/// the one-tap test (`DoPTestSession`) says the DAC plays DoP. The list itself, with the source of every entry, is
/// `Resources/dop-dacs.json`.
public enum DoPDefaults {
    /// Whether `uid` is a DAC on the known-DoP list (`DoPDACList`, bundled and updated online), matched by the USB vendor
    /// and model names in the UID. Core Audio UIDs of USB DACs look like `AppleUSBAudioEngine:<vendor>:<product>:<serial>:<n>`;
    /// the serial and interface differ per unit and port and are never looked at.
    public static func isKnownDoP(uid: String) -> Bool {
        isKnownDoP(USBIdentity.identity(forUID: uid))
    }

    /// The same, also by USB vendor and product ID when the identity carries them.
    public static func isKnownDoP(_ identity: DoPDeviceIdentity, list: DoPDACList? = nil) -> Bool {
        (list ?? DoPDACListStore.shared.list).knownDAC(for: identity) != nil
    }

    /// Whether DoP is on for `uid`, given the user's explicit on and off choices.
    public static func isEnabled(uid: String, on: Set<String>, off: Set<String>) -> Bool {
        isEnabled(USBIdentity.identity(forUID: uid), on: on, off: off)
    }

    public static func isEnabled(_ identity: DoPDeviceIdentity, on: Set<String>, off: Set<String>, list: DoPDACList? = nil) -> Bool {
        if off.contains(identity.uid) { return false }
        return on.contains(identity.uid) || isKnownDoP(identity, list: list)
    }

    /// The set the engine and device list use: explicit ons, plus connected known DACs the user hasn't turned off.
    public static func resolve(on: Set<String>, off: Set<String>, connected: Set<String>) -> Set<String> {
        resolve(on: on, off: off, connectedDevices: connected.map { USBIdentity.identity(forUID: $0) })
    }

    public static func resolve(on: Set<String>, off: Set<String>, connectedDevices: [DoPDeviceIdentity], list: DoPDACList? = nil) -> Set<String> {
        var result = on.subtracting(off)
        for device in connectedDevices where isEnabled(device, on: on, off: off, list: list) { result.insert(device.uid) }
        return result
    }
}
