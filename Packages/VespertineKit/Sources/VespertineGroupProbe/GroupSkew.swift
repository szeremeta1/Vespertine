//
// Vespertine: Phase 0 of multi-DAC speaker groups, PR 0.3: `vespertine-probe group-skew`. The leader plays the room
// measurement's timing reference twice (which also gives the microphone-against-DAC clock ratio); the follower plays the
// same chirp once, between them. One microphone hears both, so the follower's arrival against the leader's does not depend
// on when the capture started. Repeated over N restarts of the output, the spread of that number is what H3 and H4 ask for.
// The number includes the acoustic path difference between the two speakers and the mic; only its change from restart to
// restart is the start skew. `--control` plays every chirp on the leader and so measures the method's own zero.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

extension GroupSkew {
    /// A mono 32-bit float WAVE file of `samples` (the raw capture, for looking at a run afterwards).
    public static func writeFloatWAV(_ samples: [Float], rate: Double, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 4)
        data.append(contentsOf: Array("RIFF".utf8)); u32(4 + 8 + 16 + 8 + bytes); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 4); u16(4); u16(32)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(start: UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: UInt8.self), count: samples.count * 4)) }
        try data.write(to: url)
    }
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
    /// How much louder the follower's chirp is than the leader's (the follower reaches the microphone quieter); cut to the channel's headroom.
    public var followerBoostDB = GroupSkew.followerBoostDB
    /// Seconds from the start of each capture to the first reference. The follower's chirp comes a second or so later, so the
    /// list is also "how long after the output started" (H4: does the skew settle?).
    public var leadIns: [Double] = [1.5]
    public var runsPerLeadIn = 8
    public var pauseSeconds = 1.0
    public var control = false
    /// Seconds between the first and the second reference: with this set, each capture also measures the follower's slip.
    public var spanSeconds: Double?
    /// Where each run's raw capture is saved (`run-N.wav`), failed runs included; nil: nothing is saved.
    public var keepDirectory: URL?

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
    /// Runs 100 frames or more from the median of their lead-in's runs (a later copy of the chirp picked over the direct sound, not a
    /// skew): left out of `overall`, `byLeadIn` and the verdict, and listed. Needs three runs at the lead-in to tell.
    public var outliers: [Run] = []
    /// Over the runs that are not outliers.
    public var overall: GroupSkew.Stats?
    /// Long captures: the follower's slip against the leader in ppm, over the runs.
    public var memberDrift: GroupSkew.Stats?
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
        if !config.control {
            let boost = GroupSkew.followerGain(level: config.level, boostDB: config.followerBoostDB)
            progress(boost.limited
                ? String(format: "follower chirp: +%.1f dB asked, only +%.1f dB fits under 1 dB below full scale at level %.2f; raise the follower's own volume, or lower --level", config.followerBoostDB, 20 * log10(boost.gain), config.level)
                : String(format: "follower chirp: +%.1f dB over the leader's (it usually arrives quieter)", config.followerBoostDB))
        }
        for leadIn in config.leadIns {
            let layout = try GroupSkew.layout(rate: config.rate, leadIn: leadIn, level: config.level, span: config.spanSeconds)
            for _ in 0..<config.runsPerLeadIn {
                index += 1
                let device = GroupSkewDevice(inner: makeDevice(), leaderChannel: config.leaderChannel, followerChannel: config.followerChannel, control: config.control, span: config.spanSeconds != nil, followerBoostDB: config.followerBoostDB)
                let session = RoomCaptureSession(device: device, permission: permission)
                let request = RoomCaptureRequest(inputDevice: config.inputDevice, outputDevice: config.outputDevice, inputChannel: config.inputChannel,
                                                 outputChannel: config.followerChannel, referenceChannel: config.leaderChannel, layout: layout)
                do {
                    let recording = try await session.record(request)
                    if let dir = config.keepDirectory {
                        let url = dir.appendingPathComponent("run-\(index).wav")
                        do { try GroupSkew.writeFloatWAV(recording.samples, rate: config.rate, to: url) } catch { progress("run \(index): could not save \(url.path): \(error.localizedDescription)") }
                    }
                    let m = try GroupSkew.measure(samples: recording.samples, layout: layout, control: config.control, span: config.spanSeconds != nil)
                    runs.append(.init(index: index, leadInSeconds: leadIn, measurement: m))
                    progress(String(format: "run %d (lead-in %.1f s): skew %+.3f frames (%+.1f µs), mic drift %+.1f ppm", index, leadIn, m.skewFrames, m.skewMicroseconds, m.micDriftPPM)
                        + (m.memberDriftPPM.map { String(format: " · end skew %+.3f fr · follower slip %+.2f ppm", m.endSkewFrames ?? 0, $0) } ?? ""))
                } catch {
                    let why = (error as? TimingReferenceError)?.errorDescription ?? (error as? RoomCaptureError)?.errorDescription ?? "\(error)"
                    failures.append("run \(index) (lead-in \(leadIn) s): \(why)")
                    progress("run \(index) failed: \(why)")
                }
                if config.pauseSeconds > 0 { try await Task.sleep(for: .seconds(config.pauseSeconds)) }
            }
        }
        let (inliers, outliers) = GroupSkewReport.separateOutliers(runs)
        let overall = GroupSkew.stats(inliers.map(\.measurement.skewFrames))
        var rows: [GroupSkewReport.LeadInRow] = []
        for leadIn in config.leadIns {
            let mine = inliers.filter { $0.leadInSeconds == leadIn }
            if let s = GroupSkew.stats(mine.map(\.measurement.skewFrames)), let first = mine.first {
                rows.append(.init(leadInSeconds: leadIn, followerChirpSeconds: first.measurement.followerChirpSeconds, stats: s))
            }
        }
        let drift = GroupSkew.stats(inliers.compactMap(\.measurement.memberDriftPPM))
        return GroupSkewReport(control: config.control, rate: config.rate, runs: runs, failures: failures, outliers: outliers, overall: overall, memberDrift: drift, byLeadIn: rows,
                               verdict: overall.map { GroupSkew.verdict(peakToPeakFrames: $0.peakToPeak, rate: config.rate) })
    }
}

extension GroupSkewReport {
    public static let outlierFrames = GroupSkew.outlierFrames

    /// `runs` split into those that agree and those `outlierFrames` or more from the median of their lead-in (which needs three runs).
    public static func separateOutliers(_ runs: [Run]) -> (inliers: [Run], outliers: [Run]) {
        var inliers: [Run] = [], outliers: [Run] = []
        for leadIn in Set(runs.map(\.leadInSeconds)) {
            let mine = runs.filter { $0.leadInSeconds == leadIn }
            let sorted = mine.map(\.measurement.skewFrames).sorted()
            let median = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            for run in mine {
                if mine.count >= 3, abs(run.measurement.skewFrames - median) >= outlierFrames { outliers.append(run) } else { inliers.append(run) }
            }
        }
        return (inliers.sorted { $0.index < $1.index }, outliers.sorted { $0.index < $1.index })
    }

    public var text: String {
        var lines: [String] = []
        let us = { (frames: Double) in frames / rate * 1e6 }
        lines.append("group-skew \(control ? "CONTROL (every chirp on the leader: the method's own zero)" : "leader vs follower") · \(runs.count - outliers.count) good runs\(outliers.isEmpty ? "" : ", \(outliers.count) excluded"), \(failures.count) failed · \(Int(rate)) Hz")
        if let o = overall {
            lines.append(String(format: "overall: mean %+.3f fr (%+.1f µs) · σ %.3f fr (%.1f µs) · min %+.3f · max %+.3f · peak-to-peak %.3f fr (%.1f µs)",
                                o.mean, us(o.mean), o.standardDeviation, us(o.standardDeviation), o.min, o.max, o.peakToPeak, us(o.peakToPeak)))
        }
        if let d = memberDrift {
            lines.append(String(format: "slip of the follower against the leader within each long capture: mean %+.2f ppm (%+.2f frames per minute at %d Hz), min %+.2f, max %+.2f over %d captures. Meaningful with drift correction off; with it on, expect about 0.",
                                d.mean, d.mean * 1e-6 * rate * 60, Int(rate), d.min, d.max, d.count))
        }
        if byLeadIn.count > 1 {
            lines.append("by time since the output started (H4 — does it settle?):")
            for r in byLeadIn {
                lines.append(String(format: "  follower chirp at %.1f s: mean %+.3f fr · σ %.3f · peak-to-peak %.3f fr (n=%d)", r.followerChirpSeconds, r.stats.mean, r.stats.standardDeviation, r.stats.peakToPeak, r.stats.count))
            }
        }
        lines.append(contentsOf: outliers.map {
            String(format: "EXCLUDED: run %d (lead-in %.1f s) at %+.1f fr is %.0f frames or more from the median of its lead-in: a later copy of the follower's chirp was taken, not a skew. Not in the figures above or the verdict.",
                   $0.index, $0.leadInSeconds, $0.measurement.skewFrames, Self.outlierFrames)
        })
        let copies = runs.filter { $0.measurement.followerLaterCopyFrames != nil }
        if !copies.isEmpty {
            lines.append("WARNING: in \(copies.count) of \(runs.count) runs the follower's chirp came with a later copy nearly as strong, about \(Int(copies.compactMap(\.measurement.followerLaterCopyFrames).reduce(0, +) / Double(copies.count))) frames after it (a longer path, e.g. a reflection or a second driver). The earlier one is taken; if the two swap places from run to run, the figures jump by that much.")
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
