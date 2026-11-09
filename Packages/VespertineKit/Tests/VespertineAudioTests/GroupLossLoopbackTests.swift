//
// Vespertine — speaker groups through the real engine when a member goes away and comes back: the engine is shown a list of
// outputs without the follower, and then with it again (the devices are virtual and stay where they are). Pause policy: the
// group pauses, lets go of everything, and plays on from the same position when the follower returns. Carry-on policy: the song
// goes on on the leader alone, and moves back to the group when the follower returns.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Opt-in: VESPERTINE_GROUP_LOOPBACK=1 swift test --filter GroupLossLoopback
// Needs "Vespertine Loopback" and a second virtual device ("BlackHole 2ch" unless VESPERTINE_GROUP_FOLLOWER names another),
// both unused by other processes. Nothing is audible: the devices are virtual.
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group loss loopback", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_GROUP_LOOPBACK"] == "1"))
struct GroupLossLoopbackTests {
    static let leaderName = "Vespertine Loopback"
    static let followerName = ProcessInfo.processInfo.environment["VESPERTINE_GROUP_FOLLOWER"] ?? "BlackHole 2ch"
    static let rate = 96_000.0

    private func devices() throws -> [OutputDevice] {
        let all = DeviceQuery.outputDevices(dopEnabledUIDs: [])
        let leader = try #require(all.first { $0.name == Self.leaderName && $0.transport == .virtual }, "no \(Self.leaderName)")
        let follower = try #require(all.first { $0.name == Self.followerName && $0.transport == .virtual }, "no \(Self.followerName)")
        try #require(!LoopbackGuard.inUseByOthers(leader.id) && !LoopbackGuard.inUseByOthers(follower.id), "a device is in use by another process; left alone")
        try #require(leader.capabilities.supports(rate: Self.rate) && follower.capabilities.supports(rate: Self.rate), "a device lacks \(Self.rate) Hz")
        return [leader, follower]
    }

    private func nominal(_ device: OutputDevice) -> Double {
        (try? HAL.get(device.id, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0
    }

    private func wait(_ seconds: Double, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; Thread.sleep(forTimeInterval: 0.02) }
        return condition()
    }

    private struct Run {
        let engine: PlaybackEngine
        let group: SpeakerGroup
        let members: [OutputDevice]
        let url: URL
        /// Whether the follower is shown to the engine.
        let followerShown: LockedBool
    }

    private final class LockedBool: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) { self.value = value }
        var get: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    }

    private func start(loss: LossPolicy, exclusive: Bool) throws -> Run {
        let members = try devices()
        for d in members { try DeviceControl.setNominalRate(Self.rate, on: d.id) }
        let group = SpeakerGroup(name: "Vespertine test group",
                                 members: members.map { SpeakerGroup.Member(deviceUID: $0.uid, name: $0.name, channelCount: 2) },
                                 clockLeaderUID: members[0].uid, onMemberLoss: loss)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grouploss-\(UUID()).wav")
        try ChannelID.writeWAV(to: url, channels: 4, frames: Int(Self.rate * 30), rate: Self.rate, mask: 0x33)
        let shown = LockedBool(true)
        let followerUID = members[1].uid
        let engine = PlaybackEngine()
        engine.outputListing = { DeviceQuery.outputDevices(dopEnabledUIDs: []).filter { shown.get || $0.uid != followerUID } }
        var settings = EngineSettings()
        settings.exclusive = exclusive
        settings.deviceUID = group.outputUID
        settings.deviceName = group.name
        settings.speakerGroups = [group]
        engine.update(settings: settings)
        Thread.sleep(forTimeInterval: 0.2)
        engine.play(PlayableItem(url: url))
        try #require(wait(10) { engine.snapshot.state == .playing && engine.snapshot.position > 0.3 }, "never played")
        return Run(engine: engine, group: group, members: members, url: url, followerShown: shown)
    }

    @Test("Pause policy: a follower that goes away pauses the group and frees everything; its return plays on from where it was")
    func pauseAndReturn() throws {
        let probe = try devices()
        let found = probe.map(nominal)
        defer { for (d, r) in zip(probe, found) { try? DeviceControl.setNominalRate(r, on: d.id) } }
        let before = Set(DeviceQuery.allDeviceIDs())
        let run = try start(loss: .pause, exclusive: true)
        defer { run.engine.stopAndWait(); try? FileManager.default.removeItem(at: run.url) }
        for d in run.members { #expect(DeviceControl.hogOwner(d.id) == getpid()) }

        run.followerShown.set(false)
        run.engine.devicesChanged()
        #expect(wait(5) { run.engine.snapshot.state == .paused && run.engine.snapshot.waitingForDevice == run.members[1].name },
                "state \(run.engine.snapshot.state), waiting \(run.engine.snapshot.waitingForDevice ?? "-")")
        let pausedAt = run.engine.snapshot.position
        #expect(Set(DeviceQuery.allDeviceIDs()) == before, "the aggregate is gone")
        for d in run.members { #expect(DeviceControl.hogOwner(d.id) == -1, "\(d.name) is let go") }

        run.followerShown.set(true)
        run.engine.devicesChanged()
        #expect(wait(8) { run.engine.snapshot.state == .playing && run.engine.snapshot.position > pausedAt + 0.2 },
                "state \(run.engine.snapshot.state), position \(run.engine.snapshot.position) after \(pausedAt)")
        #expect(run.engine.snapshot.signalPath?.deviceUID == run.group.outputUID)
        #expect(run.engine.snapshot.signalPath?.applied.members.count == 2)
        #expect(pausedAt < run.engine.snapshot.position, "from where it was, not from the start")
    }

    @Test("Carry-on policy: the song goes on on the leader alone, and moves back to the group when the follower returns")
    func continueAndReturn() throws {
        let probe = try devices()
        let found = probe.map(nominal)
        defer { for (d, r) in zip(probe, found) { try? DeviceControl.setNominalRate(r, on: d.id) } }
        let run = try start(loss: .continueOnRemaining, exclusive: false)
        defer { run.engine.stopAndWait(); try? FileManager.default.removeItem(at: run.url) }

        run.followerShown.set(false)
        run.engine.devicesChanged()
        #expect(wait(8) { run.engine.snapshot.state == .playing && run.engine.snapshot.signalPath?.deviceUID == run.members[0].uid },
                "state \(run.engine.snapshot.state) on \(run.engine.snapshot.signalPath?.deviceName ?? "-")")
        #expect(run.engine.snapshot.standingInFor == run.group.name)
        #expect(run.engine.snapshot.signalPath?.applied.members.isEmpty == true, "a single device again")
        let at = run.engine.snapshot.position

        run.followerShown.set(true)
        run.engine.devicesChanged()
        #expect(wait(8) { run.engine.snapshot.state == .playing && run.engine.snapshot.signalPath?.deviceUID == run.group.outputUID },
                "state \(run.engine.snapshot.state) on \(run.engine.snapshot.signalPath?.deviceName ?? "-")")
        #expect(run.engine.snapshot.standingInFor == nil)
        #expect(run.engine.snapshot.position >= at, "from where it was, not from the start")
    }
}
