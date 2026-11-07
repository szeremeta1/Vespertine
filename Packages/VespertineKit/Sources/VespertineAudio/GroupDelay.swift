//
// Vespertine — speaker groups: the delay and level trim of each speaker, held in the room correction chain. macOS 27 accepts an aggregate's
// extra output latency without error and reads 0 back (checked on virtual devices), so a skew measured between the DACs can't be
// handed to Core Audio; Vespertine holds the other members' channels back instead, by whole frames, in the chain the I/O thread
// already runs. A speaker's own delay trim goes in the same place, and so does its level trim (a level per output channel, ahead of
// the bands, which the chain takes from -30 to +12 dB), so a trim lands once whichever profile the group plays with. Polarity is a sign on the same channel's gain.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A skew is how much *later* a member sounds than the others. The members that are ahead wait for the one that is latest (the
// same rule room correction and the geometry use: nobody is ever advanced, so nothing needs a negative delay). Whole-frame delays
// shift samples without changing one, so a leader that has to wait can stay bit-perfect (GroupSignalPath, `.integerDelay`).
//

import Foundation

public enum GroupDelay {
    /// Each aggregate channel's delay in ms, in channel order: its member's wait for the latest member, plus the delay trim of the
    /// speaker on it; at most what the chain holds.
    public static func perChannelMs(_ group: SpeakerGroup) -> [Double] {
        let latest = group.members.map(\.skewMs).max() ?? 0
        var delays: [Double] = []
        for member in group.members {
            let wait = max(latest - member.skewMs, 0)
            for channel in 0..<max(member.channelCount, 0) {
                let trim = group.speakers.first { $0.deviceUID == member.deviceUID && $0.channel == channel }?.delayTrimMs ?? 0
                delays.append(min(max(wait + trim, 0), RoomSpeakerAlignment.delayRange.upperBound))
            }
        }
        return delays
    }

    /// Each aggregate channel's level trim in dB, in channel order: that of the speaker on it, held to what the chain takes; a
    /// channel with no speaker, or a trim that isn't a number, has none.
    public static func perChannelLevelDB(_ group: SpeakerGroup) -> [Double] {
        var levels: [Double] = []
        for member in group.members {
            for channel in 0..<max(member.channelCount, 0) {
                let trim = group.speakers.first { $0.deviceUID == member.deviceUID && $0.channel == channel }?.trimDB ?? 0
                levels.append(trim.isFinite ? min(max(trim, RoomSpeakerAlignment.levelRange.lowerBound), RoomSpeakerAlignment.levelRange.upperBound) : 0)
            }
        }
        return levels
    }

    /// Each aggregate channel's polarity, in channel order: true when the speaker on it is marked inverted; a channel with no speaker is
    /// not.
    public static func perChannelInverted(_ group: SpeakerGroup) -> [Bool] {
        var flags: [Bool] = []
        for member in group.members {
            for channel in 0..<max(member.channelCount, 0) {
                flags.append(group.speakers.first { $0.deviceUID == member.deviceUID && $0.channel == channel }?.invertPolarity ?? false)
            }
        }
        return flags
    }

    /// Whether any channel has to be held back at all.
    public static func isNeeded(_ group: SpeakerGroup) -> Bool { perChannelMs(group).contains { $0 > 0 } }

    /// The chain to run: `room` with `delaysMs` added to its channels' own delays and `levelsDB` to their levels (its bands, filters
    /// and preamp stay), or a chain of those alone when there is no room correction. nil when there is nothing to hold back or turn
    /// and no room correction. The channels of the chain are those of the group, so a room correction measured for fewer keeps them
    /// as they are.
    public static func composing(_ room: RoomCorrectionPlayback?, delaysMs: [Double], levelsDB: [Double] = [], inverted: [Bool] = [], name: String) -> RoomCorrectionPlayback? {
        guard delaysMs.contains(where: { $0 > 0 }) || levelsDB.contains(where: { $0 != 0 }) || inverted.contains(true) else { return room }
        let count = min(max(delaysMs.count, levelsDB.count, inverted.count, room?.channels.count ?? 0), RoomCorrectionPlayback.maxChannels)
        var channels = (0..<count).map { c in c < (room?.channels.count ?? 0) ? room!.channels[c] : RoomChannelPlayback() }
        for c in 0..<min(delaysMs.count, count) { channels[c].delayMs += delaysMs[c] }
        for c in 0..<min(levelsDB.count, count) { channels[c].levelDB += levelsDB[c] }
        for c in 0..<min(inverted.count, count) where inverted[c] { channels[c].inverted.toggle() }
        return RoomCorrectionPlayback(profileID: room?.profileID ?? UUID(uuidString: "00000000-0000-4000-8000-000000670000")!,
                                      name: room?.name ?? name, preampDB: room?.preampDB ?? 0, channels: channels,
                                      impulseDirectory: room?.impulseDirectory ?? RoomImpulse.defaultDirectory).withHeadroom()
    }

    /// What the engine runs for `group`: `room` with the group's delays and level trims added (`composing`), whose preamp leaves
    /// room for the largest boost (`RoomCorrectionPlayback.withHeadroom`). `room` itself when the group adds nothing.
    public static func chain(_ room: RoomCorrectionPlayback?, group: SpeakerGroup) -> RoomCorrectionPlayback? {
        composing(room, delaysMs: perChannelMs(group), levelsDB: perChannelLevelDB(group), inverted: perChannelInverted(group), name: group.name)
    }
}
