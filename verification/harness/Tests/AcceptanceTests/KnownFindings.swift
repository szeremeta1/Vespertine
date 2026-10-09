//
// Vespertine verification: Vespertine results already recorded in FINDINGS.md. Each entry turns that check's
// failure on Vespertine into a known issue; if it stops failing, the run fails until the entry is removed.
// SPDX-License-Identifier: GPL-3.0-or-later
//

enum KnownFindings {
    /// "group/check name" → finding ID in FINDINGS.md.
    static let byCheck: [String: String] = [:]

    static func finding(group: String, check: String) -> String? { byCheck["\(group)/\(check)"] }
}
