//
// Vespertine — speaker groups: what an output session on a group reports. The format of a group is read back from each
// member, never from the aggregate (whose streams show the aggregate's rate even while a member resamples to its own), and
// the group's numbers are the weakest member's. Pure; no device.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group session")
struct GroupSessionTests {
    private let fosi = "fosi-uid", fiio = "fiio-uid"

    private func group() -> SpeakerGroup {
        SpeakerGroup(name: "Dorm quad",
                     members: [SpeakerGroup.Member(deviceUID: fosi, name: "Fosi ZD3", channelCount: 2),
                               SpeakerGroup.Member(deviceUID: fiio, name: "FiiO K11", channelCount: 2)],
                     clockLeaderUID: fosi)
    }

    private func member(_ uid: String, rate: Double = 96_000, streamRates: [Double]? = nil, depth: Int = 32, integer: Bool = true,
                        known: Bool = true, exclusive: Bool = true) -> GroupMemberSession.Member {
        GroupMemberSession.Member(uid: uid, deviceID: 1, rateBefore: 48_000, rate: rate, streamRates: streamRates ?? [rate], exclusive: exclusive,
                                  physicalBitDepth: depth, physicalIsInteger: integer, physicalFormatKnown: known)
    }

    private func plan() throws -> GroupAggregate.Plan {
        try GroupAggregate.plan(for: group(), clockDomain: { _ in 0 })
    }

    // MARK: Per member

    @Test("Every member is reported from its own readback: leader not resampled, follower resampled, channels in the group's order")
    func perMember() throws {
        let applied = GroupApplied.members(group: group(), plan: try plan(), readback: [member(fosi, depth: 32), member(fiio, depth: 24)])
        #expect(applied.map(\.uid) == [fosi, fiio])
        #expect(applied.map(\.name) == ["Fosi ZD3", "FiiO K11"])
        #expect(applied.map(\.resampled) == [false, true])
        #expect(applied.map(\.channelOffset) == [0, 2])
        #expect(applied.map(\.channelCount) == [2, 2])
        #expect(applied.map(\.physicalBitDepth) == [32, 24])
        #expect(applied.allSatisfy { $0.sampleRate == 96_000 && $0.exclusive && $0.physicalFormatKnown })
    }

    @Test("A member whose hardware clock is the leader's is not resampled")
    func sharedClock() throws {
        let linked = try GroupAggregate.plan(for: group(), clockDomain: { _ in 7 })
        let applied = GroupApplied.members(group: group(), plan: linked, readback: [member(fosi), member(fiio)])
        #expect(applied.allSatisfy { !$0.resampled })
    }

    @Test("A member that wasn't read back is reported as unconfirmed, not left out or assumed")
    func missingReadback() throws {
        let applied = GroupApplied.members(group: group(), plan: try plan(), readback: [member(fosi)])
        #expect(applied.count == 2)
        #expect(!applied[1].physicalFormatKnown && !applied[1].exclusive && applied[1].sampleRate == 0)
    }

    // MARK: The group as one device

    @Test("The group's depth is the shallowest member's, integer only if every member is, known only if all are, exclusive only if all are")
    func summary() throws {
        let all = GroupApplied.members(group: group(), plan: try plan(),
                                       readback: [member(fosi, depth: 32, integer: true), member(fiio, depth: 24, integer: false, exclusive: false)])
        let summary = GroupApplied.summary(all)
        #expect(summary.physicalBitDepth == 24)
        #expect(!summary.physicalIsInteger)
        #expect(summary.physicalFormatKnown)
        #expect(!summary.exclusive)

        let held = GroupApplied.summary(GroupApplied.members(group: group(), plan: try plan(), readback: [member(fosi), member(fiio)]))
        #expect(held.exclusive && held.physicalIsInteger && held.physicalBitDepth == 32)

        let unknown = GroupApplied.summary(GroupApplied.members(group: group(), plan: try plan(), readback: [member(fosi), member(fiio, known: false)]))
        #expect(!unknown.physicalFormatKnown)
    }

    @Test("A member with a stream that didn't read back leaves the group's format unconfirmed")
    func streamsUnreadable() throws {
        let m = member(fiio, streamRates: [])
        #expect(!GroupApplied.isConfirmed(m))
        #expect(GroupApplied.isConfirmed(member(fiio)))
    }

    // MARK: A member at the wrong rate

    @Test("A member at another rate, on the device or on one of its streams, is named: the group would resample silently")
    func wrongRate() {
        #expect(GroupApplied.memberNotAt(96_000, [member(fosi), member(fiio)]) == nil)
        #expect(GroupApplied.memberNotAt(96_000, [member(fosi), member(fiio, rate: 48_000)]) == fiio)
        #expect(GroupApplied.memberNotAt(96_000, [member(fosi), member(fiio, streamRates: [96_000, 48_000])]) == fiio)
        #expect(GroupApplied.memberNotAt(96_000, [member(fosi, streamRates: [])]) == fosi, "unreadable is not 'fine'")
    }

    // MARK: Changes the session must notice

    @Test("A rate or depth change on a member is a change; the same readback is not")
    func changes() throws {
        let before = GroupApplied.members(group: group(), plan: try plan(), readback: [member(fosi), member(fiio)])
        #expect(!GroupApplied.changed(from: before, to: before))
        let rate = GroupApplied.members(group: group(), plan: try plan(), readback: [member(fosi), member(fiio, rate: 48_000)])
        #expect(GroupApplied.changed(from: before, to: rate))
        let depth = GroupApplied.members(group: group(), plan: try plan(), readback: [member(fosi), member(fiio, depth: 16)])
        #expect(GroupApplied.changed(from: before, to: depth))
        let integer = GroupApplied.members(group: group(), plan: try plan(), readback: [member(fosi, integer: false), member(fiio)])
        #expect(GroupApplied.changed(from: before, to: integer))
        let fewer = GroupApplied.members(group: group(), plan: try plan(), readback: [member(fosi)])
        #expect(GroupApplied.changed(from: before, to: fewer))
    }

    @Test("A single device's applied format has no members, and equals itself as before")
    func singleDeviceUnchanged() {
        let format = AppliedFormat(sampleRate: 48_000, physicalBitDepth: 24, physicalIsInteger: true, virtualChannels: 2, exclusive: true, bufferFrames: 512)
        #expect(format.members.isEmpty)
    }
}
