//
// Vespertine: the queue played on the fake AirPlay receiver: what it decodes is the files' own samples, songs join
// without a gap, pause and seek flush, the end of the queue is heard, and a receiver that can't be reached is said so.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network
import Testing
import VespertineAudio
import VespertineUPnP
@testable import VespertineAirPlay

@MainActor
final class EventLog {
    var events: [EngineEvent] = []
    var started: [UUID] { events.compactMap { if case .trackStarted(let i) = $0 { i.id } else { nil } } }
    var ended: Bool { events.contains { if case .queueEnded = $0 { true } else { false } } }
    var failures: [String] { events.compactMap { if case .failed(_, let m) = $0 { m } else { nil } } }
}

@Suite("AirPlay playback", .serialized) @MainActor
struct AirPlayPlaybackTests {
    static let record = RAOPRecord.parse(serviceName: "B827EB000001@Fake", txt: ["et": "0", "md": "0,2", "cn": "1"])!

    func playback(_ receiver: FakeRAOPReceiver, encryption: RAOPEncryption = .none, rsaKey: SecKey? = nil) -> (AirPlayPlayback, EventLog) {
        let device = AirPlayDevice(deviceID: "B827EB000001", name: "Fake", raop: Self.record, host: "127.0.0.1", port: receiver.port)
        let p = AirPlayPlayback(device: device, endpoint: endpoint(receiver), encryption: encryption, rsaKey: rsaKey)
        let log = EventLog()
        p.eventHandler = { event in log.events.append(event) }
        return (p, log)
    }

    func wait(_ condition: () -> Bool, seconds: Double = 8) async {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(25)) }
    }

    @Test("A 16/44.1 song reaches the receiver sample for sample; heard, it starts; the queue's end is heard too")
    func exact() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let (url, samples) = try writeWAV(seconds: 0.6, seed: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, log) = playback(receiver)
        defer { p.shutdown() }
        let item = PlayableItem(url: url)
        p.metadataProvider = { _ in RendererTrackInfo(title: "Song", artist: "Artist", album: "Album", duration: 0.6) }
        p.play(item, at: 0)
        await wait { log.ended }
        #expect(log.started == [item.id])
        #expect(log.ended)
        #expect(p.snapshot.state == .stopped)
        let got = receiver.samples.map(Int32.init)
        #expect(got.count >= samples.count && got.count < samples.count + 704)
        #expect(Array(got.prefix(samples.count)) == samples)
        #expect(got.dropFirst(samples.count).allSatisfy { $0 == 0 })
        #expect(Array(receiver.methods.prefix(4)) == ["OPTIONS", "ANNOUNCE", "SETUP", "RECORD"])
        let parameters = receiver.requests.filter { $0.method == "SET_PARAMETER" }
        #expect(parameters.contains { String(decoding: $0.body, as: UTF8.self) == "volume: 0.000000\r\n" })
        #expect(parameters.contains { $0["Content-Type"] == "application/x-dmap-tagged" && DMAP.parse($0.body)["minm"] == Data("Song".utf8) })
        #expect(parameters.contains { String(decoding: $0.body, as: UTF8.self).hasPrefix("progress: ") })
    }

    @Test("The signal path says what was sent: BIT-PERFECT · 16/44.1 SENT for CD format, CONVERTED for 24-bit")
    func badges() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let (cd, _) = try writeWAV(seconds: 3, seed: 1)
        let (hi, _) = try writeWAV(seconds: 3, bits: 24, seed: 2)
        defer { try? FileManager.default.removeItem(at: cd); try? FileManager.default.removeItem(at: hi) }
        let (p, _) = playback(receiver)
        defer { p.shutdown() }
        p.play(PlayableItem(url: cd), at: 0)
        await wait { p.snapshot.signalPath != nil }
        #expect(p.snapshot.signalPath?.statusLine == "BIT-PERFECT · 16/44.1 SENT")
        #expect(p.snapshot.signalPath?.isBitPerfect == false)
        #expect(p.snapshot.signalPath?.isUntouched == true)
        p.play(PlayableItem(url: hi), at: 0)
        await wait { p.snapshot.signalPath?.statusLine == "CONVERTED · 16/44.1 SENT" }
        #expect(p.snapshot.signalPath?.renderer?.stepBadges == ["DITHERED"])
    }

    @Test("Two songs join frame to frame on one stream (gapless), and each starts when heard")
    func gapless() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let (a, sa) = try writeWAV(seconds: 0.5, seed: 11)
        let (b, sb) = try writeWAV(seconds: 0.4, seed: 12)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let (p, log) = playback(receiver)
        defer { p.shutdown() }
        let first = PlayableItem(url: a), second = PlayableItem(url: b)
        p.nextItemProvider = { $0.id == first.id ? second : nil }
        p.play(first, at: 0)
        await wait { log.started.count == 1 }
        #expect(p.snapshot.item?.id == first.id)
        await wait { log.ended }
        #expect(log.started == [first.id, second.id])
        let got = receiver.samples.map(Int32.init)
        #expect(Array(got.prefix(sa.count + sb.count)) == sa + sb)
        #expect(receiver.markers == 1)
        #expect(receiver.methods.filter { $0 == "FLUSH" }.isEmpty)
    }

    @Test("Pause flushes and keeps the position; resume and seek start again where asked; stop tears down")
    func pauseResumeSeek() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let (url, _) = try writeWAV(seconds: 20, seed: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, log) = playback(receiver)
        defer { p.shutdown() }
        p.play(PlayableItem(url: url), at: 0)
        await wait { log.started.count == 1 }
        try await Task.sleep(for: .milliseconds(500))
        p.pause()
        let paused = p.snapshot.position
        #expect(p.snapshot.state == .paused)
        #expect(paused > 0.2 && paused < 2)
        await wait { receiver.methods.last == "FLUSH" }
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs(p.snapshot.position - paused) < 0.01)
        p.resume()
        #expect(p.snapshot.state == .playing)
        await wait { receiver.markers == 2 }
        #expect(abs(p.snapshot.position - paused) < 0.5)
        #expect(log.started.count == 1)   // a resume isn't a new song
        p.seek(to: 10)
        await wait { receiver.markers == 3 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(p.snapshot.position >= 10 && p.snapshot.position < 10.5)
        p.stop()
        await wait { receiver.methods.last == "TEARDOWN" }
        #expect(receiver.methods.last == "TEARDOWN")
        #expect(p.snapshot.state == .stopped)
    }

    @Test("Seeking sends the song from there: what arrives after the flush is the file from that frame")
    func seekExact() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let (url, samples) = try writeWAV(seconds: 4, seed: 8)
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, _) = playback(receiver)
        defer { p.shutdown() }
        p.play(PlayableItem(url: url), at: 0)
        await wait { receiver.packetCount > 10 }
        p.pause()
        await wait { receiver.methods.last == "FLUSH" }
        receiver.clearAudio()
        p.seek(to: 2)
        p.resume()
        await wait { receiver.packetCount > 20 }
        let got = receiver.samples.map(Int32.init)
        let from = 2 * 44_100 * 2
        #expect(Array(got.prefix(20 * 704)) == Array(samples[from..<(from + 20 * 704)]))
    }

    @Test("An encrypted receiver gets the same samples")
    func encrypted() async throws {
        let (privateKey, modulus) = try TestRSA.make()
        let receiver = try FakeRAOPReceiver(privateKey: privateKey)
        defer { receiver.stop() }
        let (url, samples) = try writeWAV(seconds: 0.3, seed: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, log) = playback(receiver, encryption: .rsa, rsaKey: try RSAWrap.publicKey(modulus: modulus, exponent: Data([1, 0, 1])))
        defer { p.shutdown() }
        p.play(PlayableItem(url: url), at: 0)
        await wait { log.ended }
        #expect(Array(receiver.samples.map(Int32.init).prefix(samples.count)) == samples)
    }

    @Test("A receiver that can't be reached: the song fails with the reason, nothing else plays")
    func unreachable() async throws {
        let receiver = try FakeRAOPReceiver()
        let port = receiver.port
        receiver.stop()
        let (url, _) = try writeWAV(seconds: 0.3)
        defer { try? FileManager.default.removeItem(at: url) }
        let device = AirPlayDevice(deviceID: "B827EB000001", name: "Fake", raop: Self.record)
        let p = AirPlayPlayback(device: device, endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), encryption: .none)
        defer { p.shutdown() }
        let log = EventLog()
        p.eventHandler = { log.events.append($0) }
        p.play(PlayableItem(url: url), at: 0)
        await wait { !log.failures.isEmpty }
        #expect(log.failures.first?.hasPrefix("Fake couldn't play the song") == true)
        #expect(p.snapshot.state == .stopped)
        #expect(p.snapshot.lastError != nil)
    }

    @Test("Receiver volume goes as a parameter, the samples untouched")
    func receiverVolume() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let (url, _) = try writeWAV(seconds: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, _) = playback(receiver)
        defer { p.shutdown() }
        p.play(PlayableItem(url: url), at: 0)
        await wait { receiver.methods.contains("RECORD") }
        p.setReceiverVolume(decibels: -20)
        await wait { receiver.requests.contains { String(decoding: $0.body, as: UTF8.self) == "volume: -20.000000\r\n" } }
        #expect(receiver.requests.contains { String(decoding: $0.body, as: UTF8.self) == "volume: -20.000000\r\n" })
        #expect(!receiver.methods.contains("FLUSH"))
    }
}
