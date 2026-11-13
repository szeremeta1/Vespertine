//
// Vespertine: the switch for "Play on this phone" while it is being built. Off unless turned on, so nothing a user can reach
// changes: the iPhone app stays a remote.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

public enum PhonePlayerFlag {
    public static let defaultsKey = "phonePlayerEnabled"
    public static let launchArgument = "-VespertinePhonePlayer"

    /// On when the UserDefaults key is set (Settings, a test build) or the app was launched with `-VespertinePhonePlayer YES`.
    public static func isEnabled(defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        if let at = arguments.firstIndex(of: launchArgument) {
            let value = at + 1 < arguments.count ? arguments[at + 1].uppercased() : "YES"
            return value == "YES" || value == "TRUE" || value == "1"
        }
        return defaults.bool(forKey: defaultsKey)
    }
}
