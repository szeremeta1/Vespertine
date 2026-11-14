//
// Vespertine: wraps a decoder so a codec library's exception on a damaged file is an error, not a crash.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import CVespertineGuard
import Foundation
import SFBAudioEngine

final class GuardedDecoder: NSObject, PCMDecoding {
    /// How a decoder over a song still being copied from a share gets going again when a read of the share fails (see `decode`).
    struct Recovery {
        let entry: NetworkPlaybackCache.Entry
        /// The decoder the song was opened with (nil: picked by the file).
        let name: AudioDecoder.Name?
    }

    /// Times one decode call opens the file and the decoder afresh and goes on from the last good frame, before the song fails.
    static let reopenLimit = 3
    /// Waits before each of those tries (a share that is reconnecting needs a moment); the read-ahead decodes seconds ahead of the output.
    static let reopenDelays: [TimeInterval] = [0.25, 0.5, 1]

    /// The decoder in use: replaced by a fresh one when a read failed and the file was opened again. Decoding thread, or whoever
    /// holds the decoder (a seek).
    private let current: Locked<PCMDecoding>
    var inner: PCMDecoding { current.withLock { $0 } }
    private let recovery: Recovery?
    /// libtta (SFBAudioEngine 0.14.0) writes one byte past the frames it returns for 24-bit audio, which
    /// overruns a buffer it fills to the last frame and corrupts the heap: that frame is left free.
    private let reservesLastFrame: Bool
    init(_ inner: PCMDecoding, recovery: Recovery? = nil) {
        current = Locked(inner)
        self.recovery = recovery
        reservesLastFrame = String(describing: type(of: inner)).contains("TrueAudio")
    }

    var inputSource: InputSource { inner.inputSource }
    var sourceFormat: AVAudioFormat { inner.sourceFormat }
    var processingFormat: AVAudioFormat { inner.processingFormat }
    var decodingIsLossless: Bool { inner.decodingIsLossless }
    var properties: [AudioDecodingPropertiesKey: Any] { inner.properties }
    var isOpen: Bool { inner.isOpen }
    var supportsSeeking: Bool { inner.supportsSeeking }
    var position: AVAudioFramePosition { inner.position }
    var length: AVAudioFramePosition { inner.length }

    func open() throws { let decoder = inner; try Self.check { nguard_open(decoder, $0) } }
    func close() throws { try inner.close() }
    func decode(into buffer: AVAudioBuffer) throws {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        try decode(into: pcm, length: pcm.frameCapacity)
    }
    func decode(into buffer: AVAudioPCMBuffer, length: AVAudioFrameCount) throws {
        let length = reservesLastFrame && buffer.frameCapacity > 1 ? min(length, buffer.frameCapacity - 1) : length
        let good = inner.position
        var attempt = 0
        while true {
            let decoder = inner
            do { try Self.check { nguard_decode(decoder, buffer, length, $0) }; return }
            catch {
                // SFBAudioEngine drops the reason an input source's read failed and says the decoding did. If the source knows, a
                // read of the share failed, and a share's read can often be made again.
                guard let failure = Self.readFailure(of: decoder, decodeError: error) else { throw error }
                log.error("Decoding stopped at frame \(good, privacy: .public) on a failed read (try \(attempt + 1, privacy: .public)): \(ShareReadFailure.describe(failure.underlying), privacy: .public)")
                guard attempt < Self.reopenLimit, recoverRead(after: failure.underlying, at: good, delay: Self.reopenDelays[min(attempt, Self.reopenDelays.count - 1)]) else {
                    throw failure
                }
                attempt += 1
            }
        }
    }
    func seek(to frame: AVAudioFramePosition) throws {
        let decoder = inner
        do { try Self.check { nguard_seek(decoder, frame, $0) } }
        catch { throw Self.readFailure(of: decoder, decodeError: error) ?? error }
    }

    /// `error` as the failed read of the share it was, when `decoder`'s input source says that is what failed.
    private static func readFailure(of decoder: PCMDecoding, decodeError error: Error) -> ShareReadFailure? {
        if error is ShareReadFailure { return nil }
        guard let cause = (decoder.inputSource as? VTCacheInputSource)?.lastReadError else { return nil }
        return ShareReadFailure(cause)
    }

    /// Gets the song's copy going again and opens the file afresh, positioned on `frame`: the frame the failed decode began at. False
    /// when the failure isn't one a read can survive, the copy can't go on, or the new decoder isn't where it should be.
    private func recoverRead(after cause: Error, at frame: AVAudioFramePosition, delay: TimeInterval) -> Bool {
        guard let recovery, ShareReadFailure.isRetryable(cause) else { return false }
        Thread.sleep(forTimeInterval: delay)
        guard recovery.entry.resumeAfterReadFailure() else { return false }
        do {
            let source = recovery.entry.inputSource()
            let raw = try recovery.name.map { try AudioDecoder(inputSource: source, decoderName: $0) } ?? AudioDecoder(inputSource: source)
            try Self.check { nguard_open(raw, $0) }
            let old = inner
            guard raw.length == old.length, raw.supportsSeeking else { return false }
            try Self.check { nguard_seek(raw, frame, $0) }
            guard raw.position == frame else { return false }
            current.withLock { $0 = raw }
            try? old.close()
            log.notice("Reopened the song on the share at frame \(frame, privacy: .public)")
            return true
        } catch {
            log.error("Couldn't reopen the song on the share: \(ShareReadFailure.describe(error), privacy: .public)")
            return false
        }
    }

    private static func check(_ call: (NSErrorPointer) -> Bool) throws {
        var error: NSError?
        guard call(&error) else { throw error ?? NSError(domain: "org.szeremeta.vespertine.decoder", code: -1) }
    }
}
