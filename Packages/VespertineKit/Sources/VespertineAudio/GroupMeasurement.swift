//
// Vespertine — speaker groups: the measurement wizard on a group. A group is measured as the layout and channel map its drawing makes
// (stereo, a quad, a 5.1 or its own set of places, on the outputs of the group), saved against the group's output UID, so the profile
// fits the group while it is wired that way (`RoomProfile.applies(to:)`). The timing references come from a speaker on the clock
// leader, the one DAC that is never resampled, and the group plays for `settleSeconds` before the first sweep.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum GroupMeasurement {
    /// How long the group plays before the first sweep. In the hardware session (Fosi leader, FiiO follower) the follower crept about
    /// 0.2 ms between 1.6 s and 15.6 s after a start and had not flattened by then; a measurement taken in that time would put the
    /// creep into the delays. Not a proven bound (the plan's open item 2).
    public static let settleSeconds = 15.0

    /// What the wizard needs to measure a group.
    public struct Setup: Equatable, Sendable {
        public var layout: RoomLayout
        public var channelMap: RoomChannelMap
        /// The group's output UID: the profile made is for it.
        public var deviceUID: String
        /// The speakers, in the order of their outputs.
        public var speakers: [RoomSpeaker]
        /// The speaker that plays the timing references: on the clock leader.
        public var referenceSpeaker: RoomSpeaker
        /// The aggregate's channels the measurement plays on: up to the highest used output.
        public var outputsNeeded: Int
    }

    public enum Problem: Error, Equatable, LocalizedError, CustomStringConvertible, Sendable {
        case noSpeakers
        case noSpeakerOnLeader

        public var description: String {
            switch self {
            case .noSpeakers: "Put the speakers on the group's outputs in its editor, then measure."
            case .noSpeakerOnLeader: "No speaker is on the clock leader's outputs. The timing tones play from the clock leader, the one DAC that is never resampled: move a speaker onto it, or choose another clock leader."
            }
        }

        public var errorDescription: String? { description }
    }

    /// The setup for measuring `group`, or why it can't be.
    public static func setup(for group: SpeakerGroup) -> Result<Setup, Problem> {
        guard let fit = RoomLayout.layout(for: group) else { return .failure(.noSpeakers) }
        let wired = group.aggregateChannels
        let onLeader = group.speakers.filter { $0.deviceUID == group.clockLeaderUID && wired[$0.role] != nil }
        let leaderRooms = onLeader.compactMap { fit.speakers[$0.role] }
        guard !leaderRooms.isEmpty else { return .failure(.noSpeakerOnLeader) }
        let ordered = fit.channelMap.entries.sorted { $0.output < $1.output }
        let reference = leaderRooms.contains(.left) ? RoomSpeaker.left : ordered.first { leaderRooms.contains($0.speaker) }?.speaker ?? leaderRooms[0]
        return .success(Setup(layout: fit.layout, channelMap: fit.channelMap, deviceUID: group.outputUID, speakers: ordered.map(\.speaker),
                              referenceSpeaker: reference, outputsNeeded: (ordered.map(\.output).max() ?? -1) + 1))
    }
}
