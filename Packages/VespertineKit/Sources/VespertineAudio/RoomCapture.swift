//
// Vespertine — room measurement capture: the reference, sweep, reference stimulus, a recording session with
// permission and failure handling, and the raw recording file. The hardware sits behind `RoomCaptureDevice`.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation

public enum RoomCaptureError: Error, Equatable, LocalizedError {
    case invalidLayout
    case invalidRequest
    case permissionDenied
    case permissionRestricted
    case busy
    case cancelled
    case startFailed(String)
    case deviceUnplugged
    case framesLost(Int)
    case stalled
    case fileExists
    case invalidFileName
    case unreadableFile

    public var errorDescription: String? {
        switch self {
        case .invalidLayout: String(localized: "The measurement layout needs a sample rate, a sweep of at least a second and a gap of at least 0.3 s around the sweep.")
        case .invalidRequest: String(localized: "The measurement needs an input device, an output device and channel numbers that are not negative.")
        case .permissionDenied: String(localized: "Microphone access is off for Vespertine. Turn it on in System Settings, Privacy & Security, Microphone.")
        case .permissionRestricted: String(localized: "Microphone access is restricted on this Mac.")
        case .busy: String(localized: "A measurement is already running.")
        case .cancelled: String(localized: "The measurement was cancelled.")
        case .startFailed(let why): String(localized: "The measurement could not start: \(why)")
        case .deviceUnplugged: String(localized: "The microphone or the output device went away during the measurement.")
        case .framesLost(let n): String(localized: "The recording lost \(n) frames, so it can't be used.")
        case .stalled: String(localized: "The microphone stopped delivering audio.")
        case .fileExists: String(localized: "A recording with that name already exists.")
        case .invalidFileName: String(localized: "The recording name may only use letters, digits, dots, dashes and underscores.")
        case .unreadableFile: String(localized: "The recording file is not a readable measurement recording.")
        }
    }
}

// MARK: - Layout

/// What is played and recorded: a lead-in, a timing reference, a gap, the sweep, a gap, a second timing reference,
/// then silence for the room to decay. The recording runs a little past the end of playback.
///
/// The lead-in is long because an output may stay silent for a while after its stream starts: a USB DAC (a Fosi Audio
/// ZD3 on the first real run) dropped the first reference at 0.2 s on every capture and was audible by 0.92 s at the
/// latest. It carries a faint noise (`wakeLevel`, far below the room's noise at the microphone) so a DAC that stays
/// muted on digital silence is woken too, and ends in a short silence before the reference.
public struct RoomCaptureLayout: Equatable, Sendable {
    public let sampleRate: Double
    public let sweep: LogSweep
    public let reference: TimingReference
    /// Linear peak level of the played signal (the sweep and the references are all scaled by it).
    public let level: Double
    public let firstReferenceStart: Int
    public let sweepStart: Int
    public let secondReferenceStart: Int
    /// Frames played, and frames recorded (playback plus the input's own latency and any late start).
    public let totalFrames: Int
    public let recordingFrames: Int

    public static let minimumGapSeconds = 0.3
    public static let minimumSweepSeconds = 1.0
    public static let defaultLeadInSeconds = 1.5
    /// Peak of the lead-in's wake noise (-80 dBFS), independent of `level`.
    public static let wakeLevel = 1e-4
    /// Silence between the end of the wake noise and the first reference.
    static let wakeQuietSeconds = 0.1

    public init(sampleRate: Double, sweepDuration: Double, startHz: Double = 20, endHz: Double = 20_000, fadeSeconds: Double = 0.1,
                gap: Double = 0.5, leadIn: Double = defaultLeadInSeconds, tail: Double = 0.6, slack: Double = 0.25, level: Double = 0.25) throws {
        guard sampleRate > 0, sweepDuration >= Self.minimumSweepSeconds, gap >= Self.minimumGapSeconds, leadIn >= 0, tail >= 0,
              slack >= 0, level > 0, level <= 1 else { throw RoomCaptureError.invalidLayout }
        let sweep: LogSweep, reference: TimingReference
        do {
            sweep = try LogSweep(sampleRate: sampleRate, startHz: startHz, endHz: endHz, duration: sweepDuration, fadeSeconds: fadeSeconds)
            reference = try TimingReference(sampleRate: sampleRate)
        } catch { throw RoomCaptureError.invalidLayout }
        func frames(_ s: Double) -> Int { Int((s * sampleRate).rounded()) }
        self.sampleRate = sampleRate
        self.sweep = sweep
        self.reference = reference
        self.level = level
        firstReferenceStart = frames(leadIn)
        sweepStart = firstReferenceStart + reference.samples.count + frames(gap)
        secondReferenceStart = sweepStart + sweep.samples.count + frames(gap)
        totalFrames = secondReferenceStart + reference.samples.count + frames(tail)
        recordingFrames = totalFrames + frames(slack)
        // The estimator wants one reference in each half of the recording.
        guard firstReferenceStart + reference.samples.count < recordingFrames / 2, secondReferenceStart > recordingFrames / 2 else {
            throw RoomCaptureError.invalidLayout
        }
    }

    /// The reference is fixed by the rate, so the rest identifies the layout.
    public static func == (a: Self, b: Self) -> Bool {
        a.sampleRate == b.sampleRate && a.sweep == b.sweep && a.level == b.level && a.firstReferenceStart == b.firstReferenceStart
            && a.sweepStart == b.sweepStart && a.secondReferenceStart == b.secondReferenceStart && a.totalFrames == b.totalFrames
            && a.recordingFrames == b.recordingFrames
    }

    /// Output samples between the two references' starts, and from the first reference to the sweep (what
    /// `ClockDriftEstimate` takes).
    public var nominalSpacing: Int { secondReferenceStart - firstReferenceStart }
    public var sweepOffset: Int { sweepStart - firstReferenceStart }

    /// Frames of wake noise at the start of the lead-in.
    public var wakeFrames: Int { max(0, firstReferenceStart - Int((Self.wakeQuietSeconds * sampleRate).rounded())) }

    /// The mono signal to play: the wake noise, both timing references and the sweep, all from one speaker.
    public func stimulus() -> [Float] {
        var out = referenceStimulus()
        for (n, v) in sweep.samples.enumerated() { out[sweepStart + n] += Float(v * level) }
        return out
    }

    /// The sweep alone, silent elsewhere.
    public func sweepStimulus() -> [Float] {
        var out = [Float](repeating: 0, count: totalFrames)
        for (n, v) in sweep.samples.enumerated() { out[sweepStart + n] = Float(v * level) }
        return out
    }

    /// The wake noise and both timing references, without the sweep: what a reference speaker plays while another
    /// one plays the sweep, so every speaker's arrival is timed against the same speaker.
    public func referenceStimulus() -> [Float] {
        var out = [Float](repeating: 0, count: totalFrames)
        // Deterministic, so a capture can be replayed exactly.
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        for n in 0..<wakeFrames {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            out[n] = Float((Double(seed >> 11) / Double(1 << 53) * 2 - 1) * Self.wakeLevel)
        }
        let scale = level
        for (n, v) in reference.samples.enumerated() {
            out[firstReferenceStart + n] += Float(v * scale)
            out[secondReferenceStart + n] += Float(v * scale)
        }
        return out
    }
}

/// What the output plays during one capture: one track per output channel used, all the same length.
public struct RoomStimulus: Equatable, Sendable {
    public struct Track: Equatable, Sendable {
        public let channel: Int
        public let samples: [Float]
        public init(channel: Int, samples: [Float]) {
            self.channel = channel
            self.samples = samples
        }
    }

    public let tracks: [Track]

    public init(tracks: [Track]) { self.tracks = tracks }

    /// Every track summed: what plays in all, whichever speaker it comes from.
    public var mixed: [Float] {
        guard var out = tracks.first?.samples else { return [] }
        for track in tracks.dropFirst() {
            for (n, v) in track.samples.enumerated() where n < out.count { out[n] += v }
        }
        return out
    }
}

/// The recording after the clock mismatch between input and output is taken out.
public struct RoomCaptureAnalysis: Sendable {
    public let drift: ClockDriftEstimate
    /// Starts `leadSamples` before where the sweep would arrive from the speaker that played the timing references,
    /// on the output's time axis, long enough for the sweep and its decay. The lead keeps the sweep whole when it
    /// comes from a nearer speaker than the references.
    public let sweepSegment: [Double]
    public let leadSamples: Int

    /// How far the lead reaches: 20 ms, about 7 m of path difference.
    public static let leadSeconds = 0.02
}

// MARK: - Device and permission

public struct RoomCaptureRequest: Equatable, Sendable {
    /// Explicit Core Audio device IDs: the measurement never follows the system default.
    public let inputDevice: UInt32
    public let outputDevice: UInt32
    /// Zero-based channel of the input to record and of the output to play on.
    public let inputChannel: Int
    public let outputChannel: Int
    /// The output channel that plays the timing references, when it isn't `outputChannel`: every speaker is then
    /// timed against the same one, so the differences in their arrival survive the jitter in when a capture starts.
    public let referenceChannel: Int?
    public let layout: RoomCaptureLayout

    public init(inputDevice: UInt32, outputDevice: UInt32, inputChannel: Int, outputChannel: Int, referenceChannel: Int? = nil,
                layout: RoomCaptureLayout) {
        self.inputDevice = inputDevice
        self.outputDevice = outputDevice
        self.inputChannel = inputChannel
        self.outputChannel = outputChannel
        self.referenceChannel = referenceChannel == outputChannel ? nil : referenceChannel
        self.layout = layout
    }

    /// What plays: everything on the output channel, or the references on the reference channel and the sweep on the
    /// output channel.
    public func stimulus() -> RoomStimulus {
        guard let referenceChannel else { return RoomStimulus(tracks: [.init(channel: outputChannel, samples: layout.stimulus())]) }
        return RoomStimulus(tracks: [.init(channel: referenceChannel, samples: layout.referenceStimulus()),
                                     .init(channel: outputChannel, samples: layout.sweepStimulus())])
    }
}

/// What the input has delivered since the last read.
public struct RoomCaptureChunk: Sendable {
    public var frames: [Float]
    /// Frames the input dropped (a ring overflow or a jump in its clock) since the last read.
    public var lostFrames: Int
    /// False once the input or the output device is gone.
    public var alive: Bool

    public init(frames: [Float], lostFrames: Int, alive: Bool) {
        self.frames = frames
        self.lostFrames = lostFrames
        self.alive = alive
    }
}

public protocol RoomCaptureDevice: AnyObject, Sendable {
    /// Starts recording the input channel and playing each of `stimulus`'s tracks (at the layout's rate) on its output
    /// channel, all from the same frame.
    func start(request: RoomCaptureRequest, stimulus: RoomStimulus) throws
    /// Up to `maxFrames` frames of the recorded channel, without waiting.
    func readAvailable(maxFrames: Int) -> RoomCaptureChunk
    /// Stops both directions and releases them. Safe to call again.
    func stop()
}

public enum MicrophoneAccess: Sendable, Equatable { case notDetermined, granted, denied, restricted }

public protocol MicrophonePermission: Sendable {
    var status: MicrophoneAccess { get }
    /// Shows the system prompt when the question hasn't been answered. True when access is granted.
    func request() async -> Bool
}

// MARK: - Bounded storage

/// Fixed-capacity frame store: whatever would not fit is counted, never stored.
public struct BoundedFrameBuffer: Sendable {
    public let capacity: Int
    public private(set) var frames: [Float] = []
    public private(set) var refused = 0

    public init(capacity: Int) {
        self.capacity = max(0, capacity)
        frames.reserveCapacity(self.capacity)
    }

    public var remaining: Int { capacity - frames.count }
    public var isFull: Bool { frames.count >= capacity }

    /// Number of frames stored.
    @discardableResult
    public mutating func append(_ more: [Float]) -> Int {
        let take = min(more.count, remaining)
        frames.append(contentsOf: more.prefix(take))
        refused += more.count - take
        return take
    }
}

// MARK: - Recording

public struct RoomRecording: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public let request: RoomCaptureRequest
    public let startedAt: Date
    /// Frames the device delivered beyond the planned length (not stored).
    public let surplusFrames: Int

    public var inputDevice: UInt32 { request.inputDevice }
    public var outputDevice: UInt32 { request.outputDevice }

    /// Locates both references, estimates the clock mismatch, and cuts the sweep out on the output's time axis.
    public func analyse() throws -> RoomCaptureAnalysis {
        let layout = request.layout
        let recording = samples.map(Double.init)
        let drift = try ClockDriftEstimate.estimate(recording: recording, reference: layout.reference, nominalSpacing: layout.nominalSpacing)
        let lead = Int((RoomCaptureAnalysis.leadSeconds * layout.sampleRate).rounded())
        let start = drift.position(afterFirst: layout.sweepOffset - lead)
        let count = layout.sweep.samples.count + Int(0.5 * layout.sampleRate) + lead
        return RoomCaptureAnalysis(drift: drift, sweepSegment: drift.resampled(recording, from: start, count: count), leadSamples: lead)
    }
}

// MARK: - Session

/// One measurement at a time: permission, start, a bounded recording, and back to idle whatever happens.
public final class RoomCaptureSession: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case requestingPermission
        case recording(captured: Int, of: Int)
    }

    private let device: RoomCaptureDevice
    private let permission: MicrophonePermission
    private let pollInterval: Double
    private let stallTimeout: Double
    private let now: @Sendable () -> Date
    private let guarded = Locked<(state: State, cancelled: Bool)>((.idle, false))

    /// `stallTimeout` is how long the input may deliver nothing before the capture is given up.
    public init(device: RoomCaptureDevice, permission: MicrophonePermission, pollInterval: Double = 0.02,
                stallTimeout: Double = 3, now: @escaping @Sendable () -> Date = { Date() }) {
        self.device = device
        self.permission = permission
        self.pollInterval = pollInterval
        self.stallTimeout = stallTimeout
        self.now = now
    }

    public var state: State { guarded.withLock { $0.state } }

    public func cancel() { guarded.withLock { if $0.state != .idle { $0.cancelled = true } } }

    private var isCancelled: Bool { guarded.withLock { $0.cancelled } || Task.isCancelled }
    private func set(_ state: State) { guarded.withLock { $0.state = state } }

    public func record(_ request: RoomCaptureRequest) async throws -> RoomRecording {
        let claimed = guarded.withLock { g -> Bool in
            guard g.state == .idle else { return false }
            g = (.requestingPermission, false)
            return true
        }
        guard claimed else { throw RoomCaptureError.busy }
        defer { guarded.withLock { $0 = (.idle, false) } }

        guard request.inputDevice != 0, request.outputDevice != 0, request.inputChannel >= 0, request.outputChannel >= 0,
              (request.referenceChannel ?? 0) >= 0 else {
            throw RoomCaptureError.invalidRequest
        }
        switch permission.status {
        case .granted: break
        case .denied: throw RoomCaptureError.permissionDenied
        case .restricted: throw RoomCaptureError.permissionRestricted
        case .notDetermined:
            guard await permission.request() else { throw RoomCaptureError.permissionDenied }
        }
        if isCancelled { throw RoomCaptureError.cancelled }

        let layout = request.layout
        let planned = layout.recordingFrames
        let startedAt = now()
        do {
            try device.start(request: request, stimulus: request.stimulus())
        } catch {
            device.stop()
            throw RoomCaptureError.startFailed((error as? CoreAudioError)?.description ?? error.localizedDescription)
        }
        defer { device.stop() }

        var buffer = BoundedFrameBuffer(capacity: planned)
        let clock = ContinuousClock()
        var lastFrames = clock.now
        while !buffer.isFull {
            if isCancelled { throw RoomCaptureError.cancelled }
            let chunk = device.readAvailable(maxFrames: buffer.remaining)
            guard chunk.alive else { throw RoomCaptureError.deviceUnplugged }
            guard chunk.lostFrames == 0 else { throw RoomCaptureError.framesLost(chunk.lostFrames) }
            if chunk.frames.isEmpty {
                if clock.now - lastFrames > .seconds(stallTimeout) { throw RoomCaptureError.stalled }
            } else {
                buffer.append(chunk.frames)
                lastFrames = clock.now
                set(.recording(captured: buffer.frames.count, of: planned))
            }
            if !buffer.isFull {
                do { try await Task.sleep(for: .seconds(pollInterval)) } catch { throw RoomCaptureError.cancelled }
            }
        }
        return RoomRecording(samples: buffer.frames, sampleRate: layout.sampleRate, request: request, startedAt: startedAt,
                             surplusFrames: buffer.refused)
    }
}

// MARK: - File

/// Sidecar for a raw recording: when and how it was made.
public struct RoomRecordingInfo: Codable, Equatable, Sendable {
    public var file: String
    public var sha256: String
    public var startedAt: Date
    public var sampleRate: Double
    public var frames: Int
    public var durationSeconds: Double
    public var inputDevice: UInt32
    public var outputDevice: UInt32
    public var inputChannel: Int
    public var outputChannel: Int
    /// The output channel that played the timing references, when it wasn't `outputChannel`.
    public var referenceChannel: Int?
    /// The `ClockDriftEstimate` inputs for this layout, in output samples.
    public var nominalSpacing: Int
    public var sweepOffset: Int
}

/// The raw recording as a 32-bit float mono WAVE file (format tag 3) next to a JSON sidecar.
public enum RoomRecordingFile {
    public struct Written: Equatable, Sendable {
        public let url: URL
        public let infoURL: URL
        public let sha256: String
    }

    public static func write(_ recording: RoomRecording, name: String, in folder: URL) throws -> Written {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !name.isEmpty, !name.hasPrefix("."), name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw RoomCaptureError.invalidFileName
        }
        let url = folder.appendingPathComponent(name + ".wav"), infoURL = folder.appendingPathComponent(name + ".json")
        guard !FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: infoURL.path) else {
            throw RoomCaptureError.fileExists
        }
        let data = encode(recording.samples, sampleRate: recording.sampleRate)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let layout = recording.request.layout
        let info = RoomRecordingInfo(
            file: url.lastPathComponent, sha256: digest, startedAt: recording.startedAt, sampleRate: recording.sampleRate,
            frames: recording.samples.count, durationSeconds: Double(recording.samples.count) / recording.sampleRate,
            inputDevice: recording.inputDevice, outputDevice: recording.outputDevice, inputChannel: recording.request.inputChannel,
            outputChannel: recording.request.outputChannel, referenceChannel: recording.request.referenceChannel,
            nominalSpacing: layout.nominalSpacing, sweepOffset: layout.sweepOffset)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try data.write(to: url, options: .withoutOverwriting)
        try encoder.encode(info).write(to: infoURL, options: .withoutOverwriting)
        return Written(url: url, infoURL: infoURL, sha256: digest)
    }

    public static func readInfo(_ url: URL) throws -> RoomRecordingInfo {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let info = try? decoder.decode(RoomRecordingInfo.self, from: data) else {
            throw RoomCaptureError.unreadableFile
        }
        return info
    }

    public static func read(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
        guard let data = try? Data(contentsOf: url) else { throw RoomCaptureError.unreadableFile }
        return try decode(data)
    }

    static func encode(_ samples: [Float], sampleRate: Double) -> Data {
        var data = Data()
        func tag(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        let payload = samples.count * 4
        tag("RIFF"); u32(4 + (8 + 18) + (8 + 4) + (8 + payload) + (payload % 2)); tag("WAVE")
        tag("fmt "); u32(18); u16(3); u16(1); u32(Int(sampleRate.rounded())); u32(Int(sampleRate.rounded()) * 4); u16(4); u16(32); u16(0)
        tag("fact"); u32(4); u32(samples.count)
        tag("data"); u32(payload)
        data.reserveCapacity(data.count + payload)
        for s in samples { withUnsafeBytes(of: s.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    static func decode(_ data: Data) throws -> (samples: [Float], sampleRate: Double) {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        func isTag(_ at: Int, _ s: String) -> Bool { at + 4 <= bytes.count && Array(bytes[at..<at + 4]) == Array(s.utf8) }
        guard bytes.count >= 12, isTag(0, "RIFF"), isTag(8, "WAVE") else { throw RoomCaptureError.unreadableFile }
        var at = 12
        var rate: Double?
        while at + 8 <= bytes.count {
            let size = u32(at + 4), body = at + 8
            guard body + size <= bytes.count else { throw RoomCaptureError.unreadableFile }
            if isTag(at, "fmt ") {
                guard size >= 16, u16(body) == 3, u16(body + 2) == 1, u16(body + 14) == 32 else { throw RoomCaptureError.unreadableFile }
                rate = Double(u32(body + 4))
            } else if isTag(at, "data") {
                guard let rate, size % 4 == 0 else { throw RoomCaptureError.unreadableFile }
                let samples = (0..<size / 4).map { Float(bitPattern: UInt32(truncatingIfNeeded: u32(body + $0 * 4))) }
                return (samples, rate)
            }
            at = body + size + (size % 2)
        }
        throw RoomCaptureError.unreadableFile
    }
}
