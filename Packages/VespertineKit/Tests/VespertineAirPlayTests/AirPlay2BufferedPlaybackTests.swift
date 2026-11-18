//
// Vespertine: the queue played on the fake receiver as one whose buffered streams take 24-bit at 48 kHz (what an Apple
// TV 4K says of itself): switched on, the song goes as a buffered stream, every sample; refused, it goes as the realtime
// stream the receiver takes, from a new session; switched off, nothing changes.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network
import Testing
import VespertineAudio
import VespertineUPnP
@testable import VespertineAirPlay

@Suite("AirPlay 2 buffered playback", .serialized, .timeLimit(.minutes(2))) @MainActor
struct AirPlay2BufferedPlaybackTests {
    func playback(_ receiver: FakeRAOPReceiver, follower: FakePTPFollower?) throws -> (AirPlayPlayback, EventLog) {
        let record = try #require(AirPlayRecord.parse(serviceName: "Living Room", txt: ["deviceid": "AA:00:00:00:00:03", "features": AirPlay2PlaybackTests.features,
                                                                                         "flags": "0x4"]))
        let device = AirPlayDevice(deviceID: record.deviceID, name: "Living Room", raop: nil, airplay: record, host: "127.0.0.1", port: receiver.port)
        let p = try #require(AirPlayPlayback(device: device))
        p.pairingSecret = hex(srpSecret)
        if let follower {
            p.buffersStreams = true
            p.clockPorts = (own: (0, 0), peer: (follower.event.port, follower.general.port))
        }
        let log = EventLog()
        p.eventHandler = { event in log.events.append(event) }
        return (p, log)
    }

    @Test("Switched on, a 24-bit / 48 kHz song goes to such a receiver as a buffered stream: every sample, anchored on the clock, and the path says 24/48")
    func buffered() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let follower = try FakePTPFollower()
        defer { follower.stop() }
        receiver.pairing = FakePairing()
        receiver.info = AirPlay2BufferedSessionTests.appleTVInfo
        let (url, samples) = try writeWAV(seconds: 0.6, rate: 48_000, bits: 24, seed: 61)
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, log) = try playback(receiver, follower: follower)
        defer { p.shutdown() }
        let item = PlayableItem(url: url)
        p.play(item, at: 0)
        await untilTrue { log.started == [item.id] || !log.failures.isEmpty }
        let stage = try #require(p.snapshot.signalPath?.renderer)
        #expect(stage.sentSampleRate == 48_000)
        #expect(stage.sentBitDepth == 24)
        #expect(stage.processing.isEmpty)
        await untilTrue { log.ended }
        #expect(log.started == [item.id])
        #expect(log.failures.isEmpty)
        #expect(Array(receiver.methods.prefix(7)) == ["GET", "POST", "POST", "SETUP", "SETPEERS", "SETUP", "RECORD"])
        #expect(receiver.streamFormat == AirPlay2SessionTests.deep48)
        #expect(receiver.blockConnections == 1)
        #expect(receiver.unopened == 0)
        #expect(receiver.badBlocks == 0)
        #expect(Array(receiver.deepSamples.prefix(samples.count)) == samples)
        #expect(receiver.anchors.count == 1)
        #expect(receiver.syncs.isEmpty)
        #expect(!follower.onEvent.isEmpty)
    }

    @Test("A receiver that lists the buffered stream and refuses it plays the song all the same: a new session, the realtime stream it takes")
    func refused() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let follower = try FakePTPFollower()
        defer { follower.stop() }
        receiver.pairing = FakePairing()
        receiver.info = AirPlay2BufferedSessionTests.appleTVInfo
        receiver.refusedFormats = [0x200000]
        let (url, samples) = try writeWAV(seconds: 0.6, rate: 48_000, bits: 24, seed: 62)
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, log) = try playback(receiver, follower: follower)
        defer { p.shutdown() }
        let item = PlayableItem(url: url)
        p.play(item, at: 0)
        await untilTrue { log.started == [item.id] || !log.failures.isEmpty }
        let stage = try #require(p.snapshot.signalPath?.renderer)
        #expect(stage.sentSampleRate == 44_100)
        #expect(stage.sentBitDepth == 16)
        await untilTrue { log.ended }
        #expect(log.failures.isEmpty)
        #expect(Array(receiver.methods.prefix(12)) == ["GET", "POST", "POST", "SETUP", "SETPEERS", "SETUP", "GET", "POST", "POST", "SETUP", "SETUP", "RECORD"])
        #expect(receiver.streamFormat == .cd)
        #expect(receiver.blockConnections == 0)
        let expected = Double(samples.count / 2) * 44_100 / 48_000
        #expect(abs(Double(receiver.samples.count / 2) - expected) < 800)
    }

    @Test("Switched off, as it is unless set, the same receiver gets the realtime stream and is told of no clock")
    func off() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.pairing = FakePairing()
        receiver.info = AirPlay2BufferedSessionTests.appleTVInfo
        let (url, _) = try writeWAV(seconds: 0.4, rate: 48_000, bits: 24, seed: 63)
        defer { try? FileManager.default.removeItem(at: url) }
        let (p, log) = try playback(receiver, follower: nil)
        defer { p.shutdown() }
        #expect(!p.buffersStreams)
        p.play(PlayableItem(url: url), at: 0)
        await untilTrue { log.ended || !log.failures.isEmpty }
        #expect(log.failures.isEmpty)
        #expect(Array(receiver.methods.prefix(6)) == ["GET", "POST", "POST", "SETUP", "SETUP", "RECORD"])
        #expect(receiver.peers.isEmpty)
        #expect(receiver.streamFormat == .cd)
    }
}
