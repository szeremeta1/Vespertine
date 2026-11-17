//
// Vespertine: speaker groups: changing the outputs of a group that is already made. Another clock leader, another order, an output
// taken out (with the speakers on it) or put in. Plain data, so the editor that shows it is a thin layer.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum GroupMemberEdits {
    /// The group led by another of its outputs. Anything else is left as it is: what was measured between the DACs is kept with how
    /// it was measured (`Member.SkewContext`), and is only used again when the group runs that way.
    public static func setLeader(_ uid: String, in group: SpeakerGroup) -> SpeakerGroup {
        guard uid != group.clockLeaderUID, group.members.contains(where: { $0.deviceUID == uid }) else { return group }
        var result = group
        result.clockLeaderUID = uid
        return result
    }

    /// Whether the output can move one place earlier (-1) or later (1).
    public static func canMove(_ uid: String, by step: Int, in group: SpeakerGroup) -> Bool {
        guard let index = group.members.firstIndex(where: { $0.deviceUID == uid }) else { return false }
        return group.members.indices.contains(index + (step < 0 ? -1 : 1))
    }

    /// The group with the output one place earlier (-1) or later (1) in the order of its channels. The speakers stay on their DACs.
    public static func move(_ uid: String, by step: Int, in group: SpeakerGroup) -> SpeakerGroup {
        guard canMove(uid, by: step, in: group), let index = group.members.firstIndex(where: { $0.deviceUID == uid }) else { return group }
        var result = group
        result.members.swapAt(index, index + (step < 0 ? -1 : 1))
        return result
    }

    /// A group keeps at least two outputs.
    public static func canRemove(_ uid: String, from group: SpeakerGroup) -> Bool {
        group.members.count > 2 && group.members.contains { $0.deviceUID == uid }
    }

    /// The group without the output and without the speakers that were on it. When it led the clock, the first output left leads.
    public static func remove(_ uid: String, from group: SpeakerGroup) -> SpeakerGroup {
        guard canRemove(uid, from: group) else { return group }
        var result = group
        result.members.removeAll { $0.deviceUID == uid }
        result.speakers.removeAll { $0.deviceUID == uid }
        if result.clockLeaderUID == uid, let first = result.members.first { result.clockLeaderUID = first.deviceUID }
        return result
    }

    /// The outputs that could still join: the ones that may join a group at all, are not in this one, and whose channels still fit.
    public static func addable(_ candidates: [GroupCandidate], to group: SpeakerGroup) -> [GroupCandidate] {
        let room = SpeakerGroup.maxChannels - group.totalChannels
        return candidates.filter { c in c.isSelectable && c.channels <= room && !group.members.contains { $0.deviceUID == c.uid } }
    }

    /// The group with the output added after the others, all its channels free. Unchanged when it may not join.
    public static func add(_ candidate: GroupCandidate, to group: SpeakerGroup) -> SpeakerGroup {
        guard addable([candidate], to: group).count == 1 else { return group }
        var result = group
        result.members.append(SpeakerGroup.Member(deviceUID: candidate.uid, name: candidate.name, channelCount: candidate.channels))
        return result
    }
}
