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
import CoreMedia

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

/// Where `SystemBedDecoder` gets the decoded bed from: an `AVAssetReader` in the app, a fake in tests.
protocol BedReading: AnyObject {
    /// Begins reading; throws when it can't.
    func start() throws
    /// The next buffer, or nil at the end of the file. Throws when the reader fails.
    func next() throws -> BedBuffer?
    func cancel()
}

/// Reads a track's Dolby bed through an `AVAssetReader`, decoded to 48 kHz stereo float by the system.
final class AssetBedReader: BedReading {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

    init(asset: AVAsset, track: AVAssetTrack, origin: CMTime, seconds: TimeInterval) throws {
        reader = try AVAssetReader(asset: asset)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: SystemBedDecoder.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        reader.timeRange = CMTimeRange(start: CMTimeAdd(origin, CMTime(seconds: max(0, seconds), preferredTimescale: 48_000)),
                                       duration: .positiveInfinity)
        reader.add(output)
    }

    func start() throws {
        guard reader.startReading() else { throw reader.error ?? BedError.couldNotStart }
    }

    func next() throws -> BedBuffer? {
        guard let buffer = output.copyNextSampleBuffer() else {
            if reader.status == .failed { throw reader.error ?? BedError.readerFailed }
            // Only a completed reader has reached the end of the file; a nil from any other state is a stop to report.
            if reader.status != .completed { throw BedError.endedEarly(status: reader.status.rawValue) }
            return nil
        }
        let frames = CMSampleBufferGetNumSamples(buffer)
        guard frames > 0 else { return BedBuffer(frames: 0) { _, _, _ in true } }
        guard let block = CMSampleBufferGetDataBuffer(buffer), CMBlockBufferGetDataLength(block) >= frames * 8 else {
            throw BedError.noData(frames: frames)
        }
        return BedBuffer(frames: frames) { first, count, destination in
            CMBlockBufferCopyDataBytes(block, atOffset: first * 8, dataLength: count * 8, destination: destination) == kCMBlockBufferNoErr
        }
    }

    func cancel() { reader.cancelReading() }
}

enum BedError: Error, CustomStringConvertible {
    case couldNotStart, readerFailed, noData(frames: Int), copyFailed(atFrame: Int64), endedEarly(status: Int)

    var description: String {
        switch self {
        case .endedEarly(let status): "the bed reader stopped without finishing (AVAssetReader status \(status))"
        case .couldNotStart: "the bed reader could not start"
        case .readerFailed: "the bed reader failed"
        case .noData(let frames): "a bed buffer of \(frames) frames has no data"
        case .copyFailed(let frame): "copying the bed at frame \(frame) failed"
        }
    }
}

/// Decodes a Dolby track to a stereo downmix of its bed into a `SystemBedTap`, a little ahead of the playhead, from a
/// second reader of its own: the renderer takes the compressed frames untouched. Runs only between `start` and `stop`.
final class SystemBedDecoder: @unchecked Sendable {
    static let sampleRate = 48_000.0
    /// How far ahead of the playhead it decodes, in seconds.
    static let lookahead = 1.0
    /// Frames copied into the tap at a time; a bigger buffer from the reader is stored in several pieces.
    static let chunkFrames = 1 << 14

    /// Makes the reader for a start at `seconds` into the file.
    private let makeReader: (TimeInterval) throws -> BedReading
    let tap: SystemBedTap
    private let queue = DispatchQueue(label: "org.szeremeta.vespertine.atmos-bed", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    private var failure: Error?

    init(asset: AVAsset, track: AVAssetTrack, origin: CMTime) {
        makeReader = { try AssetBedReader(asset: asset, track: track, origin: origin, seconds: $0) }
        tap = SystemBedTap(sampleRate: Self.sampleRate)
    }

    /// For tests: decodes from `makeReader` instead of an asset.
    init(makeReader: @escaping (TimeInterval) throws -> BedReading) {
        self.makeReader = makeReader
        tap = SystemBedTap(sampleRate: Self.sampleRate)
    }

    deinit { stop() }

    /// Why the last run ended before the end of the file (a reader failure or missing data); nil otherwise.
    var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }

    /// Decodes from `seconds` into the file (the renderer's own time base) on; `playhead` says how far playback has got.
    func start(at seconds: TimeInterval, playhead: @escaping @Sendable () -> TimeInterval) {
        lock.lock()
        generation += 1
        let gen = generation
        failure = nil
        lock.unlock()
        let firstFrame = Int64((max(0, seconds) * Self.sampleRate).rounded())
        tap.reset(at: firstFrame)
        queue.async { [self] in
            var next = firstFrame
            let reader: BedReading
            do {
                reader = try makeReader(seconds)
                try reader.start()
            } catch {
                fail(gen, error, at: next)
                return
            }
            defer { reader.cancel() }
            var scratch = [Float](repeating: 0, count: 2 * Self.chunkFrames)
            while isCurrent(gen) {
                let buffer: BedBuffer
                do {
                    guard let read = try reader.next() else { return }   // the end of the file
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
    }

    /// Records why a run ended before the end of the file (unless it was stopped or replaced meanwhile, which isn't a failure).
    private func fail(_ gen: Int, _ error: Error, at frame: Int64) {
        lock.lock()
        let current = gen == generation
        if current { failure = error }
        lock.unlock()
        guard current else { return }
        log.error("Atmos bed decoder stopped at frame \(frame, privacy: .public): \(String(describing: error), privacy: .public)")
    }

    func stop() {
        lock.lock(); generation += 1; lock.unlock()
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen == generation
    }
}
