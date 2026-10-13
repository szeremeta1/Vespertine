//
// Vespertine — localized text for the analysis results.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

// No string catalog of its own: on Apple platforms the text is looked up in the main bundle, which in the app is
// Vespertine.app (its Localizable.xcstrings carries these keys too). In command-line tools and tests there is no
// table, so the English text comes back unchanged. On Linux (`vespertine-analyze`) the text is always English.
#if canImport(Darwin)
func localized(_ value: String.LocalizationValue) -> String { String(localized: value) }
#else
func localized(_ value: String) -> String { value }
#endif

extension Locale {
    /// Fixed '.' decimals: the stored summaries and the server's output, which tests compare as text.
    static let analysisPOSIX = Locale(identifier: "en_US_POSIX")
}
