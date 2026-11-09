//
// Vespertine: a rig for the engine's play/pause state machine: the real engine thread, a simulated output that counts what is
// audible, and a share whose speed and silence the test controls.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
@testable import VespertineAudio

/// A share that delivers `bytesPerSecond` on average, and can be stalled or go quiet from an offset.
final class ControlledShare: PlaybackCacheReader, @unchecked Sendable {
    let bytes: Data
    var bytesPerSecond: Double
    private let gate = NSCondition()
    private var stalled = false
    private var silentFrom: Int64?
    private var delivered = 0.0
    private var started: Date?
    private var blocked = 0
    var size: Int64 { Int64(bytes.count) }
    init(data: Data, bytesPerSecond: Double) { bytes = data; self.bytesPerSecond = bytesPerSecond }
    func read(at offset: Int64, count: Int) throws -> Data {
        gate.lock()
        while stalled || silentFrom.map({ offset >= $0 }) == true { blocked += 1; gate.wait(); blocked -= 1 }
        let start = started ?? Date()
        started = start
        delivered += Double(min(count, bytes.count - Int(offset)))
        let due = start.addingTimeInterval(delivered / bytesPerSecond)
        gate.unlock()
        let wait = due.timeIntervalSinceNow
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        return bytes.subdata(in: Int(offset)..<min(Int(offset) + count, bytes.count))
    }
    /// How many reads are held up right now by a stall or by silence: the share is being waited on, whatever the machine's speed.
    var readsWaiting: Int { gate.lock(); defer { gate.unlock() }; return blocked }
    func stall(_ value: Bool) { gate.lock(); stalled = value; gate.broadcast(); gate.unlock() }
    func goQuiet(from offset: Int64?) { gate.lock(); silentFrom = offset; gate.broadcast(); gate.unlock() }
}

/// What the engine says and what comes out, over a stretch of time.
struct Observation: CustomStringConvertible {
    var state: PlaybackState
    var buffering: Bool
    var fraction: Double?
    /// Seconds of song the playhead moved, and of sound that came out, over the window.
    var positionMoved: Double
    var audibleSeconds: Double
    var window: Double
    var audible: Bool { audibleSeconds > window * 0.5 }
    var moving: Bool { positionMoved > window * 0.5 }
    var description: String {
        String(format: "%@ buffering=%@ %@ playhead moved %.2fs, audible %.2fs of %.2fs", "\(state)", "\(buffering)",
               fraction.map { String(format: "(%.0f%%)", $0 * 100) } ?? "", positionMoved, audibleSeconds, window)
    }
}

final class PlayPauseRig: @unchecked Sendable {
    static let rate = 96_000.0
    let directory: URL
    let share: ControlledShare
    /// The song after it, on a share of its own.
    let nextShare: ControlledShare
    let cache: NetworkPlaybackCache
    let engine: PlaybackEngine
    let device: OutputDevice
    let outputs = Locked<[SimulatedOutput]>([])
    /// How long opening an output takes (a speaker group's aggregate does take a while), and how many are being opened or were.
    let openDelay = Locked<TimeInterval>(0)
    let opens = Locked(0)
    /// While set, an output opened from now on stands still (see `SimulatedOutput.held`); `holdOutput` changes the ones open too.
    private let holding = Locked(false)
    let t0 = Date()

    /// Noise as a 24-bit stereo WAV: big enough to start on a prefix (`NetworkStart`), `seconds` long.
    static func writeWAV(_ url: URL, rate: Double = PlayPauseRig.rate, seconds: Int) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
        var state: UInt32 = 777
        for _ in 0..<(Int(rate) * seconds / 48_000) {
            buffer.frameLength = 48_000
            for channel in 0..<2 {
                for frame in 0..<48_000 {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    buffer.floatChannelData![channel][frame] = Float(Int32(bitPattern: state) >> 8) / 8_388_608 * 0.5
                }
            }
            try file.write(from: buffer)
        }
    }

    /// The song's file type on the share: "wav", or "flac" (made from the same noise).
    let fileExtension: String

    /// The WAV at `wav` encoded as a 24-bit FLAC beside it.
    static func writeFLAC(from wav: URL) throws -> URL {
        let source = try AVAudioFile(forReading: wav)
        let url = wav.deletingPathExtension().appendingPathExtension("flac")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: source.fileFormat.sampleRate,
                                       AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 24]
        let out = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 96_000)!
        while source.framePosition < source.length {
            try source.read(into: buffer)
            try out.write(from: buffer)
        }
        return url
    }

    init(seconds: Int = 24, bytesPerSecond: Double = 50 * 1_048_576, nextBytesPerSecond: Double = 50 * 1_048_576,
         fileExtension: String = "wav") throws {
        self.fileExtension = fileExtension
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("playpause-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appendingPathComponent("song.wav")
        try Self.writeWAV(url, seconds: seconds)
        if fileExtension == "flac" { url = try Self.writeFLAC(from: url) }
        share = ControlledShare(data: try Data(contentsOf: url), bytesPerSecond: bytesPerSecond)
        cache = NetworkPlaybackCache(directory: directory.appendingPathComponent("cache"), budget: 256 << 20, chunk: 1 << 16)
        let share = share
        nextShare = ControlledShare(data: share.bytes, bytesPerSecond: nextBytesPerSecond)
        let nextShare = nextShare
        cache.readerFactory = { url in url.lastPathComponent == "next.wav" ? nextShare : share }
        device = OutputDevice(id: 4242, uid: "sim-out", name: "Simulated output", manufacturer: "", modelUID: nil, transport: .usb,
                              nominalSampleRate: Self.rate,
                              capabilities: DeviceCapabilities(sampleRates: [44_100, 48_000, 96_000], physicalFormats: [], outputChannels: 2, supportsDoP: false),
                              hasHardwareVolume: false, isDefault: false)
        engine = PlaybackEngine()
        engine.cacheOverride = cache
        let device = device
        engine.outputListing = { [device] }
        let outputs = outputs, openDelay = openDelay, opens = opens, holding = holding
        engine.sessionFactory = { _, plan in
            opens.withLock { $0 += 1 }
            let delay = openDelay.withLock { $0 }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let session = try OutputSession(simulating: plan, rate: plan.deviceSampleRate)
            outputs.withLock { $0.append(session.simulated!) }
            session.simulated!.held = holding.withLock { $0 }
            return session
        }
        var settings = EngineSettings()
        settings.deviceUID = device.uid
        settings.exclusive = true
        engine.update(settings: settings)
    }

    deinit {
        engine.stopAndWait()
        try? FileManager.default.removeItem(at: directory)
    }

    func nextItem() -> PlayableItem { PlayableItem(url: URL(fileURLWithPath: "/share/next.wav"), cacheKey: "next") }
    func item() -> PlayableItem { PlayableItem(url: URL(fileURLWithPath: "/share/song.\(fileExtension)"), cacheKey: "song") }

    /// Stops the output's clock (nothing plays or is consumed) or starts it again: a test sets its scene while the song stands at its start,
    /// so how fast the machine runs cannot change how much of the song is left to play when the scene is ready.
    func holdOutput(_ hold: Bool) {
        holding.withLock { $0 = hold }
        outputs.withLock { $0.forEach { $0.held = hold } }
    }

    var audibleFrames: Int { outputs.withLock { $0.reduce(0) { $0 + $1.audible } } }
    var elapsed: String { String(format: "%5.2f", Date().timeIntervalSince(t0)) }

    /// Watches for `seconds`: the engine's snapshot at the end, and how far the playhead and the sound went.
    /// The waits here are `Task.sleep`, never `Thread.sleep`: this suite runs for minutes, and a test that sleeps on a thread holds one
    /// of the few Swift concurrency threads (one per core) all that time, which on a small CI machine starves every other test.
    func observe(_ seconds: Double) async -> Observation {
        let p0 = engine.snapshot.position, a0 = audibleFrames, began = Date()
        try? await Task.sleep(for: .seconds(seconds))
        let s = engine.snapshot
        let seconds = Date().timeIntervalSince(began)
        return Observation(state: s.state, buffering: s.isBuffering, fraction: s.bufferingFraction, positionMoved: s.position - p0,
                           audibleSeconds: Double(audibleFrames - a0) / Self.rate, window: seconds)
    }

    /// Waits until `condition` holds of the snapshot (false on timeout).
    func wait(timeout: Double = 10, _ condition: (EngineSnapshot) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition(engine.snapshot) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func sleep(ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
}
