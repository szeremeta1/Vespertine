//
// Vespertine — what a speaker group's signal path honestly is: which DACs' channels reach the speakers untouched, which are
// resampled to stay in step with the leader's clock, and the badges and rows that say so. Nothing here touches playback.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The badge words are plain English for now (see SpeakerGroup.swift); they move into the string catalog with the settings
// screens that show them. "RESAMPLED", "BIT-PERFECT" and the rest are the words `SignalPath.statusLine` already uses.
//

import Foundation

/// One song on one speaker group, as the member DACs received it. The rules are the group's, from the design: a group is
/// bit-perfect only if every channel the song uses lands on a member that is not drift-corrected (the clock leader, or a
/// member sharing its hardware clock), each of those members passes the single-DAC format rules, nothing folds, filters or
/// changes the level (an integer-frame delay only shifts samples), and every used DAC is held exclusively or has no other
/// app playing to it.
public struct GroupSignalPath: Sendable, Hashable {
    /// What happens to the samples between the file and the DACs, besides routing.
    public enum Stage: Sendable, Hashable {
        case none
        /// Whole-frame delays only: samples are shifted, not changed.
        case integerDelay
        case roomCorrection
        case equalizer
        /// Replay Gain, a level trim, a fractional delay or a digital volume.
        case gain

        var modifiesSamples: Bool {
            switch self {
            case .none, .integerDelay: false
            case .roomCorrection, .equalizer, .gain: true
            }
        }
    }

    public struct Member: Sendable, Hashable {
        public var deviceUID: String
        public var name: String
        public var isLeader: Bool
        /// Drift-corrected (resampled by a few millionths) to follow the leader's clock.
        public var resampled: Bool
        /// The speakers of this song that this DAC plays. Empty: none of the song's channels go to it.
        public var speakers: [SpeakerRole]
        /// Read back from the DAC, not assumed.
        public var sampleRate: Double
        public var physicalBitDepth: Int
        public var physicalIsInteger: Bool
        public var physicalFormatKnown: Bool
        public var exclusive: Bool
        public var otherAppsPlaying: Bool

        public init(deviceUID: String, name: String, isLeader: Bool, resampled: Bool, speakers: [SpeakerRole], sampleRate: Double,
                    physicalBitDepth: Int, physicalIsInteger: Bool, physicalFormatKnown: Bool, exclusive: Bool, otherAppsPlaying: Bool) {
            self.deviceUID = deviceUID
            self.name = name
            self.isLeader = isLeader
            self.resampled = resampled
            self.speakers = speakers
            self.sampleRate = sampleRate
            self.physicalBitDepth = physicalBitDepth
            self.physicalIsInteger = physicalIsInteger
            self.physicalFormatKnown = physicalFormatKnown
            self.exclusive = exclusive
            self.otherAppsPlaying = otherAppsPlaying
        }

        public var isUsed: Bool { !speakers.isEmpty }
    }

    public var groupName: String
    public var source: SourceFormat
    /// Channels were mixed together (a fold-down or an upmix), not only placed.
    public var folds: Bool
    public var dsdConvertedToPCM: Bool
    public var stage: Stage
    public var members: [Member]
    /// How the song's channels were put onto the group's outputs (nil: they went to the first outputs, in order).
    public var router: PositionRouter?

    public init(groupName: String, source: SourceFormat, folds: Bool, dsdConvertedToPCM: Bool, stage: Stage, members: [Member],
                router: PositionRouter? = nil) {
        self.groupName = groupName
        self.source = source
        self.folds = folds
        self.dsdConvertedToPCM = dsdConvertedToPCM
        self.stage = stage
        self.members = members
        self.router = router
    }

    public var usedMembers: [Member] { members.filter(\.isUsed) }
    var leaderName: String { members.first(where: \.isLeader)?.name ?? "the leader" }

    /// This DAC's own part reaches it untouched: not resampled, a confirmed format that holds the song exactly (the single-DAC
    /// rule: integer DACs need at least the song's word length, float ones full Float32; wider than 24 bits is rounded), the
    /// song's rate, and no other app mixing into it.
    public func isUntouched(_ m: Member) -> Bool {
        guard !m.resampled, m.physicalFormatKnown, m.exclusive || !m.otherAppsPlaying,
              abs(m.sampleRate - source.sampleRate) < 0.5 else { return false }
        let bits = source.bitDepth ?? 32
        guard bits <= 24 else { return false }
        return m.physicalIsInteger ? m.physicalBitDepth >= bits : m.physicalBitDepth >= 32
    }

    /// The song was converted to another rate for the group (its own rate isn't one every member takes): a used DAC runs at a
    /// rate that isn't the song's.
    public var songResampled: Bool {
        source.encoding == .pcm && !dsdConvertedToPCM && usedMembers.contains { $0.sampleRate > 0 && abs($0.sampleRate - source.sampleRate) >= 0.5 }
    }

    public var isBitPerfect: Bool {
        guard source.encoding == .pcm, !dsdConvertedToPCM, !folds, !stage.modifiesSamples else { return false }
        let used = usedMembers
        return !used.isEmpty && used.allSatisfy(isUntouched)
    }

    /// The reasons the path is not bit-perfect, most important first, in the badge words; or "BIT-PERFECT", then always
    /// "SPEAKER GROUP".
    public var badges: [String] {
        var list: [String] = []
        if isBitPerfect {
            list.append("BIT-PERFECT")
        } else {
            let used = usedMembers
            if dsdConvertedToPCM { list.append(SignalPath.convertedFromDSD) }
            if folds { list.append("Downmixed") }
            if songResampled || used.contains(where: \.resampled) { list.append("RESAMPLED") }
            if used.contains(where: { !$0.exclusive && $0.otherAppsPlaying }) { list.append("MIXED WITH OTHER APPS") }
            switch stage {
            case .roomCorrection: list.append("ROOM CORRECTION")
            case .equalizer: list.append("EQUALIZER")
            case .gain: list.append("DIGITAL GAIN")
            case .none, .integerDelay: break
            }
            if used.contains(where: { !$0.physicalFormatKnown }) { list.append("FORMAT UNCONFIRMED") }
            if list.isEmpty { list.append("CONVERTED") }
        }
        list.append("SPEAKER GROUP")
        return list
    }

    /// The one-line state, like `SignalPath.statusLine`.
    public var statusLine: String { badges[0] }

    /// For the existing `SignalPath`: a group's output can be bit-perfect only as computed from its members.
    public var deviceProfile: DeviceProfile { .speakerGroup(canBeBitPerfect: isBitPerfect) }

    /// DACs that are resampled to follow the leader and carry some of this song's channels.
    public var resampledMemberNames: [String] { usedMembers.filter(\.resampled).map(\.name) }

    /// One line per DAC for the signal-path view.
    public var rows: [String] {
        members.map { m in
            let format = "\(m.physicalBitDepth)/\(SampleRate.format(m.sampleRate))"
            let follows = "follows \(leaderName), resampled to stay in step"
            guard m.isUsed else {
                return ["\(m.name)", "not used by this song"].joined(separator: " · ") + (m.resampled ? " · \(follows)" : "")
            }
            var parts = [m.name, m.speakers.map(\.rawValue).joined(separator: " ")]
            if m.isLeader { parts.append("clock leader") }
            else if m.resampled { parts.append(follows) }
            else { parts.append("shares \(leaderName)'s clock") }
            parts.append(format)
            if !m.resampled {
                let converted = songResampled && abs(m.sampleRate - source.sampleRate) >= 0.5
                parts.append(isUntouched(m) ? "bit-perfect"
                             : converted ? "not bit-perfect: the song is resampled from \(SampleRate.format(source.sampleRate)) kHz" : "not bit-perfect")
            }
            return parts.joined(separator: " · ")
        }
    }
}

// MARK: Built from what the engine played

extension GroupSignalPath {
    /// The stage of the chain on `usedChannels` channels: the most a stage changes wins (room correction, then the equalizer, then
    /// gain); whole-frame delays alone only shift the samples. A flat profile is no stage at all.
    static func stage(room: RoomCorrectionPlayback?, usedChannels: Int, equalizer: Bool, digitalVolumeDB: Double?, replayGainDB: Double?) -> Stage {
        stage(room: room, used: Array(0..<max(usedChannels, 0)), equalizer: equalizer, digitalVolumeDB: digitalVolumeDB, replayGainDB: replayGainDB)
    }

    /// The same, on the channels `used` (a song that leaves some outputs silent is not changed by what those outputs would do).
    static func stage(room: RoomCorrectionPlayback?, used: [Int], equalizer: Bool, digitalVolumeDB: Double?, replayGainDB: Double?) -> Stage {
        let roomChangesSamples = room.map { !$0.isFlat && !$0.changesOnlyTiming(channels: used) } ?? false
        if roomChangesSamples { return .roomCorrection }
        if equalizer { return .equalizer }
        if (digitalVolumeDB ?? 0) != 0 || (replayGainDB ?? 0) != 0 { return .gain }
        if let room, !room.isFlat, used.contains(where: { $0 >= 0 && $0 < room.channels.count && room.channels[$0].delayMs > 0 }) { return .integerDelay }
        return .none
    }

    /// The path of one song on the group that played it. With `content`, the song was put onto the group by where the speakers
    /// stand: a member is used when any of its outputs carries music, the speakers named are those outputs' own, and the song is
    /// folded when anything is mixed, panned, copied by a policy or heard nowhere (the LFE dropped). Without it the song's
    /// channels went to the aggregate's in order, so the first `plan.channels` aggregate channels are the ones in use; a speaker
    /// role names each, or the usual order for the count when the group has no speaker there. `applied.members` are the members
    /// as read back from them.
    static func make(group: SpeakerGroup, applied: AppliedFormat, source: SourceFormat, plan: OutputPlan, stage: Stage,
                     otherAppsPlaying: Bool = false, content: GroupContentPlan? = nil) -> GroupSignalPath {
        let assigned = group.rolesByAggregateChannel
        let order = Self.usualOrder
        let members = applied.members.map { m -> Member in
            let roles: [SpeakerRole]
            if let content {
                roles = content.usedChannels(ofMember: m.uid).compactMap { local -> SpeakerRole? in
                    let channel = m.channelOffset + local
                    return channel < assigned.count ? assigned[channel] : nil
                }
            } else {
                let used = (m.channelOffset..<(m.channelOffset + m.channelCount)).filter { $0 < plan.channels }
                roles = used.map { channel in (channel < assigned.count ? assigned[channel] : nil) ?? order[min(channel, order.count - 1)] }
            }
            return Member(deviceUID: m.uid, name: m.name, isLeader: m.isLeader, resampled: m.resampled, speakers: roles,
                          sampleRate: m.sampleRate, physicalBitDepth: m.physicalBitDepth, physicalIsInteger: m.physicalIsInteger,
                          physicalFormatKnown: m.physicalFormatKnown, exclusive: m.exclusive, otherAppsPlaying: otherAppsPlaying)
        }
        let folds = content.map { !$0.router.isUnmixed || !$0.router.dropped.isEmpty } ?? (plan.channels < source.channels)
        return GroupSignalPath(groupName: group.name, source: source, folds: folds, dsdConvertedToPCM: plan.dsdConvertedToPCM,
                               stage: stage, members: members, router: content?.router)
    }

    /// The speakers of a channel count, in the order a file's channels go (WAVE order).
    private static let usualOrder: [SpeakerRole] = [.frontLeft, .frontRight, .center, .lfe, .backLeft, .backRight, .sideLeft, .sideRight,
                                                    .topFrontLeft, .topFrontRight, .topBackLeft, .topBackRight]
}
