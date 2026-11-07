//
// Vespertine — speaker groups through the real engine with a speaker's delay: a click on both channels of the leader's pair
// arrives on the delayed speaker's channel exactly the delay later than on the other, in whole frames; with no delay the two
// arrive together. The delay is a trim on the first speaker, which goes into the room chain the same way a member's measured
// skew does (the skew's arithmetic is in GroupDelayTests).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Opt-in: VESPERTINE_GROUP_LOOPBACK=1 swift test --no-parallel --filter GroupMemberDelayLoopback
// Needs "Vespertine Loopback" and a second virtual device ("BlackHole 2ch" unless VESPERTINE_GROUP_FOLLOWER names another),
// both unused by other processes, and audio input access for the test process. Nothing is audible: the devices are virtual.
//

import AVFAudio
import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio
import VespertineTestSupport

@Suite("Group member delay loopback", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_GROUP_LOOPBACK"] == "1"))
struct GroupMemberDelayLoopbackTests {
    static let leaderName = "Vespertine Loopback"
    static let followerName = ProcessInfo.processInfo.environment["VESPERTINE_GROUP_FOLLOWER"] ?? "BlackHole 2ch"
    static let rate = 96_000.0

    private func devices() throws -> [OutputDevice] {
        let all = DeviceQuery.outputDevices(dopEnabledUIDs: [])
        let leader = try #require(all.first { $0.name == Self.leaderName && $0.transport == .virtual }, "no \(Self.leaderName)")
        let follower = try #require(all.first { $0.name == Self.followerName && $0.transport == .virtual }, "no \(Self.followerName)")
        try #require(!LoopbackGuard.inUseByOthers(leader.id) && !LoopbackGuard.inUseByOthers(follower.id), "a device is in use by another process; left alone")
        try #require(leader.capabilities.supports(rate: Self.rate) && follower.capabilities.supports(rate: Self.rate), "a device lacks \(Self.rate) Hz")
        try #require(AVAudioApplication.shared.recordPermission != .denied, "audio input access denied")
        return [leader, follower]
    }

    private func nominal(_ device: OutputDevice) -> Double {
        (try? HAL.get(device.id, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0
    }

    /// The click's position on each of the leader's two channels (frames into the recording), with `trimMs` on the left speaker.
    private func clickPositions(trimMs: Double) throws -> (left: Int, right: Int, path: SignalPath?) {
        let members = try devices()
        let found = members.map(nominal)
        defer { for (d, r) in zip(members, found) { try? DeviceControl.setNominalRate(r, on: d.id) } }
        let speakers = [SpeakerGroup.Speaker(role: .frontLeft, deviceUID: members[0].uid, channel: 0, position: Point2D(x: -1, y: 1.5), delayTrimMs: trimMs),
                        SpeakerGroup.Speaker(role: .frontRight, deviceUID: members[0].uid, channel: 1, position: Point2D(x: 1, y: 1.5))]
        let group = SpeakerGroup(name: "Vespertine test group",
                                 members: members.map { SpeakerGroup.Member(deviceUID: $0.uid, name: $0.name, channelCount: 2) },
                                 clockLeaderUID: members[0].uid, speakers: speakers)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("groupclick-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let seconds = 3.0, frames = Int(Self.rate * seconds), clickAt = Int(Self.rate * 1.0)
        try ChannelID.writeWAV(to: url, channels: 2, frames: frames, rate: Self.rate, mask: 0x3) { _, f in f == clickAt ? Int32(1 << 22) : 0 }

        for d in members { try DeviceControl.setNominalRate(Self.rate, on: d.id) }
        let recorder = try LoopbackRecorder(device: members[0].id, rate: Self.rate, maxChannels: 2)
        try recorder.start()
        defer { recorder.restore() }

        var settings = EngineSettings()
        settings.exclusive = false
        settings.deviceUID = group.outputUID
        settings.deviceName = group.name
        settings.speakerGroups = [group]
        let engine = PlaybackEngine()
        engine.update(settings: settings)
        Thread.sleep(forTimeInterval: 0.2)
        recorder.drain()
        engine.play(PlayableItem(url: url))
        let started = Date()
        var played = false, path: SignalPath?
        while Date().timeIntervalSince(started) < seconds + 8 {
            Thread.sleep(forTimeInterval: 0.01)
            recorder.drain()
            let snap = engine.snapshot
            if snap.state == .playing { played = true; path = path ?? snap.signalPath }
            if played, snap.state == .stopped { break }
        }
        let tail = Date().addingTimeInterval(0.3)
        while Date() < tail { Thread.sleep(forTimeInterval: 0.02); recorder.drain() }
        engine.stopAndWait()
        recorder.stop()
        try #require(played, "never played")
        func peak(_ samples: [Float]) throws -> Int {
            let at = try #require(samples.indices.max { abs(samples[$0]) < abs(samples[$1]) }, "empty recording")
            try #require(abs(samples[at]) > 0.2, "no click on a channel (peak \(abs(samples[at])))")
            return at
        }
        return (try peak(recorder.samples[0]), try peak(recorder.samples[1]), path)
    }

    @Test("No delay: the click arrives on both channels together")
    func together() throws {
        let run = try clickPositions(trimMs: 0)
        #expect(run.left == run.right, "left \(run.left), right \(run.right)")
    }

    @Test("5 ms on the left speaker: its click arrives 480 frames later at 96 kHz, in whole frames, and the path stays bit-perfect")
    func delayed() throws {
        let run = try clickPositions(trimMs: 5)
        #expect(run.left - run.right == 480, "left \(run.left), right \(run.right)")
        #expect(run.path?.group?.stage == .integerDelay)
        #expect(run.path?.isBitPerfect == true, "\(run.path?.statusLine ?? "no path")")
    }
}
