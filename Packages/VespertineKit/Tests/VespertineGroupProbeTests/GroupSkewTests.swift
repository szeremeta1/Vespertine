//
// Vespertine — Phase 0 of multi-DAC speaker groups, PR 0.3: `vespertine-probe group-skew`. A timing chirp from each DAC,
// heard by one microphone, N times; how far apart the two arrive and how much that moves from start to start.
// Everything here runs on the simulated room (a scripted delay per output channel); the opt-in test at the end uses Core Audio.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio
@testable import VespertineGroupProbe

@Suite("Group skew")
struct GroupSkewTests {
    static let rate = 48_000.0

    static func layout(leadIn: Double = 0.4) throws -> RoomCaptureLayout { try GroupSkew.layout(rate: rate, leadIn: leadIn, level: 0.25) }

    static func simulated(leaderDelay: Double = 0.0081, followerDelay: Double = 0.0094, followerGain: Double = 0.04) -> SimulatedRoomDevice {
        let room = SimulatedRoomDevice()
        room.delaySeconds = [0: leaderDelay, 1: followerDelay]
        room.gain = [0: 0.05, 1: followerGain]
        return room
    }

    /// One capture of the simulated room, the way the runner does it: the skew device in front of the room.
    static func capture(_ room: SimulatedRoomDevice, layout: RoomCaptureLayout, control: Bool = false) async throws -> RoomRecording {
        let device = GroupSkewDevice(inner: room, leaderChannel: 0, followerChannel: 1, control: control)
        let session = RoomCaptureSession(device: device, permission: AlwaysGrantedMicrophone())
        let request = RoomCaptureRequest(inputDevice: 1, outputDevice: 2, inputChannel: 0, outputChannel: 1, referenceChannel: 0, layout: layout)
        return try await session.record(request)
    }

    // MARK: What is played

    @Test func theLeaderPlaysTheTwoReferencesAndTheFollowerOneChirpBetweenThem() throws {
        let layout = try Self.layout()
        let stimulus = GroupSkew.stimulus(layout: layout, leaderChannel: 4, followerChannel: 7, control: false)
        #expect(stimulus.tracks.map(\.channel) == [4, 7])
        #expect(stimulus.tracks.allSatisfy { $0.samples.count == layout.totalFrames })
        let ref = layout.reference.samples.map { Float($0 * layout.level) }
        func carries(_ track: [Float], at start: Int) -> Bool { (0..<ref.count).allSatisfy { track[start + $0] == ref[$0] || abs(track[start + $0] - ref[$0]) < 1e-6 } }
        let leader = stimulus.tracks[0].samples, follower = stimulus.tracks[1].samples
        #expect(carries(leader, at: layout.firstReferenceStart))
        #expect(carries(leader, at: layout.secondReferenceStart))
        #expect(carries(follower, at: layout.sweepStart))
        // The follower is silent everywhere else; the leader is silent at the follower's chirp.
        #expect(follower[..<layout.sweepStart].allSatisfy { $0 == 0 })
        #expect(follower[(layout.sweepStart + ref.count)...].allSatisfy { $0 == 0 })
        #expect(leader[layout.sweepStart..<layout.sweepStart + ref.count].allSatisfy { $0 == 0 })
    }

    @Test func controlModePlaysEverythingOnTheLeaderAlone() throws {
        let layout = try Self.layout()
        let stimulus = GroupSkew.stimulus(layout: layout, leaderChannel: 0, followerChannel: 1, control: true)
        #expect(stimulus.tracks.map(\.channel) == [0])
        let samples = stimulus.tracks[0].samples
        #expect(samples[layout.sweepStart..<layout.sweepStart + layout.reference.samples.count].contains { abs($0) > 0.01 })
    }

    @Test func theLeadInSetsHowSoonAfterTheStartTheFollowerIsHeard() throws {
        let short = try Self.layout(leadIn: 0.4), long = try Self.layout(leadIn: 4)
        #expect(GroupSkew.followerChirpSeconds(short) < GroupSkew.followerChirpSeconds(long))
        #expect(abs(GroupSkew.followerChirpSeconds(long) - GroupSkew.followerChirpSeconds(short) - 3.6) < 1e-6)
    }

    // MARK: What is measured

    @Test func theSkewIsTheFollowersExtraDelayInOutputFrames() async throws {
        let layout = try Self.layout()
        let recording = try await Self.capture(Self.simulated(), layout: layout)
        let m = try GroupSkew.measure(samples: recording.samples, layout: layout)
        // 9.4 ms − 8.1 ms = 1.3 ms = 62.4 frames at 48 kHz.
        #expect(abs(m.skewFrames - 62.4) < 0.5, "measured \(m.skewFrames)")
        #expect(abs(m.skewMicroseconds - 1_300) < 12, "measured \(m.skewMicroseconds) µs")
    }

    @Test func aFollowerThatArrivesEarlierGivesANegativeSkew() async throws {
        let layout = try Self.layout()
        let recording = try await Self.capture(Self.simulated(leaderDelay: 0.0094, followerDelay: 0.0081), layout: layout)
        let m = try GroupSkew.measure(samples: recording.samples, layout: layout)
        #expect(abs(m.skewFrames + 62.4) < 0.5, "measured \(m.skewFrames)")
    }

    @Test func controlModeMeasuresTheMethodsOwnZero() async throws {
        let layout = try Self.layout()
        let recording = try await Self.capture(Self.simulated(), layout: layout, control: true)
        let m = try GroupSkew.measure(samples: recording.samples, layout: layout, control: true)
        #expect(abs(m.skewFrames) < 0.5, "control skew \(m.skewFrames)")
    }

    @Test func aSilentFollowerIsAFailureNotANumber() async throws {
        let layout = try Self.layout()
        let recording = try await Self.capture(Self.simulated(followerGain: 0), layout: layout)
        #expect(throws: (any Error).self) { try GroupSkew.measure(samples: recording.samples, layout: layout) }
    }

    // MARK: Statistics and verdict

    @Test func statsAreMeanSpreadAndPeakToPeak() throws {
        let s = try #require(GroupSkew.stats([10, 12, 14, 12]))
        #expect(s.count == 4 && s.mean == 12 && s.min == 10 && s.max == 14 && s.peakToPeak == 4)
        #expect(abs(s.standardDeviation - (8.0 / 3.0).squareRoot()) < 1e-9)
        #expect(GroupSkew.stats([]) == nil)
        #expect(try #require(GroupSkew.stats([5])).standardDeviation == 0)
    }

    @Test func theVerdictComparesTheSpreadWithWhatTheEarCanTell() {
        // 25 µs is the lower end of the interaural-time threshold: 1.2 frames at 48 kHz.
        #expect(GroupSkew.verdict(peakToPeakFrames: 0.4, rate: 48_000) == .repeatable)
        #expect(GroupSkew.verdict(peakToPeakFrames: 1.1, rate: 48_000) == .repeatable)
        #expect(GroupSkew.verdict(peakToPeakFrames: 3, rate: 48_000) == .audibleImageShift)
        #expect(GroupSkew.verdict(peakToPeakFrames: 60, rate: 48_000) == .notRepeatable)
        // The same frames are shorter at a higher rate.
        #expect(GroupSkew.verdict(peakToPeakFrames: 2, rate: 96_000) == .repeatable)
    }

    // MARK: The whole run on the simulated room

    @Test func manyRestartsGiveOneSkewAndAZeroSpread() async throws {
        var config = GroupSkewConfig(inputDevice: 1, outputDevice: 2, leaderChannel: 0, followerChannel: 1, rate: Self.rate)
        config.runsPerLeadIn = 2
        config.leadIns = [0.4, 1.0]
        config.pauseSeconds = 0
        let report = try await GroupSkewRunner.run(config, makeDevice: { Self.simulated() }, permission: AlwaysGrantedMicrophone())
        #expect(report.runs.count == 4 && report.failures.isEmpty, "\(report.failures)")
        let all = try #require(report.overall)
        #expect(abs(all.mean - 62.4) < 0.5)
        #expect(all.peakToPeak < 0.5, "a scripted room does not wander: \(all.peakToPeak)")
        #expect(report.byLeadIn.count == 2)
        #expect(report.verdict == .repeatable)
    }

    @Test func failedCapturesAreCountedAndTheRestStillReported() async throws {
        var config = GroupSkewConfig(inputDevice: 1, outputDevice: 2, leaderChannel: 0, followerChannel: 1, rate: Self.rate)
        config.runsPerLeadIn = 3
        config.leadIns = [0.4]
        config.pauseSeconds = 0
        let calls = CallCounter()
        let report = try await GroupSkewRunner.run(config, makeDevice: { Self.simulated(followerGain: calls.next() == 2 ? 0 : 0.04) },
                                                   permission: AlwaysGrantedMicrophone())
        #expect(report.runs.count == 2 && report.failures.count == 1)
    }

    @Test func aRunNeedsAtLeastOneRunAndDistinctChannels() async {
        var config = GroupSkewConfig(inputDevice: 1, outputDevice: 2, leaderChannel: 3, followerChannel: 3, rate: Self.rate)
        await #expect(throws: (any Error).self) { _ = try await GroupSkewRunner.run(config, makeDevice: { Self.simulated() }, permission: AlwaysGrantedMicrophone()) }
        config.followerChannel = 4; config.runsPerLeadIn = 0
        await #expect(throws: (any Error).self) { _ = try await GroupSkewRunner.run(config, makeDevice: { Self.simulated() }, permission: AlwaysGrantedMicrophone()) }
    }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
