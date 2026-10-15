//
// Vespertine — decodes a file read live from a network share ahead of playback, on a thread of its own.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import SFBAudioEngine

/// Decodes a file read live from a network share a few seconds ahead of the engine, on a thread of its own.
///
/// A read from a slow or busy share can take seconds (a NAS waking its disks, a weak Wi-Fi link, a scan or a copy
/// on the same connection). Decoding on the engine thread, that read held up everything else the engine does:
/// pause and skip took effect only when it returned, and the output had nothing new to play meanwhile. Here only
/// this thread waits on the share; the engine takes what's decoded and carries on.
///
/// `decode(into:length:)` never waits. It hands over what has been decoded, and throws `Starved` when nothing
/// has been yet (more is on its way, which isn't the end of the file). The output rebuffers meanwhile.
final class ReadAheadDecoder: NSObject, PCMDecoding, ConcealingDecoder {
    /// Nothing decoded yet, but more is on its way (not the end of the file).
    struct Starved: Error {}
    private struct NoBuffer: Error {}

    /// When audio last arrived from a share, for any track (a share that's slow to list a folder but still
    /// delivering music isn't dead).
    static var lastDelivery: Date { delivered.withLock { $0 } }
    private static let delivered = Locked(Date.distantPast)

    let inner: PCMDecoding
    private let format: AVAudioFormat
    private let shared: Shared
    /// Frames handed to the engine so far (where the next decode continues). Engine thread only.
    private(set) var position: AVAudioFramePosition
    /// DoP: the marker of the frame at `frame` (see `RawDoPDecoder.nextMarker`), so the marker for `position`
    /// is known while frames past it are already decoded.
    private var marker: (frame: AVAudioFramePosition, marker: AVAudioFramePosition)?

    let length: AVAudioFramePosition
    let supportsSeeking: Bool
    let decodingIsLossless: Bool
    let sourceFormat: AVAudioFormat
    let inputSource: InputSource
    let properties: [AudioDecodingPropertiesKey: Any]

    /// What the decoding thread and the engine share, under `condition`. The decoder itself is used by the
    /// decoding thread only, except while that's held (`withDecoderHeld`).
    private final class Shared: @unchecked Sendable {
        let inner: PCMDecoding
        let format: AVAudioFormat
        init(inner: PCMDecoding, format: AVAudioFormat) { self.inner = inner; self.format = format }
        let condition = NSCondition()
        var ready: [AVAudioPCMBuffer] = []
        var spare: [AVAudioPCMBuffer] = []
        /// Frames of `ready[0]` already handed over.
        var taken = 0
        /// Frames decoded and not handed over yet.
        var buffered = 0
        /// The decoder has no more (or failed with `error`).
        var ended = false
        var error: Error?
        /// Held while the decoder is used from outside (a seek).
        var paused = false
        /// The decoding thread is in a decode call.
        var busy = false
        var cancelled = false
        var concealed = 0
    }

    /// `seconds` of audio are decoded ahead (less at high rates and channel counts, within `budgetBytes`).
    init(_ inner: PCMDecoding, seconds: Double = 8, budgetBytes: Int = 48 << 20, chunk: AVAudioFrameCount = 4096) {
        self.inner = inner
        format = inner.processingFormat
        position = inner.position
        length = inner.length
        supportsSeeking = inner.supportsSeeking
        decodingIsLossless = inner.decodingIsLossless
        sourceFormat = inner.sourceFormat
        inputSource = inner.inputSource
        properties = inner.properties
        marker = (inner as? RawDoPDecoder).map { (inner.position, $0.nextMarker) }
        shared = Shared(inner: inner, format: format)
        let asbd = format.streamDescription.pointee
        let buffers = format.isInterleaved ? 1 : Int(format.channelCount)
        let bytesPerFrame = max(1, Int(asbd.mBytesPerFrame) * buffers)
        let target = max(Int(chunk) * 2, min(Int(format.sampleRate * seconds), budgetBytes / bytesPerFrame))
        super.init()
        let thread = Thread { [shared] in Self.run(shared, chunk: chunk, target: target) }
        thread.name = "Vespertine Read-Ahead"
        // Above the cache's copies and library scans (utility), below the engine.
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    deinit { stop() }

    /// The decoding thread: keeps `target` frames decoded ahead. A read stuck on the share holds up only it.
    private static func run(_ s: Shared, chunk: AVAudioFrameCount, target: Int) {
        let inner = s.inner
        while true {
            s.condition.lock()
            while !s.cancelled && (s.paused || s.ended || s.buffered >= target) { s.condition.wait() }
            if s.cancelled { s.condition.unlock(); return }
            let buffer = s.spare.popLast() ?? AVAudioPCMBuffer(pcmFormat: s.format, frameCapacity: chunk)
            s.busy = true
            s.condition.unlock()

            var failure: Error?
            if let buffer {
                do { try inner.decode(into: buffer, length: chunk) } catch { failure = error }
            } else {
                failure = NoBuffer()
            }
            let concealed = (inner as? ConcealingDecoder)?.concealedFrames

            s.condition.lock()
            s.busy = false
            if let buffer, failure == nil, buffer.frameLength > 0 {
                s.ready.append(buffer)
                s.buffered += Int(buffer.frameLength)
                delivered.withLock { $0 = Date() }
            } else {
                if let buffer { s.spare.append(buffer) }
                s.ended = true
                s.error = failure
            }
            if let concealed { s.concealed = concealed }
            s.condition.broadcast()
            s.condition.unlock()
        }
    }

    private func stop() {
        shared.condition.lock()
        shared.cancelled = true
        shared.condition.broadcast()
        shared.condition.unlock()
    }

    /// Runs `body` with the decoding thread held (waiting out a decode call in progress) and what it decoded
    /// ahead dropped, then lets it carry on from wherever `body` left the decoder.
    private func withDecoderHeld<T>(_ body: () throws -> T) rethrows -> T {
        let s = shared
        s.condition.lock()
        s.paused = true
        while s.busy { s.condition.wait() }
        s.spare += s.ready
        s.ready.removeAll()
        s.taken = 0
        s.buffered = 0
        s.ended = false
        s.error = nil
        s.condition.unlock()
        defer {
            s.condition.lock()
            s.paused = false
            s.condition.broadcast()
            s.condition.unlock()
        }
        return try body()
    }

    // MARK: PCMDecoding

    var processingFormat: AVAudioFormat { format }
    var isOpen: Bool { true }
    var concealedFrames: Int { shared.condition.withLock { shared.concealed } }

    func open() throws {}
    func close() throws { stop() }

    func decode(into buffer: AVAudioBuffer) throws {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        try decode(into: pcm, length: pcm.frameCapacity)
    }

    func decode(into buffer: AVAudioPCMBuffer, length: AVAudioFrameCount) throws {
        buffer.frameLength = 0
        let want = Int(min(length, buffer.frameCapacity))
        let s = shared
        s.condition.lock()
        defer { s.condition.unlock() }
        if s.buffered == 0 {
            if let error = s.error { throw error }
            if s.ended { return }
            throw Starved()
        }
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let out = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        var copied = 0
        while copied < want, let head = s.ready.first {
            let n = min(want - copied, Int(head.frameLength) - s.taken)
            let from = UnsafeMutableAudioBufferListPointer(head.mutableAudioBufferList)
            for (src, dst) in zip(from, out) {
                guard let source = src.mData, let destination = dst.mData else { continue }
                memcpy(destination + copied * bytesPerFrame, source + s.taken * bytesPerFrame, n * bytesPerFrame)
            }
            copied += n
            s.taken += n
            if s.taken == Int(head.frameLength) {
                s.spare.append(s.ready.removeFirst())
                s.taken = 0
            }
        }
        s.buffered -= copied
        buffer.frameLength = AVAudioFrameCount(copied)
        position += AVAudioFramePosition(copied)
        s.condition.broadcast()   // room for more
    }

    func seek(to frame: AVAudioFramePosition) throws {
        try withDecoderHeld {
            defer {
                position = inner.position
                marker = (inner as? RawDoPDecoder).map { (inner.position, $0.nextMarker) }
            }
            try inner.seek(to: frame)
        }
    }

    // MARK: For the engine

    /// Waits up to `timeout` for decoded audio (or the end of the file). True when there is some.
    @discardableResult
    func waitForAudio(timeout: TimeInterval) -> Bool {
        let s = shared
        let deadline = Date().addingTimeInterval(timeout)
        s.condition.lock()
        defer { s.condition.unlock() }
        while s.buffered == 0, !s.ended, s.condition.wait(until: deadline) {}
        return s.buffered > 0
    }

    /// DoP: the marker of the next frame handed over (see `RawDoPDecoder.nextMarker`); nil for other decoders.
    var nextDoPMarker: AVAudioFramePosition? {
        get { marker.map { ($0.marker + position - $0.frame) & 1 } }
        set {
            guard let newValue, let dop = inner as? RawDoPDecoder else { return }
            // Frames decoded ahead carry the old sequence: they're decoded again with the new one.
            withDecoderHeld {
                if inner.position != position { try? inner.seek(to: position) }
                dop.nextMarker = newValue
                marker = (inner.position, newValue)
            }
        }
    }
}
