//
// Vespertine — what the Nomad's media widget is told, and when.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineNomad

/// Records what the feed sends, standing in for the keyboard.
final class RecordingPort: NomadWidgetPort, @unchecked Sendable {
    struct Info: Equatable { var title: String?, artist: String?, elapsed: Int?, duration: Int?, isPlaying: Bool? }
    private let lock = NSLock()
    private var _infos: [Info] = []
    private var _artworks: [Data] = []
    private var _failNext = 0
    /// How long each call takes, like a keyboard that answers slowly.
    var latency: Duration = .zero
    var infos: [Info] { lock.withLock { _infos } }
    var artworks: [Data] { lock.withLock { _artworks } }
    /// The next `n` info calls fail.
    func failInfo(next n: Int) { lock.withLock { _failNext = n } }

    func sendInfo(title: String?, artist: String?, elapsed: Int?, duration: Int?, isPlaying: Bool?) async throws {
        if latency > .zero { try await Task.sleep(for: latency) }
        let fail: Bool = lock.withLock { if _failNext > 0 { _failNext -= 1; return true }; return false }
        if fail { throw NomadError.timeout }
        lock.withLock { _infos.append(Info(title: title, artist: artist, elapsed: elapsed, duration: duration, isPlaying: isPlaying)) }
    }
    func sendArtwork(_ image: Data) async throws {
        if latency > .zero { try await Task.sleep(for: latency) }
        lock.withLock { _artworks.append(image) }
    }
}

@Suite("Nomad media feed")
struct NomadFeedTests {
    private func track(_ title: String = "Where It Hurts", artist: String = "GENDEMA", playing: Bool = true, position: TimeInterval = 10,
                       art: String? = "cover-1", anchor: Date = .now) -> NomadNowPlaying {
        NomadNowPlaying(title: title, artist: artist, format: "24/96", duration: 215, position: position, anchor: anchor, isPlaying: playing, artworkID: art)
    }

    private func waitForArtwork(_ port: RecordingPort, count: Int) async {
        for _ in 0..<100 where port.artworks.count < count { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func feed(_ port: RecordingPort, style: NomadFormatStyle = .suffix) -> NomadMediaFeed {
        NomadMediaFeed(link: port, style: style, coverDelay: .milliseconds(5)) { id in Data(id.utf8) }
    }

    @Test func nothingIsSentWithoutAKeyboard() async {
        let port = RecordingPort()
        let feed = feed(port)
        await feed.update(track())
        #expect(port.infos.isEmpty && port.artworks.isEmpty)
    }

    @Test func connectingSendsTheCurrentTrackAndItsCover() async {
        let port = RecordingPort()
        let feed = feed(port)
        await feed.update(track())
        await feed.handle(.connected(name: "Nomad [E] 2"))
        await waitForArtwork(port, count: 1)
        #expect(port.infos.count == 1)
        #expect(port.infos[0] == .init(title: "Where It Hurts", artist: "GENDEMA - 24/96", elapsed: 10, duration: 215, isPlaying: true))
        #expect(port.artworks == [Data("cover-1".utf8)])
    }

    @Test func anUnchangedTrackIsNotSentAgain() async {
        let port = RecordingPort()
        let feed = feed(port)
        await feed.handle(.connected(name: "x"))
        let now = Date()
        await feed.update(track(anchor: now))
        await feed.update(track(anchor: now))
        await feed.update(track(anchor: now))
        await waitForArtwork(port, count: 1)
        #expect(port.infos.count == 1)
        #expect(port.artworks.count == 1)
    }

    @Test func pausingSendsOnlyTheStateAndTheClock() async {
        let port = RecordingPort()
        let feed = feed(port)
        await feed.handle(.connected(name: "x"))
        let now = Date()
        await feed.update(track(anchor: now))
        await feed.update(track(playing: false, position: 12, anchor: now))
        #expect(port.infos.last == .init(title: nil, artist: nil, elapsed: 12, duration: nil, isPlaying: false))
    }

    @Test func aSeekSendsTheNewPosition() async {
        let port = RecordingPort()
        let feed = feed(port)
        await feed.handle(.connected(name: "x"))
        let now = Date()
        await feed.update(track(position: 10, anchor: now))
        await feed.update(track(position: 120, anchor: now))
        #expect(port.infos.last?.elapsed == 120)
    }

    @Test func aNewTrackSendsItsTextAndOnlyItsOwnCover() async {
        let port = RecordingPort()
        let feed = feed(port)
        await feed.handle(.connected(name: "x"))
        await feed.update(track())
        await waitForArtwork(port, count: 1)
        await feed.update(track("Next Song", artist: "GENDEMA", position: 0, art: "cover-2"))
        await waitForArtwork(port, count: 2)
        #expect(port.infos.last?.title == "Next Song")
        #expect(port.infos.last?.artist == "GENDEMA - 24/96")   // a text update is always the whole track
        #expect(port.artworks == [Data("cover-1".utf8), Data("cover-2".utf8)])
    }

    @Test func stoppingTellsTheKeyboardOnce() async {
        let port = RecordingPort()
        let feed = feed(port)
        await feed.handle(.connected(name: "x"))
        await feed.update(track())
        await feed.update(nil)
        await feed.update(nil)
        #expect(port.infos.filter { $0.isPlaying == false }.count == 1)
    }

    @Test func anIdleKeyboardStaysUntouchedSoOtherPlayersKeepTheirCard() async {
        let port = RecordingPort()
        let feed = feed(port)
        await feed.handle(.connected(name: "x"))
        await feed.update(nil)
        await feed.handle(.mediaScreen(wantsData: true))
        await feed.handle(.mediaScreen(wantsData: false))
        #expect(port.infos.isEmpty && port.artworks.isEmpty)
    }

    @Test func reconnectingResendsEverything() async {
        let port = RecordingPort()
        let feed = feed(port)
        await feed.handle(.connected(name: "x"))
        await feed.update(track())
        await waitForArtwork(port, count: 1)
        await feed.handle(.disconnected)
        await feed.handle(.connected(name: "x"))
        await waitForArtwork(port, count: 2)
        #expect(port.infos.count == 2)
        #expect(port.infos[1].title == "Where It Hurts")
        #expect(port.artworks.count == 2)
    }

    @Test func openingTheMediaScreenSendsTheCurrentState() async {
        let port = RecordingPort()
        let feed = feed(port)
        await feed.handle(.connected(name: "x"))
        await feed.update(track())
        await feed.handle(.mediaScreen(wantsData: true))
        #expect(port.infos.count == 2)
        #expect(port.infos[1].title == "Where It Hurts")   // the screen may have lost it
        await feed.handle(.mediaScreen(wantsData: false))
    }

    @Test func formatStyleOffLeavesTheArtistAlone() async {
        let port = RecordingPort()
        let feed = feed(port, style: .off)
        await feed.handle(.connected(name: "x"))
        await feed.update(track())
        #expect(port.infos[0].artist == "GENDEMA")
    }
}

@Suite("Nomad feed under load")
struct NomadFeedLoadTests {
    private func track(_ i: Int, art: Bool = true) -> NomadNowPlaying {
        NomadNowPlaying(title: "Title \(i)", artist: "Artist \(i)", format: "24/96", duration: 200, position: 0, isPlaying: true,
                        artworkID: art ? "cover-\(i)" : nil)
    }

    /// Waits (up to `seconds`) for a condition, instead of guessing how long a loaded machine needs.
    private func until(_ seconds: Double = 10, _ condition: () -> Bool) async {
        for _ in 0..<Int(seconds * 100) where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func skippingFastAgainstASlowKeyboardEndsOnTheLastSongAndNeverMixesTracks() async {
        let port = RecordingPort()
        port.latency = .milliseconds(40)
        let feed = NomadMediaFeed(link: port, style: .suffix, coverDelay: .milliseconds(100)) { id in Data(id.utf8) }
        await feed.handle(.connected(name: "x"))
        for i in 0..<30 {
            Task { await feed.update(track(i)) }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let lastCover = Data("cover-29".utf8)
        await until { port.infos.last?.title == "Title 29" && port.artworks.last == lastCover }
        // Whatever was sent, a title always came with its own artist.
        for info in port.infos where info.title != nil {
            #expect(info.artist?.hasPrefix("Artist " + info.title!.dropFirst("Title ".count)) == true, "\(info)")
        }
        #expect(port.infos.last?.title == "Title 29")
        #expect(port.artworks.last == lastCover)
    }

    @Test func whatChangesWhileACallIsInFlightIsSentOnceAsTheLatestNotQueuedSongBySong() async {
        let port = GatedPort()
        let feed = NomadMediaFeed(link: port, style: .off, coverDelay: .milliseconds(5)) { _ in nil }
        await feed.handle(.connected(name: "x"))
        let first = Task { await feed.update(track(0, art: false)) }
        await until { port.isBlocked }                       // the first call is now stuck at the keyboard
        for i in 1...20 { await feed.update(track(i, art: false)) }   // each returns at once: a worker is running
        port.release()
        await first.value
        #expect(port.titles == ["Title 0", "Title 20"])      // not 21 calls
    }

    @Test func rapidTrackChangesSendOnlyTheCoverOfWhereTheySettle() async {
        let port = RecordingPort()
        let feed = NomadMediaFeed(link: port, style: .off, coverDelay: .milliseconds(400)) { id in Data(id.utf8) }
        await feed.handle(.connected(name: "x"))
        for i in 0..<5 { await feed.update(track(i)) }
        await until { !port.artworks.isEmpty }
        try? await Task.sleep(for: .milliseconds(600))       // anything else due would have gone by now
        #expect(port.artworks == [Data("cover-4".utf8)])
    }

    @Test func aFailedCallIsFollowedByTheWholeTrackNotAFragment() async {
        let port = RecordingPort()
        let feed = NomadMediaFeed(link: port, style: .suffix, coverDelay: .milliseconds(5)) { id in Data(id.utf8) }
        await feed.handle(.connected(name: "x"))
        await feed.update(track(1))
        port.failInfo(next: 1)
        await feed.update(track(2))                    // fails
        for _ in 0..<60 where port.infos.count < 2 { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(port.infos.last?.title == "Title 2")   // retried by itself, with the artist too
        #expect(port.infos.last?.artist == "Artist 2 - 24/96")
        await feed.handle(.disconnected)
    }

    @Test func aCoverThatFailsIsRetried() async {
        let port = FlakyCoverPort()
        let feed = NomadMediaFeed(link: port, style: .off, coverDelay: .milliseconds(5)) { id in Data(id.utf8) }
        await feed.handle(.connected(name: "x"))
        await feed.update(track(1))
        for _ in 0..<80 where port.sent.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(port.attempts >= 2)
        #expect(port.sent == [Data("cover-1".utf8)])
    }

    @Test func whileInputIsWritingTooTheTextIsSaidAgainAfterEachNewTrack() async {
        let port = RecordingPort()
        let feed = NomadMediaFeed(link: port, style: .suffix, coverDelay: .milliseconds(5)) { id in Data(id.utf8) }
        await feed.setContested(true)
        await feed.handle(.connected(name: "x"))
        await feed.handle(.mediaScreen(wantsData: true))
        await feed.update(track(1))
        // Input overwrites the artist ~1.3 s after a new track, so the feed repeats the whole text at about 1.6 s and 3.6 s.
        // A starved machine can wake it after both are due, and then one repeat covers both: so at least one, not exactly two.
        for _ in 0..<150 where port.infos.filter({ $0.title == "Title 1" }).count < 2 { try? await Task.sleep(for: .milliseconds(100)) }
        let full = port.infos.filter { $0.title == "Title 1" && $0.artist == "Artist 1 - 24/96" }
        #expect(full.count >= 2, "the first send, and a repeat after it")
        await feed.handle(.mediaScreen(wantsData: false))
        await feed.handle(.disconnected)
    }
}

/// Holds its first info call until released, like a keyboard busy with one call while the player moves on.
final class GatedPort: NomadWidgetPort, @unchecked Sendable {
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var _blocked = false
    private var _released = false
    private var _titles: [String] = []
    var isBlocked: Bool { lock.withLock { _blocked } }
    var titles: [String] { lock.withLock { _titles } }

    func release() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock { _released = true; defer { gate = nil }; return gate }
        waiting?.resume()
    }

    func sendInfo(title: String?, artist: String?, elapsed: Int?, duration: Int?, isPlaying: Bool?) async throws {
        let isFirst: Bool = lock.withLock { let first = _titles.isEmpty && !_blocked && !_released; if first { _blocked = true }; return first }
        if isFirst {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let done: Bool = lock.withLock { if _released { return true }; gate = c; return false }
                if done { c.resume() }
            }
        }
        lock.withLock { if let title { _titles.append(title) } }
    }
    func sendArtwork(_ image: Data) async throws {}
}

/// Fails the first cover upload, like a keyboard that didn't answer a chunk.
final class FlakyCoverPort: NomadWidgetPort, @unchecked Sendable {
    private let lock = NSLock()
    private var _attempts = 0
    private var _sent: [Data] = []
    var attempts: Int { lock.withLock { _attempts } }
    var sent: [Data] { lock.withLock { _sent } }
    func sendInfo(title: String?, artist: String?, elapsed: Int?, duration: Int?, isPlaying: Bool?) async throws {}
    func sendArtwork(_ image: Data) async throws {
        let n = lock.withLock { _attempts += 1; return _attempts }
        if n == 1 { throw NomadError.timeout }
        lock.withLock { _sent.append(image) }
    }
}

@Suite("Nomad text")
struct NomadTextTests {
    @Test func suffixFitsWhenShort() {
        #expect(NomadText.artistLine(artist: "GENDEMA", format: "24/96", style: .suffix) == "GENDEMA - 24/96")
    }

    @Test func longArtistsGiveWayBeforeTheFormat() {
        let line = NomadText.artistLine(artist: "The Dave Brubeck Quartet featuring Paul Desmond", format: "24/96", style: .suffix, budget: 28)
        #expect(line.hasSuffix(" - 24/96"))
        #expect(line.count <= 28)
        #expect(line.contains("…"))
    }

    @Test func noFormatOrOffMeansJustTheArtist() {
        #expect(NomadText.artistLine(artist: "A", format: nil, style: .suffix) == "A")
        #expect(NomadText.artistLine(artist: "A", format: "24/96", style: .off) == "A")
    }

    @Test func aTinyBudgetDropsTheFormatRatherThanTheName() {
        #expect(NomadText.artistLine(artist: "Radiohead", format: "DSD128", style: .suffix, budget: 10) == "Radiohead")
    }
}
