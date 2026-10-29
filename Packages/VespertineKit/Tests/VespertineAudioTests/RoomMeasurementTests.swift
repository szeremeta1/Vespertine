//
// Vespertine — room measurement state machine: level check, route identification, sweeps, quality rejection,
// retry and resume, against a scripted room (no microphone, no sound).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

/// Stands in for `RoomCaptureSession`: answers each request with what a scripted room would have recorded.
final class ScriptedCapturer: RoomCapturing, @unchecked Sendable {
    typealias Room = @Sendable (RoomCaptureRequest, Int) throws -> [Float]

    private let lock = NSLock()
    private var calls: [RoomCaptureRequest] = []
    var room: Room
    /// Runs inside `record`, before the recording is returned (to cancel mid-capture).
    var duringRecord: (@Sendable () -> Void)?
    private(set) var cancelCount = 0

    init(room: @escaping Room) { self.room = room }

    var requests: [RoomCaptureRequest] { lock.withLock { calls } }

    func record(_ request: RoomCaptureRequest) async throws -> RoomRecording {
        let index = lock.withLock { calls.append(request); return calls.count - 1 }
        duringRecord?()
        let samples = try room(request, index)
        return RoomRecording(samples: samples, sampleRate: request.layout.sampleRate, request: request,
                             startedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)), surplusFrames: 0)
    }

    func cancel() { lock.withLock { cancelCount += 1 } }
}

/// What a room with one microphone records: each output channel is a speaker with its own delay and gain.
struct TestRoom: Sendable {
    var gain: [Int: Double] = [0: 0.05, 1: 0.04]
    var delay: [Int: Double] = [0: 0.0081, 1: 0.0094]
    var clipAt: Double?
    var dropReferences = false
    var noise = 0.0

    func record(_ request: RoomCaptureRequest, noiseSeed: UInt64 = 7) -> [Float] {
        let layout = request.layout
        // Every track from its own speaker: its own delay (not a whole number of samples) and gain.
        var heard = [Double](repeating: 0, count: layout.recordingFrames)
        for track in request.stimulus().tracks {
            var stimulus = track.samples
            if dropReferences {
                for n in 0..<layout.reference.samples.count {
                    stimulus[layout.firstReferenceStart + n] = 0
                    stimulus[layout.secondReferenceStart + n] = 0
                }
            }
            let g = gain[track.channel] ?? 0
            let shift = (delay[track.channel] ?? 0) * layout.sampleRate
            for n in heard.indices {
                let x = Double(n) - shift
                let i = Int(x.rounded(.down)), f = x - Double(i)
                let a = i >= 0 && i < stimulus.count ? Double(stimulus[i]) : 0
                let b = i + 1 >= 0 && i + 1 < stimulus.count ? Double(stimulus[i + 1]) : 0
                heard[n] += g * (a + f * (b - a))
            }
        }
        var generator = SeededGenerator(seed: noiseSeed)
        return heard.map { value in
            var v = value
            if noise > 0 { v += noise * generator.gaussian() }
            if let clipAt { v = max(-clipAt, min(clipAt, v * 3_000)) }
            return Float(v)
        }
    }
}

@Suite("Room measurement")
struct RoomMeasurementTests {
    private static let rate = 48_000.0

    private func settings(positions: Int = 1) -> RoomMeasurementSettings {
        var s = RoomMeasurementSettings(inputDevice: 91, outputDevice: 72)
        s.sampleRate = Self.rate
        s.sweepSeconds = 1.5
        s.checkSweepSeconds = 1
        s.positions = positions
        s.minimumPeakToNoiseDB = 20
        s.routeMinimumPeakToNoiseDB = 10
        return s
    }

    private func newSession() -> RoomSession {
        RoomSession(id: UUID(), createdAt: Date(timeIntervalSince1970: 1_800_000_000), deviceUID: "FiiO-K11", layout: .stereo,
                    channelMap: .standard(.stereo), mic: RoomMic(serial: "0000001", orientation: .upward, calibrationSHA256: nil),
                    target: .flat)
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("room-measurement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func controller(_ capturer: ScriptedCapturer, settings: RoomMeasurementSettings, session: RoomSession? = nil,
                            in folder: URL) -> RoomMeasurementController {
        RoomMeasurementController(settings: settings, session: session ?? newSession(), capturer: capturer, folder: folder)
    }

    private func isSweep(_ r: RoomCaptureRequest, _ s: RoomMeasurementSettings) -> Bool { r.layout.sweep.duration == s.sweepSeconds }

    // MARK: Quality assessment

    @Test("A clean capture is accepted and reports its peak, drift and arrival")
    func assessmentAccepts() throws {
        let s = settings()
        let layout = try RoomCaptureLayout(sampleRate: Self.rate, sweepDuration: 1.5, level: 0.25)
        let request = RoomCaptureRequest(inputDevice: 1, outputDevice: 2, inputChannel: 0, outputChannel: 0, layout: layout)
        let recording = RoomRecording(samples: TestRoom().record(request), sampleRate: Self.rate, request: request,
                                      startedAt: Date(), surplusFrames: 0)
        let a = RoomCaptureAssessment.assess(recording, limits: s.limits)
        #expect(a.accepted, "\(a.rejections)")
        #expect(abs(a.metrics.peakDBFS - 20 * log10(0.05 * 0.25)) < 1.5)
        #expect(abs(a.metrics.driftPPM ?? 999) < 5)
        #expect(abs((a.metrics.arrivalSamples ?? 0) - 0.0081 * Self.rate) < 1)
    }

    @Test("Clipping, a missing reference, silence and a noisy capture are each rejected for their own reason")
    func assessmentRejects() throws {
        let s = settings()
        let layout = try RoomCaptureLayout(sampleRate: Self.rate, sweepDuration: 1.5, level: 0.25)
        let request = RoomCaptureRequest(inputDevice: 1, outputDevice: 2, inputChannel: 0, outputChannel: 0, layout: layout)
        func assess(_ room: TestRoom) -> RoomCaptureAssessment {
            RoomCaptureAssessment.assess(RoomRecording(samples: room.record(request), sampleRate: Self.rate, request: request,
                                                       startedAt: Date(), surplusFrames: 0), limits: s.limits)
        }
        var clipped = TestRoom(); clipped.clipAt = 1
        let c = assess(clipped)
        #expect(!c.accepted && c.rejections.contains { if case .clipped = $0 { true } else { false } })

        var noRef = TestRoom(); noRef.dropReferences = true
        #expect(assess(noRef).rejections.contains(.referenceMissing))

        var silent = TestRoom(); silent.gain = [0: 0]
        #expect(assess(silent).rejections.contains { if case .tooQuiet = $0 { true } else { false } })

        var noisy = TestRoom(); noisy.noise = 0.01; noisy.gain = [0: 0.012]
        #expect(!assess(noisy).accepted)
    }

    // MARK: Level check

    @Test("The level check starts quiet, rises toward the target without passing the ceiling, and never clips on the way")
    func levelCheckRaises() async throws {
        let s = settings()
        var room0 = TestRoom(); room0.gain = [0: 0.02, 1: 0.02]; let room = room0
        let capturer = ScriptedCapturer { r, _ in room.record(r) }
        let c = controller(capturer, settings: s, in: try folder())
        let end = await c.run()
        #expect(end == .completed, "\(end)")
        let levels = capturer.requests.prefix { !isSweep($0, s) }.map(\.layout.level)
        #expect(levels.first == s.startLevel)
        #expect(zip(levels, levels.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(levels.allSatisfy { $0 <= s.maxLevel })
        let chosen = try #require(c.chosenLevel)
        #expect(chosen > s.startLevel && chosen <= s.maxLevel)
        // The peak it measured at the chosen level lands at the target, or the ceiling stopped it.
        let peak = 20 * log10(0.02 * chosen)
        #expect(abs(peak - s.targetPeakDBFS) < 4 || chosen == s.maxLevel)
        #expect(capturer.requests.filter { isSweep($0, s) }.allSatisfy { $0.layout.level == chosen })
    }

    @Test("A capture that clips at the first level stops the run for the listener to turn down: nothing is raised, advanced or recorded")
    func levelCheckClipping() async throws {
        let s = settings()
        var loud0 = TestRoom(); loud0.clipAt = 1; let loud = loud0
        let capturer = ScriptedCapturer { r, _ in loud.record(r) }
        let c = controller(capturer, settings: s, in: try folder())
        let end = await c.run()
        guard case .needsAttention(.levelCheck, let issues) = end else { Issue.record("\(end)"); return }
        #expect(issues.contains { if case .quality(.clipped) = $0 { true } else { false } })
        #expect(capturer.requests.count == 1)
        #expect(c.session.captures.isEmpty)
        // Still too loud: still stopped there, and the level is never raised.
        let again = await c.run()
        guard case .needsAttention(.levelCheck, _) = again else { Issue.record("\(again)"); return }
        #expect(capturer.requests.allSatisfy { $0.layout.level == s.startLevel })
        // Turned down: the same controller carries on.
        capturer.room = { r, _ in TestRoom().record(r) }
        let fixed = await c.run()
        #expect(fixed == .completed, "\(fixed)")
    }

    @Test("Nothing heard even at the ceiling level is reported as too quiet")
    func levelCheckSilence() async throws {
        let s = settings()
        let capturer = ScriptedCapturer { r, _ in [Float](repeating: 0, count: r.layout.recordingFrames) }
        let c = controller(capturer, settings: s, in: try folder())
        let end = await c.run()
        guard case .needsAttention(.levelCheck, let issues) = end else { Issue.record("\(end)"); return }
        #expect(issues.contains { if case .quality(.tooQuiet) = $0 { true } else { false } })
        #expect(capturer.requests.last?.layout.level == s.maxLevel)
        #expect(!capturer.requests.contains { isSweep($0, s) })
    }

    // MARK: Route identification

    @Test("A speaker that never reaches the microphone fails its route check, and no sweep is played")
    func wrongRoute() async throws {
        let s = settings()
        var room0 = TestRoom(); room0.gain = [0: 0.05]; let room = room0   // output 1 is silent: the right speaker is off or on another output
        let capturer = ScriptedCapturer { r, _ in room.record(r) }
        let c = controller(capturer, settings: s, in: try folder())
        let end = await c.run()
        guard case .needsAttention(.routeCheck(.right), _) = end else { Issue.record("\(end)"); return }
        #expect(!capturer.requests.contains { isSweep($0, s) })
        #expect(c.session.captures.isEmpty)
        #expect(c.state == end)
    }

    @Test("Two outputs that sound identical (a mono downmix, or both on one speaker) are caught before any sweep")
    func indistinguishableRoutes() async throws {
        let s = settings()
        var same0 = TestRoom(); same0.gain = [0: 0.05, 1: 0.05]; same0.delay = [0: 0.0081, 1: 0.0081]; let same = same0
        let capturer = ScriptedCapturer { r, _ in same.record(r) }
        let c = controller(capturer, settings: s, in: try folder())
        let end = await c.run()
        guard case .needsAttention(.routeCheck(.right), let issues) = end else { Issue.record("\(end)"); return }
        #expect(issues.contains(.routesIndistinguishable(.left, .right)))
        #expect(!capturer.requests.contains { isSweep($0, s) })
    }

    @Test("Each speaker is played on the output its channel map names, and on no other")
    func usesChannelMap() async throws {
        let s = settings()
        var session = newSession()
        session.channelMap = RoomChannelMap(entries: [.init(speaker: .left, output: 3), .init(speaker: .right, output: 5)], verified: true)
        var room0 = TestRoom(); room0.gain = [3: 0.05, 5: 0.04]; room0.delay = [3: 0.0081, 5: 0.0094]; let room = room0
        let capturer = ScriptedCapturer { r, _ in room.record(r) }
        let c = controller(capturer, settings: s, session: session, in: try folder())
        #expect(await c.run() == .completed)
        #expect(Set(capturer.requests.map(\.outputChannel)) == [3, 5])
        #expect(capturer.requests.allSatisfy { $0.inputDevice == 91 && $0.outputDevice == 72 && $0.inputChannel == 0 })
        let sweeps = capturer.requests.filter { isSweep($0, s) }.map(\.outputChannel)
        #expect(sweeps == [3, 5])
    }

    // MARK: Sweeps, rejection and retry

    @Test("A full run records one accepted capture per speaker and position, with its file and hash")
    func fullRun() async throws {
        let s = settings()
        let dir = try folder()
        let c = controller(ScriptedCapturer { r, _ in TestRoom().record(r) }, settings: s, in: dir)
        #expect(await c.run() == .completed)
        #expect(Set(c.session.captures.map(\.speaker)) == [.left, .right])
        for capture in c.session.captures {
            #expect(capture.quality == .accepted && capture.position == 0 && capture.sampleRate == Self.rate)
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(capture.recording).path))
            let read = try RoomRecordingFile.read(dir.appendingPathComponent(capture.recording))
            #expect(read.sampleRate == Self.rate)
        }
        #expect(c.acceptedRecordings.count == 2)
        let saved = try RoomCorrectionCoding.decodeSession(Data(contentsOf: dir.appendingPathComponent("session.json")))
        #expect(saved.captures.count == 2)
    }

    @Test("A sweep that lost its timing references is rejected and kept as evidence; it is not added, nothing advances, and a retry can succeed")
    func missingReference() async throws {
        let s = settings()
        let dir = try folder()
        let flag = Locked(true)
        let capturer = ScriptedCapturer { r, _ in
            var room = TestRoom()
            if self.isSweep(r, s), r.outputChannel == 0, flag.withLock({ $0 }) { room.dropReferences = true }
            return room.record(r)
        }
        let c = controller(capturer, settings: s, in: dir)
        let end = await c.run()
        guard case .needsAttention(.sweep(.left, 0), let issues) = end else { Issue.record("\(end)"); return }
        #expect(issues.contains(.quality(.referenceMissing)))
        #expect(c.session.captures.isEmpty)
        #expect(c.acceptedRecordings.isEmpty)
        #expect(!capturer.requests.contains { isSweep($0, s) && $0.outputChannel == 1 })
        let rejected = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("rejected") && $0.hasSuffix(".wav") }
        #expect(rejected.count == 1)
        #expect(c.log.contains { !$0.accepted && $0.step == .sweep(.left, 0) })

        flag.withLock { $0 = false }
        #expect(await c.run() == .completed)
        #expect(c.session.captures.count == 2 && c.session.captures.allSatisfy { $0.quality == .accepted })
    }

    @Test("A capture that fails on the hardware (unplugged) asks for attention on that step and is retried there")
    func hardwareFailure() async throws {
        let s = settings()
        let failing = Locked(true)
        let capturer = ScriptedCapturer { r, _ in
            if self.isSweep(r, s), r.outputChannel == 1, failing.withLock({ $0 }) { throw RoomCaptureError.deviceUnplugged }
            return TestRoom().record(r)
        }
        let c = controller(capturer, settings: s, in: try folder())
        let end = await c.run()
        guard case .needsAttention(.sweep(.right, 0), let issues) = end else { Issue.record("\(end)"); return }
        #expect(issues == [.capture(.deviceUnplugged)])
        #expect(c.session.captures.map(\.speaker) == [.left])
        failing.withLock { $0 = false }
        #expect(await c.run() == .completed)
        #expect(Set(c.session.captures.map(\.speaker)) == [.left, .right])
    }

    @Test("After the attempt limit the step fails for good and a further run does not try again")
    func attemptLimit() async throws {
        var s0 = settings()
        s0.maxAttempts = 2
        let s = s0
        let capturer = ScriptedCapturer { r, _ in
            var room = TestRoom()
            room.dropReferences = self.isSweep(r, s)
            return room.record(r)
        }
        let c = controller(capturer, settings: s, in: try folder())
        let first = await c.run()
        guard case .needsAttention(.sweep(.left, 0), _) = first else { Issue.record("\(first)"); return }
        let second = await c.run()
        guard case .failed(.sweep(.left, 0), _) = second else { Issue.record("\(second)"); return }
        let calls = capturer.requests.count
        #expect(await c.run() == second)
        #expect(capturer.requests.count == calls)
        #expect(c.session.captures.isEmpty)
    }

    // MARK: Cancellation and resume

    @Test("Cancelling during a capture stops it; even a perfect recording that arrives after the cancel is not accepted")
    func cancellation() async throws {
        let s = settings()
        let holder = Locked<RoomMeasurementController?>(nil)
        let capturer = ScriptedCapturer { r, _ in TestRoom().record(r) }
        capturer.duringRecord = {
            // The first sweep request is the one cancelled.
            if capturer.requests.last.map({ self.isSweep($0, s) }) == true { holder.withLock { $0 }?.cancel() }
        }
        let c = controller(capturer, settings: s, in: try folder())
        holder.withLock { $0 = c }
        let end = await c.run()
        guard case .cancelled(.sweep(.left, 0)) = end else { Issue.record("\(end)"); return }
        #expect(capturer.cancelCount >= 1)
        #expect(c.session.captures.isEmpty && c.acceptedRecordings.isEmpty)
        #expect(!c.log.contains { $0.accepted && $0.step == .sweep(.left, 0) })

        // A cancelled run resumes from the step it stopped on.
        capturer.duringRecord = nil
        #expect(await c.run() == .completed)
        #expect(Set(c.session.captures.map(\.speaker)) == [.left, .right])
    }

    @Test("A cancel before anything runs starts nothing")
    func cancelFirst() async throws {
        let capturer = ScriptedCapturer { r, _ in TestRoom().record(r) }
        let c = controller(capturer, settings: settings(), in: try folder())
        c.cancel()
        let end = await c.run()
        guard case .cancelled = end else { Issue.record("\(end)"); return }
        #expect(capturer.requests.isEmpty)
    }

    @Test("A session that already holds an accepted capture resumes after it: the checks run again, the finished sweep does not")
    func resume() async throws {
        let s = settings()
        let dir = try folder()
        let first = controller(ScriptedCapturer { r, _ in TestRoom().record(r) }, settings: s, in: dir)
        #expect(await first.run() == .completed)
        // Rebuild a partial session: only the left capture survives.
        var partial = newSession()
        try partial.add(try #require(first.session.captures.first { $0.speaker == .left }))
        let capturer = ScriptedCapturer { r, _ in TestRoom().record(r) }
        let c = controller(capturer, settings: s, session: partial, in: dir)
        #expect(await c.run() == .completed)
        let sweeps = capturer.requests.filter { isSweep($0, s) }
        #expect(sweeps.map(\.outputChannel) == [1])
        #expect(capturer.requests.contains { !isSweep($0, s) && $0.outputChannel == 0 })
        #expect(c.session.captures.count == 2)
        #expect(Set(c.session.captures.map(\.id)).count == 2)
    }

    @Test("More than one position waits for the mic to be moved, and only the listener's confirmation moves on")
    func positions() async throws {
        let s = settings(positions: 2)
        let capturer = ScriptedCapturer { r, _ in TestRoom().record(r) }
        let c = controller(capturer, settings: s, in: try folder())
        let wait = await c.run()
        #expect(wait == .waitingForMic(position: 1))
        #expect(c.session.captures.count == 2)
        let sweepsBefore = capturer.requests.filter { isSweep($0, s) }.count
        #expect(await c.run() == wait)
        #expect(capturer.requests.filter { isSweep($0, s) }.count == sweepsBefore)
        c.confirmMicMoved()
        #expect(await c.run() == .completed)
        #expect(c.session.captures.count == 4)
        #expect(Set(c.session.captures.map(\.position)) == [0, 1])
    }

    @Test("A second run while one is going is refused rather than doubling the capture")
    func singleRun() async throws {
        let s = settings()
        let capturer = ScriptedCapturer { r, _ in TestRoom().record(r) }
        let c = controller(capturer, settings: s, in: try folder())
        async let a = c.run()
        async let b = c.run()
        let results = await [a, b]
        #expect(results.contains(.completed))
        #expect(c.session.captures.count == 2)
    }

    // MARK: Results

    @Test("Calibrated response is the raw response plus the microphone's compensation, on the sweep's reliable band, and the files carry it")
    func responseExport() async throws {
        let s = settings()
        let dir = try folder()
        let c = controller(ScriptedCapturer { r, _ in TestRoom().record(r) }, settings: s, in: dir)
        #expect(await c.run() == .completed)
        let cal = try MicCalibration.parse(Data("\"Sens Factor =-1.5dB, SERNO: 0000001\"\n20 -2.0\n1000 0.0\n20000 3.0\n".utf8))
        let recording = try #require(c.acceptedRecordings.first { $0.request.outputChannel == 0 })
        let curve = try RoomMagnitudeResponse.compute(recording: recording, calibration: cal)
        let n = curve.frequencies.count
        #expect(n > 100 && n == curve.rawDB.count && n == curve.calibratedDB.count)
        let band = recording.request.layout.sweep.reliableBand
        #expect(curve.frequencies.first! >= band.lowerBound - 1 && curve.frequencies.last! <= band.upperBound + 1)
        for i in stride(from: 0, to: curve.frequencies.count, by: 17) {
            #expect(abs(curve.calibratedDB[i] - (curve.rawDB[i] + cal.compensationDB(at: curve.frequencies[i]))) < 1e-9)
        }
        // A flat room model (gain only) recovers flat to within a dB across the middle of the band.
        let mid = curve.frequencies.indices.filter { curve.frequencies[$0] > 200 && curve.frequencies[$0] < 8000 }
        let level = mid.map { curve.rawDB[$0] }
        #expect((level.max()! - level.min()!) < 1.5)
        #expect(abs(level[0] - 20 * log10(0.05)) < 1)

        let written = try RoomResponseFiles.write([.left: curve], to: dir, name: "response")
        let csv = try String(contentsOf: written.csv[0], encoding: .utf8)
        let lines = csv.split(separator: "\n")
        #expect(lines[0] == "frequency_hz,raw_db,mic_compensation_db,calibrated_db,calibrated_normalised_db")
        #expect(lines.count == curve.frequencies.count + 1)
        #expect(lines[1].split(separator: ",").count == 5)
        let png = try Data(contentsOf: written.plot)
        #expect(png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) && png.count > 5_000)
    }
}

@Suite("Simulated room")
struct SimulatedRoomTests {
    @Test("A measurement through the simulated room is accepted by the same checks as a real one")
    func simulatedCapture() async throws {
        // The settings the driver uses: 5 s sweeps, the default quality limits.
        let settings = RoomMeasurementSettings(inputDevice: 1, outputDevice: 2)
        let session = RoomSession(id: UUID(), createdAt: Date(), deviceUID: "sim", layout: .stereo, channelMap: .standard(.stereo),
                                  mic: RoomMic(serial: "sim", orientation: .upward, calibrationSHA256: nil), target: .flat)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("room-sim-\(UUID().uuidString)")
        let capture = RoomCaptureSession(device: SimulatedRoomDevice(), permission: AlwaysGrantedMicrophone(), pollInterval: 0.001)
        let controller = RoomMeasurementController(settings: settings, session: session, capturer: capture, folder: dir)
        let end = await controller.run()
        #expect(end == .completed, "\(end) \(controller.log.last?.issues ?? [])")
        let curve = try RoomMagnitudeResponse.compute(recording: try #require(controller.acceptedRecordings.first), calibration: nil)
        // The simulated room has a resonance near 63 Hz and rolls off above 7 kHz.
        func level(_ hz: Double) -> Double { curve.normalisedDB[curve.frequencies.enumerated().min { abs($0.element - hz) < abs($1.element - hz) }!.offset] }
        #expect(level(63) > level(300) + 3)
        #expect(level(15_000) < level(1_000) - 3)
        // The room model is smooth, so the response is too: no point sits far from its neighbours.
        let smooth = curve.smoothedDB
        #expect(zip(curve.normalisedDB, smooth).allSatisfy { abs($0 - $1) < 3 })
        let written = try RoomResponseFiles.write([.left: curve], to: dir, name: "response")
        print("SIM-PLOT", written.plot.path)
    }
}

@Suite("Room measurement launch arguments")
struct RoomMeasureLaunchTests {
    @Test("--room-measure starts a run, with an optional calibration path, mic name, position count and the simulated room")
    func parsing() {
        #expect(RoomMeasureLaunch.parse(["/x/App"]) == nil)
        #expect(RoomMeasureLaunch.parse(["/x/App", "-NSDocumentRevisionsDebugMode", "YES"]) == nil)
        let plain = RoomMeasureLaunch.parse(["/x/App", "--room-measure"])
        #expect(plain == RoomMeasureLaunch(calibrationPath: nil, micName: "UMIK", positions: 1, simulate: false))
        let full = RoomMeasureLaunch.parse(["/x/App", "--room-measure", "~/Documents/UMIK-1/0000001_90deg.txt", "--room-measure-positions", "3",
                                            "--room-measure-mic", "UMIK-1", "--room-measure-simulate"])
        #expect(full == RoomMeasureLaunch(calibrationPath: "~/Documents/UMIK-1/0000001_90deg.txt", micName: "UMIK-1", positions: 3, simulate: true))
        // A flag is never taken for the path; a bad count falls back to one position, and counts are capped.
        #expect(RoomMeasureLaunch.parse(["App", "--room-measure", "--room-measure-simulate"])?.calibrationPath == nil)
        #expect(RoomMeasureLaunch.parse(["App", "--room-measure", "--room-measure-positions", "x"])?.positions == 1)
        #expect(RoomMeasureLaunch.parse(["App", "--room-measure", "--room-measure-positions", "99"])?.positions == 5)
    }
}

/// The chain of the first real run (29 October 2026: Fosi Audio ZD3 USB DAC at 48 kHz, UMIK-1), built from its captures:
/// the impulse response recovered from a route-check sweep (speaker, room and microphone, at that run's volume), the
/// microphone's own noise, and the thump the UMIK-1 records as its stream starts. The DAC was silent for the start of
/// every stream: the first timing tone (0.2-0.3 s) never arrived, while the sweep was heard from at most 0.92 s on.
struct RealChainRoom: Sendable {
    /// Samples from the start of playback to the first sample of the impulse fixture (the real arrival was 3859 samples,
    /// 80 ms: output and input latency plus the distance; the fixture keeps 256 samples before its peak).
    static let delay = 3_603
    static let impulse = fixture("room-zd3-umik-impulse")
    static let noise = fixture("room-umik-noise")
    static let startTransient = fixture("room-umik-start-transient")

    static func fixture(_ name: String) -> [Double] {
        let url = Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Fixtures")!
        return try! RoomRecordingFile.read(url).samples.map(Double.init)
    }

    /// Seconds of each stream the DAC keeps silent: the latest the real captures allow.
    var muteSeconds = 0.92
    /// The right speaker is the left one moved a little (one real speaker was measured).
    var extraDelay: [Int: Int] = [0: 0, 1: 45]
    var gain: [Int: Double] = [0: 1, 1: 0.8]

    func record(_ request: RoomCaptureRequest) -> [Float] {
        let layout = request.layout
        // Each track from its own speaker (the references and the sweep can come from different ones).
        let speakers: [(heard: [Double], gain: Double, shift: Int)] = request.stimulus().tracks.map { track in
            var played = track.samples.map(Double.init)
            for n in 0..<min(Int(muteSeconds * layout.sampleRate), played.count) { played[n] = 0 }
            return (RoomFFT.convolve(played, Self.impulse), gain[track.channel] ?? 0, Self.delay + (extraDelay[track.channel] ?? 0))
        }
        return (0..<layout.recordingFrames).map { n in
            var v = Self.noise[n % Self.noise.count]
            if n < Self.startTransient.count { v += Self.startTransient[n] }
            for s in speakers where n - s.shift >= 0 && n - s.shift < s.heard.count { v += s.gain * s.heard[n - s.shift] }
            return Float(v)
        }
    }
}

@Suite("Room measurement on the real ZD3 and UMIK-1 chain")
struct RealChainMeasurementTests {
    private func run(_ room: RealChainRoom) async throws -> RoomMeasurementController {
        // The driver's settings: default levels and limits, 5 s sweeps.
        let settings = RoomMeasurementSettings(inputDevice: 121, outputDevice: 117)
        let session = RoomSession(id: UUID(), createdAt: Date(), deviceUID: "zd3", layout: .stereo, channelMap: .standard(.stereo),
                                  mic: RoomMic(serial: "umik", orientation: .upward, calibrationSHA256: nil), target: .flat)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("room-real-\(UUID().uuidString)")
        let controller = RoomMeasurementController(settings: settings, session: session,
                                                   capturer: ScriptedCapturer { request, _ in room.record(request) }, folder: dir)
        await controller.run()
        return controller
    }

    @Test("A DAC that is silent for the start of each stream, and a microphone that thumps as it starts, still give a measurement")
    func mutedStartAndMicThump() async throws {
        let controller = try await run(RealChainRoom())
        #expect(controller.state == .completed, "\(controller.state) \(controller.log.map { "\($0.step) \($0.level) \($0.issues)" })")
        // The level is set by the tones, not by the microphone's start-up thump (-31 dBFS, which stopped the first real
        // run's level check at 0.01 while its tones peaked near -49 dBFS).
        let check = try #require(controller.log.last { $0.step == .levelCheck && $0.accepted })
        let peak = try #require(check.metrics?.peakDBFS)
        #expect(abs(peak - RoomMeasurementSettings(inputDevice: 0, outputDevice: 0).targetPeakDBFS) <= 3.5, "\(peak)")
        #expect((controller.chosenLevel ?? 0) > 0.02)
        for speaker in [RoomSpeaker.left, .right] {
            #expect(controller.log.contains { $0.step == .routeCheck(speaker) && $0.accepted })
        }
        #expect(controller.session.captures.count == 2)
    }

    @Test("Quiet timing tones are found over the microphone's low rumble, which lies far below their band")
    func quietTonesOverRumble() throws {
        // The first real run's route checks: level 0.01 at a lower volume, tones peaking near -50 dBFS, 20 dB over the
        // in-band noise but no louder than the rumble below 200 Hz.
        var room = RealChainRoom()
        room.gain = [0: 0.45]
        let layout = try RoomCaptureLayout(sampleRate: 48_000, sweepDuration: 1, level: 0.01)
        let request = RoomCaptureRequest(inputDevice: 121, outputDevice: 117, inputChannel: 0, outputChannel: 0, layout: layout)
        let samples = room.record(request)
        let recording = RoomRecording(samples: samples, sampleRate: 48_000, request: request, startedAt: Date(), surplusFrames: 0)
        let a = RoomCaptureAssessment.assess(recording, limits: RoomQualityLimits())
        #expect(a.metrics.peakDBFS < -45, "\(a.metrics.peakDBFS)")
        let drift = try recording.analyse().drift
        #expect(abs(drift.ppm) < 5)
        #expect(abs(drift.firstPosition - Double(layout.firstReferenceStart + RealChainRoom.delay + 256)) < 3)
        #expect(!a.rejections.contains(.referenceMissing) && !a.rejections.contains(.startCutOff), "\(a.rejections)")
    }

    @Test("An output that stays silent past the whole lead-in is named as a cut-off start, not as missing tones, and not retried as noise")
    func silentPastLeadIn() throws {
        var room = RealChainRoom()
        room.muteSeconds = RoomCaptureLayout.defaultLeadInSeconds + 0.15
        let layout = try RoomCaptureLayout(sampleRate: 48_000, sweepDuration: 1, level: 0.034)
        let request = RoomCaptureRequest(inputDevice: 121, outputDevice: 117, inputChannel: 0, outputChannel: 0, layout: layout)
        let recording = RoomRecording(samples: room.record(request), sampleRate: 48_000, request: request, startedAt: Date(), surplusFrames: 0)
        let a = RoomCaptureAssessment.assess(recording, limits: RoomQualityLimits())
        #expect(a.rejections == [.startCutOff], "\(a.rejections)")
        // Heard normally, the same capture passes.
        let heard = RoomRecording(samples: RealChainRoom().record(request), sampleRate: 48_000, request: request, startedAt: Date(), surplusFrames: 0)
        var limits = RoomQualityLimits(); limits.minimumPeakToNoiseDB = 15
        #expect(RoomCaptureAssessment.assess(heard, limits: limits).accepted)
    }
}
