//
// Vespertine: an AirPlay 2 session that carries a buffered stream, against the fake receiver and a PTP follower on this
// machine: when one is chosen, the requests that set it up, the blocks decoded exactly, the moment the stream is anchored
// at, a flush, and everything that leaves the realtime stream in place.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import Network
import Testing
import VespertineAudio
@testable import VespertineAirPlay

@Suite("AirPlay 2 buffered session", .serialized)
struct AirPlay2BufferedSessionTests {
    let sender = AirPlay2Sender(deviceID: "02:1A:FF:00:9C:07", name: "Test Mac", model: "Mac14,5", osVersion: "15.1")
    let identity = PTPMessage.identity(address: [0x02, 0x1A, 0xFF, 0x00, 0x9C, 0x07])

    /// What an Apple TV 4K says of itself (AirPlay 1005.13.2): realtime streams at 16-bit and 44.1 kHz only, buffered
    /// streams in many formats, 24-bit ALAC at 48 kHz among them.
    static var appleTVInfo: [String: Any] {
        ["name": "Fake", "supportedFormats": ["audioStream": 21_235_712, "bufferStream": -577_021_992_844_656_640, "lowLatencyAudioStream": 0]]
    }

    private func makeClock() throws -> PTPClock {
        try PTPClock(identity: identity, eventPort: 0, generalPort: 0)
    }

    private func open(_ receiver: FakeRAOPReceiver, wish: AirPlayWish? = AirPlay2SessionTests.deepWish, clock: PTPClock?,
                      follower: FakePTPFollower? = nil) -> RAOPSession {
        let session = RAOPSession(name: "Fake", endpoint: endpoint(receiver), encryption: .none, pairing: .withoutPIN(secret: hex(srpSecret)),
                                  sender: sender, wish: wish, clock: clock)
        if let follower { session.clockPeerPorts = (follower.event.port, follower.general.port) }
        return session
    }

    @Test("A 24-bit song at 48 kHz, a clock, and a receiver whose buffered streams take it: set up as a buffered stream, every sample exact")
    func bufferedStream() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let follower = try FakePTPFollower()
        defer { follower.stop() }
        receiver.pairing = FakePairing()
        receiver.info = Self.appleTVInfo
        let clock = try makeClock()
        let session = open(receiver, clock: clock, follower: follower)
        #expect(!session.isBuffered)
        try await session.connect(volumeDB: nil)
        #expect(session.isConnected)
        #expect(session.isBuffered)
        #expect(session.format == AirPlay2SessionTests.deep48)
        #expect(receiver.methods == ["GET", "POST", "POST", "SETUP", "SETPEERS", "SETUP", "RECORD"])
        #expect(receiver.sealed == [false, false, false, true, true, true, true])

        // The session is timed by this Mac's PTP clock, and is a group of its own.
        let setups = receiver.setups
        #expect(setups.count == 2)
        #expect(setups[0]["timingProtocol"] as? String == "PTP")
        #expect(setups[0]["timingPort"] == nil)
        let named = try #require(setups[0]["timingPeerInfo"] as? [String: Any])
        #expect((named["Addresses"] as? [String])?.count == 1)
        #expect(setups[0]["groupUUID"] as? String != nil)
        // Both clocks are named: this Mac's and the receiver's.
        #expect(receiver.peers.count == 2)
        #expect(receiver.peers.last == "127.0.0.1")
        let stream = try #require((setups[1]["streams"] as? [[String: Any]])?.first)
        #expect(stream["type"] as? Int == 103)
        #expect(stream["audioFormat"] as? Int == 0x200000)
        #expect(stream["sr"] as? Int == 48_000)
        #expect(stream["spf"] as? Int == 352)
        #expect(stream["controlPort"] == nil)
        #expect(receiver.streamFormat == AirPlay2SessionTests.deep48)
        await receiver.waitFor { receiver.eventConnections == 1 && receiver.blockConnections == 1 }
        #expect(receiver.eventConnections == 1)
        #expect(receiver.blockConnections == 1)

        // The clock was started, and tells the receiver the time at the ports it was given.
        await receiver.waitFor { !follower.onEvent.isEmpty }
        let sync = try #require(follower.onEvent.first.flatMap { PTPMessage.read($0.data) })
        #expect(sync.kind == .sync)
        #expect(sync.clock == identity)

        let sent = AirPlay2SessionTests.deepPackets(30)
        for packet in sent {
            let went = session.send(samples: packet)
            #expect(went)
        }
        await receiver.waitFor { receiver.packetCount == 30 }
        #expect(receiver.packetCount == 30)
        #expect(receiver.deepSamples == sent.flatMap { $0 })
        #expect(receiver.blockSequences == Array(0..<30))
        #expect(receiver.unopened == 0)
        #expect(receiver.badBlocks == 0)
        // No sync packets: the moments are named on the clock.
        session.sendSync()
        #expect(receiver.syncs.isEmpty)
        await session.teardown()
        #expect(receiver.methods.last == "TEARDOWN")
    }

    @Test("The first block says when it plays: its frame, two seconds after it was sent, on this Mac's clock")
    func anchor() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let follower = try FakePTPFollower()
        defer { follower.stop() }
        receiver.pairing = FakePairing()
        receiver.info = Self.appleTVInfo
        let clock = try makeClock()
        let session = open(receiver, clock: clock, follower: follower)
        try await session.connect(volumeDB: nil)
        let head = session.nextTimestamp
        let packets = AirPlay2SessionTests.deepPackets(2)
        session.send(samples: packets[0], startNanos: 5_000_000_000)
        session.send(samples: packets[1], startNanos: 6_000_000_000)
        await receiver.waitFor { !receiver.anchors.isEmpty && receiver.packetCount == 2 }
        // Only the first block anchors.
        #expect(receiver.anchors.count == 1)
        let said = try #require(receiver.anchors.first)
        #expect(said["rate"] as? Int == 1)
        #expect(said["rtpTime"] as? Int == Int(head))
        #expect(said["networkTimeSecs"] as? Int == 7)
        #expect(said["networkTimeFrac"] as? Int == 0)
        #expect(said["networkTimeTimelineID"] as? Int == Int(Int64(bitPattern: identity)))
        #expect(session.clockTimestamp(nanoseconds: 6_000_000_000) == head &+ 48_000)
        await session.teardown()
    }

    @Test("A receiver that isn't following the clock yet answers \"not yet\", and is told the same moment again until it takes it")
    func anchorAgain() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let follower = try FakePTPFollower()
        defer { follower.stop() }
        receiver.pairing = FakePairing()
        receiver.info = Self.appleTVInfo
        receiver.anchorsNotYet = 2
        let clock = try makeClock()
        let session = open(receiver, clock: clock, follower: follower)
        session.anchorPause = .milliseconds(1)
        try await session.connect(volumeDB: nil)
        let head = session.nextTimestamp
        let packets = AirPlay2SessionTests.deepPackets(2)
        session.send(samples: packets[0], startNanos: 5_000_000_000)
        // Refused twice, taken the third time.
        await receiver.waitFor { receiver.anchors.count == 3 }
        session.send(samples: packets[1], startNanos: 6_000_000_000)
        await receiver.waitFor { receiver.packetCount == 2 }
        #expect(receiver.anchors.count == 3)
        #expect(receiver.anchorsNotYet == 0)
        #expect(receiver.anchors.allSatisfy { $0["rtpTime"] as? Int == Int(head) && $0["networkTimeSecs"] as? Int == 7 && $0["networkTimeFlags"] as? Int == 0 })
        await session.teardown()
    }

    @Test("A flush drops what the receiver holds before the next block, and the next block is anchored anew")
    func flush() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let follower = try FakePTPFollower()
        defer { follower.stop() }
        receiver.pairing = FakePairing()
        receiver.info = Self.appleTVInfo
        let clock = try makeClock()
        let session = open(receiver, clock: clock, follower: follower)
        try await session.connect(volumeDB: nil)
        let head = session.nextTimestamp
        let packets = AirPlay2SessionTests.deepPackets(4)
        for packet in packets.prefix(3) { session.send(samples: packet, startNanos: 5_000_000_000) }
        await receiver.waitFor { receiver.anchors.count == 1 && receiver.packetCount == 3 }
        try await session.flush()
        #expect(receiver.methods.contains("FLUSHBUFFERED"))
        #expect(!receiver.methods.contains("FLUSH"))
        let flushed = try #require(receiver.bufferedFlushes.first)
        #expect(flushed["flushUntilSeq"] as? Int == 3)
        #expect(flushed["flushUntilTS"] as? Int == Int(head &+ 1056))

        session.send(samples: packets[3], startNanos: 9_000_000_000)
        await receiver.waitFor { receiver.anchors.count == 2 && receiver.packetCount == 4 }
        #expect(receiver.anchors.count == 2)
        let again = try #require(receiver.anchors.last)
        #expect(again["rtpTime"] as? Int == Int(head &+ 1056))
        #expect(again["networkTimeSecs"] as? Int == 11)
        // The blocks count on through a flush.
        #expect(receiver.blockSequences == [0, 1, 2, 3])
        await session.teardown()
    }

    @Test("Without a clock, the same receiver gets the realtime stream it takes: 16-bit at 44.1 kHz, as before")
    func noClock() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.pairing = FakePairing()
        receiver.info = Self.appleTVInfo
        let session = open(receiver, clock: nil)
        try await session.connect(volumeDB: nil)
        #expect(!session.isBuffered)
        #expect(session.format == .cd)
        #expect(receiver.methods == ["GET", "POST", "POST", "SETUP", "SETUP", "RECORD"])
        #expect(receiver.setups.first?["timingProtocol"] as? String == "NTP")
        let sent = packets(6)
        for packet in sent { session.send(packet) }
        await receiver.waitFor { receiver.packetCount == 6 }
        #expect(receiver.samples == sent.flatMap { $0 })
        #expect(receiver.blockConnections == 0)
        await session.teardown()
    }

    @Test("With a clock, a receiver that says nothing of buffered streams gets the realtime stream, in the format it lists")
    func noBufferedStreams() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.pairing = FakePairing()
        receiver.info = AirPlay2SessionTests.deepInfo
        let clock = try makeClock()
        let session = open(receiver, clock: clock)
        try await session.connect(volumeDB: nil)
        #expect(!session.isBuffered)
        #expect(session.format == AirPlay2SessionTests.deep48)
        #expect(receiver.methods == ["GET", "POST", "POST", "SETUP", "SETUP", "RECORD"])
        #expect(receiver.peers.isEmpty)
        await session.teardown()
    }

    @Test("With a clock, a song that 16-bit at 44.1 kHz serves as well is sent as before, and the receiver is asked nothing")
    func plainSong() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        receiver.pairing = FakePairing()
        receiver.info = Self.appleTVInfo
        let clock = try makeClock()
        let session = open(receiver, wish: nil, clock: clock)
        try await session.connect(volumeDB: nil)
        #expect(!session.isBuffered)
        #expect(session.format == .cd)
        #expect(receiver.methods == ["POST", "POST", "SETUP", "SETUP", "RECORD"])
        await session.teardown()
    }

    @Test("A receiver that lists the buffered stream and then refuses it fails the session, and nothing is left open")
    func refused() async throws {
        let receiver = try FakeRAOPReceiver()
        defer { receiver.stop() }
        let follower = try FakePTPFollower()
        defer { follower.stop() }
        receiver.pairing = FakePairing()
        receiver.info = Self.appleTVInfo
        receiver.refusedFormats = [0x200000]
        let clock = try makeClock()
        let session = open(receiver, clock: clock, follower: follower)
        await #expect(throws: RAOPError.refused("SETUP", 415)) { try await session.connect(volumeDB: nil) }
        #expect(!session.isConnected)
        #expect(!session.isBuffered)
        #expect(receiver.methods == ["GET", "POST", "POST", "SETUP", "SETPEERS", "SETUP"])
        #expect(receiver.blockConnections == 0)
    }

    @Test("What a receiver says of its buffered streams is read from supportedFormats, and only the 24-bit ALAC at 48 kHz bit counts")
    func takesBuffered() {
        #expect(AirPlay2Message.takesBuffered(info: AirPlay2Message.encode(Self.appleTVInfo)))
        #expect(!AirPlay2Message.takesBuffered(info: AirPlay2Message.encode(AirPlay2SessionTests.deepInfo)))
        #expect(!AirPlay2Message.takesBuffered(info: AirPlay2Message.encode(["supportedFormats": ["audioStream": 0x200000, "bufferStream": 0x80000]])))
        #expect(!AirPlay2Message.takesBuffered(info: Data()))
    }
}
