//
// Vespertine — the room measurement state machine: a level check, route identification for each speaker, then a
// sweep per speaker and position. Every capture is judged before it counts; a failed one never advances the run,
// and a cancelled run can be resumed. The hardware sits behind `RoomCapturing`.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// What the controller needs from a capture session: one recording per request, and a way to stop it.
public protocol RoomCapturing: AnyObject, Sendable {
    func record(_ request: RoomCaptureRequest) async throws -> RoomRecording
    func cancel()
}

extension RoomCaptureSession: RoomCapturing {}

// MARK: - Settings

public struct RoomQualityLimits: Equatable, Sendable {
    /// Linear sample value from which a capture counts as clipped.
    public var clipLevel = 0.98
    /// Below this peak (dBFS) nothing usable was heard.
    public var minimumPeakDBFS = -60.0
    public var minimumPeakToNoiseDB = 30.0
    public var maximumDriftPPM = ClockDriftEstimate.defaultLimitPPM
    public init() {}
}

public struct RoomMeasurementSettings: Equatable, Sendable {
    public var inputDevice: UInt32
    public var outputDevice: UInt32
    public var inputChannel = 0
    public var sampleRate = 48_000.0
    public var positions = 1
    public var sweepSeconds = 5.0
    /// The shorter sweep the level and route checks play.
    public var checkSweepSeconds = 1.0
    /// The level check starts here and only ever rises (to `maxLevel`), by at most `maxStepDB` at a time.
    public var startLevel = 0.01
    public var maxLevel = 0.25
    public var maxStepDB = 12.0
    /// Where the microphone's peak should land (dBFS): loud enough to clear the room's noise, far from clipping, and
    /// not louder than a flat is happy with.
    public var targetPeakDBFS = -30.0
    public var minimumPeakDBFS = -60.0
    public var clipLevel = 0.98
    public var minimumPeakToNoiseDB = 30.0
    /// The one-second route checks have less processing gain than a full sweep.
    public var routeMinimumPeakToNoiseDB = 15.0
    /// Two speakers that arrive within this many samples and this many dB of each other are one speaker.
    public var distinctSamples = 2.0
    public var distinctDB = 0.25
    public var requireDistinctRoutes = true
    /// Failed tries of one step before the run gives up on it.
    public var maxAttempts = 3

    public init(inputDevice: UInt32, outputDevice: UInt32) {
        self.inputDevice = inputDevice
        self.outputDevice = outputDevice
    }

    public var limits: RoomQualityLimits {
        var l = RoomQualityLimits()
        l.clipLevel = clipLevel
        l.minimumPeakDBFS = minimumPeakDBFS
        l.minimumPeakToNoiseDB = minimumPeakToNoiseDB
        return l
    }
}

// MARK: - Assessment

public enum RoomCaptureRejection: Equatable, Sendable {
    case clipped(peakDBFS: Double)
    case tooQuiet(peakDBFS: Double)
    case referenceMissing
    /// The second timing tone came through but the first didn't: the output was still silent when it played.
    case startCutOff
    case referenceAmbiguous
    case excessiveDrift(ppm: Double)
    case noisy(peakToNoiseDB: Double)
    case unusable(String)

    public var message: String {
        switch self {
        case .clipped(let p): String(localized: "The microphone clipped (peak \(Int(p.rounded())) dBFS). Turn the volume down.")
        case .tooQuiet(let p): String(localized: "The microphone heard almost nothing (peak \(Int(max(p, -200).rounded())) dBFS). Check the speaker is on, the right output is chosen and the microphone is pointing up.")
        case .referenceMissing: String(localized: "The timing tones didn't come through the microphone, so the capture can't be aligned.")
        case .startCutOff: String(localized: "The start of playback was cut off: the first timing tone never reached the microphone, though the second did. The speaker's output was probably still waking up (some USB DACs stay silent for a moment when sound starts).")
        case .referenceAmbiguous: String(localized: "The timing tones were smeared by something else in the room (an echo, a voice or another sound).")
        case .excessiveDrift(let ppm): String(localized: "The microphone and speaker clocks disagree by \(Int(ppm.rounded())) ppm, more than the measurement can correct.")
        case .noisy(let db): String(localized: "The room was too noisy: the sweep stood only \(Int(db.rounded())) dB over the noise.")
        case .unusable(let why): String(localized: "The capture couldn't be analysed: \(why)")
        }
    }
}

public struct RoomCaptureMetrics: Equatable, Sendable, Codable {
    public var peakDBFS: Double
    public var rmsDBFS: Double
    public var clippedSamples: Int
    public var driftPPM: Double?
    /// Where the first timing tone arrived, in samples after it was played (latency plus travel time).
    public var arrivalSamples: Double?
    public var peakToNoiseDB: Double?
}

public struct RoomCaptureAssessment: Sendable {
    public let metrics: RoomCaptureMetrics
    public let rejections: [RoomCaptureRejection]
    public var accepted: Bool { rejections.isEmpty }

    /// Judges one recording: level, then (if it was loud enough and not clipped) the references, the clock drift and
    /// the sweep's margin over the noise. The level is taken from where the first reference is played on: nothing
    /// played can arrive earlier, and the lead-in holds the microphone's own start-up (a UMIK-1 thumps to -31 dBFS as its
    /// stream starts, which once passed for a level check's tones).
    public static func assess(_ recording: RoomRecording, limits: RoomQualityLimits) -> RoomCaptureAssessment {
        let layout = recording.request.layout
        let samples = recording.samples[min(layout.firstReferenceStart, recording.samples.count)...]
        var peak = 0.0, sum = 0.0, clipped = 0
        for s in samples {
            let a = abs(Double(s))
            if a > peak { peak = a }
            if a >= limits.clipLevel { clipped += 1 }
            sum += a * a
        }
        func dB(_ v: Double) -> Double { v > 0 ? max(20 * log10(v), -200) : -200 }
        var metrics = RoomCaptureMetrics(peakDBFS: dB(peak), rmsDBFS: dB(samples.isEmpty ? 0 : (sum / Double(samples.count)).squareRoot()),
                                         clippedSamples: clipped)
        var rejections: [RoomCaptureRejection] = []
        if !recording.samples.allSatisfy({ $0.isFinite }) { return RoomCaptureAssessment(metrics: metrics, rejections: [.unusable("non-finite samples")]) }
        if clipped > 0 { rejections.append(.clipped(peakDBFS: metrics.peakDBFS)) }
        if metrics.peakDBFS < limits.minimumPeakDBFS {
            rejections.append(.tooQuiet(peakDBFS: metrics.peakDBFS))
            return RoomCaptureAssessment(metrics: metrics, rejections: rejections)
        }
        do {
            let analysis = try recording.analyse()
            metrics.driftPPM = analysis.drift.ppm
            metrics.arrivalSamples = analysis.drift.firstPosition - Double(layout.firstReferenceStart)
            if abs(analysis.drift.ppm) > limits.maximumDriftPPM { rejections.append(.excessiveDrift(ppm: analysis.drift.ppm)) }
            let impulse = try layout.sweep.recover(recording: analysis.sweepSegment)
            if let pnr = impulse.peakToNoiseDB {
                metrics.peakToNoiseDB = pnr
                if pnr < limits.minimumPeakToNoiseDB { rejections.append(.noisy(peakToNoiseDB: pnr)) }
            } else {
                rejections.append(.unusable("the noise floor couldn't be measured"))
            }
        } catch let error as TimingReferenceError {
            switch error {
            case .notFound: rejections.append(secondReferenceHeard(recording) ? .startCutOff : .referenceMissing)
            case .ambiguous: rejections.append(.referenceAmbiguous)
            case .excessiveDrift(let ppm): rejections.append(.excessiveDrift(ppm: ppm))
            case .recordingTooShort: rejections.append(.unusable("the recording is too short"))
            }
        } catch {
            rejections.append(.unusable(error.localizedDescription))
        }
        return RoomCaptureAssessment(metrics: metrics, rejections: rejections)
    }

    /// Whether the reference played second is in the recording's second half (where the estimator looks for it).
    private static func secondReferenceHeard(_ recording: RoomRecording) -> Bool {
        let samples = recording.samples.map(Double.init)
        return (try? recording.request.layout.reference.locate(in: samples, range: samples.count / 2..<samples.count)) != nil
    }
}

// MARK: - State

public enum RoomMeasurementStep: Hashable, Sendable, Codable {
    case levelCheck
    case routeCheck(RoomSpeaker)
    case sweep(RoomSpeaker, Int)
}

public enum RoomMeasurementIssue: Equatable, Sendable {
    case quality(RoomCaptureRejection)
    case capture(RoomCaptureError)
    case routesIndistinguishable(RoomSpeaker, RoomSpeaker)
    case other(String)

    public var message: String {
        switch self {
        case .quality(let r): r.message
        case .capture(let e): e.errorDescription ?? String(describing: e)
        case .routesIndistinguishable(let a, let b):
            String(localized: "The \(a.rawValue) and \(b.rawValue) outputs sounded the same at the microphone. One output is probably not reaching its own speaker (a mono mix, or both on one speaker).")
        case .other(let s): s
        }
    }
}

public enum RoomMeasurementState: Equatable, Sendable {
    case idle
    case running(RoomMeasurementStep, attempt: Int)
    /// A step failed; fix the cause and run again to retry that step.
    case needsAttention(RoomMeasurementStep, [RoomMeasurementIssue])
    /// The next position needs the microphone moved; call `confirmMicMoved()` then run again.
    case waitingForMic(position: Int)
    case cancelled(RoomMeasurementStep)
    /// Out of attempts on that step.
    case failed(RoomMeasurementStep, [RoomMeasurementIssue])
    case completed
}

public struct RoomAttemptRecord: Codable, Sendable, Equatable {
    public var step: RoomMeasurementStep
    public var attempt: Int
    public var file: String?
    public var accepted: Bool
    public var level: Double
    public var issues: [String]
    public var metrics: RoomCaptureMetrics?
}

// MARK: - Controller

public final class RoomMeasurementController: @unchecked Sendable {
    private struct Route { var arrival: Double?; var rms: Double }
    private struct Inner {
        var state = RoomMeasurementState.idle
        var running = false
        var cancelRequested = false
        var session: RoomSession
        var chosenLevel: Double?
        var routes: [RoomSpeaker: Route] = [:]
        var attempts: [RoomMeasurementStep: Int] = [:]
        var confirmedPosition: Int?
        var recordings: [RoomRecording] = []
        var log: [RoomAttemptRecord] = []
        var failed: RoomMeasurementState?
    }

    public let settings: RoomMeasurementSettings
    private let capturer: RoomCapturing
    private let folder: URL
    private let onChange: (@Sendable (RoomMeasurementState) -> Void)?
    private let inner: Locked<Inner>

    public init(settings: RoomMeasurementSettings, session: RoomSession, capturer: RoomCapturing, folder: URL,
                onChange: (@Sendable (RoomMeasurementState) -> Void)? = nil) {
        self.settings = settings
        self.capturer = capturer
        self.folder = folder
        self.onChange = onChange
        inner = Locked(Inner(session: session))
    }

    public var state: RoomMeasurementState { inner.withLock { $0.state } }
    public var session: RoomSession { inner.withLock { $0.session } }
    public var chosenLevel: Double? { inner.withLock { $0.chosenLevel } }
    /// Accepted recordings made in this run (a resumed session's earlier ones are on disk only).
    public var acceptedRecordings: [RoomRecording] { inner.withLock { $0.recordings } }
    public var log: [RoomAttemptRecord] { inner.withLock { $0.log } }

    public func cancel() {
        inner.withLock { $0.cancelRequested = true }
        capturer.cancel()
    }

    public func confirmMicMoved() {
        inner.withLock { g in
            if case .waitingForMic(let p) = g.state { g.confirmedPosition = p }
        }
    }

    private var isCancelled: Bool { inner.withLock { $0.cancelRequested } }

    private func set(_ state: RoomMeasurementState) {
        inner.withLock { $0.state = state }
        onChange?(state)
    }

    /// Runs from the first unfinished step until the run completes or something needs the listener. Calling it again
    /// after a failed step retries that step; after a cancel it resumes there. One run at a time.
    @discardableResult
    public func run() async -> RoomMeasurementState {
        let claimed = inner.withLock { g -> Bool in
            if g.running { return false }
            if case .failed = g.state { return false }
            if g.state == .completed { return false }
            g.running = true
            return true
        }
        guard claimed else { return state }
        let end = await execute()
        inner.withLock { g in g.running = false; if case .cancelled = end { g.cancelRequested = false } }
        set(end)
        return end
    }

    private func execute() async -> RoomMeasurementState {
        let speakers = session.channelMap.entries.sorted { $0.output < $1.output }.map(\.speaker)
        guard let first = speakers.first else { return .failed(.levelCheck, [.other(RoomCorrectionError.emptyMap.errorDescription ?? "")]) }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { return .failed(.levelCheck, [.other(error.localizedDescription)]) }

        if chosenLevel == nil {
            if isCancelled { return .cancelled(.levelCheck) }
            if let end = await levelCheck(speaker: first) { return end }
        }
        for speaker in speakers where inner.withLock({ $0.routes[speaker] == nil }) {
            if isCancelled { return .cancelled(.routeCheck(speaker)) }
            if let end = await routeCheck(speaker: speaker, all: speakers) { return end }
        }
        for position in 0..<settings.positions {
            for speaker in speakers where !hasCapture(speaker, position) {
                let step = RoomMeasurementStep.sweep(speaker, position)
                if isCancelled { return .cancelled(step) }
                let needsMove = inner.withLock { g in
                    position > 0 && !g.session.captures.contains { $0.position == position } && g.confirmedPosition != position
                }
                if needsMove { return .waitingForMic(position: position) }
                if let end = await sweep(speaker: speaker, position: position) { return end }
            }
        }
        return .completed
    }

    private func hasCapture(_ speaker: RoomSpeaker, _ position: Int) -> Bool {
        inner.withLock { $0.session.captures.contains { $0.speaker == speaker && $0.position == position && $0.quality == .accepted } }
    }

    // MARK: Steps

    private func request(for speaker: RoomSpeaker, seconds: Double, level: Double) throws -> RoomCaptureRequest {
        guard let entry = session.channelMap.entries.first(where: { $0.speaker == speaker }) else {
            throw RoomCorrectionError.speakerNotInMap(speaker)
        }
        let layout = try RoomCaptureLayout(sampleRate: settings.sampleRate, sweepDuration: seconds, level: level)
        return RoomCaptureRequest(inputDevice: settings.inputDevice, outputDevice: settings.outputDevice,
                                  inputChannel: settings.inputChannel, outputChannel: entry.output, layout: layout)
    }

    private enum Capture {
        case recording(RoomRecording)
        case stop(RoomMeasurementState)
    }

    /// One capture with the attempt bookkeeping: a hardware failure or a cancel ends the step here.
    private func capture(_ step: RoomMeasurementStep, speaker: RoomSpeaker, seconds: Double, level: Double) async -> Capture {
        let attempt = inner.withLock { ($0.attempts[step] ?? 0) + 1 }
        set(.running(step, attempt: attempt))
        let req: RoomCaptureRequest
        do { req = try request(for: speaker, seconds: seconds, level: level) }
        catch { return .stop(fail(step, [.other(error.localizedDescription)], file: nil, level: level, metrics: nil)) }
        do {
            let recording = try await capturer.record(req)
            if isCancelled { return .stop(.cancelled(step)) }
            return .recording(recording)
        } catch RoomCaptureError.cancelled {
            return .stop(.cancelled(step))
        } catch let error as RoomCaptureError {
            if isCancelled { return .stop(.cancelled(step)) }
            return .stop(fail(step, [.capture(error)], file: nil, level: level, metrics: nil))
        } catch {
            if isCancelled { return .stop(.cancelled(step)) }
            return .stop(fail(step, [.other(error.localizedDescription)], file: nil, level: level, metrics: nil))
        }
    }

    /// Counts a failed try. Attention while attempts remain, failure after.
    private func fail(_ step: RoomMeasurementStep, _ issues: [RoomMeasurementIssue], file: String?, level: Double,
                      metrics: RoomCaptureMetrics?) -> RoomMeasurementState {
        let attempt = inner.withLock { g -> Int in
            g.attempts[step, default: 0] += 1
            return g.attempts[step] ?? 1
        }
        record(RoomAttemptRecord(step: step, attempt: attempt, file: file, accepted: false, level: level,
                                 issues: issues.map(\.message), metrics: metrics))
        return attempt >= settings.maxAttempts ? .failed(step, issues) : .needsAttention(step, issues)
    }

    private func succeed(_ step: RoomMeasurementStep, file: String?, level: Double, metrics: RoomCaptureMetrics?) {
        let attempt = inner.withLock { g -> Int in
            let n = (g.attempts[step] ?? 0) + 1
            g.attempts[step] = nil
            return n
        }
        record(RoomAttemptRecord(step: step, attempt: attempt, file: file, accepted: true, level: level, issues: [], metrics: metrics))
    }

    private func record(_ entry: RoomAttemptRecord) {
        let all = inner.withLock { g -> [RoomAttemptRecord] in g.log.append(entry); return g.log }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(all).write(to: folder.appendingPathComponent("measurement-log.json"), options: .atomic)
    }

    /// Writes a recording under the first unused name starting with `base`.
    private func save(_ recording: RoomRecording, base: String, rejected: Bool) throws -> RoomRecordingFile.Written {
        var n = 1
        while true {
            let name = "\(base)-\(n)" + (rejected ? "-rejected" : "")
            let exists = ["wav", "json"].contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent(name + "." + $0).path) }
            if !exists { return try RoomRecordingFile.write(recording, name: name, in: folder) }
            n += 1
        }
    }

    private func levelCheck(speaker: RoomSpeaker) async -> RoomMeasurementState? {
        let step = RoomMeasurementStep.levelCheck
        var level = settings.startLevel
        let limits = settings.limits
        for _ in 0..<8 {
            switch await capture(step, speaker: speaker, seconds: settings.checkSweepSeconds, level: level) {
            case .stop(let end): return end
            case .recording(let recording):
                let metrics = RoomCaptureAssessment.assess(recording, limits: RoomQualityLimits.levelOnly(limits)).metrics
                let file = try? save(recording, base: "level-check", rejected: false).url.lastPathComponent
                if metrics.clippedSamples > 0 {
                    return fail(step, [.quality(.clipped(peakDBFS: metrics.peakDBFS))], file: file, level: level, metrics: metrics)
                }
                let shortfall = settings.targetPeakDBFS - metrics.peakDBFS
                if shortfall > 3, level < settings.maxLevel {
                    level = min(settings.maxLevel, level * pow(10, min(shortfall, settings.maxStepDB) / 20))
                    continue
                }
                if metrics.peakDBFS < settings.minimumPeakDBFS {
                    return fail(step, [.quality(.tooQuiet(peakDBFS: metrics.peakDBFS))], file: file, level: level, metrics: metrics)
                }
                inner.withLock { $0.chosenLevel = level }
                succeed(step, file: file, level: level, metrics: metrics)
                return nil
            }
        }
        return fail(step, [.other(String(localized: "The level check couldn't settle on a level."))], file: nil, level: level, metrics: nil)
    }

    private func routeCheck(speaker: RoomSpeaker, all: [RoomSpeaker]) async -> RoomMeasurementState? {
        let step = RoomMeasurementStep.routeCheck(speaker)
        let level = chosenLevel ?? settings.startLevel
        var limits = settings.limits
        limits.minimumPeakToNoiseDB = settings.routeMinimumPeakToNoiseDB
        switch await capture(step, speaker: speaker, seconds: settings.checkSweepSeconds, level: level) {
        case .stop(let end): return end
        case .recording(let recording):
            let assessment = RoomCaptureAssessment.assess(recording, limits: limits)
            let file = try? save(recording, base: "route-\(speaker.rawValue)", rejected: !assessment.accepted).url.lastPathComponent
            guard assessment.accepted else {
                return fail(step, assessment.rejections.map { .quality($0) }, file: file, level: level, metrics: assessment.metrics)
            }
            if settings.requireDistinctRoutes {
                let others = inner.withLock { $0.routes }
                for (other, route) in others where other != speaker {
                    if let a = route.arrival, let b = assessment.metrics.arrivalSamples,
                       abs(a - b) <= settings.distinctSamples, abs(route.rms - assessment.metrics.rmsDBFS) <= settings.distinctDB {
                        let pair = all.filter { $0 == other || $0 == speaker }
                        return fail(step, [.routesIndistinguishable(pair[0], pair[1])], file: file, level: level, metrics: assessment.metrics)
                    }
                }
            }
            inner.withLock { $0.routes[speaker] = Route(arrival: assessment.metrics.arrivalSamples, rms: assessment.metrics.rmsDBFS) }
            succeed(step, file: file, level: level, metrics: assessment.metrics)
            return nil
        }
    }

    private func sweep(speaker: RoomSpeaker, position: Int) async -> RoomMeasurementState? {
        let step = RoomMeasurementStep.sweep(speaker, position)
        let level = chosenLevel ?? settings.startLevel
        switch await capture(step, speaker: speaker, seconds: settings.sweepSeconds, level: level) {
        case .stop(let end): return end
        case .recording(let recording):
            let assessment = RoomCaptureAssessment.assess(recording, limits: settings.limits)
            let base = "\(speaker.rawValue)-p\(position + 1)"
            guard assessment.accepted else {
                let file = try? save(recording, base: base, rejected: true).url.lastPathComponent
                return fail(step, assessment.rejections.map { .quality($0) }, file: file, level: level, metrics: assessment.metrics)
            }
            if isCancelled { return .cancelled(step) }
            do {
                let written = try save(recording, base: base, rejected: false)
                let capture = RoomCapture(id: UUID(), speaker: speaker, position: position, recording: written.url.lastPathComponent,
                                          recordingSHA256: written.sha256, sampleRate: recording.sampleRate, outputSampleRate: recording.sampleRate,
                                          recordedAt: recording.startedAt, clockDriftPPM: assessment.metrics.driftPPM ?? 0, quality: .accepted)
                var session = self.session
                try session.add(capture)
                let data = try RoomCorrectionCoding.encode(session)
                try data.write(to: folder.appendingPathComponent("session.json"), options: .atomic)
                inner.withLock { g in g.session = session; g.recordings.append(recording) }
                succeed(step, file: written.url.lastPathComponent, level: level, metrics: assessment.metrics)
                return nil
            } catch {
                return fail(step, [.other(error.localizedDescription)], file: nil, level: level, metrics: assessment.metrics)
            }
        }
    }
}

extension RoomQualityLimits {
    /// Limits that let a capture through the level check's metrics without failing the later analysis: only its level
    /// is of interest there, and a quiet first try has no references to find.
    static func levelOnly(_ l: RoomQualityLimits) -> RoomQualityLimits {
        var out = l
        out.minimumPeakDBFS = -.infinity
        return out
    }
}
