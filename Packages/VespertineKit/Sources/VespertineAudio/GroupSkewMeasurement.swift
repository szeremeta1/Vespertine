//
// Vespertine — speaker groups: the measurement wizard's skew step. For each follower DAC, one speaker on it and one on the clock leader
// play the timing chirp (`GroupSkew`), heard by the microphone already set up for the sweeps. A long capture gives how fast the follower
// falls behind the leader while its drift correction is on (the rate trim); a few short ones give where it starts. What is kept is the
// electronic part (`GroupSkewCompensation`), with the settings it was measured under.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum GroupSkewMeasurement {
    public static let shortRuns = 5
    public static let minimumGoodRuns = 3
    /// Seconds between the two follower chirps of the long capture: two chirps ≥ 60 s apart give the rate to ±0.4 ppm at the method's ±1 frame.
    public static let rateSpanSeconds = 60.0
    /// Peak level of the chirps: -20 dBFS, as the probe's. The follower's is louder (`GroupSkew.followerGain`).
    public static let level = 0.1

    /// One capture: plays `GroupSkew.stimulus` for the layout on the given aggregate channels and returns the microphone's samples.
    public typealias Capture = @Sendable (_ layout: RoomCaptureLayout, _ leaderChannel: Int, _ followerChannel: Int, _ span: Bool) async throws -> [Float]

    public struct Pair: Equatable, Sendable {
        public var followerUID: String
        public var leaderSpeaker: SpeakerGroup.Speaker
        public var followerSpeaker: SpeakerGroup.Speaker
        public var leaderChannel: Int
        public var followerChannel: Int
    }

    /// For each follower, the pair of speakers to time: the leader's front left (or its lowest wired channel) against the follower's lowest
    /// wired channel. Members with no speaker wired are left out.
    public static func pairs(for group: SpeakerGroup) -> [Pair] {
        func wired(_ uid: String) -> [(speaker: SpeakerGroup.Speaker, channel: Int)] {
            guard let offset = group.channelOffset(ofMember: uid), let member = group.members.first(where: { $0.deviceUID == uid }) else { return [] }
            return group.speakers.filter { $0.deviceUID == uid && $0.channel >= 0 && $0.channel < member.channelCount }
                .map { ($0, offset + $0.channel) }.sorted { $0.channel < $1.channel }
        }
        let leaders = wired(group.clockLeaderUID)
        guard let leader = leaders.first(where: { $0.speaker.role == .frontLeft }) ?? leaders.first else { return [] }
        return group.members.filter { $0.deviceUID != group.clockLeaderUID }.compactMap { member in
            guard let follower = wired(member.deviceUID).first else { return nil }
            return Pair(followerUID: member.deviceUID, leaderSpeaker: leader.speaker, followerSpeaker: follower.speaker,
                        leaderChannel: leader.channel, followerChannel: follower.channel)
        }
    }

    public struct Outcome: Sendable {
        public var group: SpeakerGroup
        public var followerName: String
        /// The skew the number was taken from, in output frames, at the start of the output (the creep since it started taken off).
        public var skewFrames: Double
        /// Spread of the good short runs, in frames.
        public var spreadFrames: Double
        public var goodRuns: Int
        public var rateTrimPPM: Double?
        public var result: GroupSkewCompensation.Result
        /// What to tell the user, one line each (including what could not be done or checked).
        public var notes: [String]
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case tooFewGoodRuns(good: Int, of: Int, firstProblem: String?)
        public var errorDescription: String? {
            switch self {
            case .tooFewGoodRuns(let good, let total, let problem):
                "Only \(good) of \(total) timing captures could be read" + (problem.map { " (\($0))" } ?? "") + ". The delay between the DACs was not measured."
            }
        }
    }

    /// Measures every follower and writes the results into the group. `secondsSinceOutputStarted` is how long the aggregate has been
    /// running when it is called (the wizard holds it on from the start, so the follower has crept since; the creep is taken back off to
    /// where it was at the start, which is where a play begins). A follower whose skew can't be measured is reported in `failures` and
    /// left as it was.
    public static func run(group: SpeakerGroup, rate: Double, corrected: Set<String>, secondsSinceOutputStarted: @Sendable () -> Double = { 0 },
                           capture: Capture, progress: @Sendable (String) -> Void = { _ in }) async -> (outcomes: [Outcome], failures: [String]) {
        var current = group
        var outcomes: [Outcome] = [], failures: [String] = []
        for pair in pairs(for: group) {
            let name = group.members.first { $0.deviceUID == pair.followerUID }?.name ?? pair.followerUID
            do {
                let outcome = try await measure(pair: pair, group: current, name: name, rate: rate, isCorrected: corrected.contains(pair.followerUID),
                                                secondsSinceOutputStarted: secondsSinceOutputStarted, capture: capture, progress: progress)
                current = outcome.group
                outcomes.append(outcome)
            } catch {
                failures.append("\(name): \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
        }
        return (outcomes, failures)
    }

    static func measure(pair: Pair, group: SpeakerGroup, name: String, rate: Double, isCorrected: Bool, secondsSinceOutputStarted: @Sendable () -> Double,
                        capture: Capture, progress: @Sendable (String) -> Void) async throws -> Outcome {
        var notes: [String] = []
        let boost = GroupSkew.followerGain(level: level)
        if boost.limited { notes.append("The \(name) chirp could not be made louder than the leader's by the full \(Int(GroupSkew.followerBoostDB)) dB; if it is not found, raise its volume.") }

        // The long capture first: the follower's slip in ppm, and where it was when that capture's first follower chirp played.
        var rateTrim: Double?
        if isCorrected {
            progress("Timing \(name) against the leader over \(Int(rateSpanSeconds)) seconds…")
            do {
                let layout = try GroupSkew.layout(rate: rate, leadIn: 1.5, level: level, span: rateSpanSeconds)
                let m = try GroupSkew.measure(samples: try await capture(layout, pair.leaderChannel, pair.followerChannel, true), layout: layout, span: true)
                if let ppm = m.memberDriftPPM, abs(ppm) <= SpeakerGroup.Member.rateTrimRangePPM.upperBound {
                    rateTrim = ppm
                } else {
                    notes.append("The \(name) rate against the leader was out of the range a trim holds; it was not set.")
                }
            } catch {
                notes.append("The \(name) rate against the leader was not measured (\((error as? LocalizedError)?.errorDescription ?? "\(error)")); it is not trimmed.")
            }
        } else {
            notes.append("\(name) is not drift-corrected (it shares the leader's clock), so it has no rate to trim.")
        }

        var good: [Double] = [], firstProblem: String?, warned = false
        for run in 0..<shortRuns {
            progress("Timing \(name) against the leader (\(run + 1) of \(shortRuns))…")
            do {
                let layout = try GroupSkew.layout(rate: rate, leadIn: 1.5, level: level)
                let elapsed = secondsSinceOutputStarted()
                let m = try GroupSkew.measure(samples: try await capture(layout, pair.leaderChannel, pair.followerChannel, false), layout: layout)
                // Back to where the follower was when the output started: it crept `rateTrim` ppm since.
                let creep = (rateTrim ?? 0) * 1e-6 * (elapsed + m.followerChirpSeconds) * rate
                good.append(m.skewFrames - creep)
                if m.followerLaterCopyFrames != nil, !warned {
                    warned = true
                    notes.append("The \(name) chirp arrives twice about \(Int(m.followerLaterCopyFrames ?? 0)) frames apart (a reflection, or a second driver); the earlier one is timed.")
                }
            } catch {
                firstProblem = firstProblem ?? ((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
        // A pick 100 frames or more from the others is a later copy of the chirp, not a skew.
        let median = good.sorted().isEmpty ? 0 : good.sorted()[good.count / 2]
        let kept = good.filter { abs($0 - median) < GroupSkew.outlierFrames }
        if kept.count < good.count { notes.append("\(good.count - kept.count) of the \(name) captures landed on a later copy of the chirp and were left out.") }
        guard kept.count >= minimumGoodRuns else { throw Failure.tooFewGoodRuns(good: kept.count, of: shortRuns, firstProblem: firstProblem) }
        let stats = GroupSkew.stats(kept)!
        let skew = kept.sorted()[kept.count / 2]
        if rateTrim == nil, isCorrected { notes.append("Without the rate, the skew is as it was when measured, \(Int(secondsSinceOutputStarted())) seconds after the output started.") }
        guard let result = GroupSkewCompensation.apply(measuredFrames: skew, rate: rate, to: group, followerUID: pair.followerUID, leaderSpeaker: pair.leaderSpeaker.id,
                                                       followerSpeaker: pair.followerSpeaker.id, corrected: isCorrected, rateTrimPPM: rateTrim) else {
            throw Failure.tooFewGoodRuns(good: 0, of: shortRuns, firstProblem: "the speakers could not be matched")
        }
        if result.acousticMs == nil { notes.append("The drawing has no distance for one of the two speakers, so the whole \(String(format: "%.2f", result.measuredMs)) ms is kept, path difference included. Place both speakers in the drawing and measure again.") }
        return Outcome(group: result.group, followerName: name, skewFrames: skew, spreadFrames: stats.peakToPeak, goodRuns: kept.count, rateTrimPPM: rateTrim, result: result, notes: notes)
    }
}
