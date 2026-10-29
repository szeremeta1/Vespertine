//
// Vespertine — room measurement capture: permission, bounded recording, unplug handling and the saved file,
// all against a fake device (no microphone, no sound).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import CryptoKit
import Foundation
import Testing
@testable import VespertineAudio

/// A scripted stand-in for the input and output hardware.
final class FakeRoomDevice: RoomCaptureDevice, @unchecked Sendable {
    enum Step { case frames([Float]), unplug, lost(Int), nothing }

    private let lock = NSLock()
    private var script: [Step] = []
    private var cursor = 0
    private(set) var startedWith: (request: RoomCaptureRequest, stimulus: [Float])?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var startError: Error?
    /// When set, `start` builds the script from the stimulus: what the room would record, in `chunk`-frame pieces.
    var room: (@Sendable ([Float]) -> [Float])?
    var chunk = 4_800

    func load(_ steps: [Step]) { lock.withLock { script = steps; cursor = 0 } }

    func start(request: RoomCaptureRequest, stimulus: [Float]) throws {
        if let startError { throw startError }
        lock.withLock {
            startCount += 1
            startedWith = (request, stimulus)
            if let room {
                let recording = room(stimulus)
                script = stride(from: 0, to: recording.count, by: chunk).map {
                    .frames(Array(recording[$0..<min($0 + chunk, recording.count)]))
                }
                cursor = 0
            }
        }
    }

    func readAvailable(maxFrames: Int) -> RoomCaptureChunk {
        lock.withLock {
            guard cursor < script.count else { return RoomCaptureChunk(frames: [], lostFrames: 0, alive: true) }
            let step = script[cursor]
            cursor += 1
            switch step {
            case .frames(let f): return RoomCaptureChunk(frames: Array(f.prefix(maxFrames)), lostFrames: 0, alive: true)
            case .unplug: return RoomCaptureChunk(frames: [], lostFrames: 0, alive: false)
            case .lost(let n): return RoomCaptureChunk(frames: [], lostFrames: n, alive: true)
            case .nothing: return RoomCaptureChunk(frames: [], lostFrames: 0, alive: true)
            }
        }
    }

    func stop() { lock.withLock { stopCount += 1 } }
}

final class FakePermission: MicrophonePermission, @unchecked Sendable {
    private let lock = NSLock()
    private var current: MicrophoneAccess
    private let answer: Bool
    private(set) var requests = 0
    init(_ status: MicrophoneAccess, answer: Bool = true) { current = status; self.answer = answer }
    var status: MicrophoneAccess { lock.withLock { current } }
    func request() async -> Bool {
        lock.withLock { requests += 1; current = answer ? .granted : .denied }
        return answer
    }
}

@Suite("Room measurement capture")
struct RoomCaptureTests {
    private static let rate = 48_000.0
    private static let ppm = 40.0, delay = 0.0087, gain = 0.4

    private func layout(sweep: Double = 3) throws -> RoomCaptureLayout { try RoomCaptureLayout(sampleRate: Self.rate, sweepDuration: sweep) }
    private let request = { (layout: RoomCaptureLayout) in
        RoomCaptureRequest(inputDevice: 91, outputDevice: 72, inputChannel: 1, outputChannel: 2, layout: layout)
    }

    /// What the room records: the stimulus through a delay (not a whole number of samples) and a gain, on an input
    /// clock `ppm` fast, with `Self.slack` of extra recording after playback ends.
    private func roomModel(layout: RoomCaptureLayout) -> @Sendable ([Float]) -> [Float] {
        let ppm = Self.ppm, delay = Self.delay, gain = Self.gain, rate = Self.rate
        let reference = layout.reference, sweep = layout.sweep
        let first = Double(layout.firstReferenceStart) / rate, sweepAt = Double(layout.sweepStart) / rate
        let second = Double(layout.secondReferenceStart) / rate
        let frames = layout.recordingFrames
        return { _ in
            let ratio = 1 + ppm * 1e-6
            return (0..<frames).map { n in
                let t = Double(n) / (rate * ratio) - delay
                return Float(gain * (reference.value(at: t - first) + sweep.value(at: t - sweepAt) + reference.value(at: t - second)))
            }
        }
    }

    private func session(_ device: FakeRoomDevice, _ permission: FakePermission, stall: Double = 1) -> RoomCaptureSession {
        RoomCaptureSession(device: device, permission: permission, pollInterval: 0.001, stallTimeout: stall,
                           now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    // MARK: Layout

    @Test("The layout is reference, sweep, reference, with the references well clear of the sweep and each in its own half of the recording")
    func layoutShape() throws {
        let l = try layout()
        #expect(l.stimulus().count == l.totalFrames)
        #expect(l.firstReferenceStart > 0)
        let refLen = l.reference.samples.count
        #expect(l.sweepStart - (l.firstReferenceStart + refLen) >= Int(0.3 * Self.rate))
        #expect(l.secondReferenceStart - (l.sweepStart + l.sweep.samples.count) >= Int(0.3 * Self.rate))
        #expect(l.nominalSpacing == l.secondReferenceStart - l.firstReferenceStart)
        #expect(l.sweepOffset == l.sweepStart - l.firstReferenceStart)
        #expect(l.recordingFrames > l.totalFrames)
        // The estimator looks for the first reference in the first half, the second in the second half.
        #expect(l.firstReferenceStart + refLen < l.recordingFrames / 2)
        #expect(l.secondReferenceStart > l.recordingFrames / 2)
        let stim = l.stimulus()
        #expect(stim.contains { $0 > 0.2 })
        #expect(stim.allSatisfy { abs($0) <= 1 })
        // The lead-in holds only the faint wake noise (to rouse an output that is still starting), then silence.
        #expect(l.firstReferenceStart >= Int(RoomCaptureLayout.defaultLeadInSeconds * Self.rate))
        #expect(l.wakeFrames > 0 && stim[0..<l.wakeFrames].allSatisfy { abs($0) <= Float(RoomCaptureLayout.wakeLevel) })
        #expect(stim[0..<l.wakeFrames].contains { $0 != 0 })
        #expect(stim[l.wakeFrames..<l.firstReferenceStart].allSatisfy { $0 == 0 })
    }

    @Test("A sweep that would put the references inside the half-way split, or an unusable rate, is refused")
    func layoutRefusals() {
        #expect(throws: RoomCaptureError.invalidLayout) { try RoomCaptureLayout(sampleRate: 0, sweepDuration: 3) }
        #expect(throws: RoomCaptureError.invalidLayout) { try RoomCaptureLayout(sampleRate: 48_000, sweepDuration: 0.5) }
        #expect(throws: RoomCaptureError.invalidLayout) { try RoomCaptureLayout(sampleRate: 48_000, sweepDuration: 3, gap: 0.1) }
    }

    // MARK: Permission

    @Test("Denied and restricted permission fail without touching the device, and the session is idle again")
    func permissionDenied() async throws {
        let l = try layout()
        for status in [MicrophoneAccess.denied, .restricted] {
            let device = FakeRoomDevice(), permission = FakePermission(status)
            let s = session(device, permission)
            await #expect(throws: status == .denied ? RoomCaptureError.permissionDenied : RoomCaptureError.permissionRestricted) {
                try await s.record(request(l))
            }
            #expect(device.startCount == 0 && permission.requests == 0)
            #expect(s.state == .idle)
        }
    }

    @Test("An unanswered permission is requested once; a refusal at the prompt is a denial, an approval proceeds")
    func permissionPrompt() async throws {
        let l = try layout()
        let refused = FakePermission(.notDetermined, answer: false), device = FakeRoomDevice()
        let s = session(device, refused)
        await #expect(throws: RoomCaptureError.permissionDenied) { try await s.record(request(l)) }
        #expect(refused.requests == 1 && device.startCount == 0 && s.state == .idle)

        let approved = FakePermission(.notDetermined, answer: true), device2 = FakeRoomDevice()
        device2.room = roomModel(layout: l)
        let recording = try await session(device2, approved).record(request(l))
        #expect(approved.requests == 1 && device2.startCount == 1)
        #expect(recording.samples.count == l.recordingFrames)
    }

    // MARK: Recording

    @Test("A recording uses the requested device IDs and stimulus, has exactly the planned length, and feeds the drift estimate")
    func recordsAndAnalyses() async throws {
        let l = try layout()
        let device = FakeRoomDevice()
        device.room = roomModel(layout: l)
        let s = session(device, FakePermission(.granted))
        let recording = try await s.record(request(l))
        #expect(device.startedWith?.request.inputDevice == 91 && device.startedWith?.request.outputDevice == 72)
        #expect(device.startedWith?.request.inputChannel == 1 && device.startedWith?.request.outputChannel == 2)
        #expect(device.startedWith?.stimulus == l.stimulus())
        #expect(device.stopCount >= 1)
        #expect(s.state == .idle)
        #expect(recording.samples.count == l.recordingFrames && recording.surplusFrames == 0)
        #expect(recording.inputDevice == 91 && recording.outputDevice == 72)
        #expect(recording.startedAt == Date(timeIntervalSince1970: 1_800_000_000))

        let analysis = try recording.analyse()
        #expect(abs(analysis.drift.ppm - Self.ppm) < 1, "drift \(analysis.drift.ppm)")
        let ir = try l.sweep.recover(recording: analysis.sweepSegment)
        #expect(abs(ir.delaySamples) <= 1)
        #expect(abs(ir.response(at: 1_000).magnitudeDB - 20 * log10(Self.gain)) < 0.5)
    }

    @Test("Buffers are bounded: a device that delivers more than planned is clipped to the plan and the surplus is counted")
    func boundedRecording() async throws {
        let l = try layout()
        let device = FakeRoomDevice()
        let huge = [Float](repeating: 0.1, count: l.recordingFrames * 3)
        device.load([.frames(huge)])
        let recording = try await session(device, FakePermission(.granted)).record(request(l))
        #expect(recording.samples.count == l.recordingFrames)
        #expect(recording.surplusFrames == 0)   // one read never returns more than the room left (maxFrames)
        // Chunks past the end are counted, not stored.
        let device2 = FakeRoomDevice()
        device2.chunk = l.recordingFrames - 100
        device2.load([.frames([Float](repeating: 0.1, count: l.recordingFrames - 100)), .frames([Float](repeating: 0.2, count: 300))])
        let recording2 = try await session(device2, FakePermission(.granted)).record(request(l))
        #expect(recording2.samples.count == l.recordingFrames)
        #expect(recording2.samples.last == 0.2)
    }

    @Test("BoundedFrameBuffer never holds more than its capacity and reports what it refused")
    func boundedBuffer() {
        var buffer = BoundedFrameBuffer(capacity: 10)
        #expect(buffer.append([1, 2, 3, 4, 5, 6]) == 6)
        #expect(buffer.remaining == 4)
        #expect(buffer.append([7, 8, 9, 10, 11, 12]) == 4)
        #expect(buffer.isFull && buffer.refused == 2 && buffer.frames.count == 10)
        #expect(buffer.append([1]) == 0 && buffer.refused == 3)
        #expect(buffer.frames == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    }

    // MARK: Failure paths back to idle

    @Test("Unplugging the input or output mid-capture stops the device, fails with the cause, and leaves the session ready for another try")
    func unplug() async throws {
        let l = try layout()
        let device = FakeRoomDevice()
        device.load([.frames([Float](repeating: 0.1, count: 9_600)), .unplug])
        let s = session(device, FakePermission(.granted))
        await #expect(throws: RoomCaptureError.deviceUnplugged) { try await s.record(request(l)) }
        #expect(device.stopCount >= 1)
        #expect(s.state == .idle)
        // Idle means usable again.
        device.room = roomModel(layout: l)
        let recording = try await s.record(request(l))
        #expect(recording.samples.count == l.recordingFrames)
    }

    @Test("Lost frames make the capture unusable and are reported, not papered over")
    func lostFrames() async throws {
        let l = try layout()
        let device = FakeRoomDevice()
        device.load([.frames([Float](repeating: 0.1, count: 4_800)), .lost(512)])
        let s = session(device, FakePermission(.granted))
        await #expect(throws: RoomCaptureError.framesLost(512)) { try await s.record(request(l)) }
        #expect(device.stopCount >= 1 && s.state == .idle)
    }

    @Test("A device that never delivers frames times out instead of hanging, and a failed start is reported")
    func stalledAndStartFailure() async throws {
        let l = try layout()
        let stalled = FakeRoomDevice()
        stalled.load([.nothing])
        let s = session(stalled, FakePermission(.granted), stall: 0.05)
        await #expect(throws: RoomCaptureError.stalled) { try await s.record(request(l)) }
        #expect(stalled.stopCount >= 1 && s.state == .idle)

        let broken = FakeRoomDevice()
        broken.startError = CoreAudioError(-10851, "AudioDeviceStart (input)")
        let s2 = session(broken, FakePermission(.granted))
        await #expect(throws: RoomCaptureError.startFailed("AudioDeviceStart (input) failed: -10851")) {
            try await s2.record(request(l))
        }
        #expect(s2.state == .idle)
    }

    @Test("Cancelling stops the device and returns to idle; a second capture while one runs is refused")
    func cancelAndBusy() async throws {
        let l = try layout()
        let device = FakeRoomDevice()
        device.load(Array(repeating: .nothing, count: 1))
        let s = session(device, FakePermission(.granted), stall: 30)
        let req = request(l)
        let first = Task { try await s.record(req) }
        while s.state == .idle { try await Task.sleep(for: .milliseconds(1)) }
        await #expect(throws: RoomCaptureError.busy) { try await s.record(request(l)) }
        s.cancel()
        await #expect(throws: RoomCaptureError.cancelled) { try await first.value }
        #expect(device.stopCount >= 1 && s.state == .idle)
    }

    @Test("A request whose channels are not valid for the plan is refused before anything starts")
    func invalidRequest() async throws {
        let l = try layout()
        let device = FakeRoomDevice()
        let s = session(device, FakePermission(.granted))
        let bad = RoomCaptureRequest(inputDevice: 0, outputDevice: 72, inputChannel: 0, outputChannel: 0, layout: l)
        await #expect(throws: RoomCaptureError.invalidRequest) { try await s.record(bad) }
        let bad2 = RoomCaptureRequest(inputDevice: 91, outputDevice: 72, inputChannel: -1, outputChannel: 0, layout: l)
        await #expect(throws: RoomCaptureError.invalidRequest) { try await s.record(bad2) }
        #expect(device.startCount == 0 && s.state == .idle)
    }

    // MARK: File

    @Test("The saved file reads back as 32-bit float mono at the capture rate, sample for sample, with its hash and timestamp record")
    func fileWriter() async throws {
        let l = try layout()
        let device = FakeRoomDevice()
        device.room = roomModel(layout: l)
        let recording = try await session(device, FakePermission(.granted)).record(request(l))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("roomcapture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let saved = try RoomRecordingFile.write(recording, name: "front-left-1", in: folder)
        #expect(saved.url.lastPathComponent == "front-left-1.wav")
        let bytes = try Data(contentsOf: saved.url)
        #expect(saved.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())

        // An independent reader agrees about the format and the content.
        let file = try AVAudioFile(forReading: saved.url, commonFormat: .pcmFormatFloat32, interleaved: false)
        #expect(file.processingFormat.sampleRate == Self.rate && file.processingFormat.channelCount == 1)
        #expect(file.length == AVAudioFramePosition(recording.samples.count))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let read = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        #expect(read == recording.samples)

        // Our own reader, and the sidecar with the timestamps.
        let back = try RoomRecordingFile.read(saved.url)
        #expect(back.samples == recording.samples && back.sampleRate == Self.rate)
        let info = try RoomRecordingFile.readInfo(saved.infoURL)
        #expect(info.startedAt == recording.startedAt && info.sampleRate == Self.rate)
        #expect(info.frames == recording.samples.count && info.inputDevice == 91 && info.outputDevice == 72)
        #expect(info.sha256 == saved.sha256 && info.durationSeconds == Double(recording.samples.count) / Self.rate)
        #expect(info.nominalSpacing == l.nominalSpacing && info.sweepOffset == l.sweepOffset)

        // Refuses to overwrite and to escape the folder.
        #expect(throws: RoomCaptureError.fileExists) { try RoomRecordingFile.write(recording, name: "front-left-1", in: folder) }
        #expect(throws: RoomCaptureError.invalidFileName) { try RoomRecordingFile.write(recording, name: "../evil", in: folder) }
    }

    @Test("A truncated or foreign file is rejected when read, not misread")
    func fileReaderRefusals() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("roomcapture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let junk = folder.appendingPathComponent("junk.wav")
        try Data("not a wav file at all, really".utf8).write(to: junk)
        #expect(throws: RoomCaptureError.unreadableFile) { try RoomRecordingFile.read(junk) }
    }
}
