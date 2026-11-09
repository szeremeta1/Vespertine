//
// Vespertine: speaker groups: the private aggregate device a group plays through. What its description says (the clock
// leader as the main sub-device, drift correction on every follower that doesn't share the leader's clock), without
// touching an audio device.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group aggregate description")
struct GroupAggregateTests {
    private func member(_ uid: String, domain: UInt32 = 0, quality: Int = 0x7F, latency: Double = 0) -> GroupAggregate.Member {
        GroupAggregate.Member(uid: uid, clockDomain: domain, driftQuality: quality, extraLatencyFrames: latency)
    }

    private func plan(_ members: [GroupAggregate.Member], leader: String? = nil, drift: GroupAggregate.DriftMode = .byClockDomain) throws -> GroupAggregate.Plan {
        try GroupAggregate.plan(name: "Downstairs quad", uid: "org.szeremeta.vespertine.group.test", members: members, leaderUID: leader ?? members[0].uid, drift: drift)
    }

    private func subDevices(_ description: [String: Any]) -> [[String: Any]] {
        description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] ?? []
    }

    // MARK: Drift correction

    @Test("The leader is never corrected; a follower is, because two DACs are two clocks (clock domain 0 means 'unknown', never 'shared')")
    func driftByDefault() throws {
        let plan = try plan([member("fosi"), member("fiio")])
        #expect(plan.drift == [false, true] && plan.isResampled)
        #expect(try self.plan([member("a"), member("b"), member("c")]).drift == [false, true, true])
    }

    @Test("Devices that report the leader's own non-zero clock domain share its hardware clock: no correction, nothing resampled")
    func sharedClock() throws {
        let shared = try plan([member("a", domain: 7), member("b", domain: 7)])
        #expect(shared.drift == [false, false] && !shared.isResampled)
        #expect(try plan([member("a", domain: 7), member("b", domain: 8), member("c", domain: 7)]).drift == [false, true, false])
        #expect(try plan([member("a", domain: 0), member("b", domain: 0)]).drift == [false, true])
    }

    @Test("Drift correction can be switched off for a test or a measurement: every member free-running")
    func driftOff() throws {
        let plan = try plan([member("a"), member("b")], drift: .off)
        #expect(plan.drift == [false, false] && !plan.isResampled)
    }

    // MARK: The dictionary

    @Test("The description: private, not stacked (stacked is a multi-output device, the same audio to every member), named, with a UID")
    func description() throws {
        let d = GroupAggregate.description(try plan([member("fosi"), member("fiio")]))
        #expect(d[kAudioAggregateDeviceNameKey] as? String == "Downstairs quad")
        #expect(d[kAudioAggregateDeviceUIDKey] as? String == "org.szeremeta.vespertine.group.test")
        #expect(d[kAudioAggregateDeviceIsPrivateKey] as? Int == 1)
        #expect(d[kAudioAggregateDeviceIsStackedKey] as? Int == 0)
        #expect(d[kAudioAggregateDeviceClockDeviceKey] == nil, "the leader is the main sub-device; no separate clock device")
    }

    @Test("Sub-devices keep the group's order (the stream order, so the first member's channels come first); the leader is the main one")
    func orderAndMain() throws {
        let d = GroupAggregate.description(try plan([member("a"), member("b"), member("c")], leader: "b"))
        #expect(subDevices(d).map { $0[kAudioSubDeviceUIDKey] as? String } == ["a", "b", "c"])
        #expect(d[kAudioAggregateDeviceMainSubDeviceKey] as? String == "b")
        // The main sub-device is not corrected, whichever place it has in the list.
        #expect(subDevices(d).map { $0[kAudioSubDeviceDriftCompensationKey] as? Int } == [1, 0, 1])
    }

    @Test("Each corrected member carries its drift quality; the main one and uncorrected ones carry none; a measured skew is not asked of Core Audio, which ignores it")
    func perMemberKeys() throws {
        let d = GroupAggregate.description(try plan([member("a"), member("b", quality: 0x40, latency: 96), member("c", domain: 0)]))
        let subs = subDevices(d)
        #expect(subs[0][kAudioSubDeviceDriftCompensationQualityKey] == nil && subs[0][kAudioSubDeviceExtraOutputLatencyKey] == nil)
        #expect(subs[1][kAudioSubDeviceDriftCompensationQualityKey] as? Int == 0x40 && subs[1][kAudioSubDeviceExtraOutputLatencyKey] == nil)
        #expect(subs[2][kAudioSubDeviceDriftCompensationQualityKey] as? Int == 0x7F && subs[2][kAudioSubDeviceExtraOutputLatencyKey] == nil)
    }

    @Test("The description is a property list Core Audio can take")
    func propertyList() throws {
        let d = GroupAggregate.description(try plan([member("a"), member("b", latency: 12.5)]))
        #expect((try? PropertyListSerialization.data(fromPropertyList: d, format: .binary, options: 0)) != nil)
    }

    // MARK: Refusals

    @Test("A plan needs two different members, with the leader among them, and sane numbers")
    func refusals() {
        #expect(throws: GroupAggregateError.tooFewMembers) { try GroupAggregate.plan(name: "x", uid: "u", members: [member("a")], leaderUID: "a") }
        #expect(throws: GroupAggregateError.duplicateMember("a")) { try GroupAggregate.plan(name: "x", uid: "u", members: [member("a"), member("a")], leaderUID: "a") }
        #expect(throws: GroupAggregateError.leaderNotAMember("z")) { try GroupAggregate.plan(name: "x", uid: "u", members: [member("a"), member("b")], leaderUID: "z") }
        #expect(throws: GroupAggregateError.invalidMember("b")) { try GroupAggregate.plan(name: "x", uid: "u", members: [member("a"), member("b", quality: 200)], leaderUID: "a") }
        #expect(throws: GroupAggregateError.invalidMember("b")) { try GroupAggregate.plan(name: "x", uid: "u", members: [member("a"), member("b", latency: -1)], leaderUID: "a") }
        #expect(throws: GroupAggregateError.invalidMember("b")) { try GroupAggregate.plan(name: "x", uid: "u", members: [member("a"), member("b", latency: .nan)], leaderUID: "a") }
    }

    // MARK: From a saved group

    @Test("A saved group becomes a plan: its members in its order, its leader, each member's quality and measured latency, the clock domains read live")
    func fromGroup() throws {
        var group = GroupFixtures.quad()
        group.members[1].driftQuality = 0x20
        group.members[1].extraLatencyFrames = 48
        let plan = try GroupAggregate.plan(for: group, clockDomain: { $0 == GroupFixtures.fosi ? 5 : 0 })
        #expect(plan.name == "Downstairs quad" && plan.leaderUID == GroupFixtures.fosi)
        #expect(plan.members.map(\.uid) == [GroupFixtures.fosi, GroupFixtures.fiio])
        #expect(plan.members.map(\.clockDomain) == [5, 0])
        #expect(plan.members[1].driftQuality == 0x20 && plan.members[1].extraLatencyFrames == 48)
        #expect(plan.uid.hasPrefix(GroupAggregate.uidPrefix) && plan.uid.contains(group.id.uuidString.lowercased()))
        #expect(plan.drift == [false, true])
    }

    // MARK: Telling Vespertine's own aggregates apart

    @Test("Vespertine's aggregates are recognised by their UID, so the device list can leave them out")
    func ownUIDs() {
        let id = UUID()
        let a = GroupAggregate.makeUID(groupID: id), b = GroupAggregate.makeUID(groupID: id)
        #expect(GroupAggregate.isGroupAggregateUID(a) && GroupAggregate.isGroupAggregateUID(b) && a != b)
        #expect(!GroupAggregate.isGroupAggregateUID("AppleUSBAudioEngine:Fosi:ZD3:1"))
        #expect(!GroupAggregate.isGroupAggregateUID("vespertine-group:\(id.uuidString.lowercased())"), "that is the output's UID, not an aggregate's")
    }
}
