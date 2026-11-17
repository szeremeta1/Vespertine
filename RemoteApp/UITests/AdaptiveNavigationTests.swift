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
        // The demo plays on its pretend Mac whatever an earlier run left chosen, so no test makes a sound.
        app.launchArguments = ["-VTDemo", "YES", "-VTPlay", "YES", "-VTScreen", screen, "-VTVinyl", "NO", "-playsOnThisDevice", "NO"]
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

    /// The library lists what the Mac's sidebar lists: Genres, Recently Added and Songs beside the rest, and the sources.
    func testLibraryListsTheMacsSectionsAndSources() {
        launch(screen: "library")
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(sidebar("genres").waitForExistence(timeout: 15))
            XCTAssertTrue(sidebar("recentlyAdded").exists)
            XCTAssertTrue(sidebar("songs").exists)
            XCTAssertTrue(sidebar("source").waitForExistence(timeout: 10))
            sidebar("genres").tap()
        } else {
            XCTAssertTrue(element("library-genres").waitForExistence(timeout: 15))
            XCTAssertTrue(element("library-recentlyAdded").exists)
            XCTAssertTrue(element("library-songs").exists)
            XCTAssertTrue(app.staticTexts["Studio NAS"].waitForExistence(timeout: 10))
            element("library-genres").tap()
        }
        XCTAssertTrue(element("genres-grid").waitForExistence(timeout: 10))
        let jazz = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Jazz'")).firstMatch
        XCTAssertTrue(jazz.waitForExistence(timeout: 10))
    }

    /// A favorite the library has twice (a stereo file and a Dolby Atmos mix) is one row, with its copies a tap away.
    func testAFavoriteInTwoCopiesIsOneRowWithItsCopies() {
        launch(screen: "favorites")
        let copies = app.buttons["2 COPIES"]
        XCTAssertTrue(copies.waitForExistence(timeout: 15))
        // One row of the list (the mini player names the song too).
        XCTAssertEqual(app.cells.containing(NSPredicate(format: "label CONTAINS 'Harbor Lights'")).count, 1)
        copies.tap()
        XCTAssertTrue(app.navigationBars["Copies"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Dolby Atmos'")).firstMatch.waitForExistence(timeout: 5))
    }

    /// Screenshots of the Macs screen must never list real Macs that happen to be on the capture machine's network.
    func testScreenshotMacsListShowsOnlyMadeUpMacs() {
        app.launchArguments = ["-VTSamplePairing", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["Living Room iMac"].waitForExistence(timeout: 10))
        let pairSection = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'MacBook Pro' OR label ENDSWITH 'MacBook Air'"))
        XCTAssertEqual(pairSection.count, 0)
    }

    /// The demo notice bar shows in a normal demo, and is gone from App Store captures (-VTScreenshot YES), which keep the demo library.
    func testDemoNoticeIsHiddenOnlyForScreenshots() {
        launch()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Demo: a made-up library")).firstMatch.waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = ["-VTDemo", "YES", "-VTPlay", "YES", "-VTVinyl", "NO", "-VTScreenshot", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Demo: a made-up library")).firstMatch.exists)
        XCTAssertFalse(app.buttons["Leave Demo"].exists)
    }

    /// At the largest text size the demo bar is one line and a button, not half the screen; a tap on the line opens it.
    func testDemoNoticeStaysSmallAtTheLargestTextSize() {
        launch(screen: "output", largeText: true)
        let notice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Demo: a made-up library")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        let leave = app.buttons["Leave Demo"]
        XCTAssertTrue(leave.exists)
        let closed = notice.frame.height
        XCTAssertLessThan(leave.frame.maxY - notice.frame.minY, app.windows.firstMatch.frame.height * 0.2)
        notice.tap()
        if UIDevice.current.userInterfaceIdiom == .phone {
            // The bar opens over a moment: look until it has, for five seconds at most.
            var looks = 0
            while notice.frame.height <= closed * 1.5, looks < 20 {
                usleep(250_000)
                looks += 1
            }
            XCTAssertGreaterThan(notice.frame.height, closed * 1.5)
        }
        XCTAssertTrue(leave.exists)
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

    /// The last row of a list stops above the mini player, not under it, and Settings is reached from the top of Output.
    func testOutputsLastRowClearsTheMiniPlayerAndSettingsIsAtTheTop() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "The phone's tab layout.")
        launch(screen: "output")
        XCTAssertTrue(app.navigationBars["Output"].waitForExistence(timeout: 15))
        let mini = element("mini-player")
        XCTAssertTrue(mini.waitForExistence(timeout: 10))
        for _ in 0..<4 { app.swipeUp() }
        let last = app.cells.allElementsBoundByIndex.last { $0.exists && $0.frame.height > 0 }
        let row = try XCTUnwrap(last)
        XCTAssertLessThanOrEqual(row.frame.maxY, mini.frame.minY + 1, "the last row is under the mini player")
        for _ in 0..<4 { app.swipeDown() }
        element("output-gear").tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose Another Mac"].exists)
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

    /// Now Playing has no button for the record: a tap on the cover or the record is the switch, VoiceOver gets it as the
    /// element's action, and the choice is kept for the next launch.
    func testATapOnTheArtSwitchesBetweenTheCoverAndTheRecord() {
        launch()
        let art = app.descendants(matching: .any).matching(identifier: "now-playing-art").firstMatch
        XCTAssertTrue(art.waitForExistence(timeout: 10))
        XCTAssertEqual(art.label, "Cover")
        // The round button that used to sit on the cover is gone.
        XCTAssertFalse(app.buttons["Show a Record"].exists)
        XCTAssertFalse(app.buttons["Show the Cover"].exists)
        capture("cover-flat")
        art.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "now-playing-art").matching(NSPredicate(format: "label == %@", "Record")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Show the Cover"].exists)
        capture("cover-vinyl")
        // Remembered: a launch that doesn't say otherwise starts on the record.
        app.terminate()
        app.launchArguments = ["-VTDemo", "YES", "-VTPlay", "YES", "-VTScreen", "nowPlaying"]
        app.launch()
        let again = app.descendants(matching: .any).matching(identifier: "now-playing-art").firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 15))
        XCTAssertEqual(again.label, "Record")
        again.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "now-playing-art").matching(NSPredicate(format: "label == %@", "Cover")).firstMatch.waitForExistence(timeout: 5))
    }

    /// TestFlight AGWqTwVAvOJJl42tjue-P-M: dragging the position slider to the middle of a song and letting go moves the
    /// song there, and the knob stays there.
    func testDraggingThePositionSliderMidSongSeeksThere() throws {
        launch()
        let slider = app.sliders["Position"].firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        let before = try XCTUnwrap(Self.times(slider.value as? String))
        XCTAssertGreaterThan(before.duration, 60)
        // From the knob to the far part of the song, then let go.
        let here = before.position / before.duration
        let there = here < 0.5 ? 0.9 : 0.1
        let from = slider.coordinate(withNormalizedOffset: CGVector(dx: here, dy: 0.5))
        let to = slider.coordinate(withNormalizedOffset: CGVector(dx: there, dy: 0.5))
        from.press(forDuration: 0.2, thenDragTo: to)
        let near: (Double) -> Bool = { abs($0 - there * before.duration) < 0.15 * before.duration }
        let moved = expectation(for: NSPredicate { element, _ in
            Self.times((element as? XCUIElement)?.value as? String).map { near($0.position) } ?? false
        }, evaluatedWith: slider)
        wait(for: [moved], timeout: 5)
        capture("scrubbed")
        // And it stays: a few seconds on, the song plays on from where it was put, not from where it was.
        sleep(4)
        let after = try XCTUnwrap(Self.times(slider.value as? String))
        XCTAssertTrue(near(after.position - 4) || near(after.position), "at \(after.position) of \(after.duration), put at \(there * before.duration)")
    }

    /// "2:47 of 5:15" as (167, 315).
    private static func times(_ value: String?) -> (position: Double, duration: Double)? {
        func seconds(_ text: Substring) -> Double? {
            let parts = text.split(separator: ":").map { Double($0) }
            guard !parts.isEmpty, !parts.contains(nil) else { return nil }
            return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        }
        guard let words = value?.split(separator: " "), let first = words.first, let last = words.last,
              let position = seconds(first), let duration = seconds(last), duration > 0 else { return nil }
        return (position, duration)
    }

    /// Saves the screen next to the test results when VT_SHOTS names a folder.
    private func capture(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["VT_SHOTS"], !folder.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
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
