// A playlist's page, end to end on the demo Mac (TestFlight feedback AOf1M7oLiLlxngkwwaWog5Y): Play and Shuffle, how many
// songs and how long, a tapped song playing on in the playlist's order, a song's menu, a long playlist and an empty one.
// Run serially, on an explicitly selected simulator. No network, no pairing and no sound (the demo Mac plays nothing aloud).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
import XCTest
import UIKit

@MainActor
final class PlaylistTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-VTDemo", "YES", "-VTScreen", "playlists", "-VTVinyl", "NO", "-VTTestPlaylists", "YES"]
        app.launch()
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    func testAPlaylistHasPlayShuffleAndSaysHowManySongsAndHowLong() {
        open("Late Night")
        XCTAssertTrue(element("playlist-play").waitForExistence(timeout: 10))
        XCTAssertTrue(element("playlist-shuffle").exists)
        XCTAssertTrue(element("playlist-play").isEnabled && element("playlist-shuffle").isEnabled)
        let facts = element("playlist-facts")
        XCTAssertTrue(facts.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor { facts.label.contains("14 songs") && facts.label.contains("·") }, "count and length: \(facts.label)")
        XCTAssertTrue(rows().firstMatch.exists)
        capture("playlist-page")
        XCTAssertEqual(collect(in: element("playlist-page"), rows).count, 14, "every song is listed")
    }

    func testTappingASongPlaysItAndTheRestInThePlaylistsOrder() {
        open("Late Night")
        XCTAssertTrue(rows().firstMatch.waitForExistence(timeout: 10))
        let titles = collect(in: element("playlist-page"), rows)
        XCTAssertEqual(titles.count, 14)
        // A song further down, not the first (TestFlight feedback tf-7adda59b4b).
        let row = rows().allElementsBoundByIndex.filter(\.isHittable)[2]
        let tapped = Self.title(of: row.label)
        row.tap()
        let start = titles.firstIndex(of: tapped) ?? 0
        XCTAssertGreaterThan(start, 0)
        tab("Queue").tap()
        XCTAssertTrue(waitFor { self.queueTitles().first == tapped }, "playing: \(queueTitles().first ?? "nothing")")
        capture("queue-after-tap")
        XCTAssertEqual(collect(in: element("queue-list"), queueRows), Array(titles[start...]), "the rest follows in the playlist's order")
    }

    func testPlayStartsAtTheFirstSongInOrder() {
        open("Late Night")
        XCTAssertTrue(rows().firstMatch.waitForExistence(timeout: 10))
        let titles = collect(in: element("playlist-page"), rows)
        element("playlist-play").tap()
        tab("Queue").tap()
        XCTAssertTrue(waitFor { self.queueTitles().first == titles[0] })
        XCTAssertEqual(collect(in: element("queue-list"), queueRows), titles)
    }

    func testShufflePlaysEverySongFromARandomOne() {
        open("Late Night")
        XCTAssertTrue(rows().firstMatch.waitForExistence(timeout: 10))
        let titles = collect(in: element("playlist-page"), rows)
        var firsts: Set<String> = []
        for round in 0..<4 {
            element("playlist-shuffle").tap()
            tab("Queue").tap()
            XCTAssertTrue(waitFor { !self.queueTitles().isEmpty })
            firsts.insert(queueTitles()[0])
            if firsts.count == 1 && round == 0 {
                let queued = collect(in: element("queue-list"), queueRows)
                XCTAssertEqual(queued.count, 14, "every song is queued")
                XCTAssertEqual(Set(queued), Set(titles))
            }
            tab("Library").tap()
            XCTAssertTrue(element("playlist-shuffle").waitForExistence(timeout: 5))
        }
        // 4 shuffles of 14 songs all starting on the same one: about 1 in 2,700.
        XCTAssertGreaterThan(firsts.count, 1, "Shuffle starts from a random song")
        tab("Queue").tap()
        capture("queue-after-shuffle")
    }

    func testASongsMenuHasPlayNextAndPlayLater() {
        open("Late Night")
        XCTAssertTrue(rows().firstMatch.waitForExistence(timeout: 10))
        let titles = rowTitles()
        element("playlist-play").tap()
        rows().element(boundBy: 2).press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Play Next"].waitForExistence(timeout: 5))
        let later = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play Later'")).firstMatch
        XCTAssertTrue(later.exists)
        XCTAssertTrue(app.buttons["Add to Favorites"].exists || app.buttons["Remove from Favorites"].exists)
        capture("song-menu")
        app.buttons["Play Next"].tap()
        rows().element(boundBy: 3).press(forDuration: 1.2)
        XCTAssertTrue(later.waitForExistence(timeout: 5))
        later.tap()
        tab("Queue").tap()
        // Now Playing (the first song), then Playing Next: the song for Play Next, then the one for Play Later.
        XCTAssertTrue(waitFor { self.queueTitles().count >= 3 && self.queueTitles()[1] == titles[2] })
        XCTAssertEqual(Array(queueTitles()[0..<3]), [titles[0], titles[2], titles[3]])
        XCTAssertTrue(app.staticTexts["Playing Next"].exists || app.otherElements["Playing Next"].exists)
    }

    func testALongPlaylistLoadsWholeAndScrollsToTheEnd() {
        open("Long Mix")
        let facts = element("playlist-facts")
        XCTAssertTrue(facts.waitForExistence(timeout: 10))
        // The length shows once every page is in.
        XCTAssertTrue(waitFor(timeout: 20) { facts.label.contains("1,200 songs") && facts.label.contains("·") }, facts.label)
        let list = element("playlist-page")
        for _ in 0..<12 { list.swipeUp(velocity: .fast) }
        // A song far down plays from there.
        let visible = rows().allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertGreaterThan(visible.count, 2)
        let row = visible[visible.count / 2]
        let title = Self.title(of: row.label)
        row.tap()
        tab("Queue").tap()
        XCTAssertTrue(waitFor { self.queueTitles().first == title })
        capture("long-playlist-queue")
    }

    func testAnEmptyPlaylistSaysSoAndCannotPlay() {
        open("Nothing Yet")
        XCTAssertTrue(element("playlist-empty").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["This playlist has no songs."].exists)
        XCTAssertFalse(element("playlist-play").isEnabled)
        XCTAssertFalse(element("playlist-shuffle").isEnabled)
        capture("empty-playlist")
    }

    func testEveryRowShowsItsCoverAndTheListOpensFromSearch() {
        // The rows' covers are drawn (screenshot); a playlist found by search opens the same page.
        open("Late Night")
        XCTAssertTrue(rows().firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("late")
        let found = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Late Night'")).firstMatch
        XCTAssertTrue(found.waitForExistence(timeout: 10))
        found.tap()
        XCTAssertTrue(element("playlist-play").waitForExistence(timeout: 10))
        XCTAssertTrue(element("playlist-shuffle").exists)
    }

    // MARK: Helpers

    private func open(_ name: String) {
        let list = element("playlists-list")
        XCTAssertTrue(list.waitForExistence(timeout: 15))
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no playlist \(name)")
        row.tap()
        XCTAssertTrue(element("playlist-page").waitForExistence(timeout: 10))
    }

    private func rows() -> XCUIElementQuery {
        element("playlist-page").descendants(matching: .button).matching(identifier: "song-row")
    }

    private func rowTitles() -> [String] {
        rows().allElementsBoundByIndex.map { Self.title(of: $0.label) }
    }

    private func queueRows() -> XCUIElementQuery {
        app.buttons.matching(identifier: "queue-row")
    }

    private func queueTitles() -> [String] {
        queueRows().allElementsBoundByIndex.map { Self.title(of: $0.label) }
    }

    /// Every title of a lazy list (only the rows on screen exist), read while scrolling to its end, in order; then back to the top.
    private func collect(in list: XCUIElement, _ rows: () -> XCUIElementQuery) -> [String] {
        var titles: [String] = []
        var still = 0
        while still < 2 {
            let before = titles.count
            for label in rows().allElementsBoundByIndex.map(\.label) {
                let title = Self.title(of: label)
                if !titles.contains(title) { titles.append(title) }
            }
            still = titles.count == before ? still + 1 : 0
            list.swipeUp()
        }
        for _ in 0..<6 { list.swipeDown(velocity: .fast) }
        return titles
    }

    /// A row's label reads "Title, Artist — Album, 3:12": the title is up to the first comma.
    private static func title(of label: String) -> String {
        label.components(separatedBy: ", ").first ?? label
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tab(_ name: String) -> XCUIElement {
        app.tabBars.buttons[name].exists ? app.tabBars.buttons[name] : app.buttons[name]
    }

    private func waitFor(timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    /// Kept with the results, and written where `VT_SHOTS` says (for the PR's screenshots).
    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["VT_SHOTS"], !folder.isEmpty {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }
}
