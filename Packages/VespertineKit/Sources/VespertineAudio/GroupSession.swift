//
// Vespertine: speaker groups: what an output session on a group holds and reports. The format of a group is read back from
// each member, never from the aggregate: the aggregate's streams show the aggregate's rate even while a member resamples
// to its own (checked on macOS 27), so reading them would call a silently converted path untouched.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation

/// One member of a playing group, as read back from the member.
public struct MemberApplied: Sendable, Hashable {
    public var uid: String
    public var name: String
    /// Drift-corrected (resampled by a few millionths) to follow the clock leader.
    public var resampled: Bool
    public var isLeader: Bool
    /// Where this member's channels start in the aggregate, and how many it has.
    public var channelOffset: Int
    public var channelCount: Int
    public var sampleRate: Double
    public var physicalBitDepth: Int
    public var physicalIsInteger: Bool
    public var physicalFormatKnown: Bool
    public var exclusive: Bool
}

/// The pure part of opening a group: members' numbers from their readbacks.
public enum GroupApplied {
    /// A member's format was read back completely: its rate, and a physical format on every output stream.
    public static func isConfirmed(_ member: GroupMemberSession.Member) -> Bool {
        member.physicalFormatKnown && !member.streamRates.isEmpty && !member.streamRates.contains(0)
    }

    /// The group's members in the group's order. A member with no readback is reported unconfirmed, not left out.
    public static func members(group: SpeakerGroup, plan: GroupAggregate.Plan, readback: [GroupMemberSession.Member]) -> [MemberApplied] {
        var offset = 0
        var applied: [MemberApplied] = []
        for (index, member) in group.members.enumerated() {
            let read = readback.first { $0.uid == member.deviceUID }
            let count = max(member.channelCount, 0)
            applied.append(MemberApplied(
                uid: member.deviceUID, name: member.name,
                resampled: index < plan.drift.count ? plan.drift[index] : member.deviceUID != group.clockLeaderUID,
                isLeader: member.deviceUID == group.clockLeaderUID,
                channelOffset: offset, channelCount: count,
                sampleRate: read?.rate ?? 0,
                physicalBitDepth: read?.physicalBitDepth ?? 0,
                physicalIsInteger: read?.physicalIsInteger ?? false,
                physicalFormatKnown: read.map(isConfirmed) ?? false,
                exclusive: read?.exclusive ?? false))
            offset += count
        }
        return applied
    }

    public struct Summary: Sendable, Equatable {
        public var physicalBitDepth: Int
        public var physicalIsInteger: Bool
        public var physicalFormatKnown: Bool
        public var exclusive: Bool
    }

    /// The group as one device, by its weakest member: the shallowest depth, integer only if every member is, confirmed only if
    /// all are, exclusive only if all are.
    public static func summary(_ members: [MemberApplied]) -> Summary {
        Summary(physicalBitDepth: members.map(\.physicalBitDepth).min() ?? 0,
                physicalIsInteger: !members.isEmpty && members.allSatisfy(\.physicalIsInteger),
                physicalFormatKnown: !members.isEmpty && members.allSatisfy(\.physicalFormatKnown),
                exclusive: !members.isEmpty && members.allSatisfy(\.exclusive))
    }

    /// The first member that is not at `rate` on the device and on every one of its streams (including one that can't be
    /// read): the group would resample it silently, so it must not play. nil when all are at the rate.
    public static func memberNotAt(_ rate: Double, _ members: [GroupMemberSession.Member]) -> String? {
        members.first { !$0.isAt(rate) }?.uid
    }

    /// The members' formats have moved from what the session set up (another app or Audio MIDI Setup changed one), or a
    /// member has gone.
    public static func changed(from before: [MemberApplied], to now: [MemberApplied]) -> Bool {
        guard before.count == now.count else { return true }
        return zip(before, now).contains { a, b in
            a.uid != b.uid || abs(a.sampleRate - b.sampleRate) >= 0.5 || a.physicalBitDepth != b.physicalBitDepth
                || a.physicalIsInteger != b.physicalIsInteger
        }
    }
}

/// What a group's output session owns besides its I/O: the private aggregate and the held, configured members. Letting go
/// of it takes the aggregate out of Core Audio, then (unless handed on) frees the members.
final class GroupSessionResources: @unchecked Sendable {
    let group: SpeakerGroup
    let aggregate: GroupAggregateDevice
    let members: GroupMemberSession
    private let lock = NSLock()
    private var released = false

    init(group: SpeakerGroup, aggregate: GroupAggregateDevice, members: GroupMemberSession) {
        self.group = group
        self.aggregate = aggregate
        self.members = members
    }

    /// Configures the members at `rate` (held, if `exclusive`), then combines them. Whatever fails leaves nothing held and no
    /// aggregate behind. `devices` are the group's members in the group's order.
    static func open(group: SpeakerGroup, devices: [OutputDevice], rate: Double, exclusive: Bool,
                     drift: GroupAggregate.DriftMode = .byClockDomain) throws -> GroupSessionResources {
        let members = try GroupMemberSession.begin(devices: devices, rate: rate, exclusive: exclusive)
        if let wrong = GroupApplied.memberNotAt(rate, members.members) {
            members.release()
            throw GroupMemberError.rateRefused(uid: wrong, name: devices.first { $0.uid == wrong }?.name ?? wrong, rate: rate)
        }
        do {
            let plan = try GroupAggregate.plan(for: group, clockDomain: { GroupAggregateDevice.clockDomain(uid: $0) }, drift: drift)
            let aggregate = try GroupAggregateDevice.create(plan)
            return GroupSessionResources(group: group, aggregate: aggregate, members: members)
        } catch {
            members.release()
            throw error
        }
    }

    /// The members as the devices hold them now, in the group's order.
    func readBack() -> [GroupMemberSession.Member] { members.readAgain() }

    /// `keepHolding`: the next session takes over the members' exclusive access.
    func release(keepHolding: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        aggregate.destroy()
        members.release(keepHolding: keepHolding)
    }

    deinit { release() }
}
