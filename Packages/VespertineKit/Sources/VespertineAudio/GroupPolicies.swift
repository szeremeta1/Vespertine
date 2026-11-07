//
// Vespertine — speaker groups: the choices for what a stereo song does on more than two speakers, what becomes of the subwoofer
// channel, and what happens when an output goes away. The options, the words for them, and how a choice goes into the group.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plain English for now, outside the string catalog (see SpeakerGroup.swift).
//

import Foundation

public enum GroupPolicies {
    public static let defaultMirrorTrimDB = -6.0
    public static let defaultLFEToAllDB = -10.0
    public static let levelRange: ClosedRange<Double> = -20...0

    // MARK: Stereo

    public enum StereoChoice: String, CaseIterable, Sendable, Identifiable {
        case frontOnly, mirror, eachPairStereo, allSpeakers
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .frontOnly: "Front pair only"
            case .mirror: "Mirror on the back pair"
            case .eachPairStereo: "Each pair its own stereo"
            case .allSpeakers: "Every speaker"
            }
        }

        public var detail: String {
            switch self {
            case .frontOnly: "Left and right play on the front pair; the other speakers stay quiet. The clock leader's channels can stay bit-perfect."
            case .mirror: "Left and right play on the front pair, and again on the back pair at a lower level."
            case .eachPairStereo: "Each pair of speakers plays the song's left and right."
            case .allSpeakers: "Every speaker plays something of the song."
            }
        }
    }

    public static func stereoChoice(_ group: SpeakerGroup) -> StereoChoice {
        switch group.stereoPolicy {
        case .frontOnly: .frontOnly
        case .mirror: .mirror
        case .eachPairStereo: .eachPairStereo
        case .allSpeakers: .allSpeakers
        }
    }

    public static func setStereo(_ choice: StereoChoice, in group: SpeakerGroup) -> SpeakerGroup {
        var result = group
        switch choice {
        case .frontOnly: result.stereoPolicy = .frontOnly
        case .mirror:
            if case .mirror = group.stereoPolicy { return group }
            result.stereoPolicy = .mirror(trimDB: defaultMirrorTrimDB)
        case .eachPairStereo: result.stereoPolicy = .eachPairStereo
        case .allSpeakers: result.stereoPolicy = .allSpeakers
        }
        return result
    }

    /// The mirror's level; nil when mirror is not the choice.
    public static func mirrorTrim(_ group: SpeakerGroup) -> Double? {
        if case .mirror(let trim) = group.stereoPolicy { return trim }
        return nil
    }

    /// Only where the mirror is the choice; held between -20 dB and 0, and a number that isn't one goes back to the default.
    public static func setMirrorTrim(_ trimDB: Double, in group: SpeakerGroup) -> SpeakerGroup {
        guard case .mirror = group.stereoPolicy else { return group }
        var result = group
        result.stereoPolicy = .mirror(trimDB: trimDB.isFinite ? min(max(trimDB, levelRange.lowerBound), levelRange.upperBound) : defaultMirrorTrimDB)
        return result
    }

    /// What the stereo choices do today.
    public static let stereoNote = "Played: a stereo song goes to the speakers by where the speakers stand, then this choice decides what the others do. Only the front pair plays it unless you choose otherwise."

    // MARK: Subwoofer channel

    public enum LFEChoice: String, CaseIterable, Sendable, Identifiable {
        case drop, toAll, toSpeaker
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .drop: "Leave it out"
            case .toAll: "Add it to every speaker"
            case .toSpeaker: "Add it to one speaker"
            }
        }

        public var detail: String {
            switch self {
            case .drop: "As in the usual downmix: a group with no subwoofer plays without the LFE channel."
            case .toAll: "The LFE channel is added to every speaker, at a lower level."
            case .toSpeaker: "The LFE channel is added to the speaker you choose."
            }
        }
    }

    public static func lfeChoice(_ group: SpeakerGroup) -> LFEChoice {
        switch group.lfePolicy {
        case .drop: .drop
        case .toAll: .toAll
        case .toSpeaker: .toSpeaker
        }
    }

    /// `.toSpeaker` picks the group's subwoofer speaker, else its first speaker; with no speaker at all the LFE stays left out.
    public static func setLFE(_ choice: LFEChoice, in group: SpeakerGroup) -> SpeakerGroup {
        var result = group
        switch choice {
        case .drop: result.lfePolicy = .drop
        case .toAll:
            if case .toAll = group.lfePolicy { return group }
            result.lfePolicy = .toAll(dB: defaultLFEToAllDB)
        case .toSpeaker:
            if case .toSpeaker = group.lfePolicy { return group }
            if let speaker = group.speakers.first(where: { $0.role == .lfe }) ?? group.speakers.first { result.lfePolicy = .toSpeaker(speaker.id) }
            else { result.lfePolicy = .drop }
        }
        return result
    }

    public static func lfeLevel(_ group: SpeakerGroup) -> Double? {
        if case .toAll(let dB) = group.lfePolicy { return dB }
        return nil
    }

    public static func setLFELevel(_ dB: Double, in group: SpeakerGroup) -> SpeakerGroup {
        guard case .toAll = group.lfePolicy else { return group }
        var result = group
        result.lfePolicy = .toAll(dB: dB.isFinite ? min(max(dB, levelRange.lowerBound), levelRange.upperBound) : defaultLFEToAllDB)
        return result
    }

    /// A speaker of the group; anything else is ignored.
    public static func setLFESpeaker(_ id: UUID, in group: SpeakerGroup) -> SpeakerGroup {
        guard group.speakers.contains(where: { $0.id == id }) else { return group }
        var result = group
        result.lfePolicy = .toSpeaker(id)
        return result
    }

    public static let lfeNote = "Played: a song's LFE channel goes by this choice, or to the group's subwoofer when it has one."

    // MARK: A lost output

    public enum LossChoice: String, CaseIterable, Sendable, Identifiable {
        case pause, continueOnRemaining
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .pause: "Pause"
            case .continueOnRemaining: "Carry on with the rest"
            }
        }

        public var detail: String {
            switch self {
            case .pause: "The music pauses and plays on from the same place when the output comes back."
            case .continueOnRemaining: "The music goes on on the outputs that are left, folded onto them. If the clock leader is the one that goes, it pauses instead: the group never carries on silently on another clock."
            }
        }
    }

    public static func lossChoice(_ group: SpeakerGroup) -> LossChoice { group.onMemberLoss == .pause ? .pause : .continueOnRemaining }

    public static func setLoss(_ choice: LossChoice, in group: SpeakerGroup) -> SpeakerGroup {
        var result = group
        result.onMemberLoss = choice == .pause ? .pause : .continueOnRemaining
        return result
    }

    /// What a group's per-speaker settings do in playback today.
    public static let playedToday = "Played today: each channel of a song goes to the speakers by where the speakers stand, and the delays, level trims and polarity shown here (the waits, the delay trims, the level trims and the speakers marked inverted)."

    public static let lossNote = "Played by the engine: a lost output pauses the group or moves it to the rest, and it moves back when the output returns."
}
