import AVFAudio
import CVespertineRT
import Foundation
import SFBAudioEngine
import Testing
@testable import VespertineAudio

private final class SlowShare: PlaybackCacheReader, @unchecked Sendable {
    let bytes: Data
    let gate = NSCondition()
    var stalled = false
    var reads = 0
    var size: Int64 { Int64(bytes.count) }
    init(count: Int) { bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 * 31) }) }
    init(data: Data) { bytes = data }
    func read(at offset: Int64, count: Int) throws -> Data {
        gate.lock()
        while stalled { gate.wait() }
        reads += 1
        gate.unlock()
        Thread.sleep(forTimeInterval: 0.001)
        return bytes[Int(offset)..<min(Int(offset) + count, bytes.count)]
    }
    func stall(_ value: Bool) { gate.lock(); stalled = value; gate.broadcast(); gate.unlock() }
    var readCount: Int { gate.withLock { reads } }
}

private final class ReconnectingShare: PlaybackCacheReader, @unchecked Sendable {
    let size: Int64 = 4096
    var attempts = 0
    func read(at offset: Int64, count: Int) throws -> Data {
        attempts += 1
        if attempts <= 2 { throw POSIXError(.ETIMEDOUT) }
        return Data(repeating: 42, count: count)
    }
}

struct NetworkPlaybackCacheTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Temporary share errors retry the same bytes instead of terminating playback")
    func reconnectingShare() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20)
        let entry = try cache.entry(key: "retry", url: URL(fileURLWithPath: "/share/a.flac"), reader: ReconnectingShare())
        try entry.prepare(full: true, lead: 0, cancelled: { false })
        #expect(try entry.read(at: 0, count: 4096) == Data(repeating: 42, count: 4096))
        #expect(!entry.isWaiting)
    }

    @Test("A slow current track is completely local before output; a later outage makes no reads")
    func fullCopySurvivesOutage() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let share = SlowShare(count: 128 * 1024)
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096)
        let entry = try cache.entry(key: "song", url: URL(fileURLWithPath: "/share/song.flac"), reader: share)
        share.stall(true)
        #expect(!entry.isComplete)
        #expect(entry.isWaiting)
        share.stall(false)
        try entry.prepare(full: true, lead: 0, cancelled: { false })
        #expect(entry.isComplete)
        #expect(!entry.isWaiting)
        let before = share.readCount
        share.stall(true); defer { share.stall(false) }
        #expect(try entry.read(at: 0, count: share.bytes.count) == share.bytes)
        #expect(share.readCount == before)
    }

    @Test("Large DSD uses a local lead; a stalled producer cannot interrupt reads within that reserve")
    func progressiveLead() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let share = SlowShare(count: 1024 * 1024)
        let cache = NetworkPlaybackCache(directory: dir, budget: 2 << 20, chunk: 4096)
        let entry = try cache.entry(key: "dsd", url: URL(fileURLWithPath: "/share/song.dsf"), reader: share)
        try entry.prepare(full: false, lead: 65536, cancelled: { false })
        #expect(!entry.isComplete)
        share.stall(true); defer { share.stall(false) }
        for offset in stride(from: 0, to: 65536, by: 4096) {
            #expect(try entry.read(at: Int64(offset), count: 4096) == share.bytes[offset..<offset + 4096])
        }
    }

    @Test("Unwritten sparse ranges wait, never return zeros or premature EOF; loading clears on delivery")
    func waitingTransitions() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let share = SlowShare(count: 131072)
        share.stall(true)
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096)
        let entry = try cache.entry(key: "wait", url: URL(fileURLWithPath: "/share/song.dsf"), reader: share)
        let finished = DispatchSemaphore(value: 0)
        let result = Locked<Data?>(nil)
        DispatchQueue.global().async {
            result.withLock { $0 = try? entry.read(at: 98304, count: 4096) }
            finished.signal()
        }
        #expect(finished.wait(timeout: .now() + 0.03) == .timedOut)
        #expect(entry.isWaiting)
        share.stall(false)
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(result.withLock { $0 } == share.bytes[98304..<102400])
        #expect(!entry.isWaiting)
    }

    @Test("A cancelled start returns promptly while the share is stuck")
    func cancellation() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let share = SlowShare(count: 65536); share.stall(true)
        defer { share.stall(false) }
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096)
        let entry = try cache.entry(key: "cancel", url: URL(fileURLWithPath: "/share/song.flac"), reader: share)
        #expect(throws: CancellationError.self) { try entry.prepare(full: true, lead: 0, cancelled: { true }) }
    }

    @Test("Current and next remain leased, disk reservations are bounded, crash leftovers are cleaned")
    func budgetAndCleanup() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: dir.appendingPathComponent("abandoned.partial"))
        let cache = NetworkPlaybackCache(directory: dir, budget: 16384, chunk: 1024)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("abandoned.partial").path))
        let current = try cache.entry(key: "current", url: URL(fileURLWithPath: "/a.flac"), reader: SlowShare(count: 8192))
        let next = try cache.entry(key: "next", url: URL(fileURLWithPath: "/b.flac"), reader: SlowShare(count: 8192))
        try current.prepare(full: true, lead: 0, cancelled: { false })
        try next.prepare(full: true, lead: 0, cancelled: { false })
        #expect(cache.reservedBytes == 16384)
        #expect(throws: (any Error).self) { try cache.entry(key: "third", url: URL(fileURLWithPath: "/c.flac"), reader: SlowShare(count: 8192)) }
        #expect(try current.read(at: 0, count: 8192).count == 8192)
        #expect(try next.read(at: 0, count: 8192).count == 8192)
    }

    @Test("Cache cleanup respects another live session's lease")
    func liveSessionIsNotRemoved() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = NetworkPlaybackCache(directory: dir, budget: 1 << 20)
        let share = SlowShare(count: 8192)
        let entry = try first.entry(key: "live", url: URL(fileURLWithPath: "/live.flac"), reader: share)
        try entry.prepare(full: true, lead: 0, cancelled: { false })
        let second = NetworkPlaybackCache(directory: dir, budget: 1 << 20)
        #expect(first.directory != second.directory)
        #expect(FileManager.default.fileExists(atPath: entry.url.path))
        #expect(try entry.read(at: 0, count: 8192) == share.bytes)
    }

    @Test("DVD folder staging keeps named IFO and VOB files together and byte exact")
    func dvdFolder() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("VIDEO_TS")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let ifo = source.appendingPathComponent("VIDEO_TS.IFO")
        let vob = source.appendingPathComponent("VTS_01_1.VOB")
        try Data([1, 2, 3]).write(to: ifo)
        try Data([4, 5, 6, 7]).write(to: vob)
        let cache = NetworkPlaybackCache(directory: dir.appendingPathComponent("cache"), budget: 1 << 20)
        let folder = try cache.directoryEntry(for: ifo, cancelled: { false })
        #expect(folder.url.lastPathComponent == "VIDEO_TS.IFO")
        #expect(try Data(contentsOf: folder.url) == Data([1, 2, 3]))
        #expect(try Data(contentsOf: folder.url.deletingLastPathComponent().appendingPathComponent(vob.lastPathComponent)) == Data([4, 5, 6, 7]))
        #expect(cache.reservedBytes == 7)
    }

    @Test("Staged PCM renders the whole track with zero underruns while its share is stalled")
    func renderWithoutNetwork() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("source.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
            buffer.frameLength = 48000
            for channel in 0..<2 { for frame in 0..<48000 { buffer.floatChannelData![channel][frame] = Float(frame % 128) / 256 } }
            try file.write(from: buffer)
        }
        let share = SlowShare(data: try Data(contentsOf: url))
        let cache = NetworkPlaybackCache(directory: dir.appendingPathComponent("cache"), budget: 1 << 20, chunk: 8192)
        let entry = try cache.entry(key: "pcm", url: url, reader: share)
        try entry.prepare(full: true, lead: 0, cancelled: { false })
        share.stall(true); defer { share.stall(false) }
        let file = try AVAudioFile(forReading: entry.url, commonFormat: .pcmFormatFloat32, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 256)!
        let ring = try #require(nrt_ring_create(1024, 2))
        let context = try #require(nrt_context_create(ring, 256))
        defer { nrt_context_destroy(context); nrt_ring_destroy(ring) }
        var rendered: Int64 = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: 256)
            let n = buffer.frameLength
            #expect(nrt_ring_write(ring, buffer.floatChannelData![0], n) == n)
            var out = [Float](repeating: 0, count: Int(n) * 2)
            out.withUnsafeMutableBufferPointer { nrt_context_render_interleaved(context, $0.baseAddress!, n, 2) }
            #expect(out == Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(n) * 2)))
            rendered += Int64(n)
        }
        #expect(rendered == 48000)
        #expect(nrt_context_take_underruns(context) == 0)
    }

    @Test("A native PCM probe retains its cache lease after the engine stages another source")
    func nativeDecoderLease() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("source.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48)!
            buffer.frameLength = 48
            for c in 0..<2 { for f in 0..<48 { buffer.floatChannelData![c][f] = 0 } }
            try file.write(from: buffer)
        }
        let share = SlowShare(data: try Data(contentsOf: url))
        let cache = NetworkPlaybackCache(directory: dir.appendingPathComponent("cache"), budget: 1 << 20)
        var entry: NetworkPlaybackCache.Entry? = try cache.entry(key: "lease", url: url, reader: share)
        try entry!.prepare(full: true, lead: 0, cancelled: { false })
        weak var lease = entry
        let probed = try SourceOpener.probe(entry!.url)
        entry = nil
        withExtendedLifetime(probed) {
            #expect(lease != nil)
            #expect(cache.reservedBytes == Int64(share.bytes.count))
            #expect(FileManager.default.fileExists(atPath: probed.url.path))
        }
    }

    @Test("Guarded FFmpeg DSD→PCM and DoP match direct decoding byte for byte", arguments: [false, true])
    func dsdDecoderIdentity(dop: Bool) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("source.dsf")
        let planes = (0..<2).map { channel in (0..<16384).map { UInt8(truncatingIfNeeded: $0 * 17 + channel) } }
        try DSDFiles.writeDSF(planes, rate: 2822400, to: url)
        var data = try Data(contentsOf: url)
        data.append(Data(repeating: 0, count: 2 << 20)) // uncached tail forces the guarded AVIO path
        let share = SlowShare(data: data)
        let cache = NetworkPlaybackCache(directory: dir.appendingPathComponent("cache"), budget: 4 << 20, chunk: 1024)
        let entry = try cache.entry(key: "dsd", url: url, reader: share)
        try entry.prepare(full: false, lead: 65536, cancelled: { false })
        #expect(!entry.isComplete)
        share.stall(true); defer { share.stall(false) }
        func decode(_ path: URL) throws -> [[UInt8]] {
            let probed = try SourceOpener.probe(path)
            let rate = 2822400.0 / (dop ? 16 : 8)
            let plan = OutputPlan(mode: dop ? .dop : .pcm, deviceSampleRate: rate, decodedSampleRate: rate,
                                  physicalBitDepth: dop ? 24 : 32, channels: 2, dsdConvertedToPCM: !dop, reason: "")
            let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: path))
            let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 257)!
            var result = [[UInt8]](repeating: [], count: 2)
            while true {
                try decoder.decode(into: buffer, length: 257)
                if buffer.frameLength == 0 { return result }
                for c in 0..<2 {
                    result[c] += UnsafeRawBufferPointer(start: buffer.floatChannelData![c], count: Int(buffer.frameLength) * 4)
                }
            }
        }
        #expect(try decode(entry.url) == decode(url))
    }
}
