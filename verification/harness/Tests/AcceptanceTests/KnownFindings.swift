//
// Vespertine verification: results already explained elsewhere. KnownFindings: Vespertine failures recorded in
// FINDINGS.md. EquivalentMutants: mutants no check can kill, explained in REPORT.md. Each entry turns that failure
// into a known issue; if it stops failing, the run fails until the entry is removed.
// SPDX-License-Identifier: GPL-3.0-or-later
//

enum KnownFindings {
    /// "group/check name" → finding ID in FINDINGS.md.
    static let byCheck: [String: String] = [
        "BIT-PERFECT verdict/PCM: a rate or physical format that couldn't be read back is not trusted": "F-01",
    ]

    static func finding(group: String, check: String) -> String? { byCheck["\(group)/\(check)"] }
}

/// Mutants no check can kill because, on the reference implementation they wrap, they behave exactly like it. Each
/// entry says why; REPORT.md gives the reasoning. If a check kills one, the run fails until the entry is removed.
enum EquivalentMutants {
    static let byID: [String: String] = [
        "C-DST-001-g": "it shortens only frames that aren't fixtures, and the reference decoder (the fixtures' known "
            + "answers) decodes nothing else, so it never changes an output",
    ]
}
