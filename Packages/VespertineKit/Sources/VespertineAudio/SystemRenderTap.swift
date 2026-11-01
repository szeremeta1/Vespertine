//
// Vespertine — what the visualizer reads while macOS renders Dolby Atmos.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The visualizer's view of an Atmos track that macOS renders: Vespertine's own output isn't involved then, so the
/// samples come from here instead (`SystemBedTap`; tests use a fake).
protocol SystemRenderTap: AnyObject, Sendable {
    /// Switches the decoding behind the tap on or off (it runs only while a visualizer window is showing).
    func setTapping(_ on: Bool)
    /// Copies the newest `left.count` frames up to what is playing now (`PlaybackEngine.copyVisualizerTap`'s contract).
    func copy(left: inout [Float], right: inout [Float]) -> PlaybackEngine.VisualizerTapRead?
}

import AVFoundation

/// The stereo downmix of the decoded Dolby bed, kept for the last second or so, indexed by frame from the start of the
/// file. macOS renders Atmos in its own path and hands nothing back, so this is what the visualizer analyses: the
/// bed that macOS decodes for any app (its objects are mixed into the speaker layout of the rendered output, which
/// can't be observed). Frames are read at the renderer's playhead, so the picture follows what is playing.
final class SystemBedTap: @unchecked Sendable {
    let sampleRate: Double
    private let capacity: Int
    private let lock = NSLock()
    private var left: [Float]
    private var right: [Float]
    /// The frame after the newest one stored; nothing before `end - stored` is valid.
    private var end: Int64 = 0
    private var stored: Int64 = 0

    init(sampleRate: Double, capacity: Int = 1 << 17) {
        self.sampleRate = sampleRate
        self.capacity = capacity
        left = [Float](repeating: 0, count: capacity)
        right = left
    }

    /// Forgets everything (a seek, or the start of a track).
    func reset(at frame: Int64) {
        lock.lock(); defer { lock.unlock() }
        end = frame
        stored = 0
    }

    /// The frame after the newest stored.
    var endFrame: Int64 { lock.lock(); defer { lock.unlock() }; return end }

    /// Stores interleaved stereo `samples` (`frames` of them) starting at frame `at`. A start that doesn't continue the
    /// last one drops what was stored.
    func append(interleaved samples: UnsafePointer<Float>, frames: Int, at: Int64) {
        lock.lock(); defer { lock.unlock() }
        if at != end { stored = 0 }
        for i in 0..<frames {
            let slot = Int((at + Int64(i)) % Int64(capacity))
            left[slot] = samples[2 * i]
            right[slot] = samples[2 * i + 1]
        }
        end = at + Int64(frames)
        stored = min(Int64(capacity), stored + Int64(frames))
    }

    /// Fills `left` and `right` with the `left.count` frames before `playhead` (zeros where nothing was decoded), or
    /// returns nil when none of them were.
    func copy(left l: inout [Float], right r: inout [Float], playhead: Int64) -> PlaybackEngine.VisualizerTapRead? {
        lock.lock(); defer { lock.unlock() }
        let n = l.count
        let first = playhead - Int64(n)
        let validFrom = end - stored
        guard stored > 0, playhead > validFrom, first < end else { return nil }
        for i in 0..<n {
            let f = first + Int64(i)
            if f >= validFrom, f < end {
                let slot = Int(f % Int64(capacity))
                l[i] = left[slot]; r[i] = right[slot]
            } else {
                l[i] = 0; r[i] = 0
            }
        }
        return .init(frames: n, position: UInt64(max(0, playhead)), sampleRate: sampleRate, isDSD: false)
    }
}

/// One buffer of interleaved stereo float frames from a `BedReading`.
struct BedBuffer {
    var frames: Int
    /// Copies `count` frames starting at frame `first` of this buffer into `destination`; false when the data isn't there.
    var copy: (_ first: Int, _ count: Int, _ destination: UnsafeMutablePointer<Float>) -> Bool
}

/// Where `SystemBedDecoder` gets the decoded bed from: Audio Toolbox in the app, a fake in tests.
protocol BedReading: AnyObject {
    /// Begins reading; throws when it can't.
    func start() throws
    /// The next buffer, or nil at the end of the file. Throws when the reader fails.
    func next() throws -> BedBuffer?
    func cancel()
}

/// Reads a Dolby track's bed with Audio Toolbox's `ExtAudioFile`, which decodes on the calling thread, and folds it to
/// stereo as macOS does for any app (Lo/Ro: centre and surrounds at -3 dB, LFE left out).
///
/// Not `AVAssetReader`: its first buffer waits for a free thread of Swift's concurrency pool (as the async `load` does,
/// see `LoadedAudioTrack`). While the app or a test keeps every pool thread busy or blocked, the bed didn't start until
/// they freed up; on a 3-core CI machine running the suite, not within two minutes.
final class AudioFileBedReader: BedReading {
    static let framesPerRead = 8192
    private let file: ExtAudioFileRef
    private let channels: Int
    /// What each of the file's channels adds to the left and the right.
    private let gains: [(left: Float, right: Float)]
    private let firstFrame: Int64
    private var decoded: [Float]

    init(url: URL, seconds: TimeInterval) throws {
        var opened: ExtAudioFileRef?
        try Self.check(ExtAudioFileOpenURL(url as CFURL, &opened), "open")
        guard let opened else { throw BedError.audioToolbox(step: "open", status: kAudio_FileNotFoundError) }
        file = opened
        do {
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format), "format")
            channels = max(1, Int(format.mChannelsPerFrame))
            gains = Self.labels(of: file, channels: channels).map(Self.gains)
            var client = AudioStreamBasicDescription(
                mSampleRate: SystemBedDecoder.sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(4 * channels),
                mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
                mBitsPerChannel: 32, mReserved: 0)
            try Self.check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                                   UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client), "client format")
        } catch {
            ExtAudioFileDispose(file)
            throw error
        }
        firstFrame = Int64((max(0, seconds) * SystemBedDecoder.sampleRate).rounded())
        decoded = [Float](repeating: 0, count: Self.framesPerRead * channels)
    }

    deinit { ExtAudioFileDispose(file) }

    func start() throws { try Self.check(ExtAudioFileSeek(file, firstFrame), "seek") }

    func next() throws -> BedBuffer? {
        var frames = UInt32(Self.framesPerRead)
        let channels = channels
        let status = decoded.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return ExtAudioFileRead(file, &frames, &list)
        }
        try Self.check(status, "read")
        let n = Int(frames)
        guard n > 0 else { return nil }   // the end of the file
        var stereo = [Float](repeating: 0, count: 2 * n)
        for i in 0..<n {
            var l: Float = 0, r: Float = 0
            for c in 0..<channels {
                let x = decoded[i * channels + c]
                l += x * gains[c].left
                r += x * gains[c].right
            }
            stereo[2 * i] = l
            stereo[2 * i + 1] = r
        }
        return BedBuffer(frames: n) { first, count, destination in
            stereo.withUnsafeBufferPointer { destination.update(from: $0.baseAddress! + 2 * first, count: 2 * count) }
            return true
        }
    }

    func cancel() {}

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw BedError.audioToolbox(step: step, status: status) }
    }

    /// The speaker of each channel, as the file names it (L R when it doesn't say).
    private static func labels(of file: ExtAudioFileRef, channels: Int) -> [AudioChannelLabel] {
        var size: UInt32 = 0
        var labels: [AudioChannelLabel] = []
        if ExtAudioFileGetPropertyInfo(file, kExtAudioFileProperty_FileChannelLayout, &size, nil) == noErr,
           size >= UInt32(MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!) {
            let raw = UnsafeMutableRawPointer.allocate(byteCount: max(Int(size), MemoryLayout<AudioChannelLayout>.size),
                                                       alignment: MemoryLayout<AudioChannelLayout>.alignment)
            defer { raw.deallocate() }
            if ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileChannelLayout, &size, raw) == noErr {
                labels = AVAudioChannelLayout(layout: raw.assumingMemoryBound(to: AudioChannelLayout.self)).channelLabels
            }
        }
        if !labels.contains(where: AVAudioChannelLayout.isSpeaker) {
            labels = channels == 1 ? [kAudioChannelLabel_Mono] : [kAudioChannelLabel_Left, kAudioChannelLabel_Right]
        }
        return (0..<channels).map { $0 < labels.count ? labels[$0] : kAudioChannelLabel_Unused }
    }

    /// Lo/Ro: a speaker on the left goes to the left, at -3 dB unless it's the front left; centres go to both at -3 dB;
    /// the LFE and anything unnamed stay out.
    private static func gains(_ label: AudioChannelLabel) -> (left: Float, right: Float) {
        let h: Float = 0.70710677
        switch label {
        case kAudioChannelLabel_Left: return (1, 0)
        case kAudioChannelLabel_Right: return (0, 1)
        case kAudioChannelLabel_Mono: return (1, 1)
        case kAudioChannelLabel_Center, kAudioChannelLabel_CenterSurround, kAudioChannelLabel_VerticalHeightCenter,
             kAudioChannelLabel_TopCenterSurround, kAudioChannelLabel_TopBackCenter:
            return (h, h)
        case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RearSurroundLeft,
             kAudioChannelLabel_LeftWide, kAudioChannelLabel_LeftCenter, kAudioChannelLabel_VerticalHeightLeft,
             kAudioChannelLabel_TopBackLeft, kAudioChannelLabel_LeftTopMiddle, kAudioChannelLabel_LeftTopRear:
            return (h, 0)
        case kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightSurroundDirect, kAudioChannelLabel_RearSurroundRight,
             kAudioChannelLabel_RightWide, kAudioChannelLabel_RightCenter, kAudioChannelLabel_VerticalHeightRight,
             kAudioChannelLabel_TopBackRight, kAudioChannelLabel_RightTopMiddle, kAudioChannelLabel_RightTopRear:
            return (0, h)
        default: return (0, 0)
        }
    }
}

enum BedError: Error, CustomStringConvertible {
    case audioToolbox(step: String, status: OSStatus), copyFailed(atFrame: Int64), stalled(seconds: Double)

    var description: String {
        switch self {
        case .audioToolbox(let step, let status): "the bed reader's \(step) failed (Audio Toolbox error \(status))"
        case .copyFailed(let frame): "copying the bed at frame \(frame) failed"
        case .stalled(let seconds): "a bed read has not returned for \(String(format: "%.1f", seconds)) s"
        }
    }
}

/// Decodes a Dolby track to a stereo downmix of its bed into a `SystemBedTap`, a little ahead of the playhead, from a
/// second reader of its own: the renderer takes the compressed frames untouched. Runs only between `start` and `stop`.
///
/// Each run reads on a thread of its own, so a read that doesn't return holds up nothing else: a seek starts the new
/// position at once, and the stuck run ends, storing nothing, when its read returns. A read that takes longer than
/// `stallLimit` is recorded as a stall and the decoder starts over at the playhead, once per start.
final class SystemBedDecoder: @unchecked Sendable {
    static let sampleRate = 48_000.0
    /// How far ahead of the playhead it decodes, in seconds.
    static let lookahead = 1.0
    /// Frames copied into the tap at a time; a bigger buffer from the reader is stored in several pieces.
    static let chunkFrames = 1 << 14
    /// How long a read may take before it counts as stalled.
    static let stallLimit = 3.0

    /// Makes the reader for a start at `seconds` into the file.
    private let makeReader: (TimeInterval) throws -> BedReading
    let tap: SystemBedTap
    private let stallLimit: TimeInterval
    private let lock = NSLock()
    private var generation = 0
    private var failure: Error?
    /// The current run's playhead, for a restart.
    private var playhead: (@Sendable () -> TimeInterval)?
    /// When the current run's read (or its reader's opening) began, while one is under way.
    private var readingSince: Date?
    /// Whether the current run is already the restart after a stall.
    private var restarted = false

    /// Decodes the file at `url`.
    convenience init(url: URL) {
        self.init(makeReader: { try Self.reader(for: url, at: $0) })
    }

    /// For tests: decodes from `makeReader` instead of a file, with reads stalled after `stallLimit` seconds.
    init(makeReader: @escaping (TimeInterval) throws -> BedReading, stallLimit: TimeInterval = SystemBedDecoder.stallLimit) {
        self.makeReader = makeReader
        self.stallLimit = stallLimit
        tap = SystemBedTap(sampleRate: Self.sampleRate)
    }

    /// The reader for a start at `seconds` into the file at `url`.
    static func reader(for url: URL, at seconds: TimeInterval) throws -> BedReading {
        try AudioFileBedReader(url: url, seconds: seconds)
    }

    deinit { stop() }

    /// Why the last run ended before the end of the file (a reader failure or missing data) or stalled; nil otherwise.
    var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }

    /// Decodes from `seconds` into the file (the renderer's own time base) on; `playhead` says how far playback has got.
    func start(at seconds: TimeInterval, playhead: @escaping @Sendable () -> TimeInterval) {
        begin(at: seconds, playhead: playhead, replacing: nil)
    }

    /// Starts a run; as a restart (`replacing` the stalled run's generation) only while that run is still the current one.
    private func begin(at seconds: TimeInterval, playhead: @escaping @Sendable () -> TimeInterval, replacing stalled: Int?) {
        lock.lock()
        if let stalled, stalled != generation { lock.unlock(); return }
        generation += 1
        let gen = generation
        if stalled == nil { failure = nil }
        restarted = stalled != nil
        self.playhead = playhead
        readingSince = nil
        lock.unlock()
        let firstFrame = Int64((max(0, seconds) * Self.sampleRate).rounded())
        tap.reset(at: firstFrame)
        let thread = Thread { [self] in run(gen, at: seconds, from: firstFrame, playhead: playhead) }
        thread.name = "org.szeremeta.vespertine.atmos-bed"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func run(_ gen: Int, at seconds: TimeInterval, from firstFrame: Int64, playhead: @Sendable () -> TimeInterval) {
        var next = firstFrame
        let reader: BedReading
        reading(gen, true)
        do {
            reader = try makeReader(seconds)
            try reader.start()
        } catch {
            fail(gen, error, at: next)
            return
        }
        reading(gen, false)
        defer { reader.cancel() }
        var scratch = [Float](repeating: 0, count: 2 * Self.chunkFrames)
        while isCurrent(gen) {
            let buffer: BedBuffer
            reading(gen, true)
            do {
                let read = try reader.next()
                reading(gen, false)
                guard let read else { return }   // the end of the file
                buffer = read
            } catch {
                fail(gen, error, at: next)
                return
            }
            // Wait for the playhead before decoding further than a second ahead.
            while isCurrent(gen), Double(next) / Self.sampleRate - playhead() > Self.lookahead {
                Thread.sleep(forTimeInterval: 0.02)
            }
            guard isCurrent(gen) else { return }
            // Whatever the buffer's size, all of it is stored, a chunk at a time, so `next` follows the reader.
            var done = 0
            while done < buffer.frames {
                let count = min(Self.chunkFrames, buffer.frames - done)
                guard scratch.withUnsafeMutableBufferPointer({ buffer.copy(done, count, $0.baseAddress!) }) else {
                    fail(gen, BedError.copyFailed(atFrame: next), at: next)
                    return
                }
                scratch.withUnsafeBufferPointer { tap.append(interleaved: $0.baseAddress!, frames: count, at: next) }
                next += Int64(count)
                done += count
            }
        }
    }

    /// Starts over at the playhead when the current run's read has taken longer than `stallLimit`, recording the stall.
    /// Only once per start: a restart that stalls too is recorded and left to finish (or to the next start). Called
    /// whenever the visualizer reads the tap, so it costs a lock.
    func restartIfStalled() {
        lock.lock()
        guard let since = readingSince, let playhead, Date().timeIntervalSince(since) > stallLimit else { lock.unlock(); return }
        let waited = Date().timeIntervalSince(since)
        let gen = generation, retry = !restarted
        failure = BedError.stalled(seconds: waited)
        readingSince = nil   // reported once
        lock.unlock()
        log.error("Atmos bed decoder stalled: a read has not returned for \(waited, format: .fixed(precision: 1), privacy: .public) s; \(retry ? "starting over at the playhead" : "waiting for the next start", privacy: .public)")
        if retry { begin(at: playhead(), playhead: playhead, replacing: gen) }
    }

    /// Notes when the current run's read begins and ends.
    private func reading(_ gen: Int, _ busy: Bool) {
        lock.lock()
        if gen == generation { readingSince = busy ? Date() : nil }
        lock.unlock()
    }

    /// Records why a run ended before the end of the file (unless it was stopped or replaced meanwhile, which isn't a failure).
    private func fail(_ gen: Int, _ error: Error, at frame: Int64) {
        lock.lock()
        let current = gen == generation
        if current { failure = error; readingSince = nil }
        lock.unlock()
        guard current else { return }
        log.error("Atmos bed decoder stopped at frame \(frame, privacy: .public): \(String(describing: error), privacy: .public)")
    }

    func stop() {
        lock.lock(); generation += 1; readingSince = nil; lock.unlock()
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen == generation
    }
}
