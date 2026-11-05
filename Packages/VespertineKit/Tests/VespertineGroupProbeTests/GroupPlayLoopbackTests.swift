//
// Vespertine — Phase 0 of multi-DAC speaker groups, PR 0.2: the real engine playing a quad file to a private aggregate of
// two virtual devices, recorded back from each member's own input.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Opt-in: VESPERTINE_GROUP_LOOPBACK=1 swift test --filter GroupPlayLoopback
// Needs "Vespertine Loopback" (the leader) and a second virtual device ("BlackHole 2ch" unless VESPERTINE_GROUP_FOLLOWER
// names another), both unused by other processes, and audio input access for the test process. Nothing is audible. The
// members' rates are put back afterwards.
//

import AVFAudio
import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio
@testable import VespertineGroupProbe

@Suite("Group play loopback", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_GROUP_LOOPBACK"] == "1"))
struct GroupPlayLoopbackTests {
    static let rate = 48_000.0
    static let leaderName = "Vespertine Loopback"
    static let followerName = ProcessInfo.processInfo.environment["VESPERTINE_GROUP_FOLLOWER"] ?? "BlackHole 2ch"

    /// A quad WAV (FL FR BL BR, 24-bit): channels 0 and 1 are quiet pseudo-random values (so equality means bit for bit),
    /// channel 2 a 997 Hz sine and channel 3 a 1499 Hz sine.
    static func quadValue(channel: Int, frame: Int) -> Int32 {
        if channel < 2 {
            let h = (UInt64(frame) &* 2_654_435_761 &+ UInt64(channel) &* 40_503 &+ 12_345) & 0xFFFF_FFFF
            let unit = Double(h >> 8) / Double(1 << 24) - 0.5          // −0.5 … 0.5
            return Int32((unit * 0.2 * 8_388_607).rounded())
        }
        let hz = channel == 2 ? 997.0 : 1_499.0
        return Int32((0.1 * sin(2 * .pi * hz * Double(frame) / rate) * 8_388_607).rounded())
    }

    static func writeQuadWAV(to url: URL, seconds: Double) throws {
        let frames = Int(rate * seconds), channels = 4
        var data = Data(capacity: frames * channels * 3)
        for f in 0..<frames { for c in 0..<channels {
            let v = quadValue(channel: c, frame: f)
            data.append(contentsOf: [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16)])
        } }
        func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        var fmt = Data()
        fmt.append(contentsOf: le(UInt16(0xFFFE)) + le(UInt16(channels)) + le(UInt32(rate)) + le(UInt32(rate) * 12) + le(UInt16(12)) + le(UInt16(24)))
        fmt.append(contentsOf: le(UInt16(22)) + le(UInt16(24)) + le(UInt32(0x33)) + le(UInt16(1)))
        fmt.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        var file = Data("RIFF".utf8)
        file.append(contentsOf: le(UInt32(4 + 8 + fmt.count + 8 + data.count)))
        file.append(Data("WAVE".utf8)); file.append(Data("fmt ".utf8)); file.append(contentsOf: le(UInt32(fmt.count))); file.append(fmt)
        file.append(Data("data".utf8)); file.append(contentsOf: le(UInt32(data.count))); file.append(data)
        try file.write(to: url)
    }

    /// Amplitude of `hz` in `x[from..<from+count]` (Goertzel).
    static func amplitude(_ x: [Float], hz: Double, from: Int, count: Int) -> Double {
        let w = 2 * Double.pi * hz / rate, coeff = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for n in from..<from + count { let s = Double(x[n]) + coeff * s1 - s2; s2 = s1; s1 = s }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return 2 * power.squareRoot() / Double(count)
    }

    @Test func aQuadFileReachesTheLeaderBitForBitAndTheFollowerChannelForChannel() throws {
        let devices = OutputDevices.list()
        let leader = try #require(devices.first { $0.name == Self.leaderName && $0.transport == .virtual }, "no \(Self.leaderName)")
        let follower = try #require(devices.first { $0.name == Self.followerName && $0.transport == .virtual }, "no \(Self.followerName)")
        try #require(!LoopbackGuard.inUseByOthers(leader.id) && !LoopbackGuard.inUseByOthers(follower.id), "a device is in use by another process; left alone")
        try #require(AVAudioApplication.shared.recordPermission != .denied, "audio input access denied")
        let found = [leader, follower].map { ProbeHAL.nominalRate($0.id) }
        defer { for (d, r) in zip([leader, follower], found) { ProbeHAL.setNominalRate(r, on: d.id) } }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("groupquad-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeQuadWAV(to: url, seconds: 4)

        // Record each member's own input while the group plays.
        for d in [leader, follower] { ProbeHAL.setNominalRate(Self.rate, on: d.id) }
        let leaderRec = try LoopbackRecorder(device: leader.id, rate: Self.rate, maxChannels: 2)
        let followerRec = try LoopbackRecorder(device: follower.id, rate: Self.rate, maxChannels: 2)
        try leaderRec.start(); try followerRec.start()
        defer { leaderRec.stop(); leaderRec.restore(); followerRec.stop(); followerRec.restore() }

        var config = GroupPlayConfig(devices: [leader, follower], files: [url])
        config.seconds = 3.2
        config.log = { _ in }
        config.tick = { leaderRec.drain(); followerRec.drain() }
        let report = try GroupPlay.run(config)
        leaderRec.drain(); followerRec.drain()

        // The report: played, each member really at the group rate, the badge honest, everything put back.
        let file = try #require(report.files.first)
        #expect(file.played, "\(file.error ?? file.state)")
        #expect(report.members.allSatisfy { abs($0.rateDuringPlay - Self.rate) < 0.5 }, "\(report.members.map(\.rateDuringPlay))")
        #expect(report.members.map(\.driftCompensation) == [false, true])
        #expect(report.aggregateStreams == 2)
        #expect(!file.claimsBitPerfect, "an aggregate must not be called bit-perfect: \(file.statusLine ?? "")")
        #expect(report.truthWarnings.isEmpty, "\(report.truthWarnings)")
        #expect(report.aggregateGoneAfter && report.restoredAllRates)
        #expect(file.channelNames.count == 4, "\(file.channelNames)")

        // Leader: its two channels are the file's first two, bit for bit.
        let anchor = Int(Self.rate * 0.5), window = Int(Self.rate * 1.0)
        let expected0 = (0..<32).map { Float(Self.quadValue(channel: 0, frame: anchor + $0)) / 8_388_608 }
        let l0 = leaderRec.samples[0], l1 = leaderRec.samples[1]
        let start = try #require(l0.indices.dropLast(window + 32).first { i in (0..<32).allSatisfy { l0[i + $0] == expected0[$0] } },
                                 "the file's frame \(anchor) never reached the leader's first channel (\(l0.count) frames recorded)")
        var mismatches = 0
        for f in 0..<window {
            if l0[start + f] != Float(Self.quadValue(channel: 0, frame: anchor + f)) / 8_388_608 { mismatches += 1 }
            if l1[start + f] != Float(Self.quadValue(channel: 1, frame: anchor + f)) / 8_388_608 { mismatches += 1 }
        }
        #expect(mismatches == 0, "\(mismatches) of \(2 * window) leader samples differ from the file")

        // Follower: its two channels are the file's last two (a sine each), not each other's and not silent. They went
        // through drift correction, so only the tone is checked, not the bits.
        let f0 = followerRec.samples[0], f1 = followerRec.samples[1]
        let first = try #require(f0.indices.first { abs(f0[$0]) > 0.01 }, "nothing reached the follower")
        let from = first + Int(Self.rate * 0.5), count = Int(Self.rate * 1.0)
        try #require(from + count <= f0.count && from + count <= f1.count)
        let a0 = (997.0, Self.amplitude(f0, hz: 997, from: from, count: count)), b0 = (1_499.0, Self.amplitude(f0, hz: 1_499, from: from, count: count))
        let a1 = (997.0, Self.amplitude(f1, hz: 997, from: from, count: count)), b1 = (1_499.0, Self.amplitude(f1, hz: 1_499, from: from, count: count))
        #expect(a0.1 > 0.09 && b0.1 < a0.1 / 100, "follower channel 1 should be the 997 Hz sine: \(a0.1) vs \(b0.1)")
        #expect(b1.1 > 0.09 && a1.1 < b1.1 / 100, "follower channel 2 should be the 1499 Hz sine: \(b1.1) vs \(a1.1)")
    }
}

// MARK: - group-skew through a real aggregate of two virtual devices

/// Stands in for the microphone: records the aggregate's own inputs (each virtual member's input hears what was played to that
/// member) and adds the leader's and the follower's together, so one "microphone" hears both, exactly as the UMIK hears two
/// speakers. Plays through the same stimulus player the room measurement uses.
final class AggregateLoopbackDevice: RoomCaptureDevice, @unchecked Sendable {
    private let aggregate: AudioObjectID
    private let leaderInput: Int
    private let followerInput: Int
    private let lock = NSLock()
    private var recorder: LoopbackRecorder?
    private var player: RoomStimulusPlayer?
    private var cursor = 0

    init(aggregate: AudioObjectID, leaderInput: Int, followerInput: Int) {
        self.aggregate = aggregate; self.leaderInput = leaderInput; self.followerInput = followerInput
    }

    func start(request: RoomCaptureRequest, stimulus: RoomStimulus) throws {
        lock.lock(); defer { lock.unlock() }
        let rate = request.layout.sampleRate
        let recorder = try LoopbackRecorder(device: aggregate, rate: rate, maxChannels: 4)
        let player = try RoomStimulusPlayer(device: aggregate, stimulus: stimulus, rate: rate)
        self.recorder = recorder; self.player = player; cursor = 0
        try recorder.start()
        try player.start()
    }

    func readAvailable(maxFrames: Int) -> RoomCaptureChunk {
        lock.lock(); defer { lock.unlock() }
        guard let recorder else { return RoomCaptureChunk(frames: [], lostFrames: 0, alive: false) }
        recorder.drain()
        let a = recorder.samples[leaderInput], b = recorder.samples[followerInput]
        let available = min(a.count, b.count)
        let take = max(0, min(maxFrames, available - cursor))
        let frames = (0..<take).map { a[cursor + $0] + b[cursor + $0] }
        cursor += take
        return RoomCaptureChunk(frames: frames, lostFrames: 0, alive: true)
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        player?.stop(); player = nil
        recorder?.stop(); recorder?.restore(); recorder = nil
    }
}

extension GroupPlayLoopbackTests {
    struct DriftCase: Sendable, CustomTestStringConvertible {
        let drift: GroupAggregate.DriftMode
        let quality: Int
        var testDescription: String { drift == .off ? "drift off" : "drift on, quality \(quality)" }
    }

    @Test(arguments: [DriftCase(drift: .off, quality: 127), DriftCase(drift: .byClockDomain, quality: 127), DriftCase(drift: .byClockDomain, quality: 64),
                      DriftCase(drift: .byClockDomain, quality: 0)])
    func theSkewBetweenTwoVirtualMembersOfARealAggregateIsMeasuredAndRepeatable(_ c: DriftCase) async throws {
        let drift = c.drift
        let devices = OutputDevices.list()
        let leader = try #require(devices.first { $0.name == Self.leaderName && $0.transport == .virtual }, "no \(Self.leaderName)")
        let follower = try #require(devices.first { $0.name == Self.followerName && $0.transport == .virtual }, "no \(Self.followerName)")
        try #require(!LoopbackGuard.inUseByOthers(leader.id) && !LoopbackGuard.inUseByOthers(follower.id), "a device is in use by another process; left alone")
        try #require(AVAudioApplication.shared.recordPermission != .denied, "audio input access denied")
        let found = [leader, follower].map { ProbeHAL.nominalRate($0.id) }
        defer { for (d, r) in zip([leader, follower], found) { ProbeHAL.setNominalRate(r, on: d.id) } }
        for d in [leader, follower] { ProbeHAL.setNominalRate(Self.rate, on: d.id) }
        let aggregate = try PrivateAggregate.create(members: [.init(uid: leader.uid, clockDomain: 0), .init(uid: follower.uid, clockDomain: 0)],
                                                    name: "Vespertine group skew test", drift: drift, quality: c.quality)
        defer { aggregate.destroy() }
        try await Task.sleep(for: .milliseconds(500))

        var config = GroupSkewConfig(inputDevice: 1, outputDevice: aggregate.id, leaderChannel: 0, followerChannel: 2, rate: Self.rate)
        config.runsPerLeadIn = 4
        config.leadIns = [1.0]
        config.pauseSeconds = 0.5
        let id = aggregate.id
        let report = try await GroupSkewRunner.run(config, makeDevice: { AggregateLoopbackDevice(aggregate: id, leaderInput: 0, followerInput: 2) },
                                                   permission: AlwaysGrantedMicrophone())
        print("\(c.testDescription): " + report.text)
        #expect(report.failures.isEmpty, "\(report.failures)")
        let overall = try #require(report.overall)
        #expect(overall.count == 4)
        // Two virtual devices on the host clock, aligned by the aggregate: the follower lands within a few ms of the leader,
        // and the same place every start (within the ear's 25 µs, about 1.2 frames).
        #expect(abs(overall.mean) < 240, "mean skew \(overall.mean) frames")
        // With no drift correction nothing is added to the follower: the two land together.
        if drift == .off { #expect(abs(overall.mean) < 1, "no drift correction, yet the follower is \(overall.mean) frames off") }
        #expect(overall.peakToPeak < 1.2, "peak-to-peak \(overall.peakToPeak) frames")
    }
}
