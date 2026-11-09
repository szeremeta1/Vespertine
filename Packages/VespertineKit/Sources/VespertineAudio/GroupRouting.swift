//
// Vespertine: speaker groups: a song put onto a group by where the speakers stand. The pure part of what `Decoding` does for a
// group in place of a speaker-setup fold: which speakers a song's channels stand for, the plan that gives the ring one channel
// for every output of the group, and the router (`PositionRouter`, with the group's stereo and LFE policies) behind it.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation

public enum GroupRouting {
    /// The speakers a song's channels stand for, in the order the decoder hands them over: a mono file is a centre, a stereo one
    /// a left and a right, a file that names its speakers keeps them, else the usual (WAVE) order for the count. nil for a count
    /// with no such order (9, 11, 13…): there is nothing to place them by.
    public static func sourceLabels(channels: Int, speakers: [AudioChannelLabel]?) -> [AudioChannelLabel]? {
        switch channels {
        case ..<1: return nil
        case 1: return [kAudioChannelLabel_Center]
        case 2: return [kAudioChannelLabel_Left, kAudioChannelLabel_Right]
        default:
            if let speakers, speakers.count == channels { return speakers }
            return ChannelLayouts.wavOrderLabels(channels: channels)
        }
    }

    /// The same, for a probed file (before any decoder exists).
    public static func sourceLabels(of source: SourceFormat) -> [AudioChannelLabel]? {
        sourceLabels(channels: source.channels, speakers: ChannelLayouts.speakerLabels(source.channelLabels.flatMap { $0.count == source.channels ? $0 : nil }))
    }

    /// `source` on `group`; nil when its channels have no order or the group has nowhere to put them.
    public static func content(source: SourceFormat, group: SpeakerGroup) -> GroupContentPlan? {
        sourceLabels(of: source).flatMap { GroupContentPlan(source: $0, group: group) }
    }

    /// `plan` for a song put onto `group` by `content`: the ring is as wide as the group (every output, used or not), so one
    /// session serves songs of any channel count and a speaker's place in the ring never moves. Without a content plan the
    /// plan is the one it was (the song's channels go to the first outputs, in order).
    public static func routed(_ plan: OutputPlan, content: GroupContentPlan?, group: SpeakerGroup, source: SourceFormat) -> OutputPlan {
        guard let content, plan.mode == .pcm else { return plan }
        var routed = plan
        routed.channels = group.totalChannels
        routed.deviceChannelCount = nil
        routed.routeLabels = nil
        let name = ChannelLayouts.name(labels: sourceLabels(of: source), channels: source.channels)
        let router = content.router
        let speakers = group.speakers.count
        if router.isUnmixed && router.dropped.isEmpty {
            routed.reason = "\(name) to the speakers of \(group.name), each channel on its own. " + plan.reason
        } else {
            routed.reason = "\(name) spread over the \(speakers) speakers of \(group.name) by where the speakers stand. " + plan.reason
        }
        return routed
    }
}
