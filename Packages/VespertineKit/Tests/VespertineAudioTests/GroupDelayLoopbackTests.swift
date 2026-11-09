//
// Vespertine: speaker groups through the real engine with a delay (room correction's timing alone) on the leader's pair: the
// samples arrive late and still bit for bit, and the signal path says BIT-PERFECT; with a level trim added they are not, and it says
// ROOM CORRECTION.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Opt-in: VESPERTINE_GROUP_LOOPBACK=1 swift test --no-parallel --filter GroupDelayLoopback
// Needs "Vespertine Loopback" and a second virtual device ("BlackHole 2ch" unless VESPERTINE_GROUP_FOLLOWER names another),
// both unused by other processes, and audio input access for the test process. Nothing is audible: the devices are virtual.
//

import AVFAudio
import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio
import VespertineTestSupport

@Suite("Group delay loopback", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_GROUP_LOOPBACK"] == "1"))
struct GroupDelayLoopbackTests {
    static let leaderName = "Vespertine Loopback"
    static let followerName = ProcessInfo.processInfo.environment["VESPERTINE_GROUP_FOLLOWER"] ?? "BlackHole 2ch"
    static let rate = 96_000.0
    static let delayMs = 5.0

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

    /// A stereo song on the group with `levelDB` on the left channel and a delay on both; returns the leader's recording and the path.
    private func play(levelDB: Double) throws -> (left: [Float], right: [Float], path: SignalPath?, frames: Int) {
        let members = try devices()
        let found = members.map(nominal)
        defer { for (d, r) in zip(members, found) { try? DeviceControl.setNominalRate(r, on: d.id) } }
        let group = SpeakerGroup(name: "Vespertine test group",
                                 members: members.map { SpeakerGroup.Member(deviceUID: $0.uid, name: $0.name, channelCount: 2) },
                                 clockLeaderUID: members[0].uid)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("groupdelay-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let seconds = 3.0, frames = Int(Self.rate * seconds)
        try ChannelID.writeWAV(to: url, channels: 2, frames: frames, rate: Self.rate, mask: 0x3)

        for d in members { try DeviceControl.setNominalRate(Self.rate, on: d.id) }
        let recorder = try LoopbackRecorder(device: members[0].id, rate: Self.rate, maxChannels: 2)
        try recorder.start()
        defer { recorder.restore() }

        var settings = EngineSettings()
        settings.exclusive = false
        settings.deviceUID = group.outputUID
        settings.deviceName = group.name
        settings.speakerGroups = [group]
        settings.roomCorrections[group.outputUID] = RoomCorrectionPlayback(
            profileID: UUID(), name: "Timing", preampDB: 0,
            channels: [RoomChannelPlayback(delayMs: Self.delayMs, levelDB: levelDB), RoomChannelPlayback(delayMs: Self.delayMs)])
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
        return (recorder.samples[0], recorder.samples[1], path, frames)
    }

    @Test("A delay alone: the leader's samples arrive late and bit for bit, and the path says BIT-PERFECT")
    func delayOnly() throws {
        let run = try play(levelDB: 0)
        #expect(run.path?.isBitPerfect == true && run.path?.statusLine == "BIT-PERFECT", "\(run.path?.statusLine ?? "no path")")
        #expect(run.path?.group?.stage == .integerDelay)
        let anchor = Int(Self.rate * 0.5)
        let start = try #require(run.left.indices.first { i in ChannelID.decode(run.left[i]).map { $0.channel == 0 && $0.frame == anchor } ?? false },
                                 "source frame \(anchor) never reached the leader")
        let window = run.frames - anchor - Int(Self.rate * 0.05) - Int(Self.rate * Self.delayMs / 1000)
        try #require(start + window <= run.left.count && start + window <= run.right.count, "recording ends early")
        var interleaved = [Float](repeating: 0, count: window * 2)
        for f in 0..<window { interleaved[f * 2] = run.left[start + f]; interleaved[f * 2 + 1] = run.right[start + f] }
        #expect(ChannelID.identify(interleaved, stride: 2, frames: window, firstFrame: anchor) == [0, 1])
    }

    @Test("A level trim on top: the samples are no longer the file's, and the path says ROOM CORRECTION")
    func withLevel() throws {
        let run = try play(levelDB: -3)
        #expect(run.path?.isBitPerfect == false && run.path?.statusLine == "ROOM CORRECTION", "\(run.path?.statusLine ?? "no path")")
        #expect(run.path?.group?.stage == .roomCorrection)
    }
}
