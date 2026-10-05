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
    var infos: [Info] { lock.withLock { _infos } }
    var artworks: [Data] { lock.withLock { _artworks } }

    func sendInfo(title: String?, artist: String?, elapsed: Int?, duration: Int?, isPlaying: Bool?) async throws {
        lock.withLock { _infos.append(Info(title: title, artist: artist, elapsed: elapsed, duration: duration, isPlaying: isPlaying)) }
    }
    func sendArtwork(_ image: Data) async throws { lock.withLock { _artworks.append(image) } }
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
        NomadMediaFeed(link: port, style: style) { id in Data(id.utf8) }
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
        #expect(port.infos.last?.artist == nil)   // same artist line: already on the keyboard
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
