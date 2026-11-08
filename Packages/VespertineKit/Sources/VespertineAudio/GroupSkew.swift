//
// Vespertine — speaker groups: the follower's arrival against the leader's, heard by one microphone. The leader plays the room
// measurement's timing reference twice (which also gives the microphone-against-DAC clock ratio); the follower plays the same chirp once,
// between them, so the follower's arrival does not depend on when the capture started. Used by `vespertine-probe group-skew` (the spread
// over N restarts) and by the group measurement wizard (the skew to hold the other members back by, `GroupSkewMeasurement`).
// The number includes the acoustic path difference between the two speakers and the mic.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum GroupSkew {
    public struct Measurement: Codable, Equatable, Sendable {
        /// Follower arrival minus leader arrival, in output frames, against where a leader chirp at the same moment would be.
        public var skewFrames: Double
        public var skewMicroseconds: Double
        /// The microphone's clock against the output's, from the leader's two references.
        public var micDriftPPM: Double
        /// Seconds from the start of the played signal to the follower's chirp.
        public var followerChirpSeconds: Double
        /// Long captures only (`span`): the same figure at the end of the capture, and how fast the follower slipped against
        /// the leader in between, in parts per million. Only meaningful while the follower is not being drift-corrected.
        public var endSkewFrames: Double?
        public var memberDriftPPM: Double?
        /// The follower's chirp over the floor of its search window (accepted from `TimingReference.expectedMinimumPeakToFloor`).
        public var followerPeakToFloor: Double?
        /// Frames to a later copy of the follower's chirp nearly as strong as the one taken (see `TimingReference.Detection`); nil when none.
        public var followerLaterCopyFrames: Double?
    }

    public struct Stats: Codable, Equatable, Sendable {
        public var count: Int
        public var mean: Double
        public var min: Double
        public var max: Double
        public var standardDeviation: Double
        public var peakToPeak: Double
    }

    public enum Verdict: String, Codable, Sendable {
        /// Spread within about the smallest time difference between the ears the ear can tell (25 µs).
        case repeatable
        case audibleImageShift
        case notRepeatable
    }

    /// A layout whose first reference comes after `leadIn` seconds (the follower's chirp follows about a second later). The tail
    /// grows with the lead-in: the room measurement's drift estimate wants one reference in each half of the recording.
    /// `span`: a long capture (the seconds between the first and the second reference), for the slip over minutes; the tail
    /// then also holds the follower's second chirp.
    public static func layout(rate: Double, leadIn: Double, level: Double, span: Double? = nil) throws -> RoomCaptureLayout {
        try RoomCaptureLayout(sampleRate: rate, sweepDuration: max(1.0, span ?? 1.0), gap: 0.5, leadIn: leadIn,
                              tail: max(span == nil ? 0.4 : 1.4, leadIn + 0.1), slack: 0.25, level: level)
    }

    /// Where the follower's chirp(s) start in the played signal: after the first reference, and (long captures) after the second.
    public static func followerChirpFrames(_ layout: RoomCaptureLayout, span: Bool) -> (first: Int, second: Int?) {
        let gap = layout.sweepStart - layout.firstReferenceStart - layout.reference.samples.count
        return (layout.sweepStart, span ? layout.secondReferenceStart + layout.reference.samples.count + gap : nil)
    }

    public static func followerChirpSeconds(_ layout: RoomCaptureLayout) -> Double { Double(layout.sweepStart) / layout.sampleRate }

    /// A run this far (output frames) from the median of the runs at its lead-in is a wrong pick, not a skew: the 2026-11-07 session had
    /// +186 and +162 frames from a later copy of the follower's chirp in series that otherwise spread over 2.4 frames.
    public static let outlierFrames = 100.0

    /// How much louder the follower's chirp is played than the leader's. In the hardware session it reached the microphone 16 dB under
    /// the leader's (the two DACs' volume knobs were not alike), which is what lost its first arrival under the noise and the copies.
    public static let followerBoostDB = 11.0
    /// Highest peak the boosted chirp may have: the follower's channel keeps 1 dB of headroom.
    public static let followerPeakLimit = 0.89

    /// The follower's chirp gain for a layout at `level`: `boostDB`, but never so much that its peak passes `followerPeakLimit`.
    /// `limited` is true when the headroom cut the boost short (the user is to raise the follower's own volume instead).
    public static func followerGain(level: Double, boostDB: Double = followerBoostDB) -> (gain: Double, limited: Bool) {
        let wanted = pow(10, boostDB / 20)
        let room = followerPeakLimit / max(level, 1e-9)
        return room < wanted ? (max(room, 1), true) : (wanted, false)
    }

    /// The leader's track: wake noise and both references. The follower's track: the same chirp once, at the sweep's slot, `boostDB` louder
    /// (`followerGain`). In control mode the follower's chirp is played by the leader too (the same channel, added to its track, not boosted).
    public static func stimulus(layout: RoomCaptureLayout, leaderChannel: Int, followerChannel: Int, control: Bool, span: Bool = false,
                                followerBoostDB boost: Double = followerBoostDB) -> RoomStimulus {
        let gain = followerGain(level: layout.level, boostDB: boost).gain
        var leader = layout.referenceStimulus()
        var follower = [Float](repeating: 0, count: layout.totalFrames)
        let slots = followerChirpFrames(layout, span: span)
        for start in [slots.first] + (slots.second.map { [$0] } ?? []) {
            for (n, v) in layout.reference.samples.enumerated() {
                let sample = Float(v * layout.level)
                if control { leader[start + n] += sample } else { follower[start + n] = Float(v * layout.level * gain) }
            }
        }
        var tracks = [RoomStimulus.Track(channel: leaderChannel, samples: leader)]
        if !control { tracks.append(.init(channel: followerChannel, samples: follower)) }
        return RoomStimulus(tracks: tracks)
    }

    /// Finds both references and the follower's chirp in one recording. Throws when any is missing or ambiguous.
    ///
    /// The follower's chirp is the same chirp as the references, so the references are searched for only outside the
    /// follower's slot (`ClockDriftEstimate.estimate` looks in each half of the recording and would see two equal peaks).
    public static func measure(samples: [Float], layout: RoomCaptureLayout, control: Bool = false, span: Bool = false) throws -> Measurement {
        let recording = samples.map(Double.init)
        let reference = layout.reference
        let rate = layout.sampleRate
        let m = reference.samples.count
        let slot = Int(0.2 * rate)                        // a follower slot: its start ± 200 ms (the arrival offsets are far smaller)
        let slots = followerChirpFrames(layout, span: span)
        let firstRange = 0..<(slots.first - slot)
        let first = try reference.locate(in: recording, range: firstRange)
        // The second reference is looked for around where the nominal spacing puts it (half a second either side: the mic clock is
        // within 500 ppm, 150 ms over a 5-minute capture), not across a long capture; and never in a follower slot.
        let guess = Int(first.position) + layout.nominalSpacing
        let half = Int(0.5 * rate)
        let secondRange = max(slots.first + m + slot, guess - half)..<min(slots.second.map { $0 - slot } ?? recording.count, guess + half + m)
        let second = try reference.locate(in: recording, range: secondRange)
        let ratio = (second.position - first.position) / Double(layout.nominalSpacing)
        let ppm = (ratio - 1) * 1e6
        guard abs(ppm) <= ClockDriftEstimate.defaultLimitPPM else { throw TimingReferenceError.excessiveDrift(ppm: ppm) }
        // Both fitted starts carry the same stretch bias; it cancels in the ratio but not in where the follower's chirp is.
        let bias = (ratio - 1) * reference.stretchCentroid
        let window = Int(0.05 * rate)
        var detections: [TimingReference.Detection] = []
        func skew(at slotStart: Int) throws -> Double {
            // Where a leader chirp at this slot would arrive, then where the follower's chirp did. The place is known to ±50 ms, so the
            // chirp is accepted on how far it stands over the window's floor (`.expected`), not on the normalised score.
            let expected = first.position - bias + Double(slotStart - layout.firstReferenceStart) * ratio
            let detection = try reference.locate(in: recording, range: (Int(expected) - window)..<(Int(expected) + window), acceptance: .expected)
            detections.append(detection)
            return (detection.position - bias - expected) / ratio
        }
        let start = try skew(at: slots.first)
        var end: Double?, drift: Double?
        if let secondSlot = slots.second {
            let e = try skew(at: secondSlot)
            end = e
            drift = (e - start) / Double(secondSlot - slots.first) * 1e6
        }
        return Measurement(skewFrames: start, skewMicroseconds: start / rate * 1e6, micDriftPPM: ppm,
                           followerChirpSeconds: followerChirpSeconds(layout), endSkewFrames: end, memberDriftPPM: drift,
                           followerPeakToFloor: detections.first?.peakToFloor, followerLaterCopyFrames: detections.first?.laterCopyFrames)
    }

    public static func stats(_ values: [Double]) -> Stats? {
        guard let first = values.first else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.count > 1 ? values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1) : 0
        let lo = values.min() ?? first, hi = values.max() ?? first
        return Stats(count: values.count, mean: mean, min: lo, max: hi, standardDeviation: variance.squareRoot(), peakToPeak: hi - lo)
    }

    /// The thresholds are a proposal: 25 µs is the low end of what adults can tell as an interaural time difference (the
    /// often-quoted 10 µs is optimistic); 200 µs is a spread no fixed alignment can hide.
    public static func verdict(peakToPeakFrames: Double, rate: Double) -> Verdict {
        let microseconds = peakToPeakFrames / rate * 1e6
        if microseconds <= 25 { return .repeatable }
        return microseconds <= 200 ? .audibleImageShift : .notRepeatable
    }
}

/// Puts the skew stimulus in front of any capture device: whatever the session hands over is replaced.
public final class GroupSkewDevice: RoomCaptureDevice, @unchecked Sendable {
    private let inner: RoomCaptureDevice
    private let leaderChannel: Int
    private let followerChannel: Int
    private let control: Bool
    private let span: Bool
    private let followerBoostDB: Double

    public init(inner: RoomCaptureDevice, leaderChannel: Int, followerChannel: Int, control: Bool, span: Bool = false,
                followerBoostDB: Double = GroupSkew.followerBoostDB) {
        self.inner = inner; self.leaderChannel = leaderChannel; self.followerChannel = followerChannel; self.control = control; self.span = span
        self.followerBoostDB = followerBoostDB
    }

    public func start(request: RoomCaptureRequest, stimulus _: RoomStimulus) throws {
        try inner.start(request: request, stimulus: GroupSkew.stimulus(layout: request.layout, leaderChannel: leaderChannel,
                                                                        followerChannel: followerChannel, control: control, span: span, followerBoostDB: followerBoostDB))
    }
    public func readAvailable(maxFrames: Int) -> RoomCaptureChunk { inner.readAvailable(maxFrames: maxFrames) }
    public func stop() { inner.stop() }
}
