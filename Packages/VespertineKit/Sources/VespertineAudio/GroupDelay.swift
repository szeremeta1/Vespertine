//
// Vespertine: speaker groups: the delay and level trim of each speaker, held in the room correction chain. macOS 27 accepts an aggregate's
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
    /// How much later than the leader this member sounds, in ms, for the DACs themselves (not the speakers' distances). `resampled` is
    /// whether the aggregate drift-corrects it now (nil: not known, the saved number stands as it is); `rate` the group's sample rate.
    /// - A skew measured under the settings the member runs with now is used as it is: it already holds the resampler's delay.
    /// - A skew measured under other settings (drift correction was off, or another quality or rate) is not used.
    /// - A member with no measurement is held back by what is certain: the drift-correction resampler's measured delay
    ///   (`GroupSkewCompensation`), and a typed-in `skewMs` on top of it. Nothing is guessed beyond that.
    public static func lateMs(_ member: SpeakerGroup.Member, resampled: Bool?, rate: Double) -> Double {
        let certain = resampled == true ? GroupSkewCompensation.resamplerDelayMs(driftQuality: member.driftQuality, rate: rate) : 0
        guard let context = member.skewContext else { return member.skewMs + certain }
        guard let resampled else { return member.skewMs }
        return context.holds(driftCorrected: resampled, driftQuality: member.driftQuality, sampleRate: rate) ? member.skewMs : certain
    }

    /// How long a play is kept aligned by the rate trim (below), from the start of the output, for a member that doesn't say
    /// (`Member.rateTrimSeconds`).
    public static let rateTrimHorizonSeconds = 600.0

    /// How long this member's trim runs from the start of the output: its own measured span, or the default horizon.
    public static func trimSeconds(_ member: SpeakerGroup.Member) -> Double {
        guard let seconds = member.rateTrimSeconds, seconds.isFinite, SpeakerGroup.Member.rateTrimSecondsRange.contains(seconds) else { return rateTrimHorizonSeconds }
        return seconds
    }

    /// How fast this member falls behind the others while it plays, in ppm: its measured rate (`Member.rateTrimPPM`), if that was
    /// measured under the settings it runs with now (the same rule as `lateMs`; a member that is not drift-corrected is not trimmed).
    public static func creepPPM(_ member: SpeakerGroup.Member, resampled: Bool?, rate: Double) -> Double {
        guard member.rateTrimPPM.isFinite, member.rateTrimPPM != 0, resampled != false else { return 0 }
        if let context = member.skewContext, let resampled, !context.holds(driftCorrected: resampled, driftQuality: member.driftQuality, sampleRate: rate) { return 0 }
        return member.rateTrimPPM
    }

    /// Per member, in the group's order: how fast it is to be brought forward against the slowest creeping one, in ppm (never negative,
    /// as nobody is delayed more and more: the others are held back by `rateHeadroomMs` at the start instead, and this member's share of
    /// that is given back at this rate).
    public static func advancePPM(_ group: SpeakerGroup, resampled: Set<String>? = nil, rate: Double = 48_000) -> [Double] {
        let creep = group.members.map { member in creepPPM(member, resampled: resampled.map { $0.contains(member.deviceUID) }, rate: rate) }
        let slowest = creep.min() ?? 0
        return creep.map { $0 - slowest }
    }

    /// The hold every channel gets at the start so that a member can be brought forward later: the largest advance over
    /// `rateTrimHorizonSeconds`, and the 8 frames the interpolator looks ahead of its read position (`ROOM_ADV_REACH`). 0 with no trim.
    public static func rateHeadroomMs(_ group: SpeakerGroup, resampled: Set<String>? = nil, rate: Double = 48_000) -> Double {
        let advance = advancePPM(group, resampled: resampled, rate: rate), seconds = advanceSeconds(group, resampled: resampled, rate: rate)
        guard let largest = zip(advance, seconds).map({ $0 * 1e-6 * $1 }).max(), largest > 0, rate > 0 else { return 0 }
        return largest * 1000 + 8 / rate * 1000
    }

    /// Per member, in the group's order: for how long it is brought forward (`advancePPM`), in seconds; 0 for a member that isn't. A member
    /// that creeps itself runs for its own span; one brought forward because another gets ahead runs for that one's span; with both, the
    /// longer (the advance itself is the sum of the two rates throughout, which is exact when the spans are equal).
    public static func advanceSeconds(_ group: SpeakerGroup, resampled: Set<String>? = nil, rate: Double = 48_000) -> [Double] {
        let creep = group.members.map { member in creepPPM(member, resampled: resampled.map { $0.contains(member.deviceUID) }, rate: rate) }
        guard let slowest = creep.indices.min(by: { creep[$0] < creep[$1] }) else { return [] }
        return group.members.indices.map { i in
            guard creep[i] - creep[slowest] > 0 else { return 0 }
            let own = creep[i] > 0 ? trimSeconds(group.members[i]) : 0
            let other = creep[slowest] < 0 ? trimSeconds(group.members[slowest]) : 0
            return max(own, other)
        }
    }

    /// Each aggregate channel's delay in ms, in channel order: its member's wait for the latest member, plus the delay trim of the
    /// speaker on it, plus the rate trim's headroom (every channel alike); at most what the chain holds. `resampled`: the UIDs of the
    /// members the aggregate drift-corrects (nil: unknown); `rate`: the group's sample rate. `memberWaits` false leaves the members'
    /// waits out (a profile measured on the group holds them already), keeping the trims and the headroom.
    public static func perChannelMs(_ group: SpeakerGroup, resampled: Set<String>? = nil, rate: Double = 48_000, memberWaits: Bool = true) -> [Double] {
        let late = group.members.map { member in lateMs(member, resampled: resampled.map { $0.contains(member.deviceUID) }, rate: rate) }
        let latest = late.max() ?? 0
        let headroom = rateHeadroomMs(group, resampled: resampled, rate: rate)
        var delays: [Double] = []
        for (index, member) in group.members.enumerated() {
            let wait = memberWaits ? max(latest - late[index], 0) : 0
            for channel in 0..<max(member.channelCount, 0) {
                let trim = group.speakers.first { $0.deviceUID == member.deviceUID && $0.channel == channel }?.delayTrimMs ?? 0
                delays.append(min(max(wait + trim + headroom, 0), RoomSpeakerAlignment.delayRange.upperBound))
            }
        }
        return delays
    }

    /// Each aggregate channel's advance in ppm, in channel order: its member's (`advancePPM`).
    public static func perChannelAdvancePPM(_ group: SpeakerGroup, resampled: Set<String>? = nil, rate: Double = 48_000) -> [Double] {
        let advance = advancePPM(group, resampled: resampled, rate: rate)
        return group.members.indices.flatMap { index in [Double](repeating: advance[index], count: max(group.members[index].channelCount, 0)) }
    }

    /// Each aggregate channel's advance span in seconds, in channel order: its member's (`advanceSeconds`).
    public static func perChannelAdvanceSeconds(_ group: SpeakerGroup, resampled: Set<String>? = nil, rate: Double = 48_000) -> [Double] {
        let seconds = advanceSeconds(group, resampled: resampled, rate: rate)
        return group.members.indices.flatMap { index in [Double](repeating: seconds[index], count: max(group.members[index].channelCount, 0)) }
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
    public static func isNeeded(_ group: SpeakerGroup, resampled: Set<String>? = nil, rate: Double = 48_000) -> Bool { perChannelMs(group, resampled: resampled, rate: rate).contains { $0 > 0 } }

    /// The chain to run: `room` with `delaysMs` added to its channels' own delays and `levelsDB` to their levels (its bands, filters
    /// and preamp stay), or a chain of those alone when there is no room correction. nil when there is nothing to hold back or turn
    /// and no room correction. The channels of the chain are those of the group, so a room correction measured for fewer keeps them
    /// as they are.
    public static func composing(_ room: RoomCorrectionPlayback?, delaysMs: [Double], levelsDB: [Double] = [], inverted: [Bool] = [], advancePPM: [Double] = [], advanceSeconds: [Double] = [], name: String) -> RoomCorrectionPlayback? {
        guard delaysMs.contains(where: { $0 > 0 }) || levelsDB.contains(where: { $0 != 0 }) || inverted.contains(true) || advancePPM.contains(where: { $0 > 0 }) else { return room }
        let count = min(max(delaysMs.count, levelsDB.count, inverted.count, advancePPM.count, room?.channels.count ?? 0), RoomCorrectionPlayback.maxChannels)
        var channels = (0..<count).map { c in c < (room?.channels.count ?? 0) ? room!.channels[c] : RoomChannelPlayback() }
        for c in 0..<min(delaysMs.count, count) { channels[c].delayMs += delaysMs[c] }
        for c in 0..<min(levelsDB.count, count) { channels[c].levelDB += levelsDB[c] }
        for c in 0..<min(inverted.count, count) where inverted[c] { channels[c].inverted.toggle() }
        for c in 0..<min(advancePPM.count, count) where advancePPM[c] > 0 { channels[c].advancePPM = advancePPM[c] }
        for c in 0..<min(advanceSeconds.count, count) where advanceSeconds[c] > 0 && advancePPM.indices.contains(c) && advancePPM[c] > 0 { channels[c].advanceSeconds = advanceSeconds[c] }
        return RoomCorrectionPlayback(profileID: room?.profileID ?? UUID(uuidString: "00000000-0000-4000-8000-000000670000")!,
                                      name: room?.name ?? name, preampDB: room?.preampDB ?? 0, channels: channels,
                                      impulseDirectory: room?.impulseDirectory ?? RoomImpulse.defaultDirectory).withHeadroom()
    }

    /// What the engine runs for `group`: `room` with the group's delays and level trims added (`composing`), whose preamp leaves
    /// room for the largest boost (`RoomCorrectionPlayback.withHeadroom`). `room` itself when the group adds nothing.
    /// A profile measured on this group while it ran as it runs now already holds the delay between its DACs (the sweeps were timed
    /// against the leader), so the members' waits are left out then; anything else gets them as before.
    public static func chain(_ room: RoomCorrectionPlayback?, group: SpeakerGroup, resampled: Set<String>? = nil, rate: Double = 48_000) -> RoomCorrectionPlayback? {
        let measuredHere = room?.measuredGroupClock?.holds(for: group, resampled: resampled, rate: rate) == true
        return composing(room, delaysMs: perChannelMs(group, resampled: resampled, rate: rate, memberWaits: !measuredHere), levelsDB: perChannelLevelDB(group), inverted: perChannelInverted(group),
                         advancePPM: perChannelAdvancePPM(group, resampled: resampled, rate: rate),
                         advanceSeconds: perChannelAdvanceSeconds(group, resampled: resampled, rate: rate), name: group.name)
    }
}
