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

/// Decodes a Dolby track to a stereo downmix of its bed into a `SystemBedTap`, a little ahead of the playhead, from a
/// second reader of its own: the renderer takes the compressed frames untouched. Runs only between `start` and `stop`.
final class SystemBedDecoder: @unchecked Sendable {
    static let sampleRate = 48_000.0
    /// How far ahead of the playhead it decodes, in seconds.
    static let lookahead = 1.0

    private let asset: AVAsset
    private let track: AVAssetTrack
    private let origin: CMTime
    let tap: SystemBedTap
    private let queue = DispatchQueue(label: "org.szeremeta.vespertine.atmos-bed", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0

    init(asset: AVAsset, track: AVAssetTrack, origin: CMTime) {
        self.asset = asset
        self.track = track
        self.origin = origin
        tap = SystemBedTap(sampleRate: Self.sampleRate)
    }

    deinit { stop() }

    /// Decodes from `seconds` into the file (the renderer's own time base) on; `playhead` says how far playback has got.
    func start(at seconds: TimeInterval, playhead: @escaping @Sendable () -> TimeInterval) {
        lock.lock()
        generation += 1
        let gen = generation
        lock.unlock()
        let firstFrame = Int64((max(0, seconds) * Self.sampleRate).rounded())
        tap.reset(at: firstFrame)
        queue.async { [self] in
            guard let reader = try? AVAssetReader(asset: asset) else { return }
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.sampleRate,
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
            guard reader.startReading() else { return }
            defer { reader.cancelReading() }
            var next = firstFrame
            var scratch = [Float](repeating: 0, count: 1 << 15)
            while isCurrent(gen), let buffer = output.copyNextSampleBuffer() {
                // Wait for the playhead before decoding further than a second ahead.
                while isCurrent(gen), Double(next) / Self.sampleRate - playhead() > Self.lookahead {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                guard isCurrent(gen), let block = CMSampleBufferGetDataBuffer(buffer) else { return }
                let frames = CMSampleBufferGetNumSamples(buffer)
                let bytes = min(CMBlockBufferGetDataLength(block), scratch.count * MemoryLayout<Float>.size)
                guard frames > 0, frames * 2 <= scratch.count, bytes >= frames * 8 else { continue }
                _ = scratch.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * 8, destination: $0.baseAddress!) }
                scratch.withUnsafeBufferPointer { tap.append(interleaved: $0.baseAddress!, frames: frames, at: next) }
                next += Int64(frames)
            }
        }
    }

    func stop() {
        lock.lock(); generation += 1; lock.unlock()
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen == generation
    }
}
