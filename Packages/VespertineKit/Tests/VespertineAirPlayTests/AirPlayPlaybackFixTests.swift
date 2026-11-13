//
// Vespertine: AirPlay playback, fix round 1: the song opened ahead survives what doesn't change it, no file is ever opened on
// the pacer's thread (a late next song is waited for, still gapless), the receiver-volume note follows the volume, volume
// sends are coalesced, and a SETUP without a session fails the song instead of crashing.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network
import Testing
import VespertineAudio
import VespertineUPnP
@testable import VespertineAirPlay

@Suite("AirPlay playback, fix round 1", .serialized) @MainActor
struct AirPlayPlaybackFixTests {
    func make(_ receiver: FakeRAOPReceiver) -> (AirPlayPlayback, EventLog) {
        let device = AirPlayDevice(deviceID: "B827EB000001", name: "Fake", raop: AirPlayPlaybackTests.record, host: "127.0.0.1", port: receiver.port)
        let p = AirPlayPlayback(device: device, endpoint: endpoint(receiver), encryption: .none)
        let log = EventLog()
        p.eventHandler = { log.events.append($0) }
        return (p, log)
    }

    func wait(_ condition: () -> Bool, seconds: Double = 8) async {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(25)) }
    }

    @Test("The same settings again, a volume step and a queue change that keeps the next song keep the song opened ahead")
    func preparedSurvives() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let (a, _) = try writeWAV(seconds: 8, seed: 1)
        let (b, _) = try writeWAV(seconds: 1, seed: 2)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let (p, _) = make(receiver)
        defer { p.shutdown() }
        let first = PlayableItem(url: a), second = PlayableItem(url: b)
        p.nextItemProvider = { $0.id == first.id ? second : nil }
        p.play(first, at: 0)
        await wait { p.preparedNext?.segment != nil }
        let opened = try #require(p.preparedNext?.segment)
        p.update(settings: RendererSettings())
        p.setReceiverVolume(decibels: -3)
        p.queueChanged()
        try await Task.sleep(for: .milliseconds(600))
        #expect(p.preparedNext?.segment === opened)
        #expect(p.preparedNext?.item.id == second.id)
    }

    @Test("A next song that isn't open at the boundary is waited for, opened off the pacer, and joins without a gap")
    func lateNextSong() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let (a, sa) = try writeWAV(seconds: 0.3, seed: 21)
        let (b, sb) = try writeWAV(seconds: 0.3, seed: 22)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let (p, log) = make(receiver)
        defer { p.shutdown() }
        let onPacer = Locked(0), opens = Locked(0)
        p.onOpen = { pacer in opens.withLock { $0 += 1 }; if pacer { onPacer.withLock { $0 += 1 } } }
        p.preparationDelay = 0.8
        let first = PlayableItem(url: a), second = PlayableItem(url: b)
        p.nextItemProvider = { $0.id == first.id ? second : nil }
        p.play(first, at: 0)
        await wait { log.ended }
        #expect(log.ended)
        #expect(opens.withLock { $0 } >= 2)
        #expect(onPacer.withLock { $0 } == 0)
        let got = receiver.samples.map(Int32.init)
        #expect(Array(got.prefix(sa.count + sb.count)) == sa + sb)
        #expect(log.started == [first.id, second.id])
    }

    @Test("The receiver-volume note in the signal path follows the volume while the song plays")
    func liveWarning() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let (url, _) = try writeWAV(seconds: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, _) = make(receiver)
        defer { p.shutdown() }
        p.play(PlayableItem(url: url), at: 0)
        await wait { p.snapshot.signalPath != nil }
        #expect(p.snapshot.signalPath?.renderer?.warnings.isEmpty == true)
        p.setReceiverVolume(decibels: -12)
        let shown = p.snapshot.signalPath?.renderer?.warnings ?? ["<none>"]
        #expect(shown.first?.contains("12") == true && shown.first?.contains("dB") == true, "\(shown)")
        p.setReceiverVolume(decibels: 0)
        #expect(p.snapshot.signalPath?.renderer?.warnings.isEmpty == true)
    }

    @Test("A volume drag sends far fewer SET_PARAMETERs than steps, and the last one is the last level")
    func coalesced() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let (url, _) = try writeWAV(seconds: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, _) = make(receiver)
        defer { p.shutdown() }
        p.play(PlayableItem(url: url), at: 0)
        await wait { receiver.methods.contains("RECORD") }
        try await Task.sleep(for: .milliseconds(100))
        for step in 1...100 { p.setReceiverVolume(decibels: -Double(step) * 0.2) }
        await wait { receiver.requests.last.map { String(decoding: $0.body, as: UTF8.self) } == "volume: -20.000000\r\n" }
        let volumes = receiver.requests.filter { String(decoding: $0.body, as: UTF8.self).hasPrefix("volume:") }
        #expect(volumes.last.map { String(decoding: $0.body, as: UTF8.self) } == "volume: -20.000000\r\n")
        #expect(volumes.count < 30)
    }

    @Test("A SETUP answered with an empty Session fails the song with a reason; nothing crashes")
    func emptySession() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.sessionHeader = ""
        let (url, _) = try writeWAV(seconds: 0.3)
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, log) = make(receiver)
        defer { p.shutdown() }
        p.play(PlayableItem(url: url), at: 0)
        await wait { !log.failures.isEmpty }
        #expect(log.failures.count == 1)
        #expect(p.snapshot.state == .stopped)
    }

    @Test("A play overtaken while it connects says nothing about the old song")
    func staleFailure() async throws {
        let receiver = try FakeRAOPReceiver()
        let port = receiver.port
        receiver.stop()
        let (url, _) = try writeWAV(seconds: 0.3)
        defer { try? FileManager.default.removeItem(at: url) }
        let device = AirPlayDevice(deviceID: "B827EB000001", name: "Fake", raop: AirPlayPlaybackTests.record)
        let p = AirPlayPlayback(device: device, endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), encryption: .none)
        defer { p.shutdown() }
        let log = EventLog()
        p.eventHandler = { log.events.append($0) }
        p.play(PlayableItem(url: url), at: 0)
        p.stop()
        try await Task.sleep(for: .milliseconds(500))
        #expect(log.failures.isEmpty)
    }
}
