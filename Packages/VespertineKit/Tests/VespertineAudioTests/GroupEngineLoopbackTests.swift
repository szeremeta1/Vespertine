//
// Vespertine — speaker groups through the real engine: a quad file chosen on a group of two virtual devices, recorded back from
// each member's input. The leader's channels arrive bit for bit; the follower's, resampled to stay in step, arrive as the tones
// they were; the signal path names the members; and stopping leaves no aggregate and nothing held.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Opt-in: VESPERTINE_GROUP_LOOPBACK=1 swift test --filter GroupEngineLoopback
// Needs "Vespertine Loopback" and a second virtual device ("BlackHole 2ch" unless VESPERTINE_GROUP_FOLLOWER names another),
// both unused by other processes, and audio input access for the test process. Nothing is audible: the devices are virtual.
//

import AVFAudio
import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio
import VespertineTestSupport

@Suite("Group engine loopback", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_GROUP_LOOPBACK"] == "1"))
struct GroupEngineLoopbackTests {
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

    @Test("A quad file on a group: the leader's channels bit for bit, the follower's as tones, the members named in the path, everything let go")
    func quad() throws {
        let members = try devices()
        let found = members.map(nominal)
        defer { for (d, r) in zip(members, found) { try? DeviceControl.setNominalRate(r, on: d.id) } }
        let before = Set(DeviceQuery.allDeviceIDs())
        let group = SpeakerGroup(name: "Vespertine test group",
                                 members: members.map { SpeakerGroup.Member(deviceUID: $0.uid, name: $0.name, channelCount: 2) },
                                 clockLeaderUID: members[0].uid)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grouploop-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let seconds = 3.0, frames = Int(Self.rate * seconds)
        try ChannelID.writeWAV(to: url, channels: 4, frames: frames, rate: Self.rate, mask: 0x33) { c, f in
            c < 2 ? ChannelID.word(channel: c, frame: f)
                  : Int32(0.25 * Double(1 << 23) * sin(2 * Double.pi * Self.tones[c - 2] * Double(f) / Self.rate))
        }

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

        // The path names the group and its members, read back from the members.
        let applied = try #require(path?.applied)
        #expect(path?.deviceUID == group.outputUID)
        #expect(applied.members.map(\.uid) == members.map(\.uid))
        #expect(applied.members.map(\.resampled) == [false, true])
        #expect(applied.sampleRate == Self.rate && applied.virtualChannels == 4 && applied.streamCount == 2)

        // The leader: source channels 0 and 1, every sample the file's own.
        let anchor = Int(Self.rate * 0.5)
        let left = leaderRec.samples[0]
        let start = try #require(left.indices.first { i in ChannelID.decode(left[i]).map { $0.channel == 0 && $0.frame == anchor } ?? false },
                                 "source frame \(anchor) never reached the leader")
        let window = frames - anchor - Int(Self.rate * 0.05)
        try #require(start + window <= left.count && start + window <= leaderRec.samples[1].count, "recording ends early")
        var interleaved = [Float](repeating: 0, count: window * 2)
        for ch in 0..<2 { for f in 0..<window { interleaved[f * 2 + ch] = leaderRec.samples[ch][start + f] } }
        #expect(ChannelID.identify(interleaved, stride: 2, frames: window, firstFrame: anchor) == [0, 1])

        // The follower: its two tones, each on its own channel, nothing else.
        let from = Int(Self.rate * 1.0), count = Int(Self.rate * 1.0)
        try #require(followerRec.samples[0].count >= from + count && followerRec.samples[1].count >= from + count)
        for (ch, tone) in Self.tones.enumerated() {
            let slice = followerRec.samples[ch][from..<(from + count)]
            let other = Self.tones[1 - ch]
            #expect(toneShare(slice, tone: tone) > 0.99, "follower channel \(ch + 1) is not its \(tone) Hz tone")
            #expect(toneShare(slice, tone: other) < 0.01)
        }

        #expect(Set(DeviceQuery.allDeviceIDs()) == before, "the aggregate is gone")
        for d in members { #expect(DeviceControl.hogOwner(d.id) == -1) }
    }
}
