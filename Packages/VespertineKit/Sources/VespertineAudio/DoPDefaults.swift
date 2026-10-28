//
// Vespertine — DACs known to take DoP, so DSD plays natively on them without a trip to Settings.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// DoP stays a per-device choice; this only sets the starting point. A device listed here has DoP on until the
/// user turns it off (an explicit off is remembered and wins). Devices not listed stay off until switched on.
public enum DoPDefaults {
    /// Core Audio UIDs of USB DACs start `AppleUSBAudioEngine:<vendor>:<product>:`; the serial and interface after
    /// that differ per unit and port, so the entries match that prefix.
    ///
    /// - FiiO K11: DoP confirmed on hardware (docs/VERIFICATION.md).
    /// - Fosi Audio ZD3 (XMOS XU316, USB ID 152a:889b): lists 44.1 kHz to 768 kHz at 24 and 32 bit, so the DoP
    ///   carriers for DSD64, DSD128 and DSD256 exist; the vendor lists DSD512, which macOS can't carry (it would
    ///   need a 1411.2 kHz carrier). See docs/DEVICES.md for what was checked on hardware.
    static let knownDoPPrefixes = [
        "AppleUSBAudioEngine:FIIO:FiiO K11:",
        "AppleUSBAudioEngine:XMOS:Fosi Audio ZD3:",
    ]

    public static func isKnownDoP(uid: String) -> Bool {
        knownDoPPrefixes.contains { uid.hasPrefix($0) }
    }

    /// Whether DoP is on for `uid`, given the user's explicit on and off choices.
    public static func isEnabled(uid: String, on: Set<String>, off: Set<String>) -> Bool {
        if off.contains(uid) { return false }
        return on.contains(uid) || isKnownDoP(uid: uid)
    }

    /// The set the engine and device list use: explicit ons, plus connected known DACs the user hasn't turned off.
    public static func resolve(on: Set<String>, off: Set<String>, connected: Set<String>) -> Set<String> {
        var result = on.subtracting(off)
        for uid in connected where isEnabled(uid: uid, on: on, off: off) { result.insert(uid) }
        return result
    }
}
