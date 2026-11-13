// Run serially, on an explicitly selected simulator. No network or real pairing required.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
import XCTest
import UIKit

@MainActor
final class AdaptiveNavigationTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app?.terminate()
        if (ProcessInfo.processInfo.environment["VT_CAPTURE_ORIENTATION"] ?? "").isEmpty {
            XCUIDevice.shared.orientation = .portrait
        }
    }

    private func launch(screen: String = "nowPlaying", width: Int? = nil, largeText: Bool = false) {
        app.launchArguments = ["-VTDemo", "YES", "-VTPlay", "YES", "-VTScreen", screen, "-VTVinyl", "NO"]
        if let width { app.launchArguments += ["-VTTestWindowWidth", "\(width)"] }
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        if screen == "nowPlaying" {
            XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 15))
        }
    }

    func testNativeLayoutAndNavigation() {
        launch()
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(element("regular-layout").exists)
            XCTAssertTrue(sidebar("queue").waitForExistence(timeout: 5))
            sidebar("queue").tap()
            XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 5))
            sidebar("library").tap()
            let firstAlbum = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Low Tide Lanterns'")).firstMatch
            XCTAssertTrue(firstAlbum.waitForExistence(timeout: 10))
            sidebar("output").tap()
            XCTAssertTrue(app.navigationBars["Output"].waitForExistence(timeout: 5))
        } else {
            XCTAssertTrue(element("compact-layout").exists)
            tab("Queue").tap()
            XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 5))
            tab("Library").tap()
            XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
        }
    }

    /// Screenshots of the Macs screen must never list real Macs that happen to be on the capture machine's network.
    func testScreenshotMacsListShowsOnlyMadeUpMacs() {
        app.launchArguments = ["-VTSamplePairing", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["Living Room iMac"].waitForExistence(timeout: 10))
        let pairSection = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'MacBook Pro' OR label ENDSWITH 'MacBook Air'"))
        XCTAssertEqual(pairSection.count, 0)
    }

    func testNarrowWindowUsesTabsNotSidebar() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad window-width harness")
        // Exercises real views constrained to 440 pt; this is not an OS Split View test, and the system still reports a
        // regular-width window here, so iPadOS draws its top tab pill (which overflows) instead of the bottom bar a real
        // 440 pt window would get. Only the choice of layout is checked; tapping the overflowing pill is not reliable here.
        launch(width: 440)
        XCTAssertTrue(element("compact-layout").exists)
        XCTAssertFalse(element("regular-layout").exists)
        XCTAssertFalse(sidebar("queue").exists)
        XCTAssertTrue(app.buttons["Pause"].exists)
    }

    func testRotationRetainsQueueAndControlsRemainReachable() {
        launch(screen: "queue")
        XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 15))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Clear"].isHittable)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.navigationBars["Queue"].exists)
    }

    func testLargeTypePlayerCanScrollToTransport() {
        launch(width: UIDevice.current.userInterfaceIdiom == .pad ? 440 : nil, largeText: true)
        let playPause = app.buttons.matching(NSPredicate(format: "label == 'Pause' OR label == 'Play'")).firstMatch
        for _ in 0..<5 where !playPause.isHittable { app.swipeUp() }
        XCTAssertTrue(playPause.isHittable)
        let before = playPause.label
        playPause.tap()
        XCTAssertTrue(app.buttons[before == "Pause" ? "Play" : "Pause"].waitForExistence(timeout: 5))
    }

    func testSetCaptureOrientation() throws {
        guard let orientation = ProcessInfo.processInfo.environment["VT_CAPTURE_ORIENTATION"], !orientation.isEmpty else {
            throw XCTSkip("Only used by the sequential capture runner")
        }
        XCUIDevice.shared.orientation = orientation == "landscape" ? .landscapeLeft : .portrait
    }

    func testCaptureBothOrientations() {
        launch()
        for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = orientation == .portrait ? "portrait" : "landscape"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    /// SwiftUI containers can surface as any element type, so look the identifier up among all of them.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The bottom tab bar on iPhone; the tabs are plain buttons wherever iPadOS draws them elsewhere.
    private func tab(_ name: String) -> XCUIElement {
        app.tabBars.buttons[name].exists ? app.tabBars.buttons[name] : app.buttons[name]
    }

    private func sidebar(_ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "sidebar-" + name).firstMatch
    }
}
