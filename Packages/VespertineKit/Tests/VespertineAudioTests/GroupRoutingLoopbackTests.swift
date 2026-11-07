//
// Vespertine — speaker groups routed by where the speakers stand, through the real engine: a stereo song on a group of two virtual
// devices, recorded back from each member's input. Front only, the leader's pair holds the file bit for bit and the follower is
// silent; mirrored, the follower repeats the song at the chosen level; and the path says which DACs played.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Opt-in: VESPERTINE_GROUP_LOOPBACK=1 swift test --no-parallel --filter GroupRoutingLoopback
// Needs "Vespertine Loopback" and a second virtual device ("BlackHole 2ch" unless VESPERTINE_GROUP_FOLLOWER names another),
// both unused by other processes, and audio input access for the test process. Nothing is audible: the devices are virtual.
//

import AVFAudio
import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio
import VespertineTestSupport

@Suite("Group routing loopback", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_GROUP_LOOPBACK"] == "1"))
struct GroupRoutingLoopbackTests {
    static let leaderName = "Vespertine Loopback"
    static let followerName = ProcessInfo.processInfo.environment["VESPERTINE_GROUP_FOLLOWER"] ?? "BlackHole 2ch"
    static let rate = 96_000.0
    static let tones = [1_000.0, 2_000.0]

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

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
    }

    /// Energy of `tone` in `samples` over its total energy (1: a pure tone, 0: none of it).
    private func toneShare(_ samples: ArraySlice<Float>, tone: Double) -> Double {
        let w = 2 * Double.pi * tone / Self.rate
        var re = 0.0, im = 0.0, total = 0.0
        for (i, s) in samples.enumerated() {
            re += Double(s) * cos(w * Double(i)); im += Double(s) * sin(w * Double(i)); total += Double(s) * Double(s)
        }
        let n = Double(samples.count)
        return total > 0 ? 2 * (re * re + im * im) / (n * total) : 0
    }

    struct Played {
        var leader: [[Float]]
        var follower: [[Float]]
        var path: SignalPath?
        var frames: Int
    }

    /// Plays a stereo file made by `sample` on a quad made of the two devices with `policy`, and records both members.
    private func play(policy: StereoPolicy, sample: @escaping (Int, Int) -> Int32) throws -> Played {
        let members = try devices()
        let found = members.map(nominal)
        defer { for (d, r) in zip(members, found) { try? DeviceControl.setNominalRate(r, on: d.id) } }
        var group = SpeakerGroup(name: "Vespertine test group",
                                 members: members.map { SpeakerGroup.Member(deviceUID: $0.uid, name: $0.name, channelCount: 2) },
                                 clockLeaderUID: members[0].uid,
                                 speakers: [
                                    .init(role: .frontLeft, deviceUID: members[0].uid, channel: 0, position: Point2D(x: -1, y: 1.5)),
                                    .init(role: .frontRight, deviceUID: members[0].uid, channel: 1, position: Point2D(x: 1, y: 1.5)),
                                    .init(role: .backLeft, deviceUID: members[1].uid, channel: 0, position: Point2D(x: -1, y: -1.5)),
                                    .init(role: .backRight, deviceUID: members[1].uid, channel: 1, position: Point2D(x: 1, y: -1.5)),
                                 ])
        group.stereoPolicy = policy

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grouproute-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let seconds = 3.0, frames = Int(Self.rate * seconds)
        try ChannelID.writeWAV(to: url, channels: 2, frames: frames, rate: Self.rate, mask: 0x3, sample: sample)

        for d in members { try DeviceControl.setNominalRate(Self.rate, on: d.id) }
        let leaderRec = try LoopbackRecorder(device: members[0].id, rate: Self.rate, maxChannels: 2)
        let followerRec = try LoopbackRecorder(device: members[1].id, rate: Self.rate, maxChannels: 2)
        try leaderRec.start()
        try followerRec.start()
        defer { leaderRec.restore(); followerRec.restore() }

        var settings = EngineSettings()
        settings.exclusive = false
        settings.deviceUID = group.outputUID
        settings.deviceName = group.name
        settings.speakerGroups = [group]
        let engine = PlaybackEngine()
        engine.update(settings: settings)
        Thread.sleep(forTimeInterval: 0.2)
        leaderRec.drain(); followerRec.drain()
        engine.play(PlayableItem(url: url))

        let started = Date()
        var played = false, path: SignalPath?
        while Date().timeIntervalSince(started) < seconds + 8 {
            Thread.sleep(forTimeInterval: 0.01)
            leaderRec.drain(); followerRec.drain()
            let snap = engine.snapshot
            if snap.state == .playing { played = true; path = path ?? snap.signalPath }
            if played, snap.state == .stopped { break }
        }
        let tail = Date().addingTimeInterval(0.3)
        while Date() < tail { Thread.sleep(forTimeInterval: 0.02); leaderRec.drain(); followerRec.drain() }
        engine.stopAndWait()
        leaderRec.stop(); followerRec.stop()
        try #require(played, "never played")
        return Played(leader: leaderRec.samples, follower: followerRec.samples, path: path, frames: frames)
    }

    @Test("A stereo song on the quad, front only: the front pair holds the file bit for bit, the back pair is silent, and only the leader's DAC is named")
    func frontOnly() throws {
        let played = try play(policy: .frontOnly) { c, f in ChannelID.word(channel: c, frame: f) }
        let anchor = Int(Self.rate * 0.5)
        let left = played.leader[0]
        let start = try #require(left.indices.first { i in ChannelID.decode(left[i]).map { $0.channel == 0 && $0.frame == anchor } ?? false },
                                 "source frame \(anchor) never reached the leader")
        let window = played.frames - anchor - Int(Self.rate * 0.05)
        try #require(start + window <= left.count && start + window <= played.leader[1].count, "recording ends early")
        var interleaved = [Float](repeating: 0, count: window * 2)
        for ch in 0..<2 { for f in 0..<window { interleaved[f * 2 + ch] = played.leader[ch][start + f] } }
        #expect(ChannelID.identify(interleaved, stride: 2, frames: window, firstFrame: anchor) == [0, 1])
        // Nothing reached the follower.
        let from = Int(Self.rate * 1.0), count = Int(Self.rate * 1.0)
        try #require(played.follower[0].count >= from + count)
        for ch in 0..<2 { #expect(played.follower[ch][from..<(from + count)].allSatisfy { abs($0) < 1e-5 }, "follower channel \(ch + 1) is not silent") }
        let path = try #require(played.path)
        #expect(path.group?.members.map(\.speakers) == [[.frontLeft, .frontRight], []])
        #expect(path.group?.folds == false)
        #expect(path.applied.virtualChannels == 4 && path.plan.channels == 4)
    }

    @Test("A stereo song mirrored to the back pair at -6 dB: the follower repeats each side at half the level, and both DACs are named")
    func mirrored() throws {
        let played = try play(policy: .mirror(trimDB: -6)) { c, f in
            Int32(0.25 * Double(1 << 23) * sin(2 * Double.pi * Self.tones[c] * Double(f) / Self.rate))
        }
        let from = Int(Self.rate * 1.0), count = Int(Self.rate * 1.0)
        try #require(played.follower[0].count >= from + count && played.leader[0].count >= from + count)
        for ch in 0..<2 {
            let lead = played.leader[ch][from..<(from + count)], follow = played.follower[ch][from..<(from + count)]
            #expect(toneShare(follow, tone: Self.tones[ch]) > 0.99, "follower channel \(ch + 1) is not the \(Self.tones[ch]) Hz tone")
            #expect(toneShare(follow, tone: Self.tones[1 - ch]) < 0.01)
            let ratio = rms(follow) / max(rms(lead), 1e-9)
            #expect(abs(ratio - pow(10, -6.0 / 20)) < 0.02, "channel \(ch + 1): follower is \(ratio) of the leader")
        }
        let path = try #require(played.path)
        #expect(path.group?.members.map(\.speakers) == [[.frontLeft, .frontRight], [.backLeft, .backRight]])
        #expect(path.group?.badges.contains("RESAMPLED") == true)
    }
}
