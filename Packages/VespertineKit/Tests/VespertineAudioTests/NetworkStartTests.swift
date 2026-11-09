//
// Vespertine: a song on a share starts on a prefix, not after the whole file: the policy, the guarded decoder, and the time to first audio.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import Testing
@testable import VespertineAudio

/// A share that delivers `bytesPerSecond` on average: each read waits until the bytes delivered so far could have arrived (an absolute
/// schedule, so a sleep that overshoots on a busy host is made up by the next read), and it can be stalled.
private final class ThrottledShare: PlaybackCacheReader, @unchecked Sendable {
    let bytes: Data
    let bytesPerSecond: Double
    private let gate = NSCondition()
    private var stalled = false
    /// Reads at or beyond this offset wait (nil: none do): a share that goes quiet after a known amount, however fast it is.
    private var silentFrom: Int64?
    private var delivered = 0.0
    private var started: Date?
    var size: Int64 { Int64(bytes.count) }
    init(data: Data, bytesPerSecond: Double) { bytes = data; self.bytesPerSecond = bytesPerSecond }
    func read(at offset: Int64, count: Int) throws -> Data {
        gate.lock()
        while stalled || silentFrom.map({ offset >= $0 }) == true { gate.wait() }
        let start = started ?? Date()
        started = start
        delivered += Double(min(count, bytes.count - Int(offset)))
        let due = start.addingTimeInterval(delivered / bytesPerSecond)
        gate.unlock()
        let wait = due.timeIntervalSinceNow
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        return bytes.subdata(in: Int(offset)..<min(Int(offset) + count, bytes.count))   // a memcpy: a debug build's Data(slice) is slow
    }
    func stall(_ value: Bool) { gate.lock(); stalled = value; gate.broadcast(); gate.unlock() }
    func goQuiet(from offset: Int64?) { gate.lock(); silentFrom = offset; gate.broadcast(); gate.unlock() }
}

@Suite("Network start")
struct NetworkStartTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A 24-bit stereo WAV of noise (so a wrong or missing byte is heard in the comparison), `seconds` long.
    private func writeWAV(_ url: URL, rate: Double = 96_000, seconds: Int) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
        var state: UInt32 = 12345
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

    private func plan(rate: Double) -> OutputPlan {
        OutputPlan(mode: .pcm, deviceSampleRate: rate, decodedSampleRate: rate, physicalBitDepth: 32, channels: 2, dsdConvertedToPCM: false, reason: "")
    }

    /// Opens `url` the way the engine does and decodes `frames` frames (all of the song when nil): the decoded bytes.
    private func decode(_ url: URL, rate: Double = 96_000, frames: Int? = nil) throws -> [UInt8] {
        let probed = try SourceOpener.probe(url)
        let decoder = try SourceOpener.decoder(for: probed, plan: plan(rate: rate), item: PlayableItem(url: url))
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096)!
        var out: [UInt8] = []
        var decoded = 0
        while frames.map({ decoded < $0 }) ?? true {
            try decoder.decode(into: buffer, length: 4096)
            if buffer.frameLength == 0 { break }
            decoded += Int(buffer.frameLength)
            for part in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)   // per buffer: a frame of all channels, or of one
                if let data = part.mData { out += UnsafeRawBufferPointer(start: data, count: Int(buffer.frameLength) * bytesPerFrame) }
            }
        }
        return out
    }

    @Test("Which songs start on a prefix: FLAC, WAV and DSD files above a size, never a CUE track, never the rest")
    func policy() {
        let big: Int64 = 200 << 20
        #expect(NetworkStart.startsEarly(fileExtension: "flac", size: big, isRegion: false))
        #expect(NetworkStart.startsEarly(fileExtension: "WAV", size: big, isRegion: false))
        #expect(NetworkStart.startsEarly(fileExtension: "aiff", size: big, isRegion: false))
        // DSF and DSDIFF keep their header and first audio at the front too. A 5.1 DSD64 song of under 512 MB used to be
        // copied whole before its first note: minutes on a share with a long round trip, all of it on "Preparing output…".
        #expect(NetworkStart.startsEarly(fileExtension: "dsf", size: big, isRegion: false))
        #expect(NetworkStart.startsEarly(fileExtension: "DFF", size: big, isRegion: false))
        #expect(NetworkStart.startsEarly(fileExtension: "dsdiff", size: big, isRegion: false))
        #expect(!NetworkStart.startsEarly(fileExtension: "flac", size: big, isRegion: true))
        #expect(!NetworkStart.startsEarly(fileExtension: "flac", size: 3 << 20, isRegion: false))
        for ext in ["m4a", "mp3", "ape", "wv", "ogg", "iso"] {
            #expect(!NetworkStart.startsEarly(fileExtension: ext, size: big, isRegion: false), "\(ext)")
        }
    }

    @Test("The lead: a fast link needs the least, a slow one the part of the song it cannot bring in while it plays, a stalled one the lot")
    func lead() {
        let size: Int64 = 100 << 20, duration = 100.0       // 1 MiB of file per second of song
        func lead(link mibPerSecond: Double, position: Int64 = 0) -> Int64 {
            NetworkStart.lead(fileSize: size, position: position, duration: duration, copied: Int64(mibPerSecond * 4 * 1_048_576), elapsed: 4)
        }
        #expect(lead(link: 20) == NetworkStart.smallestLead)
        #expect(lead(link: 1.3) == NetworkStart.smallestLead)           // just fast enough once the safety margin is taken off
        let half = lead(link: 0.9)                                       // 0.9 / 1.3 = 0.69 MiB/s: 31 MiB short
        #expect(half > NetworkStart.smallestLead && half < size)
        let mebibyte: Double = 1_048_576
        // Spelled out step by step: one long arithmetic expression inside #expect is more than Swift 6.3's type checker will do in time.
        func expectedLead(link: Double) -> Double {
            let arrivesWhilePlaying: Double = 100.0 * link / 1.3
            let missing: Double = 100.0 - arrivesWhilePlaying
            return missing * mebibyte
        }
        let halfDifference: Double = abs(Double(half) - expectedLead(link: 0.9))
        #expect(halfDifference < mebibyte)
        // A link slower than the song plays has to bring part of the song in first (here 0.5 / 1.3 of it arrives while it plays)…
        let slowDifference: Double = abs(Double(lead(link: 0.5)) - expectedLead(link: 0.5))
        #expect(slowDifference < mebibyte)
        // …all of it when the copy has all but stopped, and never more than what is left.
        #expect(lead(link: 0.00001) > size - (1 << 20))
        #expect(lead(link: 0.00001, position: 1 << 20) > size - (2 << 20))
        #expect(lead(link: 0.00001, position: 1 << 20) <= size - (1 << 20))
        #expect(NetworkStart.lead(fileSize: size, position: 0, duration: duration, copied: 0, elapsed: 0) == size)   // nothing measured yet
        #expect(NetworkStart.lead(fileSize: size, position: 0, duration: 0, copied: 1 << 20, elapsed: 1) == size)   // no length
    }

    @Test("The start lead: a few seconds of the song on a fast link, not a fixed 128 MiB or the whole file; the shortfall on a slow one")
    func startLead() {
        // A 5.1 DSD64 song of 3:48: about 483 MB at 2.12 MB/s, from a share 100 ms away that copies 6.7 MB/s.
        let duration = 228.0
        let size = Int64(2_822_400.0 / 8 * 6 * duration)
        let perSecond = Double(size) / duration
        func lead(link bytesPerSecond: Double, position: Int64 = 0) -> Int64 {
            NetworkStart.startLead(fileSize: size, position: position, duration: duration,
                                   copied: Int64(bytesPerSecond * 4), elapsed: 4)
        }
        let fast = lead(link: 6_700_000)
        // At least `safetySeconds` of the song, so one slow round trip is not a gap…
        #expect(Double(fast) >= perSecond * NetworkStart.safetySeconds - 1)
        // …and nowhere near the 128 MiB (a minute of waiting at this speed) or the whole file the start used to wait for.
        #expect(fast < 32 << 20, "lead \(fast >> 20) MiB")
        // A link slower than the song still brings in what it cannot fetch while the song plays.
        let slow = lead(link: 1_500_000)
        let expected = Double(size) - 1_500_000 / 1.3 * duration
        #expect(abs(Double(slow) - expected) < 1_048_576, "lead \(slow >> 20) MiB, expected about \(Int(expected) >> 20)")
        // Never more than what is left, and the whole rest when nothing has been measured yet.
        #expect(lead(link: 6_700_000, position: size - (1 << 20)) <= 1 << 20)
        #expect(NetworkStart.startLead(fileSize: size, position: 0, duration: duration, copied: 0, elapsed: 0) == size)
        // PCM keeps the plain lead: no floor of seconds.
        #expect(NetworkStart.startLead(fileSize: size, position: 0, duration: duration, copied: Int64(6_700_000 * 4), elapsed: 4,
                                       minimumSeconds: 0) == NetworkStart.smallestLead)
    }

    @Test("The lead from the middle of a song (a seek, another output) plans on the part still to play, not the whole song")
    func leadFromTheMiddle() {
        let size: Int64 = 100 << 20, duration = 100.0       // 1 MiB of file per second of song
        let mebibyte: Double = 1_048_576
        // 0.5 MiB/s, trusted as 0.5 / 1.3: from halfway, 50 MiB remain and 50 s of song bring in 50 * 0.5 / 1.3 MiB of them.
        let lead = NetworkStart.lead(fileSize: size, position: 50 << 20, duration: duration, copied: Int64(0.5 * 4 * mebibyte), elapsed: 4)
        let arrivesWhilePlaying: Double = 50.0 * 0.5 / 1.3
        let expected: Double = (50.0 - arrivesWhilePlaying) * mebibyte
        let difference: Double = abs(Double(lead) - expected)
        #expect(difference < mebibyte, "lead \(Double(lead) / mebibyte) MiB, expected about \(expected / mebibyte)")
        // A link faster than the song still needs only the least, from anywhere.
        #expect(NetworkStart.lead(fileSize: size, position: 50 << 20, duration: duration, copied: Int64(20 * 4 * mebibyte), elapsed: 4)
                == NetworkStart.smallestLead)
    }

    @Test("A decoder reads a song that is still being copied: the start waits for nothing but its prefix, and the whole song is exact")
    func decodesWhileCopying() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("song.wav")
        try writeWAV(url, seconds: 6)
        let share = ThrottledShare(data: try Data(contentsOf: url), bytesPerSecond: 200 * 1_048_576)
        let cache = NetworkPlaybackCache(directory: dir.appendingPathComponent("cache"), budget: 64 << 20, chunk: 1 << 16)
        share.goQuiet(from: 2 << 20)      // the first two megabytes arrive; after that the share says nothing, however fast the copy is
        let entry = try cache.entry(key: "song", url: url, reader: share)
        try entry.prepare(full: false, lead: 1 << 20, cancelled: { false })
        // What the decoder gets now must come from the bytes already on disk.
        #expect(!entry.isComplete)
        let first = try decode(entry.url, frames: 20_000)
        #expect(first.count >= 40_000)
        let direct = try decode(url)
        #expect(Array(direct.prefix(first.count)) == first)
        share.goQuiet(from: nil)
        // The rest arrives while it is decoded: nothing is zeros, nothing ends early.
        let all = try decode(entry.url)
        let mismatch = zip(all, direct).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        #expect(all == direct, "\(all.count) bytes against \(direct.count); first difference at \(mismatch.map(String.init) ?? "none")")
        try entry.prepare(full: true, lead: 0, cancelled: { false })
        #expect(entry.isComplete)
        #expect(try Data(contentsOf: entry.url) == share.bytes, "the staged file is the share's file")
    }

    /// The share here is all bandwidth and no round trip, timed with sleeps: one read at a time, so what is compared is a prefix against
    /// the whole file (several reads in flight are for a share far away, see `NetworkPlaybackCacheTests.readsInFlight`).
    @Test("Time to first audio: a prefix on a throttled share starts without the rest of the file, where copying the file first waits for all of it")
    func timeToFirstAudio() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("song.wav")
        try writeWAV(url, seconds: 40)                                  // about 23 MB
        let data = try Data(contentsOf: url)
        let rate = 30.0 * 1_048_576                                      // a share that does 30 MB/s
        func firstAudio(_ open: () throws -> URL) throws -> Double {
            let started = Date()
            let local = try open()
            _ = try decode(local, frames: 4096)
            return Date().timeIntervalSince(started)
        }
        let localSeconds = try firstAudio { url }
        let fullSeconds = try firstAudio {
            let cache = NetworkPlaybackCache(directory: dir.appendingPathComponent("full"), budget: 64 << 20, readsInFlight: 1)
            let entry = try cache.entry(key: "full", url: url, reader: ThrottledShare(data: data, bytesPerSecond: rate))
            try entry.prepare(full: true, lead: 0, cancelled: { false })
            leak.withLock { $0.append(entry) }
            return entry.url
        }
        // The prefix start is proved by what it needs, not by how long it takes (a ratio of two wall-clock times moves with the
        // machine's load): the share goes quiet a little beyond the prefix, so first audio can only come from the prefix alone.
        // Starting only after the whole file would wait on it for good, and the deadline turns that into a failure.
        let quietShare = ThrottledShare(data: data, bytesPerSecond: rate)
        quietShare.goQuiet(from: NetworkStart.prefix + (1 << 20))
        defer { quietShare.goQuiet(from: nil) }
        let deadline = Date().addingTimeInterval(60)
        let earlySeconds = try firstAudio {
            let cache = NetworkPlaybackCache(directory: dir.appendingPathComponent("early"), budget: 64 << 20, readsInFlight: 1)
            let entry = try cache.entry(key: "early", url: url, reader: quietShare)
            try entry.prepare(full: false, lead: NetworkStart.prefix, cancelled: { Date() > deadline })
            #expect(!entry.isComplete, "first audio came from the prefix, with the rest of the file not there yet")
            leak.withLock { $0.append(entry) }
            return entry.url
        }
        let cacheOnly: Double = try {
            let cache = NetworkPlaybackCache(directory: dir.appendingPathComponent("raw"), budget: 64 << 20)
            let started = Date()
            let entry = try cache.entry(key: "raw", url: url, reader: ThrottledShare(data: data, bytesPerSecond: 1e12))
            try entry.prepare(full: true, lead: 0, cancelled: { false })
            leak.withLock { $0.append(entry) }
            return Date().timeIntervalSince(started)
        }()
        print(String(format: "cache copy of the same file from an instant share: %.0f ms", cacheOnly * 1000))
        print(String(format: "time to first audio, %d MB at 30 MB/s: local %.0f ms, whole file first %.0f ms, prefix first %.0f ms",
                     data.count >> 20, localSeconds * 1000, fullSeconds * 1000, earlySeconds * 1000))
        #expect(fullSeconds > Double(data.count) / rate * 0.9)            // the copy is what the old start waited for
        #expect(earlySeconds < 60, "the prefix was enough for first audio with the share quiet beyond it")
    }

    /// Entries outlive the measurement (their files must stay until the decoders are done).
    private let leak = Locked([NetworkPlaybackCache.Entry]())
}
