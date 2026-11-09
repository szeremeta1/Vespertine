//
// Vespertine: speaker groups: what a measured skew between the DACs means for one member, and what to hold it back by.
// The microphone hears the sum of an electronic part (the DAC's and USB path's buffering, the drift-correction resampler's delay) and an
// acoustic part (this speaker being nearer or farther than the leader's). Only the electronic part belongs in `Member.skewMs`: the
// speakers' distances are already equalised from the drawing (`SpeakerGeometry.alignment`), so putting the whole number in would count the
// path difference twice.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum GroupSkewCompensation {
    /// The delay Core Audio's drift-correction resampler adds to a member, in frames: 53.5 ± 1.1 at 48 kHz, quality 127 (the follower's
    /// whole arrival pattern, shifted by this much with correction on against off; 2026-11-07, FiiO K11 behind a Fosi ZD3). Measured at that
    /// quality and rate only. A resampler's filter is a number of frames, so the delay is taken as that many frames at any rate (1.115 ms
    /// at 48 kHz, 0.56 ms at 96 kHz): unverified away from 48 kHz.
    public static let resamplerDelayFrames = 53.5
    public static let resamplerMeasuredQuality = 127

    /// The resampler's delay in ms for a corrected member at `rate`; 0 at a quality it wasn't measured at (a guess there could be wrong
    /// by as much as the delay itself).
    public static func resamplerDelayMs(driftQuality: Int, rate: Double) -> Double {
        driftQuality == resamplerMeasuredQuality && rate > 0 ? resamplerDelayFrames / rate * 1000 : 0
    }

    /// How much later than a leader speaker this member's sound arrives for want of nothing but the speakers' distances, in ms (positive:
    /// the follower's speaker is farther from the seat); nil when either speaker has no distance in the drawing (it stands at the seat, or
    /// its position isn't a number): the whole measured number is then kept and the caller is to say it is unsubtracted.
    public static func acousticMs(group: SpeakerGroup, leaderSpeaker: UUID, followerSpeaker: UUID, speedOfSound: Double = SpeakerGeometry.defaultSpeedOfSound) -> Double? {
        let placed = SpeakerGeometry.alignment(for: group, sampleRate: 48_000, speedOfSound: speedOfSound)
        guard let leader = placed.first(where: { $0.speakerID == leaderSpeaker }), let follower = placed.first(where: { $0.speakerID == followerSpeaker }) else { return nil }
        return (follower.distance - leader.distance) / speedOfSound * 1000
    }

    public struct Result: Equatable, Sendable {
        /// The group with the member's `skewMs` and its context written. A follower measured as sounding *earlier* than the leader
        /// (negative after the acoustic part) is written as the leader sounding later by that much, since nobody is ever advanced.
        public var group: SpeakerGroup
        /// ms the follower arrives after the leader at the mic, as measured.
        public var measuredMs: Double
        /// ms taken off for the speakers' distances; nil if they couldn't be (then `electronicMs == measuredMs`).
        public var acousticMs: Double?
        public var electronicMs: Double
    }

    /// Writes a measured follower-against-leader skew into `group`. `measuredFrames` is `GroupSkew.Measurement.skewFrames` at `rate`; it was
    /// measured with the follower drift-corrected or not as `corrected` says.
    public static func apply(measuredFrames: Double, rate: Double, to group: SpeakerGroup, followerUID: String, leaderSpeaker: UUID, followerSpeaker: UUID,
                             corrected: Bool, rateTrimPPM: Double? = nil) -> Result? {
        guard rate > 0, measuredFrames.isFinite, followerUID != group.clockLeaderUID,
              let followerIndex = group.members.firstIndex(where: { $0.deviceUID == followerUID }),
              let leaderIndex = group.members.firstIndex(where: { $0.deviceUID == group.clockLeaderUID }) else { return nil }
        let measured = measuredFrames / rate * 1000
        let acoustic = acousticMs(group: group, leaderSpeaker: leaderSpeaker, followerSpeaker: followerSpeaker)
        let electronic = measured - (acoustic ?? 0)
        var out = group
        let context = SpeakerGroup.Member.SkewContext(driftCorrected: corrected, driftQuality: group.members[followerIndex].driftQuality, sampleRate: rate)
        let limit = SpeakerGroup.delayTrimRangeMs
        let rounded = { (v: Double) in (v * 1000).rounded() / 1000 }
        out.members[followerIndex].skewMs = min(max(rounded(electronic), 0), limit.upperBound)
        out.members[followerIndex].skewContext = context
        out.members[leaderIndex].skewMs = min(max(rounded(-electronic), 0), limit.upperBound)
        out.members[leaderIndex].skewContext = context
        if let rateTrimPPM, rateTrimPPM.isFinite { out.members[followerIndex].rateTrimPPM = min(max(rateTrimPPM, SpeakerGroup.Member.rateTrimRangePPM.lowerBound), SpeakerGroup.Member.rateTrimRangePPM.upperBound) }
        return Result(group: out, measuredMs: measured, acousticMs: acoustic, electronicMs: electronic)
    }
}
