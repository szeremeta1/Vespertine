// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
import XCTest
#if !LAYOUT_STANDALONE
@testable import VespertineRemote
#endif

final class AdaptiveLayoutTests: XCTestCase {
    func testRegularWidthGetsSidebar() {
        for width in [CGFloat(600), 744, 768, 820, 834, 1024, 1194, 1366] {
            XCTAssertTrue(RemoteLayout.usesSidebar(regularWidth: true, width: width))
        }
    }
    func testCompactAndNarrowWindowsGetTabs() {
        for width in [CGFloat(320), 375, 402, 430, 440, 507, 599] {
            XCTAssertFalse(RemoteLayout.usesSidebar(regularWidth: true, width: width))
            XCTAssertFalse(RemoteLayout.usesSidebar(regularWidth: false, width: width))
        }
        XCTAssertFalse(RemoteLayout.usesSidebar(regularWidth: false, width: 1024))
    }
    func testPlayerOnlyUsesColumnsWhenBothColumnsFit() {
        XCTAssertTrue(RemoteLayout.playerColumns(width: 1000, height: 700, accessibilityText: false))
        XCTAssertTrue(RemoteLayout.playerColumns(width: 850, height: 300, accessibilityText: false))
        XCTAssertFalse(RemoteLayout.playerColumns(width: 600, height: 300, accessibilityText: false))
        XCTAssertFalse(RemoteLayout.playerColumns(width: 1000, height: 240, accessibilityText: false))
        XCTAssertFalse(RemoteLayout.playerColumns(width: 744, height: 1024, accessibilityText: false))
        XCTAssertFalse(RemoteLayout.playerColumns(width: 1000, height: 700, accessibilityText: true))
    }
    func testArtworkFitsResizingWindows() {
        for width in stride(from: CGFloat(240), through: 1440, by: 20) {
            for height in stride(from: CGFloat(240), through: 1400, by: 40) {
                let columns = RemoteLayout.playerColumns(width: width, height: height, accessibilityText: false)
                let side = RemoteLayout.coverSide(width: width, height: height, columns: columns)
                XCTAssertGreaterThanOrEqual(side, 0)
                XCTAssertLessThanOrEqual(side, width - 48)
                XCTAssertLessThanOrEqual(side, 520)
                if columns {
                    XCTAssertLessThanOrEqual(side, height - 24)
                    XCTAssertGreaterThanOrEqual(width - 48 - 32 - side, 300)
                }
            }
        }
    }
    func testAlbumGridAdaptsWithoutTinyCovers() {
        XCTAssertEqual(RemoteLayout.albumColumns(width: 320, accessibilityText: false), 1)
        XCTAssertEqual(RemoteLayout.albumColumns(width: 440, accessibilityText: false), 2)
        XCTAssertEqual(RemoteLayout.albumColumns(width: 820, accessibilityText: false), 4)
        XCTAssertEqual(RemoteLayout.albumColumns(width: 1200, accessibilityText: false), 6)
        XCTAssertEqual(RemoteLayout.albumColumns(width: 440, accessibilityText: true), 1)
        XCTAssertEqual(RemoteLayout.albumColumns(width: 820, accessibilityText: true), 3)
    }
    func testLibraryDestinationsMapToOneCompactTab() {
        for place in RemoteDestination.allCases {
            XCTAssertEqual(place.compactTab, place.isLibrary ? .library : place)
        }
        XCTAssertEqual(RemoteDestination.starting(at: "album"), .library)
        XCTAssertEqual(RemoteDestination.starting(at: "coverFlow"), .library)
        XCTAssertEqual(RemoteDestination.starting(at: "artists"), .artists)
        XCTAssertEqual(RemoteDestination.starting(at: nil), .nowPlaying)
    }
}
