//
// Vespertine: speaker groups: an output session on a real group of two virtual devices. The aggregate is not held, the
// members are; the format is the members' own; the session runs; and letting go leaves no aggregate and no hold behind.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Opt-in: VESPERTINE_GROUP_LOOPBACK=1 swift test --filter GroupSessionLoopback
// Needs "Vespertine Loopback" and a second virtual device ("BlackHole 2ch" unless VESPERTINE_GROUP_FOLLOWER names another),
// both unused by other processes. Silence is played for a moment; the members' rates are put back afterwards.
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group session loopback", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_GROUP_LOOPBACK"] == "1"))
struct GroupSessionLoopbackTests {
    static let leaderName = "Vespertine Loopback"
    static let followerName = ProcessInfo.processInfo.environment["VESPERTINE_GROUP_FOLLOWER"] ?? "BlackHole 2ch"
    static let rate = 96_000.0

    private func devices() throws -> [OutputDevice] {
        let all = OutputDevices.list()
        let leader = try #require(all.first { $0.name == Self.leaderName && $0.transport == .virtual }, "no \(Self.leaderName)")
        let follower = try #require(all.first { $0.name == Self.followerName && $0.transport == .virtual }, "no \(Self.followerName)")
        try #require(!LoopbackGuard.inUseByOthers(leader.id) && !LoopbackGuard.inUseByOthers(follower.id), "a device is in use by another process; left alone")
        try #require(leader.capabilities.supports(rate: Self.rate) && follower.capabilities.supports(rate: Self.rate), "a device lacks \(Self.rate) Hz")
        return [leader, follower]
    }

    private func nominal(_ device: OutputDevice) -> Double {
        (try? HAL.get(device.id, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0
    }

    private func group(_ devices: [OutputDevice]) -> SpeakerGroup {
        SpeakerGroup(name: "Vespertine test group",
                     members: devices.map { SpeakerGroup.Member(deviceUID: $0.uid, name: $0.name, channelCount: 2) },
                     clockLeaderUID: devices[0].uid)
    }

    private func plan(_ devices: [OutputDevice]) -> OutputPlan {
        let source = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: Self.rate, bitDepth: 24, channels: 4)
        return GroupFormatRules.plan(source: source, device: GroupCapabilities.combined(devices.map(\.capabilities)))
    }

    @Test("A session on a group: members held and at the rate, the aggregate not held, the format read from the members, then everything let go")
    func openRunClose() throws {
        let members = try devices()
        let found = members.map(nominal)
        defer { for (d, r) in zip(members, found) { try? DeviceControl.setNominalRate(r, on: d.id) } }
        let before = Set(DeviceQuery.allDeviceIDs())
        let group = group(members)
        let resources = try GroupSessionResources.open(group: group, devices: members, rate: Self.rate, exclusive: true)
        let aggregateID = resources.aggregate.id, aggregateUID = resources.aggregate.plan.uid
        let session = try OutputSession(deviceID: aggregateID, plan: plan(members), exclusive: true, group: resources)

        let applied = session.applied
        #expect(applied.sampleRate == Self.rate)
        #expect(applied.streamCount == 2 && applied.virtualChannels == 4)
        #expect(applied.members.map(\.uid) == members.map(\.uid))
        #expect(applied.members.map(\.resampled) == [false, true])
        #expect(applied.members.map(\.channelOffset) == [0, 2])
        #expect(applied.members.allSatisfy { $0.sampleRate == Self.rate && $0.exclusive && $0.physicalFormatKnown })
        #expect(applied.exclusive && applied.physicalFormatKnown && !applied.integerMode)
        #expect(DeviceControl.hogOwner(aggregateID) != getpid(), "the aggregate has no hog; only the members are held")
        for d in members { #expect(DeviceControl.hogOwner(d.id) == getpid()) }
        #expect(!session.formatChanged(), "nothing moved yet")

        try session.start()
        usleep(300_000)
        #expect(session.isRunning)
        session.invalidate(releaseHog: true)

        #expect(GroupAggregateDevice.deviceID(uid: aggregateUID) == nil)
        for d in members { #expect(DeviceControl.hogOwner(d.id) == -1) }
        #expect(Set(DeviceQuery.allDeviceIDs()) == before)
    }

    @Test("A change to a member's rate by someone else is noticed by the session")
    func memberRateChange() throws {
        let members = try devices()
        let found = members.map(nominal)
        defer { for (d, r) in zip(members, found) { try? DeviceControl.setNominalRate(r, on: d.id) } }
        let resources = try GroupSessionResources.open(group: group(members), devices: members, rate: Self.rate, exclusive: false)
        let session = try OutputSession(deviceID: resources.aggregate.id, plan: plan(members), exclusive: false, group: resources)
        defer { session.invalidate(releaseHog: true) }
        #expect(!session.formatChanged())
        try DeviceControl.setNominalRate(48_000, on: members[1].id)
        usleep(300_000)
        #expect(session.formatChanged())
    }

    @Test("Handing the holds on: the next session starts with the members still held")
    func keepHolding() throws {
        let members = try devices()
        let found = members.map(nominal)
        defer { for (d, r) in zip(members, found) { try? DeviceControl.setNominalRate(r, on: d.id) } }
        let first = try GroupSessionResources.open(group: group(members), devices: members, rate: Self.rate, exclusive: true)
        let session = try OutputSession(deviceID: first.aggregate.id, plan: plan(members), exclusive: true, group: first)
        session.invalidate(releaseHog: false, restoreFormat: false)
        for d in members { #expect(DeviceControl.hogOwner(d.id) == getpid(), "kept for the next session") }
        let second = try GroupSessionResources.open(group: group(members), devices: members, rate: Self.rate, exclusive: true)
        second.release()
        for d in members { #expect(DeviceControl.hogOwner(d.id) == -1) }
    }
}
