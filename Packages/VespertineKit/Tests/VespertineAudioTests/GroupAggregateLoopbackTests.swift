//
// Vespertine: speaker groups: a real private aggregate of two virtual devices. What Core Audio holds after creating it (the
// main sub-device, the drift flags and quality per sub-device, a stream per member), that it stays out of the device list,
// and that it is gone after being destroyed.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Opt-in: VESPERTINE_GROUP_LOOPBACK=1 swift test --filter GroupAggregateLoopback
// Needs "Vespertine Loopback" and a second virtual device ("BlackHole 2ch" unless VESPERTINE_GROUP_FOLLOWER names another),
// both unused by other processes. Nothing is played or recorded and no device setting is changed.
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group aggregate loopback", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_GROUP_LOOPBACK"] == "1"))
struct GroupAggregateLoopbackTests {
    static let leaderName = "Vespertine Loopback"
    static let followerName = ProcessInfo.processInfo.environment["VESPERTINE_GROUP_FOLLOWER"] ?? "BlackHole 2ch"

    private func devices() throws -> (leader: OutputDevice, follower: OutputDevice) {
        let all = OutputDevices.list()
        let leader = try #require(all.first { $0.name == Self.leaderName && $0.transport == .virtual }, "no \(Self.leaderName)")
        let follower = try #require(all.first { $0.name == Self.followerName && $0.transport == .virtual }, "no \(Self.followerName)")
        try #require(!LoopbackGuard.inUseByOthers(leader.id) && !LoopbackGuard.inUseByOthers(follower.id), "a device is in use by another process; left alone")
        return (leader, follower)
    }

    private func members(_ devices: [OutputDevice]) -> [GroupAggregate.Member] {
        devices.map { GroupAggregate.Member(uid: $0.uid, clockDomain: GroupAggregateDevice.clockDomain(uid: $0.uid)) }
    }

    @Test("Made, read back, hidden from the device list, and removed")
    func lifecycle() throws {
        let (leader, follower) = try devices()
        let before = Set(DeviceQuery.allDeviceIDs())
        let plan = try GroupAggregate.plan(name: "Vespertine test group", uid: GroupAggregate.makeUID(groupID: UUID()),
                                           members: members([leader, follower]), leaderUID: leader.uid)
        let aggregate = try GroupAggregateDevice.create(plan)
        defer { aggregate.destroy() }

        // What Core Audio holds, not what was asked for.
        #expect(aggregate.mainSubDeviceUID() == leader.uid)
        let states = aggregate.subDeviceStates()
        #expect(Set(states.map(\.uid)) == [leader.uid, follower.uid])
        let leaderState = try #require(states.first { $0.uid == leader.uid }), followerState = try #require(states.first { $0.uid == follower.uid })
        #expect(!leaderState.driftCompensation && followerState.driftCompensation)
        #expect(followerState.driftQuality == 0x7F)
        // One stream per member, in the group's order, all channels counted.
        #expect(DeviceQuery.outputStreams(aggregate.id).count == 2)
        #expect(DeviceQuery.outputChannelCount(aggregate.id) == DeviceQuery.outputChannelCount(leader.id) + DeviceQuery.outputChannelCount(follower.id))

        // It exists for Core Audio, and not for the device list.
        #expect(DeviceQuery.allDeviceIDs().contains(aggregate.id))
        #expect(!OutputDevices.list().contains { $0.id == aggregate.id || $0.uid == plan.uid })
        #expect(!OutputDevices.connectedUIDs().contains(plan.uid))

        aggregate.destroy()
        #expect(GroupAggregateDevice.deviceID(uid: plan.uid) == nil)
        #expect(Set(DeviceQuery.allDeviceIDs()) == before)
        aggregate.destroy()        // twice is harmless
    }

    @Test("The leader is the time base wherever it stands in the order, and is the one that isn't corrected")
    func leaderNotFirst() throws {
        let (leader, follower) = try devices()
        let plan = try GroupAggregate.plan(name: "Vespertine test group", uid: GroupAggregate.makeUID(groupID: UUID()),
                                           members: members([follower, leader]), leaderUID: leader.uid)
        let aggregate = try GroupAggregateDevice.create(plan)
        defer { aggregate.destroy() }
        #expect(aggregate.mainSubDeviceUID() == leader.uid)
        let states = aggregate.subDeviceStates()
        #expect(states.first { $0.uid == leader.uid }?.driftCompensation == false)
        #expect(states.first { $0.uid == follower.uid }?.driftCompensation == true)
    }

    @Test("Drift correction off, and a lower quality, reach the sub-devices")
    func settingsReachCoreAudio() throws {
        let (leader, follower) = try devices()
        var m = members([leader, follower])
        m[1].driftQuality = 0x40
        let off = try GroupAggregateDevice.create(GroupAggregate.plan(name: "Vespertine test group", uid: GroupAggregate.makeUID(groupID: UUID()),
                                                                      members: m, leaderUID: leader.uid, drift: .off))
        defer { off.destroy() }
        #expect(off.subDeviceStates().allSatisfy { !$0.driftCompensation })
        off.destroy()

        let on = try GroupAggregateDevice.create(GroupAggregate.plan(name: "Vespertine test group", uid: GroupAggregate.makeUID(groupID: UUID()),
                                                                     members: m, leaderUID: leader.uid))
        defer { on.destroy() }
        let state = try #require(on.subDeviceStates().first { $0.uid == follower.uid })
        #expect(state.driftQuality == 0x40 && state.driftCompensation)
    }

    @Test("Making and removing it again and again leaves nothing behind")
    func repeated() throws {
        let (leader, follower) = try devices()
        let before = Set(DeviceQuery.allDeviceIDs())
        for _ in 0..<3 {
            let aggregate = try GroupAggregateDevice.create(GroupAggregate.plan(name: "Vespertine test group", uid: GroupAggregate.makeUID(groupID: UUID()),
                                                                                members: members([leader, follower]), leaderUID: leader.uid))
            aggregate.destroy()
        }
        #expect(Set(DeviceQuery.allDeviceIDs()) == before)
    }

    @Test("A device that isn't there reports clock domain 0, and cannot be combined: creating fails cleanly")
    func missingDevice() throws {
        let (leader, _) = try devices()
        #expect(GroupAggregateDevice.clockDomain(uid: "no-such-device") == 0)
        let plan = try GroupAggregate.plan(name: "Vespertine test group", uid: GroupAggregate.makeUID(groupID: UUID()),
                                           members: [GroupAggregate.Member(uid: leader.uid, clockDomain: 0), GroupAggregate.Member(uid: "no-such-device", clockDomain: 0)],
                                           leaderUID: leader.uid)
        let before = Set(DeviceQuery.allDeviceIDs())
        do {
            let aggregate = try GroupAggregateDevice.create(plan)
            // Core Audio may accept a UID it cannot find; then it must at least not offer a stream for it.
            defer { aggregate.destroy() }
            #expect(DeviceQuery.outputStreams(aggregate.id).count < 2)
        } catch {
            #expect(error is GroupAggregateError)
        }
        #expect(Set(DeviceQuery.allDeviceIDs()) == before)
    }
}
