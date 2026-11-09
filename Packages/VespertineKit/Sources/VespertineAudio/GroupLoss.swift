//
// Vespertine: speaker groups: a member that goes away while the group plays. The decision is plain data (below, tested
// without a device); the engine acts on it (PlaybackEngine.devicesChanged).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A follower lost either pauses the group or lets it carry on with the members that are left, as the group's loss policy says
// (the music is folded onto them by the usual downmix). The leader lost always pauses: its clock is the group's, and the group
// never carries on silently on another one in the middle of a song. A member that returns brings the group back at the
// position it had reached.
//

import Foundation

public enum GroupLoss {
    public enum Status: Equatable, Sendable {
        case intact
        /// These followers (by name, in the group's order) are gone.
        case followersLost([String])
        case leaderLost(String)
    }

    public enum Action: Equatable, Sendable {
        case none
        /// Fade out, pause, and wait for the member to come back.
        case pause
        /// Carry on with the members that are left.
        case continueOnRest
    }

    /// Who of `group` is missing from the connected outputs.
    public static func assess(_ group: SpeakerGroup, connected: Set<String>) -> Status {
        if let leader = group.members.first(where: { $0.deviceUID == group.clockLeaderUID }), !connected.contains(leader.deviceUID) {
            return .leaderLost(leader.name)
        }
        let lost = group.members.filter { $0.deviceUID != group.clockLeaderUID && !connected.contains($0.deviceUID) }.map(\.name)
        return lost.isEmpty ? .intact : .followersLost(lost)
    }

    public static func action(for status: Status, policy: LossPolicy) -> Action {
        switch status {
        case .intact: .none
        case .leaderLost: .pause
        case .followersLost: policy == .continueOnRemaining ? .continueOnRest : .pause
        }
    }
}

extension SpeakerGroup {
    /// The group without these members, and without the speakers that were on them: what is left to play. Same ID and name, so
    /// the output keeps its settings.
    public func without(memberUIDs lost: Set<String>) -> SpeakerGroup {
        var rest = self
        rest.members = members.filter { !lost.contains($0.deviceUID) }
        rest.speakers = speakers.filter { !lost.contains($0.deviceUID) }
        return rest
    }
}

extension GroupOutput {
    /// A group after followers were lost, when it carries on with the rest: the members that are connected as a group (two or
    /// more), or just the leader's own device. Only for a group set to carry on, and never without its leader.
    public static func resolveDegraded(_ group: SpeakerGroup, among devices: [OutputDevice]) -> Resolution {
        guard group.onMemberLoss == .continueOnRemaining else { return resolve(group, among: devices) }
        let connected = Set(devices.map(\.uid))
        guard case .followersLost = GroupLoss.assess(group, connected: connected) else { return resolve(group, among: devices) }
        let rest = group.without(memberUIDs: Set(group.members.map(\.deviceUID)).subtracting(connected))
        if rest.members.count == 1, let device = devices.first(where: { $0.uid == rest.clockLeaderUID }) { return .single(device) }
        return resolve(rest, among: devices)
    }
}
