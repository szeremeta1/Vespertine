//
// Vespertine: Phase 0 of multi-DAC speaker groups, PR 0.2: the private aggregate behind `vespertine-probe group-play`.
// The description is checked as plain data; the opt-in test below creates a real private aggregate of virtual devices.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import Testing
import VespertineAudio
@testable import VespertineGroupProbe

@Suite("Group aggregate")
struct GroupAggregateTests {
    static func spec(_ uid: String, domain: UInt32 = 0) -> VespertineGroupProbe.GroupAggregate.Member { .init(uid: uid, clockDomain: domain) }

    // MARK: The description handed to Core Audio

    @Test func theAggregateIsPrivateWithTheLeaderAsMain() throws {
        let d = VespertineGroupProbe.GroupAggregate.description(name: "Probe", uid: "probe-1", members: [Self.spec("fosi"), Self.spec("fiio")])
        #expect(d[kAudioAggregateDeviceIsPrivateKey] as? Int == 1)
        #expect(d[kAudioAggregateDeviceMainSubDeviceKey] as? String == "fosi")
        #expect(d[kAudioAggregateDeviceUIDKey] as? String == "probe-1")
        #expect(d[kAudioAggregateDeviceNameKey] as? String == "Probe")
        // Not a stacked (multi-output) device: that would send the same audio to every member.
        #expect((d[kAudioAggregateDeviceIsStackedKey] as? Int ?? 0) == 0)
    }

    @Test func subDevicesKeepTheListOrderBecauseThatIsTheStreamOrder() throws {
        let d = VespertineGroupProbe.GroupAggregate.description(name: "P", uid: "p", members: [Self.spec("a"), Self.spec("b"), Self.spec("c")])
        let list = try #require(d[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        #expect(list.compactMap { $0[kAudioSubDeviceUIDKey] as? String } == ["a", "b", "c"])
    }

    @Test func theLeaderIsNeverDriftCorrectedAndFollowersAreAtTopQuality() throws {
        let d = VespertineGroupProbe.GroupAggregate.description(name: "P", uid: "p", members: [Self.spec("a"), Self.spec("b")])
        let list = try #require(d[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        #expect(list[0][kAudioSubDeviceDriftCompensationKey] as? Int == 0)
        #expect(list[1][kAudioSubDeviceDriftCompensationKey] as? Int == 1)
        #expect(list[1][kAudioSubDeviceDriftCompensationQualityKey] as? Int == Int(kAudioAggregateDriftCompensationMaxQuality))
    }

    @Test func aSharedNonZeroClockDomainTurnsDriftCorrectionOffForThatMember() throws {
        let d = VespertineGroupProbe.GroupAggregate.description(name: "P", uid: "p", members: [Self.spec("a", domain: 5), Self.spec("b", domain: 5), Self.spec("c", domain: 6)])
        let list = try #require(d[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        #expect(list.map { $0[kAudioSubDeviceDriftCompensationKey] as? Int } == [0, 0, 1])
    }

    @Test func zeroIsNotASharedClockDomain() {
        #expect(VespertineGroupProbe.GroupAggregate.driftFlags([Self.spec("a"), Self.spec("b")]) == [false, true])
    }

    @Test func driftCanBeForcedOffForExperiments() throws {
        let d = VespertineGroupProbe.GroupAggregate.description(name: "P", uid: "p", members: [Self.spec("a"), Self.spec("b")], drift: .off)
        let list = try #require(d[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        #expect(list.map { $0[kAudioSubDeviceDriftCompensationKey] as? Int } == [0, 0])
    }

    @Test func aDifferentQualityIsPassedThrough() throws {
        let d = VespertineGroupProbe.GroupAggregate.description(name: "P", uid: "p", members: [Self.spec("a"), Self.spec("b")], quality: 0x20)
        let list = try #require(d[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        #expect(list[1][kAudioSubDeviceDriftCompensationQualityKey] as? Int == 0x20)
    }

    @Test func theUIDIsUniquePerProcessAndLaunch() {
        let a = VespertineGroupProbe.GroupAggregate.makeUID(), b = VespertineGroupProbe.GroupAggregate.makeUID()
        #expect(a != b)
        #expect(a.contains(String(getpid())))
    }

    // MARK: Picking the rate

    @Test func theSourceRateIsUsedWhenEveryMemberOffersIt() {
        let plan = RatePlanner.choose(source: 96_000, memberRates: [[44_100, 48_000, 96_000], [48_000, 96_000, 192_000]])
        #expect(plan == .init(rate: 96_000, exact: true))
    }

    @Test func otherwiseTheNearestCommonRateAtOrAboveTheSourceIsUsedAndNotExact() {
        let plan = RatePlanner.choose(source: 88_200, memberRates: [[44_100, 48_000, 96_000, 192_000], [48_000, 96_000]])
        #expect(plan == .init(rate: 96_000, exact: false))
    }

    @Test func ifNothingCommonIsAboveTheHighestCommonRateBelowIsUsed() {
        let plan = RatePlanner.choose(source: 384_000, memberRates: [[44_100, 48_000, 96_000], [48_000, 96_000, 192_000]])
        #expect(plan == .init(rate: 96_000, exact: false))
    }

    @Test func noCommonRateMeansNoPlan() {
        #expect(RatePlanner.choose(source: 48_000, memberRates: [[44_100], [48_000]]) == nil)
        #expect(RatePlanner.choose(source: 48_000, memberRates: []) == nil)
    }

    // MARK: Real Core Audio, virtual devices only (opt-in: it creates a private aggregate and sets no rates)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_GROUP_LOOPBACK"] == "1"))
    func aRealPrivateAggregateIsCreatedReadAndDestroyed() throws {
        let virtual = OutputDevices.list().filter { $0.transport == .virtual }
        try #require(virtual.count >= 2, "needs two virtual devices (Vespertine Loopback and BlackHole)")
        let members = Array(virtual.prefix(2)).map { VespertineGroupProbe.GroupAggregate.Member(uid: $0.uid, clockDomain: 0) }
        let aggregate = try PrivateAggregate.create(members: members, name: "Vespertine group probe test")
        let uid = aggregate.uid
        let states = aggregate.subDeviceStates()
        #expect(states.map(\.uid) == members.map(\.uid))
        #expect(states.map(\.driftCompensation) == [false, true])
        #expect(states[1].quality == Int(kAudioAggregateDriftCompensationMaxQuality))
        // The aggregate has one output stream per member, in list order, and no hog-mode property of its own.
        #expect(ProbeHAL.outputStreams(aggregate.id).count == 2)
        #expect(!ProbeHAL.isSettable(aggregate.id, kAudioDevicePropertyHogMode))
        #expect(OutputDevices.list().contains { $0.uid == uid })
        aggregate.destroy()
        #expect(ProbeHAL.deviceID(uid: uid) == nil)
    }
}

@Suite("Group play gate")
struct GroupPlayGateTests {
    typealias C = GroupPlayGate.Candidate
    static let on = [GroupPlayGate.environmentVariable: "1"]
    static let loop = C(name: "Vespertine Loopback", uid: "L", transport: .virtual)
    static let hole = C(name: "BlackHole 2ch", uid: "B", transport: .virtual)
    static let dac = C(name: "Fosi", uid: "F", transport: .usb)

    @Test func itNeedsTheDevelopmentVariable() {
        #expect(GroupPlayGate.refusal(devices: [Self.loop, Self.hole], realHardwareAllowed: true, environment: [:], inUseByOthers: { _ in false })?.contains("VESPERTINE_GROUP_PROBE") == true)
    }

    @Test func twoVirtualDevicesAreAllowed() {
        #expect(GroupPlayGate.refusal(devices: [Self.loop, Self.hole], realHardwareAllowed: false, environment: Self.on, inUseByOthers: { _ in false }) == nil)
    }

    @Test func aRealOutputNeedsTheExplicitFlag() {
        let refused = GroupPlayGate.refusal(devices: [Self.dac, Self.hole], realHardwareAllowed: false, environment: Self.on, inUseByOthers: { _ in false })
        #expect(refused?.contains("Fosi") == true && refused?.contains("--real-hardware") == true)
        #expect(GroupPlayGate.refusal(devices: [Self.dac, Self.hole], realHardwareAllowed: true, environment: Self.on, inUseByOthers: { _ in false }) == nil)
    }

    @Test func aVirtualDeviceSomeoneElseUsesIsLeftAlone() {
        let refused = GroupPlayGate.refusal(devices: [Self.loop, Self.hole], realHardwareAllowed: false, environment: Self.on, inUseByOthers: { $0.uid == "B" })
        #expect(refused?.contains("BlackHole 2ch") == true)
    }

    @Test func aGroupNeedsAtLeastTwoDistinctDevices() {
        #expect(GroupPlayGate.refusal(devices: [Self.loop], realHardwareAllowed: false, environment: Self.on, inUseByOthers: { _ in false }) != nil)
        #expect(GroupPlayGate.refusal(devices: [Self.loop, Self.loop], realHardwareAllowed: false, environment: Self.on, inUseByOthers: { _ in false }) != nil)
    }

    @Test func aggregatesDoNotNest() {
        let agg = C(name: "Mine", uid: "A", transport: .aggregate)
        #expect(GroupPlayGate.refusal(devices: [Self.loop, agg], realHardwareAllowed: true, environment: Self.on, inUseByOthers: { _ in false })?.contains("nest") == true)
    }
}
