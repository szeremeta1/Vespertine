//
// Vespertine: one failed read from a share mid-song must not end the song. A song played from an SMB share stopped about a minute in
// and the queue moved on, with "An error occurred during PCM audio decoding." The FLAC was fine: a read of the share's file had failed,
// the cache threw the real error away (`try?`), SFBAudioEngine turned the failed read into a decoding error, and the read-ahead
// decoder treated that as the end of the song.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import SFBAudioEngine
import Testing
@testable import VespertineAudio

/// A share whose first handle fails one read (or every read, for good) at `faultAt` and whose later handles read normally. Reads
/// from `holdFrom` on wait until `release()`, so a decoder can be opened on the first part of the file while the rest is still to come.
private final class FaultyShare: @unchecked Sendable {
    enum Fault {
        /// The first read at or past `faultAt` throws this, once.
        case once(POSIXErrorCode)
        /// The first read at or past `faultAt` answers with no bytes (a short read, once).
        case emptyOnce
        /// Every read at or past `faultAt`, on any handle, throws this.
        case always(POSIXErrorCode)
    }

    let bytes: Data
    let faultAt: Int64
    let fault: Fault
    private let state = NSCondition()
    private var held: Bool
    private var fired = false
    private var opened = 0
    private let holdFrom: Int64

    init(bytes: Data, fault: Fault) {
        self.bytes = bytes
        self.fault = fault
        faultAt = Int64(bytes.count) * 2 / 5
        holdFrom = 256 << 10
        held = true
    }

    /// How many times a handle was opened (the cache's first, then one per reopen).
    var handlesOpened: Int { state.withLock { opened } }
    var faultFired: Bool { state.withLock { fired } }
    func release() { state.withLock { held = false; state.broadcast() } }

    func open() -> any PlaybackCacheReader {
        state.withLock { opened += 1 }
        return Handle(self)
    }

    private final class Handle: PlaybackCacheReader, @unchecked Sendable {
        let share: FaultyShare
        init(_ share: FaultyShare) { self.share = share }
        var size: Int64 { Int64(share.bytes.count) }
        func read(at offset: Int64, count: Int) throws -> Data {
            let s = share
            s.state.lock()
            while s.held, offset >= s.holdFrom { s.state.wait() }
            var failure: POSIXErrorCode?
            var empty = false
            if offset + Int64(count) > s.faultAt {
                switch s.fault {
                case .once(let code): if !s.fired { s.fired = true; failure = code }
                case .emptyOnce: if !s.fired { s.fired = true; empty = true }
                case .always(let code): s.fired = true; failure = code
                }
            }
            s.state.unlock()
            if let failure { throw POSIXError(failure) }
            if empty { return Data() }
            return s.bytes.subdata(in: Int(offset)..<min(Int(offset) + count, s.bytes.count))
        }
    }
}

@Suite("A failed read from a share mid-song")
struct ShareReadRetryTests {
    private let seconds = 4
    private let rate = 48_000.0

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shareretry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A song as a FLAC on `share`, opened through the cache while only its first 256 KiB have arrived, then read to the end by a
    /// read-ahead decoder. The frames it handed over and the error it ended with (nil: it ended at the end of the file).
    private func playThrough(_ fault: FaultyShare.Fault, in dir: URL) throws -> (frames: Int, error: Error?, share: FaultyShare) {
        let wav = dir.appendingPathComponent("song.wav")
        try PlayPauseRig.writeWAV(wav, rate: rate, seconds: seconds)
        let flac = try PlayPauseRig.writeFLAC(from: wav)
        let share = FaultyShare(bytes: try Data(contentsOf: flac), fault: fault)
        let cache = NetworkPlaybackCache(directory: dir.appendingPathComponent("cache"), budget: 64 << 20, chunk: 1 << 14)
        cache.readerFactory = { _ in share.open() }
        let entry = try cache.entry(key: "song", url: flac)
        try entry.prepare(full: false, lead: 192 << 10, cancelled: { false })
        try #require(!entry.isComplete)
        let probed = try SourceOpener.probe(entry.url)
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: rate, decodedSampleRate: rate, physicalBitDepth: 32, channels: 2,
                              dsdConvertedToPCM: false, reason: "")
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: entry.url))
        let ahead = ReadAheadDecoder(decoder)
        share.release()

        let buffer = AVAudioPCMBuffer(pcmFormat: ahead.processingFormat, frameCapacity: 4096)!
        let deadline = Date().addingTimeInterval(60)
        var frames = 0
        var failure: Error?
        while Date() < deadline {
            do { try ahead.decode(into: buffer, length: 4096) }
            catch is ReadAheadDecoder.Starved { Thread.sleep(forTimeInterval: 0.002); continue }
            catch { failure = error; break }
            if buffer.frameLength == 0 { if ahead.hasEnded { break } else { Thread.sleep(forTimeInterval: 0.002); continue } }
            frames += Int(buffer.frameLength)
        }
        withExtendedLifetime(entry) {}
        return (frames, failure, share)
    }

    @Test("A read that fails once with ESTALE does not end the song: the file is opened again and every frame plays")
    func staleHandle() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let played = try playThrough(.once(.ESTALE), in: dir)
        try #require(played.share.faultFired, "the fault was never reached, so this proved nothing")
        #expect(played.error == nil, "the song failed: \(String(describing: played.error))")
        #expect(played.frames == seconds * Int(rate))
        #expect(played.share.handlesOpened >= 2, "the dead handle was not replaced")
    }

    @Test("A read that fails once with EBADF does not end the song either")
    func badDescriptor() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let played = try playThrough(.once(.EBADF), in: dir)
        try #require(played.share.faultFired)
        #expect(played.error == nil, "the song failed: \(String(describing: played.error))")
        #expect(played.frames == seconds * Int(rate))
    }

    @Test("A read that answers with nothing mid-file once does not end the song: the decoder opens again at the last good frame")
    func shortReadOnce() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let played = try playThrough(.emptyOnce, in: dir)
        try #require(played.share.faultFired)
        #expect(played.error == nil, "the song failed: \(String(describing: played.error))")
        #expect(played.frames == seconds * Int(rate), "frames were lost or repeated across the retry")
    }

    @Test("A share that keeps failing is given a few tries, then the song fails saying the read of the share failed and why")
    func persistentFailureSaysWhy() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let played = try playThrough(.always(.ENOENT), in: dir)
        try #require(played.share.faultFired)
        let failure = try #require(played.error, "the song ended without an error although the file was cut short")
        let text = failure.localizedDescription
        #expect(!text.contains("PCM audio decoding"), "the message blames decoding: \(text)")
        #expect(text.localizedCaseInsensitiveContains("share"), "the message does not say the share read failed: \(text)")
        #expect(text.contains(POSIXError(.ENOENT).localizedDescription) || text.contains("ENOENT") || text.contains("No such file"),
                "the message does not carry the underlying error: \(text)")
        let underlying = (failure as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        #expect(underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(ENOENT), "the cause is not kept: \(String(describing: underlying))")
        #expect(played.frames < seconds * Int(rate))
        #expect(played.share.handlesOpened <= 6, "retried \(played.share.handlesOpened) times: it should give up after a few")
    }
}
