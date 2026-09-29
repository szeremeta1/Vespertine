//
// Vespertine — albums are dated by their original release, not the reissue in hand.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
@testable import VespertineLibrary

@Suite("Original release year")
struct OriginalYearTests {
    @Test("The original-date tag wins over a reissue's DATE", arguments: [
        (["ORIGINALDATE": "1980-07-25"], 2003, 1980),
        (["ORIGINALYEAR": "1975"], 2014, 1975),
        (["ORIGINAL DATE": "1969"], 2019, 1969),
        (["ORIGINAL YEAR": "1966"], nil, 1966),
        ([:], 2011, 2011),
        (["ORIGDATE": "2003-04-01"], 1977, 1977),        // BWF recording stamp, not a release date
        (["ORIGINALDATE": "2030"], 2020, 2020),          // an original can't be later than the release
        (["ORIGINALDATE": "unknown"], 1999, 1999),
    ] as [([String: String], Int?, Int?)])
    func originalYear(tags: [String: String], release: Int?, expected: Int?) {
        #expect(MetadataReader.originalYear(tags, releaseYear: release) == expected)
    }
}
