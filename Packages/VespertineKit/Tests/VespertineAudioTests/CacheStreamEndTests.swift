//
// Vespertine: a FLAC song read live from a share (through the cache's input source) ends where the file does. libFLAC asks the input
// source whether it is at the end whenever a read comes back empty; an input source that never says yes leaves the decoder
// asking for ever, at full speed, so the song never ends: the queue does not move on, the output runs dry (every empty buffer is
// an underrun) and a skip is the only way out.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import SFBAudioEngine
import Testing
@testable import VespertineAudio

@Suite("A song streamed from a share ends at the end of its file")
struct CacheStreamEndTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("streamend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Decodes with `decoder` to the end on a thread of its own, giving up after `seconds`. The frames decoded, or nil when the
    /// decoding had not finished by then.
    private func framesDecoded(_ decoder: PCMDecoding, seconds: Double) -> Int? {
        let result = Locked<Int?>(nil)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096)!
            var frames = 0
            while true {
                do { try decoder.decode(into: buffer, length: 4096) } catch { break }
                if buffer.frameLength == 0 { break }
                frames += Int(buffer.frameLength)
            }
            result.withLock { $0 = frames }
            done.signal()
        }
        thread.name = "Stream end decode"
        thread.start()
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        return result.withLock { $0 }
    }

    @Test("FLAC read through the cache reaches its end, with every frame")
    func flacEnds() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("song.wav")
        try PlayPauseRig.writeWAV(wav, rate: 48_000, seconds: 3)
        let url = try PlayPauseRig.writeFLAC(from: wav)
        let share = ControlledShare(data: try Data(contentsOf: url), bytesPerSecond: 500 * 1_048_576)
        let cache = NetworkPlaybackCache(directory: dir.appendingPathComponent("cache"), budget: 64 << 20, chunk: 1 << 16)
        // Only the first part of the file has arrived when the decoder is opened (a song started on a prefix): it reads through the
        // cache's input source, not from the half-written file. The rest arrives while it decodes.
        share.goQuiet(from: 256 << 10)
        let entry = try cache.entry(key: "song", url: url, reader: share)
        try entry.prepare(full: false, lead: 1 << 18, cancelled: { false })
        try #require(!entry.isComplete)
        let probed = try SourceOpener.probe(entry.url)
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: 48_000, decodedSampleRate: 48_000, physicalBitDepth: 32, channels: 2,
                              dsdConvertedToPCM: false, reason: "")
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: entry.url))
        share.goQuiet(from: nil)
        let frames = framesDecoded(decoder, seconds: 20)
        #expect(frames != nil, "the decoder never reached the end of the file: it is asking the cache for more, for ever")
        #expect(frames == 3 * 48_000)
    }
}
