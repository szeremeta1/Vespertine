//
// Vespertine: speaker groups: changing the outputs of a group that is already made (leader, order, taking one out, putting one in).
// Pure; no device.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Changing a group's outputs")
struct GroupMemberEditsTests {
    /// Three two-channel DACs laid out as 5.1, the first leading, the second measured 1.5 ms behind it.
    private func group() throws -> SpeakerGroup {
        var g = SpeakerGroup(name: "Cinema",
                             members: ["a", "b", "c"].map { SpeakerGroup.Member(deviceUID: $0, name: "DAC \($0)", channelCount: 2) },
                             clockLeaderUID: "a", room: RoomOutline(width: 6, depth: 6))
        g = try #require(GroupPresets.apply(.itu51, to: g))
        g.members[1].skewMs = 1.5
        g.members[1].skewContext = SpeakerGroup.Member.SkewContext(driftCorrected: true, driftQuality: 127, sampleRate: 48_000)
        return g
    }

    private func candidate(_ uid: String, channels: Int = 2, eligibility: GroupCandidate.Eligibility = .ok) -> GroupCandidate {
        GroupCandidate(uid: uid, name: "DAC \(uid)", channels: channels, transport: .usb, eligibility: eligibility)
    }

    @Test("Another output can lead the clock; one that isn't in the group cannot; nothing else changes")
    func leader() throws {
        let g = try group()
        let led = GroupMemberEdits.setLeader("c", in: g)
        #expect(led.clockLeaderUID == "c" && led.isValid)
        var same = led
        same.clockLeaderUID = "a"
        #expect(same == g, "only the leader changed, the measurement is kept")
        #expect(GroupMemberEdits.setLeader("nobody", in: g) == g)
        #expect(GroupMemberEdits.setLeader("a", in: g) == g)
    }

    @Test("The order of the outputs can be changed, not past either end, and the speakers stay on their DACs")
    func order() throws {
        let g = try group()
        let moved = GroupMemberEdits.move("c", by: -1, in: g)
        #expect(moved.members.map(\.deviceUID) == ["a", "c", "b"])
        #expect(moved.speakers == g.speakers && moved.isValid)
        #expect(GroupChannelMap.rows(moved).map(\.role) == [.frontLeft, .frontRight, .sideLeft, .sideRight, .center, .lfe])
        #expect(GroupMemberEdits.move("a", by: -1, in: g) == g && GroupMemberEdits.move("c", by: 1, in: g) == g && GroupMemberEdits.move("x", by: 1, in: g) == g)
        #expect(GroupMemberEdits.canMove("a", by: 1, in: g) && !GroupMemberEdits.canMove("a", by: -1, in: g) && !GroupMemberEdits.canMove("c", by: 1, in: g))
        #expect(GroupMemberEdits.move("a", by: 1, in: g).members.map(\.deviceUID) == ["b", "a", "c"])
    }

    @Test("An output is taken out with the speakers on it; the first one left leads when it led; a group keeps two")
    func removing() throws {
        let g = try group()
        let without = GroupMemberEdits.remove("b", from: g)
        #expect(without.members.map(\.deviceUID) == ["a", "c"] && without.clockLeaderUID == "a")
        #expect(without.speakers.map(\.role) == [.frontLeft, .frontRight, .sideLeft, .sideRight])
        #expect(without.isValid, "\(without.issues)")
        let headless = GroupMemberEdits.remove("a", from: g)
        #expect(headless.clockLeaderUID == "b" && headless.members.map(\.deviceUID) == ["b", "c"] && headless.isValid)
        #expect(headless.members[0].skewMs == 1.5, "what was measured stays with its DAC")
        #expect(!GroupMemberEdits.canRemove("a", from: without) && GroupMemberEdits.remove("a", from: without) == without, "two are the fewest")
        #expect(!GroupMemberEdits.canRemove("x", from: g) && GroupMemberEdits.remove("x", from: g) == g)
    }

    @Test("An output is put in after the others with its channels free; not one that is in already, may not join, or doesn't fit in 16 channels")
    func adding() throws {
        let g = try group()
        let more = GroupMemberEdits.add(candidate("d", channels: 4), to: g)
        #expect(more.members.map(\.deviceUID) == ["a", "b", "c", "d"] && more.totalChannels == 10 && more.isValid)
        #expect(more.speakers == g.speakers && GroupChannelMap.unassigned(more).count == 4)
        #expect(GroupMemberEdits.add(candidate("a"), to: g) == g)
        #expect(GroupMemberEdits.add(candidate("bt", eligibility: .refused("no")), to: g) == g)
        #expect(GroupMemberEdits.add(candidate("big", channels: 12), to: g) == g, "6 + 12 is past 16")
        #expect(GroupMemberEdits.add(candidate("fits", channels: 10), to: g).totalChannels == 16)
        let offered = GroupMemberEdits.addable([candidate("a"), candidate("d"), candidate("bt", eligibility: .refused("no")), candidate("big", channels: 12),
                                            candidate("w", eligibility: .warning("built in"))], to: g)
        #expect(offered.map(\.uid) == ["d", "w"])
    }
}
