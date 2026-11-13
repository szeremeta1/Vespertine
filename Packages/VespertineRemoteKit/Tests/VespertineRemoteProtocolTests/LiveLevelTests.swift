//
// Vespertine Remote: the volume slider's level: sent while it's dragged, the newest only, and never pulled back by an
// older level from the Mac.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Network)
import Foundation
import Testing
import VespertineRemoteClient
import VespertineRemoteProtocol

/// What the Mac was sent, and a gate that holds a send open the way a slow connection does.
@MainActor
private final class Sent {
    var levels: [Double] = []
    var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func send(_ level: Double) async {
        levels.append(level)
        if held { await withCheckedContinuation { waiting.append($0) } }
    }

    func open() {
        held = false
        let all = waiting
        waiting = []
        for continuation in all { continuation.resume() }
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool, seconds: Double = 5) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite("The volume slider", .serialized) @MainActor
struct LiveLevelTests {
    @Test("The volume is sent while the slider is being dragged, not when the finger lifts")
    func sendsWhileDragging() async {
        let sent = Sent()
        let level = LiveLevel { await sent.send($0) }
        level.interval = .milliseconds(1)
        level.drag(to: 0.3)
        #expect(await waitUntil { sent.levels == [0.3] })
        level.drag(to: 0.4)
        #expect(await waitUntil { sent.levels == [0.3, 0.4] })
        // Lifting the finger sends nothing more: the Mac already has the last level.
        level.end()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(sent.levels == [0.3, 0.4])
    }

    @Test("While a send is on its way, only the newest level waits behind it")
    func newestWins() async {
        let sent = Sent()
        sent.held = true
        let level = LiveLevel { await sent.send($0) }
        level.interval = .milliseconds(1)
        level.drag(to: 0.1)
        #expect(await waitUntil { sent.levels == [0.1] })
        for step in [0.2, 0.3, 0.4, 0.5] { level.drag(to: step) }
        level.end()
        sent.open()
        #expect(await waitUntil { sent.levels.count == 2 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(sent.levels == [0.1, 0.5])
    }

    @Test("The thumb stays where the finger put it: an older level from the Mac doesn't pull it back")
    func staleReportsDontMoveTheThumb() async {
        let sent = Sent()
        let level = LiveLevel { await sent.send($0) }
        level.interval = .milliseconds(1)
        level.settle = .seconds(60)
        #expect(level.shown(reported: 0.2) == 0.2)
        level.drag(to: 0.8)
        // The Mac answers the first send with where it was a moment ago.
        level.reported(0.25)
        #expect(level.shown(reported: 0.25) == 0.8)
        level.drag(to: 0.9)
        level.end()
        #expect(await waitUntil { sent.levels.last == 0.9 })
        try? await Task.sleep(for: .milliseconds(30))
        // Still on its way up after the finger lifted.
        level.reported(0.8)
        #expect(level.shown(reported: 0.8) == 0.9)
        // The Mac has it: from here the slider shows the Mac's level again (its own keys can change it).
        level.reported(0.9)
        #expect(level.held == nil)
        #expect(level.shown(reported: 0.6) == 0.6)
    }

    @Test("A level the Mac never confirms is let go, so the slider shows the Mac's own level again")
    func letsGoWithoutAReport() async {
        let sent = Sent()
        let level = LiveLevel { await sent.send($0) }
        level.interval = .milliseconds(1)
        level.settle = .milliseconds(20)
        level.drag(to: 0.7)
        level.end()
        #expect(level.held == 0.7)
        #expect(await waitUntil { level.held == nil })
        #expect(level.shown(reported: 0.5) == 0.5)
    }

    @Test("Dragging the session's volume sends setVolume to the Mac as it moves")
    func sessionSendsSetVolume() async {
        let mac = DemoMac(name: "Demo") { _, _ in nil }
        let session = RemoteSession(pairing: SavedPairing(serverID: DemoMac.serverID, name: "Demo", device: "demo", key: Data()), clientName: "Test") { mac }
        session.connect()
        #expect(await waitUntil { session.isConnected && session.player != nil })
        session.volume.drag(to: 0.21)
        // No end(): the finger is still down, and the Mac's level already follows it.
        #expect(await waitUntil { session.player?.volume.level == 0.21 })
        #expect(session.volume.shown(reported: session.player?.volume.level ?? 0) == 0.21)
        session.volume.end()
        #expect(await waitUntil { session.volume.held == nil })
        session.close()
    }
}
#endif
