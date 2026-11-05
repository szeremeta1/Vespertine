//
// Vespertine — Phase 0 of multi-DAC speaker groups, PR 0.3: `vespertine-probe group-skew`. The leader plays the room
// measurement's timing reference twice (which also gives the microphone-against-DAC clock ratio); the follower plays the
// same chirp once, between them. One microphone hears both, so the follower's arrival against the leader's does not depend
// on when the capture started. Repeated over N restarts of the output, the spread of that number is what H3 and H4 ask for.
// The number includes the acoustic path difference between the two speakers and the mic; only its change from restart to
// restart is the start skew. `--control` plays every chirp on the leader and so measures the method's own zero.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

public enum GroupSkew {
    public struct Measurement: Codable, Equatable, Sendable {
        /// Follower arrival minus leader arrival, in output frames, against where a leader chirp at the same moment would be.
        public var skewFrames: Double
        public var skewMicroseconds: Double
        /// The microphone's clock against the output's, from the leader's two references.
        public var micDriftPPM: Double
        /// Seconds from the start of the played signal to the follower's chirp.
        public var followerChirpSeconds: Double
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
    public static func layout(rate: Double, leadIn: Double, level: Double) throws -> RoomCaptureLayout {
        try RoomCaptureLayout(sampleRate: rate, sweepDuration: 1.0, gap: 0.5, leadIn: leadIn, tail: max(0.4, leadIn + 0.1), slack: 0.25, level: level)
    }

    public static func followerChirpSeconds(_ layout: RoomCaptureLayout) -> Double { Double(layout.sweepStart) / layout.sampleRate }

    /// The leader's track: wake noise and both references. The follower's track: the same chirp once, at the sweep's slot.
    /// In control mode the follower's chirp is played by the leader too (the same channel, added to its track).
    public static func stimulus(layout: RoomCaptureLayout, leaderChannel: Int, followerChannel: Int, control: Bool) -> RoomStimulus {
        var leader = layout.referenceStimulus()
        var follower = [Float](repeating: 0, count: layout.totalFrames)
        for (n, v) in layout.reference.samples.enumerated() {
            let sample = Float(v * layout.level)
            if control { leader[layout.sweepStart + n] += sample } else { follower[layout.sweepStart + n] = sample }
        }
        var tracks = [RoomStimulus.Track(channel: leaderChannel, samples: leader)]
        if !control { tracks.append(.init(channel: followerChannel, samples: follower)) }
        return RoomStimulus(tracks: tracks)
    }

    /// Finds both references and the follower's chirp in one recording. Throws when any is missing or ambiguous.
    ///
    /// The follower's chirp is the same chirp as the references, so the references are searched for only outside the
    /// follower's slot (`ClockDriftEstimate.estimate` looks in each half of the recording and would see two equal peaks).
    public static func measure(samples: [Float], layout: RoomCaptureLayout, control: Bool = false) throws -> Measurement {
        let recording = samples.map(Double.init)
        let reference = layout.reference
        let rate = layout.sampleRate
        let slot = Int(0.2 * rate)                        // the follower's slot: its start ± 200 ms (the arrival offsets are far smaller)
        let firstRange = 0..<(layout.sweepStart - slot)
        let secondRange = (layout.sweepStart + reference.samples.count + slot)..<recording.count
        let first = try reference.locate(in: recording, range: firstRange)
        let second = try reference.locate(in: recording, range: secondRange)
        let ratio = (second.position - first.position) / Double(layout.nominalSpacing)
        let ppm = (ratio - 1) * 1e6
        guard abs(ppm) <= ClockDriftEstimate.defaultLimitPPM else { throw TimingReferenceError.excessiveDrift(ppm: ppm) }
        // Both fitted starts carry the same stretch bias; it cancels in the ratio but not in where the follower's chirp is.
        let bias = (ratio - 1) * reference.stretchCentroid
        let expected = first.position - bias + Double(layout.sweepOffset) * ratio     // where a leader chirp at the follower's slot would arrive
        let window = Int(0.05 * rate)
        let detection = try reference.locate(in: recording, range: (Int(expected) - window)..<(Int(expected) + window))
        let position = detection.position - bias
        let frames = (position - expected) / ratio
        return Measurement(skewFrames: frames, skewMicroseconds: frames / rate * 1e6, micDriftPPM: ppm, followerChirpSeconds: followerChirpSeconds(layout))
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

    public init(inner: RoomCaptureDevice, leaderChannel: Int, followerChannel: Int, control: Bool) {
        self.inner = inner; self.leaderChannel = leaderChannel; self.followerChannel = followerChannel; self.control = control
    }

    public func start(request: RoomCaptureRequest, stimulus _: RoomStimulus) throws {
        try inner.start(request: request, stimulus: GroupSkew.stimulus(layout: request.layout, leaderChannel: leaderChannel,
                                                                        followerChannel: followerChannel, control: control))
    }
    public func readAvailable(maxFrames: Int) -> RoomCaptureChunk { inner.readAvailable(maxFrames: maxFrames) }
    public func stop() { inner.stop() }
}

// MARK: - The run

public struct GroupSkewConfig: Sendable {
    public var inputDevice: UInt32
    public var outputDevice: UInt32
    public var inputChannel = 0
    public var leaderChannel: Int
    public var followerChannel: Int
    public var rate: Double
    public var level = 0.1
    /// Seconds from the start of each capture to the first reference. The follower's chirp comes a second or so later, so the
    /// list is also "how long after the output started" (H4: does the skew settle?).
    public var leadIns: [Double] = [1.5]
    public var runsPerLeadIn = 8
    public var pauseSeconds = 1.0
    public var control = false

    public init(inputDevice: UInt32, outputDevice: UInt32, leaderChannel: Int, followerChannel: Int, rate: Double) {
        self.inputDevice = inputDevice; self.outputDevice = outputDevice
        self.leaderChannel = leaderChannel; self.followerChannel = followerChannel; self.rate = rate
    }
}

public struct GroupSkewReport: Codable, Equatable, Sendable {
    public struct Run: Codable, Equatable, Sendable {
        public var index: Int
        public var leadInSeconds: Double
        public var measurement: GroupSkew.Measurement
    }
    public struct LeadInRow: Codable, Equatable, Sendable {
        public var leadInSeconds: Double
        public var followerChirpSeconds: Double
        public var stats: GroupSkew.Stats
    }
    public var control: Bool
    public var rate: Double
    public var runs: [Run]
    public var failures: [String]
    public var overall: GroupSkew.Stats?
    public var byLeadIn: [LeadInRow]
    public var verdict: GroupSkew.Verdict?
}

public enum GroupSkewRunner {
    /// Captures `runsPerLeadIn` times for each lead-in (each capture starts the output afresh), measuring each. A capture that
    /// fails is recorded and the rest go on. `makeDevice` gives a fresh capture device per run.
    public static func run(_ config: GroupSkewConfig, makeDevice: () -> RoomCaptureDevice, permission: MicrophonePermission,
                           progress: (String) -> Void = { _ in }) async throws -> GroupSkewReport {
        guard config.runsPerLeadIn >= 1, !config.leadIns.isEmpty else { throw GroupProbeError.message("at least one run is needed") }
        guard config.control || config.leaderChannel != config.followerChannel else { throw GroupProbeError.message("the leader and the follower need different output channels") }
        guard config.leaderChannel >= 0, config.followerChannel >= 0, config.inputChannel >= 0 else { throw GroupProbeError.message("channels can't be negative") }
        var runs: [GroupSkewReport.Run] = []
        var failures: [String] = []
        var index = 0
        for leadIn in config.leadIns {
            let layout = try GroupSkew.layout(rate: config.rate, leadIn: leadIn, level: config.level)
            for _ in 0..<config.runsPerLeadIn {
                index += 1
                let device = GroupSkewDevice(inner: makeDevice(), leaderChannel: config.leaderChannel, followerChannel: config.followerChannel, control: config.control)
                let session = RoomCaptureSession(device: device, permission: permission)
                let request = RoomCaptureRequest(inputDevice: config.inputDevice, outputDevice: config.outputDevice, inputChannel: config.inputChannel,
                                                 outputChannel: config.followerChannel, referenceChannel: config.leaderChannel, layout: layout)
                do {
                    let recording = try await session.record(request)
                    let m = try GroupSkew.measure(samples: recording.samples, layout: layout, control: config.control)
                    runs.append(.init(index: index, leadInSeconds: leadIn, measurement: m))
                    progress(String(format: "run %d (lead-in %.1f s): skew %+.3f frames (%+.1f µs), mic drift %+.1f ppm", index, leadIn, m.skewFrames, m.skewMicroseconds, m.micDriftPPM))
                } catch {
                    let why = (error as? TimingReferenceError)?.errorDescription ?? (error as? RoomCaptureError)?.errorDescription ?? "\(error)"
                    failures.append("run \(index) (lead-in \(leadIn) s): \(why)")
                    progress("run \(index) failed: \(why)")
                }
                if config.pauseSeconds > 0 { try await Task.sleep(for: .seconds(config.pauseSeconds)) }
            }
        }
        let overall = GroupSkew.stats(runs.map(\.measurement.skewFrames))
        var rows: [GroupSkewReport.LeadInRow] = []
        for leadIn in config.leadIns {
            let mine = runs.filter { $0.leadInSeconds == leadIn }
            if let s = GroupSkew.stats(mine.map(\.measurement.skewFrames)), let first = mine.first {
                rows.append(.init(leadInSeconds: leadIn, followerChirpSeconds: first.measurement.followerChirpSeconds, stats: s))
            }
        }
        return GroupSkewReport(control: config.control, rate: config.rate, runs: runs, failures: failures, overall: overall, byLeadIn: rows,
                               verdict: overall.map { GroupSkew.verdict(peakToPeakFrames: $0.peakToPeak, rate: config.rate) })
    }
}

extension GroupSkewReport {
    public var text: String {
        var lines: [String] = []
        let us = { (frames: Double) in frames / rate * 1e6 }
        lines.append("group-skew \(control ? "CONTROL (every chirp on the leader: the method's own zero)" : "leader vs follower") · \(runs.count) good runs, \(failures.count) failed · \(Int(rate)) Hz")
        if let o = overall {
            lines.append(String(format: "overall: mean %+.3f fr (%+.1f µs) · σ %.3f fr (%.1f µs) · min %+.3f · max %+.3f · peak-to-peak %.3f fr (%.1f µs)",
                                o.mean, us(o.mean), o.standardDeviation, us(o.standardDeviation), o.min, o.max, o.peakToPeak, us(o.peakToPeak)))
        }
        if byLeadIn.count > 1 {
            lines.append("by time since the output started (H4 — does it settle?):")
            for r in byLeadIn {
                lines.append(String(format: "  follower chirp at %.1f s: mean %+.3f fr · σ %.3f · peak-to-peak %.3f fr (n=%d)", r.followerChirpSeconds, r.stats.mean, r.stats.standardDeviation, r.stats.peakToPeak, r.stats.count))
            }
        }
        lines.append(contentsOf: failures.map { "FAILED: \($0)" })
        if let v = verdict {
            switch v {
            case .repeatable: lines.append("Verdict: the spread is within about 25 µs, the smallest timing difference between the ears an adult can tell. A fixed alignment would hold from start to start.")
            case .audibleImageShift: lines.append("Verdict: the spread is between 25 and 200 µs. The stereo image could shift a little from start to start; re-measuring at each start, or a Phase B own-clock design, may be needed.")
            case .notRepeatable: lines.append("Verdict: the spread is over 200 µs. A fixed alignment will not hold; this argues for Phase B (our own multi-device clock).")
            }
        }
        if !control { lines.append("The mean includes the acoustic path difference between the two speakers and the mic; only the spread is the start skew. Run with --control for the method's own spread.") }
        return lines.joined(separator: "\n")
    }
}
