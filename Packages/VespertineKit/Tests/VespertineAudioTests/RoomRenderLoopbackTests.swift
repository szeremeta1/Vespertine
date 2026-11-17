//
// Vespertine: speaker groups: Fill the room through the real engine. A stereo song (one tone, the same on both channels) played
// on a quad of two virtual devices and recorded back from each one's input, three times: with the switch off, with the stage in
// front, and filled evenly. Off, the back pair is silent; stage in front, it plays the song 3 dB under the front pair; even, at
// the front pair's level. The signal path says ROOM RENDER when, and only when, the switch is on.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Opt-in: VESPERTINE_GROUP_LOOPBACK=1 VESPERTINE_GROUP_FOLLOWER="Vespertine Loopback B" swift test --filter RoomRenderLoopback
// Needs "Vespertine Loopback" and a second virtual device, both unused by other processes, and audio input access for the test
// process. Nothing is audible: the devices are virtual.
//

import AVFAudio
import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio
import VespertineTestSupport

@Suite("Fill the room loopback", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_GROUP_LOOPBACK"] == "1"))
struct RoomRenderLoopbackTests {
    static let leaderName = "Vespertine Loopback"
    static let followerName = ProcessInfo.processInfo.environment["VESPERTINE_GROUP_FOLLOWER"] ?? "BlackHole 2ch"
    static let rate = 48_000.0
    static let tone = 1_000.0
    static let level = 0.25

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

    /// The amplitude of the tone in `samples`.
    private func amplitude(_ samples: ArraySlice<Float>) -> Double {
        let w = 2 * Double.pi * Self.tone / Self.rate
        var re = 0.0, im = 0.0
        for (i, s) in samples.enumerated() { re += Double(s) * cos(w * Double(i)); im += Double(s) * sin(w * Double(i)) }
        return 2 * (re * re + im * im).squareRoot() / Double(max(samples.count, 1))
    }

    /// Plays the song on `group` and returns the tone's amplitude on front left, front right, back left, back right, with the
    /// badges the signal path showed.
    private func play(_ url: URL, seconds: Double, on group: SpeakerGroup, members: [OutputDevice]) throws -> (levels: [Double], badges: [String]) {
        let frontRec = try LoopbackRecorder(device: members[0].id, rate: Self.rate, maxChannels: 2)
        let backRec = try LoopbackRecorder(device: members[1].id, rate: Self.rate, maxChannels: 2)
        try frontRec.start()
        try backRec.start()
        defer { frontRec.restore(); backRec.restore() }

        var settings = EngineSettings()
        settings.exclusive = false
        settings.deviceUID = group.outputUID
        settings.deviceName = group.name
        settings.speakerGroups = [group]
        let engine = PlaybackEngine()
        engine.update(settings: settings)
        Thread.sleep(forTimeInterval: 0.2)
        frontRec.drain(); backRec.drain()
        let skip = [frontRec.samples[0].count, backRec.samples[0].count]
        engine.play(PlayableItem(url: url))

        let started = Date()
        var played = false, badges: [String] = []
        while Date().timeIntervalSince(started) < seconds + 8 {
            Thread.sleep(forTimeInterval: 0.01)
            frontRec.drain(); backRec.drain()
            let snap = engine.snapshot
            if snap.state == .playing {
                played = true
                if let shown = snap.signalPath?.group?.badges, badges.isEmpty { badges = shown }
            }
            if played, snap.state == .stopped { break }
        }
        let tail = Date().addingTimeInterval(0.3)
        while Date() < tail { Thread.sleep(forTimeInterval: 0.02); frontRec.drain(); backRec.drain() }
        engine.stopAndWait()
        frontRec.stop(); backRec.stop()
        try #require(played, "never played")

        // The loudest second of each recording: the song is 3 s of one steady tone.
        var levels: [Double] = []
        for (rec, from) in [(frontRec, skip[0]), (backRec, skip[1])] {
            for ch in 0..<2 {
                let x = rec.samples[ch]
                let window = Int(Self.rate)
                var best = 0.0, at = from
                while at + window <= x.count { best = max(best, amplitude(x[at..<(at + window)])); at += window / 4 }
                levels.append(best)
            }
        }
        return (levels, badges)
    }

    @Test("Off, the back pair is silent; stage in front, 3 dB under the front pair; even, at the front pair's level")
    func fills() throws {
        let members = try devices()
        let found = members.map(nominal)
        defer { for (d, r) in zip(members, found) { try? DeviceControl.setNominalRate(r, on: d.id) } }
        let before = Set(DeviceQuery.allDeviceIDs())
        let front = members[0].uid, back = members[1].uid
        func group(_ render: RoomRenderSettings?) -> SpeakerGroup {
            SpeakerGroup(name: "Vespertine test group",
                         members: members.map { SpeakerGroup.Member(deviceUID: $0.uid, name: $0.name, channelCount: 2) },
                         clockLeaderUID: front,
                         speakers: [.init(role: .frontLeft, deviceUID: front, channel: 0, position: Point2D(x: 0, y: 1)),
                                    .init(role: .frontRight, deviceUID: front, channel: 1, position: Point2D(x: 1, y: 1)),
                                    .init(role: .backLeft, deviceUID: back, channel: 0, position: Point2D(x: 0, y: -1)),
                                    .init(role: .backRight, deviceUID: back, channel: 1, position: Point2D(x: 1, y: -1))],
                         listener: Listener(position: Point2D(x: 0.5, y: 0)), stereoPolicy: .frontOnly, lfePolicy: .drop, roomRender: render)
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fillloop-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let seconds = 3.0
        try ChannelID.writeWAV(to: url, channels: 2, frames: Int(Self.rate * seconds), rate: Self.rate, mask: 0x3) { _, f in
            Int32(Self.level * Double(1 << 23) * sin(2 * Double.pi * Self.tone * Double(f) / Self.rate))
        }
        for d in members { try DeviceControl.setNominalRate(Self.rate, on: d.id) }

        func dB(_ a: Double, over b: Double) -> Double { 20 * log10(max(a, 1e-9) / max(b, 1e-9)) }
        var lines: [String] = []
        func report(_ name: String, _ r: (levels: [Double], badges: [String])) {
            let l = r.levels.map { String(format: "%.1f", dB($0, over: 1)) }
            lines.append("FILLLOOP \(name): FL \(l[0]) FR \(l[1]) BL \(l[2]) BR \(l[3]) dBFS, badges \(r.badges)")
        }

        let off = try play(url, seconds: seconds, on: group(nil), members: members)
        report("off", off)
        let stage = try play(url, seconds: seconds, on: group(RoomRenderSettings()), members: members)
        report("stage in front", stage)
        let even = try play(url, seconds: seconds, on: group(RoomRenderSettings(style: .even)), members: members)
        report("even everywhere", even)
        print(lines.joined(separator: "\n"))

        for r in [off, stage, even] {
            for f in 0..<2 { #expect(abs(dB(r.levels[f], over: Self.level)) < 0.2, "the front pair plays the song at its own level") }
        }
        for b in 2..<4 {
            #expect(dB(off.levels[b], over: off.levels[0]) < -60, "off: the back pair is silent")
            #expect(abs(dB(stage.levels[b], over: stage.levels[b - 2]) + 3) < 0.5, "stage in front: 3 dB under the front pair")
            #expect(abs(dB(even.levels[b], over: even.levels[b - 2])) < 0.3, "even: at the front pair's level")
        }
        #expect(!off.badges.contains("ROOM RENDER"))
        #expect(stage.badges.contains("ROOM RENDER") && even.badges.contains("ROOM RENDER"))
        #expect(Set(DeviceQuery.allDeviceIDs()) == before, "the aggregate is gone")
    }
}
