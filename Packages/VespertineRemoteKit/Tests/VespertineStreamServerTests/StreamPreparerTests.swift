//
// Vespertine: the Mac's stream channel end to end without a network: open a song, read it in ranges, convert what the
// phone can't decode (once, cached), and keep the phone to its own streams.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteProtocol
@testable import VespertineStreamServer

/// A converter that writes known bytes, counts its calls, and can be held until the test lets it go.
private final class FakeTranscoder: StreamTranscoding, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [TranscodeRequest] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var opened = true
    private var _holds = false
    private var _failWith: String?
    var calls: [TranscodeRequest] { lock.withLock { _calls } }
    var failWith: String? {
        get { lock.withLock { _failWith } }
        set { lock.withLock { _failWith = newValue } }
    }
    static let flacBytes = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    private func record(_ request: TranscodeRequest) -> Bool { lock.withLock { _calls.append(request); return _holds } }
    private func wait(_ c: CheckedContinuation<Void, Never>) {
        let go = lock.withLock { () -> Bool in
            if opened { return true }
            gate = c
            return false
        }
        if go { c.resume() }
    }

    func transcode(_ request: TranscodeRequest, to destination: URL, progress: @Sendable (Double) -> Void) async throws -> TranscodeResult {
        if record(request) { await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in wait(c) } }
        if let message = failWith { throw TranscodeFailure(message: message) }
        progress(0.5)
        try Self.flacBytes.write(to: destination)
        return TranscodeResult(format: StreamFormat(codec: "FLAC", container: "flac", sampleRate: request.sampleRate, bitDepth: request.bitDepth,
                                                    channels: request.channels, channelLabels: [1, 2, 3, 4, 5, 6, 7, 8].prefix(request.channels).map { $0 }, lossless: true),
                               frames: Int64(request.sampleRate) * 10)
    }

    func hold() { lock.withLock { opened = false; _holds = true } }
    func release() {
        let g = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            opened = true
            let g = gate
            gate = nil
            return g
        }
        g?.resume()
    }
    func channelLabels(of request: StreamSourceFacts) async -> [UInt32]? { request.channels == 6 ? [1, 2, 3, 4, 5, 6] : nil }
}

private struct Rig {
    let dir: URL
    let originals: URL
    let preparer: StreamPreparer
    let transcoder: FakeTranscoder
    var library: LibraryBox

    final class LibraryBox: @unchecked Sendable {
        private var songs: [Int64: StreamSourceFacts] = [:]
        private let lock = NSLock()
        func get(_ id: Int64) -> StreamSourceFacts? { lock.withLock { songs[id] } }
        func set(_ id: Int64, _ s: StreamSourceFacts) { lock.withLock { songs[id] = s } }
    }

    static func make(limit: Int64 = 1_000_000, streamsPerClient: Int? = nil) throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stream-prep-\(UUID().uuidString)", isDirectory: true)
        let originals = dir.appendingPathComponent("music", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let box = LibraryBox()
        let transcoder = FakeTranscoder()
        let cache = try StreamCache(directory: dir.appendingPathComponent("cache"), limitBytes: limit)
        let preparer = streamsPerClient.map { StreamPreparer(cache: cache, transcoder: transcoder, source: { box.get($0) }, maxStreamsPerClient: $0) }
            ?? StreamPreparer(cache: cache, transcoder: transcoder, source: { box.get($0) })
        return Rig(dir: dir, originals: originals, preparer: preparer, transcoder: transcoder, library: box)
    }

    @discardableResult
    func addFile(_ id: Int64, ext: String, bytes: Int, channels: Int = 2, rate: Double = 44_100, depth: Int? = 16, dsd: Bool = false) throws -> URL {
        let url = originals.appendingPathComponent("song\(id).\(ext)")
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 % 251) }).write(to: url)
        library.set(id, StreamSourceFacts(id: id, url: url, fileExtension: ext, codec: ext.uppercased(), isDSD: dsd, isLossless: true, sampleRate: rate,
                                         bitDepth: depth, channels: channels, duration: 10, fileSize: Int64(bytes),
                                         modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), isRegion: false, needsMacDecoder: false, replayGain: nil))
        return url
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

private func opened(_ result: StreamPreparer.Opened) -> StreamDescriptor? {
    if case .ready(let d) = result { return d }
    return nil
}

private func chunk(_ result: StreamPreparer.Read) -> StreamFrame? {
    if case .chunk(let f) = result { return f }
    return nil
}

@Suite struct OriginalStreams {
    @Test func aRangeIsExactlyTheFilesBytes() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        let url = try rig.addFile(1, ext: "flac", bytes: 10_000)
        let file = try Data(contentsOf: url)
        let descriptor = try #require(opened(await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil)))
        #expect(descriptor.kind == .original && descriptor.byteSize == 10_000 && descriptor.format.container == "flac")
        let frame = try #require(chunk(await rig.preparer.read(client: "a", request: 5, stream: descriptor.stream, offset: 1234, length: 2000)))
        #expect(frame.request == 5 && frame.stream == descriptor.stream && frame.offset == 1234)
        #expect(frame.payload == file[1234..<3234] && !frame.endOfStream)
    }

    @Test func theLastRangeSaysItIsTheLastAndIsShort() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.addFile(1, ext: "wav", bytes: 1000)
        let d = try #require(opened(await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil)))
        let frame = try #require(chunk(await rig.preparer.read(client: "a", request: 1, stream: d.stream, offset: 900, length: 500)))
        #expect(frame.payload.count == 100 && frame.endOfStream)
    }

    @Test func readingExactlyToTheEndIsTheEnd() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.addFile(1, ext: "wav", bytes: 1000)
        let d = try #require(opened(await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil)))
        #expect(chunk(await rig.preparer.read(client: "a", request: 1, stream: d.stream, offset: 500, length: 500))?.endOfStream == true)
    }

    @Test func readingPastTheEndIsAnEmptyEndNotAnError() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.addFile(1, ext: "wav", bytes: 1000)
        let d = try #require(opened(await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil)))
        let frame = try #require(chunk(await rig.preparer.read(client: "a", request: 1, stream: d.stream, offset: 5000, length: 100)))
        #expect(frame.payload.isEmpty && frame.endOfStream)
    }

    @Test func aReadIsCappedAtTheChunkLimit() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.addFile(1, ext: "flac", bytes: RemoteProtocol.maximumChunk * 2 + 5)
        let d = try #require(opened(await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil)))
        let frame = try #require(chunk(await rig.preparer.read(client: "a", request: 1, stream: d.stream, offset: 0, length: Int.max)))
        #expect(frame.payload.count == RemoteProtocol.maximumChunk && !frame.endOfStream)
    }

    @Test func badRangesAreRefused() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.addFile(1, ext: "flac", bytes: 100)
        let d = try #require(opened(await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil)))
        for (offset, length) in [(Int64(-1), 10), (0, 0), (0, -5)] {
            if case .chunk = await rig.preparer.read(client: "a", request: 1, stream: d.stream, offset: offset, length: length) { Issue.record("offset \(offset) length \(length) was served") }
        }
    }

    @Test func aMultichannelOriginalCarriesItsSpeakerLabels() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.addFile(1, ext: "flac", bytes: 100, channels: 6, rate: 48_000, depth: 24)
        let d = try #require(opened(await rig.preparer.open(client: "a", id: 1, maxSampleRate: 48_000)))
        #expect(d.kind == .original && d.format.channels == 6 && d.format.channelLabels == [1, 2, 3, 4, 5, 6])
    }

    @Test func theTagChangesWhenTheFileDoes() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.addFile(1, ext: "flac", bytes: 100)
        let first = try #require(opened(await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil)))
        try rig.addFile(1, ext: "flac", bytes: 101)
        let second = try #require(opened(await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil)))
        #expect(first.tag != second.tag)
    }

    @Test func aSongNotInTheLibraryIsRefused() async throws {
        // A phone names songs by library ID only: no path ever comes from it.
        let rig = try Rig.make(); defer { rig.cleanup() }
        if case .failed = await rig.preparer.open(client: "a", id: 999, maxSampleRate: nil) {} else { Issue.record("an unknown song opened") }
    }

    @Test func aMissingFileIsReportedNotCrashedOn() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        let url = try rig.addFile(1, ext: "flac", bytes: 100)
        try FileManager.default.removeItem(at: url)
        if case .failed(let why) = await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil) { #expect(!why.isEmpty) } else { Issue.record("opened a missing file") }
    }

    @Test func theOriginalFileIsNeverWritten() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        let url = try rig.addFile(1, ext: "flac", bytes: 4000)
        let before = try Data(contentsOf: url)
        let d = try #require(opened(await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil)))
        _ = await rig.preparer.read(client: "a", request: 1, stream: d.stream, offset: 0, length: 4000)
        await rig.preparer.close(client: "a", stream: d.stream)
        #expect(try Data(contentsOf: url) == before)
    }
}

@Suite struct ConvertedStreams {
    @Test func aDsdFileIsConvertedOnceAndThenServedFromTheCache() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.addFile(1, ext: "dsf", bytes: 100, channels: 6, rate: 2_822_400, depth: 1, dsd: true)
        let d = try #require(await settle { await rig.preparer.open(client: "a", id: 1, maxSampleRate: 48_000) })
        #expect(d.kind == .flac && d.format.channels == 6 && d.format.sampleRate == 44_100 && d.format.channelLabels == [1, 2, 3, 4, 5, 6])
        #expect(d.byteSize == Int64(FakeTranscoder.flacBytes.count) && d.frames == 441_000)
        let frame = try #require(chunk(await rig.preparer.read(client: "a", request: 1, stream: d.stream, offset: 100, length: 50)))
        #expect(frame.payload == FakeTranscoder.flacBytes[100..<150])
        // Again, from another phone: no second conversion.
        _ = try #require(await settle { await rig.preparer.open(client: "b", id: 1, maxSampleRate: 48_000) })
        #expect(rig.transcoder.calls.count == 1)
        #expect(rig.transcoder.calls[0].channels == 6 && rig.transcoder.calls[0].sampleRate == 44_100 && rig.transcoder.calls[0].bitDepth == 24)
    }

    @Test func whileItConvertsThePhoneIsToldToAskAgain() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.addFile(1, ext: "dsf", bytes: 100, rate: 2_822_400, depth: 1, dsd: true)
        rig.transcoder.hold()
        guard case .preparing = await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil) else { Issue.record("not preparing"); return }
        guard case .preparing = await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil) else { Issue.record("not preparing the second time"); return }
        #expect(rig.transcoder.calls.count <= 1, "asking twice doesn't convert twice")
        rig.transcoder.release()
        #expect(await settle { await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil) } != nil)
        #expect(rig.transcoder.calls.count == 1)
    }

    @Test func twoPhonesAskingAtOnceShareOneConversion() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.addFile(1, ext: "ape", bytes: 100)
        rig.transcoder.hold()
        _ = await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil)
        _ = await rig.preparer.open(client: "b", id: 1, maxSampleRate: nil)
        rig.transcoder.release()
        _ = await settle { await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil) }
        _ = await settle { await rig.preparer.open(client: "b", id: 1, maxSampleRate: nil) }
        #expect(rig.transcoder.calls.count == 1)
    }

    @Test func aConversionThatFailsSaysWhyAndMayBeTriedAgain() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.addFile(1, ext: "ape", bytes: 100)
        rig.transcoder.failWith = "The decoder gave up."
        var reason: String?
        for _ in 0..<200 {
            if case .failed(let why) = await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil) { reason = why; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reason == "The decoder gave up.")
        rig.transcoder.failWith = nil
        #expect(await settle { await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil) } != nil, "the next ask converts again")
    }

    @Test func aConversionSurvivesARestartOfTheMacApp() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.addFile(1, ext: "ape", bytes: 100, channels: 6, rate: 48_000, depth: 24)
        _ = try #require(await settle { await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil) })
        // A new preparer over the same cache folder: it finds the finished file and its format.
        let again = StreamPreparer(cache: try StreamCache(directory: rig.dir.appendingPathComponent("cache"), limitBytes: 1_000_000),
                                   transcoder: rig.transcoder, source: { rig.library.get($0) })
        let d = try #require(opened(await again.open(client: "x", id: 1, maxSampleRate: nil)))
        #expect(d.format.channels == 6 && d.format.channelLabels == [1, 2, 3, 4, 5, 6])
        #expect(rig.transcoder.calls.count == 1)
    }

    @Test func infoSaysWhichSongsWillBeConverted() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.addFile(1, ext: "flac", bytes: 100)
        try rig.addFile(2, ext: "dsf", bytes: 100, rate: 2_822_400, depth: 1, dsd: true)
        try rig.addFile(3, ext: "wav", bytes: 100, channels: 12)
        let infos = await rig.preparer.info(ids: [1, 2, 3, 404], maxSampleRate: nil)
        #expect(infos.map(\.id) == [1, 2, 3], "an unknown song is left out")
        #expect(infos.map(\.kind) == [.original, .flac, nil])
        #expect(infos[2].macOnlyReason != nil)
    }
}

@Suite struct StreamLimits {
    /// A phone that plays a song, has the next one ready and fetches one to keep has all three open, with one to spare for
    /// the moment a song changes.
    @Test func aPhoneCanPlayPrefetchAndKeepASongAtOnce() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        for id in 1...5 { try rig.addFile(Int64(id), ext: "flac", bytes: 100) }
        var all: [StreamDescriptor] = []
        for id in 1...4 { all.append(try #require(opened(await rig.preparer.open(client: "a", id: Int64(id), maxSampleRate: nil)))) }
        for stream in all {
            guard case .chunk = await rig.preparer.read(client: "a", request: 1, stream: stream.stream, offset: 0, length: 10) else {
                Issue.record("stream \(stream.stream) was closed"); continue
            }
        }
        _ = try #require(opened(await rig.preparer.open(client: "a", id: 5, maxSampleRate: nil)))
        if case .chunk = await rig.preparer.read(client: "a", request: 1, stream: all[0].stream, offset: 0, length: 10) { Issue.record("a fifth stream fit") }
    }

    @Test func aPhoneHasOneStreamAndOnePrefetch() async throws {
        let rig = try Rig.make(streamsPerClient: 2); defer { rig.cleanup() }
        for id in 1...3 { try rig.addFile(Int64(id), ext: "flac", bytes: 100) }
        let first = try #require(opened(await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil)))
        let second = try #require(opened(await rig.preparer.open(client: "a", id: 2, maxSampleRate: nil)))
        let third = try #require(opened(await rig.preparer.open(client: "a", id: 3, maxSampleRate: nil)))
        // The oldest is closed to make room.
        if case .chunk = await rig.preparer.read(client: "a", request: 1, stream: first.stream, offset: 0, length: 10) { Issue.record("the oldest stream stayed open") }
        #expect(chunk(await rig.preparer.read(client: "a", request: 2, stream: second.stream, offset: 0, length: 10)) != nil)
        #expect(chunk(await rig.preparer.read(client: "a", request: 3, stream: third.stream, offset: 0, length: 10)) != nil)
    }

    @Test func oneStreamIsNeverReadByAnotherPhone() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.addFile(1, ext: "flac", bytes: 100)
        let d = try #require(opened(await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil)))
        if case .chunk = await rig.preparer.read(client: "b", request: 1, stream: d.stream, offset: 0, length: 10) { Issue.record("phone b read phone a's stream") }
    }

    @Test func aClosedStreamIsGoneAndClosingTwiceIsHarmless() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.addFile(1, ext: "flac", bytes: 100)
        let d = try #require(opened(await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil)))
        await rig.preparer.close(client: "a", stream: d.stream)
        await rig.preparer.close(client: "a", stream: d.stream)
        if case .chunk = await rig.preparer.read(client: "a", request: 1, stream: d.stream, offset: 0, length: 10) { Issue.record("read a closed stream") }
    }

    @Test func aPhoneThatLeavesTakesItsStreamsWithIt() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.addFile(1, ext: "flac", bytes: 100)
        let d = try #require(opened(await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil)))
        await rig.preparer.closeAll(client: "a")
        if case .chunk = await rig.preparer.read(client: "a", request: 1, stream: d.stream, offset: 0, length: 10) { Issue.record("a stream outlived its phone") }
    }

    @Test func aConvertedFileInUseSurvivesEviction() async throws {
        let rig = try Rig.make(limit: 10); defer { rig.cleanup() }   // smaller than any conversion
        try rig.addFile(1, ext: "ape", bytes: 100)
        let d = try #require(await settle { await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil) })
        #expect(chunk(await rig.preparer.read(client: "a", request: 1, stream: d.stream, offset: 0, length: 100)) != nil)
    }
}

/// A gate a test closes on one song's reads (a share that has stopped answering).
private final class SlowDisk: @unchecked Sendable {
    private let lock = NSCondition()
    private var held: Set<Int64> = []
    private var waiting = 0
    func hold(_ song: Int64) { lock.withLock { _ = held.insert(song) } }
    func release(_ song: Int64) { lock.withLock { held.remove(song); lock.broadcast() } }
    var blocked: Int { lock.withLock { waiting } }
    func before(_ song: Int64) {
        lock.lock()
        waiting += 1
        while held.contains(song) { lock.wait() }
        waiting -= 1
        lock.unlock()
    }
}

@Suite struct SharedMac {
    @Test func aReadStuckOnASlowShareDoesNotHoldUpAnotherPhone() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.addFile(1, ext: "flac", bytes: 100)
        try rig.addFile(2, ext: "flac", bytes: 100)
        let disk = SlowDisk()
        await rig.preparer.setReadHook { disk.before($0) }
        let slow = try #require(opened(await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil)))
        let quick = try #require(opened(await rig.preparer.open(client: "b", id: 2, maxSampleRate: nil)))
        disk.hold(1)
        let preparer = rig.preparer
        let stuck = Task { await preparer.read(client: "a", request: 1, stream: slow.stream, offset: 0, length: 10) }
        for _ in 0..<200 where disk.blocked == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(disk.blocked == 1)
        // Phone b reads, opens and closes while a's read is still stuck.
        #expect(chunk(await rig.preparer.read(client: "b", request: 2, stream: quick.stream, offset: 0, length: 10))?.payload.count == 10)
        #expect(await rig.preparer.activity().count == 2)
        disk.release(1)
        #expect(chunk(await stuck.value)?.payload.count == 10)
    }

    @Test func theMacCanSayWhichPhonePlaysWhat() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.addFile(1, ext: "flac", bytes: 100)
        try rig.addFile(2, ext: "ape", bytes: 100)
        _ = try #require(opened(await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil)))
        _ = try #require(await settle { await rig.preparer.open(client: "b", id: 2, maxSampleRate: nil) })
        let activity = await rig.preparer.activity().sorted { $0.client < $1.client }
        #expect(activity.map(\.client) == ["a", "b"])
        #expect(activity.map(\.song) == [1, 2])
        #expect(activity.map(\.kind) == [.original, .flac])
        await rig.preparer.closeAll(client: "a")
        #expect(await rig.preparer.activity().map(\.client) == ["b"])
    }

    @Test func aPhoneWhoseLeaveWasTakenAwayLosesItsStreamsAtOnce() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.addFile(1, ext: "flac", bytes: 100)
        let d = try #require(opened(await rig.preparer.open(client: "phone#1", id: 1, maxSampleRate: nil)))
        _ = try #require(opened(await rig.preparer.open(client: "other#2", id: 1, maxSampleRate: nil)))
        await rig.preparer.closeAll(clientsOf: "phone")
        if case .chunk = await rig.preparer.read(client: "phone#1", request: 1, stream: d.stream, offset: 0, length: 10) { Issue.record("still open") }
        #expect(await rig.preparer.activity().map(\.client) == ["other#2"])
    }
}

@Suite struct CacheControls {
    @Test func emptyingTheCacheKeepsWhatAPhoneIsReading() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.addFile(1, ext: "ape", bytes: 100)
        try rig.addFile(2, ext: "ape", bytes: 100)
        let playing = try #require(await settle { await rig.preparer.open(client: "a", id: 1, maxSampleRate: nil) })
        let other = try #require(await settle { await rig.preparer.open(client: "a", id: 2, maxSampleRate: nil) })
        await rig.preparer.close(client: "a", stream: other.stream)
        #expect(await rig.preparer.cacheBytes() == Int64(FakeTranscoder.flacBytes.count * 2))
        await rig.preparer.clearCache()
        #expect(await rig.preparer.cacheBytes() == Int64(FakeTranscoder.flacBytes.count))
        #expect(chunk(await rig.preparer.read(client: "a", request: 1, stream: playing.stream, offset: 0, length: 100)) != nil)
    }

    @Test func aSmallerLimitTakesEffectAtOnce() async throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        for id in 1...3 { try rig.addFile(Int64(id), ext: "ape", bytes: 100 + id) }
        for id in 1...3 {
            let d = try #require(await settle { await rig.preparer.open(client: "a", id: Int64(id), maxSampleRate: nil) })
            await rig.preparer.close(client: "a", stream: d.stream)
        }
        #expect(await rig.preparer.cacheBytes() == Int64(FakeTranscoder.flacBytes.count * 3))
        await rig.preparer.setCacheLimit(Int64(FakeTranscoder.flacBytes.count + 10))
        #expect(await rig.preparer.cacheBytes() == Int64(FakeTranscoder.flacBytes.count))
    }
}

/// Asks until the stream is ready (the conversion runs in the background), up to two seconds.
private func settle(_ ask: @escaping () async -> StreamPreparer.Opened) async -> StreamDescriptor? {
    for _ in 0..<200 {
        switch await ask() {
        case .ready(let d): return d
        case .failed: return nil
        case .preparing: try? await Task.sleep(for: .milliseconds(10))
        }
    }
    return nil
}
