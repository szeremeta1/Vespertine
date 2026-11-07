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

    public init(groupName: String, source: SourceFormat, folds: Bool, dsdConvertedToPCM: Bool, stage: Stage, members: [Member]) {
        self.groupName = groupName
        self.source = source
        self.folds = folds
        self.dsdConvertedToPCM = dsdConvertedToPCM
        self.stage = stage
        self.members = members
    }

    public var usedMembers: [Member] { members.filter(\.isUsed) }
    var leaderName: String { members.first(where: \.isLeader)?.name ?? "the leader" }

    /// This DAC's own part reaches it untouched: not resampled, a confirmed format that holds the song exactly (the single-DAC
    /// rule: integer DACs need at least the song's word length, float ones full Float32; wider than 24 bits is rounded), the
    /// song's rate, and no other app mixing into it.
    func isUntouched(_ m: Member) -> Bool {
        guard !m.resampled, m.physicalFormatKnown, m.exclusive || !m.otherAppsPlaying,
              abs(m.sampleRate - source.sampleRate) < 0.5 else { return false }
        let bits = source.bitDepth ?? 32
        guard bits <= 24 else { return false }
        return m.physicalIsInteger ? m.physicalBitDepth >= bits : m.physicalBitDepth >= 32
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
            if used.contains(where: \.resampled) { list.append("RESAMPLED") }
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
            if !m.resampled { parts.append(isUntouched(m) ? "bit-perfect" : "not bit-perfect") }
            return parts.joined(separator: " · ")
        }
    }
}
