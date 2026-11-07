//
// Vespertine — speaker groups: what each output of a group carries for a given song, and what a lost output does to the
// group. The consequences of the listener's choices (stereo on more than two speakers, the LFE, a DAC that goes away) for
// the music each member plays, which is what the signal path has to tell the truth about.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation

/// A song's routing on a group, and what it means for each member.
public struct GroupContentPlan: Equatable, Sendable {
    public let router: PositionRouter
    public let group: SpeakerGroup

    /// nil when there is nothing to play or nowhere to play it (see `PositionRouter`).
    public init?(source: [AudioChannelLabel], group: SpeakerGroup) {
        guard let router = PositionRouter(source: source, group: group) else { return nil }
        self.router = router
        self.group = group
    }

    /// The aggregate's channels that carry any music.
    public var usedOutputs: [Int] { router.usedOutputs }

    /// The channels of a member (0 is its first) that carry any music.
    public func usedChannels(ofMember uid: String) -> [Int] {
        channels(ofMember: uid).filter { !router.matrixRow($0.aggregate).isEmpty }.map(\.local)
    }

    /// The channels of a member that carry exactly one channel of the file at exactly 1.0: its samples, nothing added.
    public func untouchedChannels(ofMember uid: String) -> [Int] {
        let untouched = Set(router.untouchedOutputs)
        return channels(ofMember: uid).filter { untouched.contains($0.aggregate) }.map(\.local)
    }

    /// The members with at least one channel that carries music, in the group's order.
    public var membersCarryingMusic: [String] {
        group.members.map(\.deviceUID).filter { !usedChannels(ofMember: $0).isEmpty }
    }

    /// The member plays music, and every channel of it that does is the file's own (no mix, fold, pan or level): the most that
    /// can be said of it before the questions of clock and exclusive access.
    public func carriesOnlyUntouchedChannels(ofMember uid: String) -> Bool {
        let used = usedChannels(ofMember: uid)
        return !used.isEmpty && used == untouchedChannels(ofMember: uid)
    }

    private func channels(ofMember uid: String) -> [(local: Int, aggregate: Int)] {
        guard let member = group.members.first(where: { $0.deviceUID == uid }), let offset = group.channelOffset(ofMember: uid) else { return [] }
        return (0..<max(member.channelCount, 0)).map { ($0, offset + $0) }
    }
}

extension SpeakerGroup {
    public enum PauseReason: Equatable, Sendable {
        /// The group is set to pause when an output goes away.
        case byPolicy(lost: [String])
        /// The clock leader went. Playing on under another leader's clock mid-song is never done silently; these are the outputs
        /// left to choose a new leader from.
        case leaderLost(candidates: [String])
        /// No output is left, or none with a speaker.
        case nothingLeft
    }

    public enum LossOutcome: Equatable, Sendable {
        /// None of the lost outputs is in this group.
        case unaffected
        /// Fade out and pause.
        case pause(PauseReason)
        /// Go on with this group: the outputs that are left, their channels counted again from the first. The music folds
        /// onto the speakers that remain (`PositionRouter` on this group).
        case continueOn(SpeakerGroup)
    }

    /// What happens when these outputs (by UID) go away while the group plays.
    public func outcome(losing lost: Set<String>) -> LossOutcome {
        let gone = members.filter { lost.contains($0.deviceUID) }
        guard !gone.isEmpty else { return .unaffected }
        let remaining = members.filter { !lost.contains($0.deviceUID) }
        guard !remaining.isEmpty else { return .pause(.nothingLeft) }
        if lost.contains(clockLeaderUID) { return .pause(.leaderLost(candidates: remaining.map(\.deviceUID))) }
        if onMemberLoss == .pause { return .pause(.byPolicy(lost: gone.map(\.deviceUID))) }
        var reduced = self
        reduced.members = remaining
        reduced.speakers = speakers.filter { speaker in remaining.contains { $0.deviceUID == speaker.deviceUID } }
        guard !reduced.speakers.isEmpty else { return .pause(.nothingLeft) }
        return .continueOn(reduced)
    }
}
