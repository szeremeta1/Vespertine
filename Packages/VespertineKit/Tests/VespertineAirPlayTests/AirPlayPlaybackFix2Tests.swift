//
// Vespertine: AirPlay playback, fix round 2: a next song that can't be opened fails by name and the one after it plays, a
// session the receiver dropped is opened again instead of failing the song, and a paused session is closed after a while
// (the receiver is free for other senders) with the song kept where it was.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network
import Testing
import VespertineAudio
import VespertineUPnP
@testable import VespertineAirPlay

@Suite("AirPlay playback, fix round 2", .serialized, .timeLimit(.minutes(2))) @MainActor
struct AirPlayPlaybackFix2Tests {
    func make(_ receiver: FakeRAOPReceiver) -> (AirPlayPlayback, EventLog) {
        let device = AirPlayDevice(deviceID: "B827EB000001", name: "Fake", raop: AirPlayPlaybackTests.record, host: "127.0.0.1", port: receiver.port)
        let p = AirPlayPlayback(device: device, endpoint: endpoint(receiver), encryption: .none)
        let log = EventLog()
        p.eventHandler = { log.events.append($0) }
        return (p, log)
    }

    func wait(_ condition: @MainActor () -> Bool) async { await untilTrue(condition) }

    @Test("A next song that can't be opened fails by name once the song before it has played, and the one after it plays")
    func unopenableNext() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let (a, sa) = try writeWAV(seconds: 0.4, seed: 51)
        let (c, sc) = try writeWAV(seconds: 0.4, seed: 53)
        defer { [a, c].forEach { try? FileManager.default.removeItem(at: $0) } }
        let (p, log) = make(receiver)
        defer { p.shutdown() }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-missing-\(UUID().uuidString).wav")
        let first = PlayableItem(url: a), second = PlayableItem(url: missing), third = PlayableItem(url: c)
        p.nextItemProvider = { $0.id == first.id ? second : $0.id == second.id ? third : nil }
        p.play(first, at: 0)
        await wait { log.ended }
        #expect(log.ended)
        #expect(log.failures.count == 1, "\(log.failures)")
        #expect(log.started == [first.id, third.id])
        // The song before it was sent whole, and the one after starts from its first frame on a fresh stream.
        #expect(Array(receiver.samples.map(Int32.init).prefix(sa.count)) == sa)
        let markers = receiver.markerTimestamps
        #expect(markers.count == 2)
        guard markers.count == 2 else { return }
        #expect(Array(receiver.samples(from: markers[1]).map(Int32.init).prefix(sc.count)) == sc)
    }

    @Test("A session the receiver has dropped is opened again on Play: the song carries on, nothing fails")
    func staleSession() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let (url, _) = try writeWAV(seconds: 20, seed: 54)
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, log) = make(receiver)
        defer { p.shutdown() }
        p.play(PlayableItem(url: url), at: 0)
        await wait { log.started.count == 1 }
        try await Task.sleep(for: .milliseconds(400))
        p.pause()
        await wait { receiver.methods.last == "FLUSH" }
        let paused = p.snapshot.position
        receiver.refuse = ["FLUSH": 454]   // "Session Not Found", as a receiver that restarted answers
        p.resume()
        await wait { receiver.methods.filter { $0 == "RECORD" }.count == 2 }
        #expect(receiver.methods.filter { $0 == "RECORD" }.count == 2)
        await wait { receiver.markers >= 2 }
        #expect(log.failures.isEmpty, "\(log.failures)")
        #expect(p.snapshot.state == .playing)
        #expect(abs(p.snapshot.position - paused) < 1.5)
        #expect(log.started.count == 1)
    }

    @Test("Paused for a while, the receiver is let go; the song stays paused where it was and Play carries on from there")
    func pausedSessionCloses() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let (url, _) = try writeWAV(seconds: 20, seed: 55)
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, log) = make(receiver)
        defer { p.shutdown() }
        p.idleLimit = 0.4
        p.play(PlayableItem(url: url), at: 0)
        await wait { log.started.count == 1 }
        try await Task.sleep(for: .milliseconds(400))
        p.pause()
        let paused = p.snapshot.position
        await wait { receiver.methods.last == "TEARDOWN" }
        #expect(receiver.methods.last == "TEARDOWN")
        #expect(p.snapshot.state == .paused)
        #expect(abs(p.snapshot.position - paused) < 0.01)
        #expect(p.isEngaged)
        p.resume()
        await wait { receiver.methods.filter { $0 == "RECORD" }.count == 2 && receiver.markers >= 2 }
        #expect(receiver.methods.filter { $0 == "RECORD" }.count == 2)
        #expect(p.snapshot.state == .playing)
        #expect(abs(p.snapshot.position - paused) < 1.5)
        #expect(log.failures.isEmpty, "\(log.failures)")
        #expect(log.started.count == 1)
    }

    @Test("A pause that is played again before the limit keeps its session")
    func resumedInTime() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let (url, _) = try writeWAV(seconds: 20, seed: 56)
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, log) = make(receiver)
        defer { p.shutdown() }
        p.idleLimit = 0.5
        p.play(PlayableItem(url: url), at: 0)
        await wait { log.started.count == 1 }
        p.pause()
        await wait { receiver.methods.last == "FLUSH" }
        p.resume()
        try await Task.sleep(for: .milliseconds(1200))
        #expect(!receiver.methods.contains("TEARDOWN"))
        #expect(receiver.methods.filter { $0 == "RECORD" }.count == 1)
        #expect(p.snapshot.state == .playing)
    }
}
