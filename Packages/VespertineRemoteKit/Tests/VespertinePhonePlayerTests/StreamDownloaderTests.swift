//
// Vespertine: the phone's side of a stream: ranges fetched a few at a time, written where they belong, however they arrive.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteClient
import VespertineRemoteProtocol
@testable import VespertinePhonePlayer

private func descriptor(size: Int) -> StreamDescriptor {
    StreamDescriptor(stream: 1, kind: .original,
                     byteSize: Int64(size),
                     format: StreamFormat(codec: "FLAC", container: "flac", sampleRate: 44_100, bitDepth: 16, channels: 2, channelLabels: nil, lossless: true),
                     frames: nil, tag: "t", chunkSize: 1000)
}

private func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("downloader-\(UUID()).flac") }

/// A Mac in memory: serves ranges of `data`, in whatever order and speed the test asks for.
private final class FakeReader: @unchecked Sendable {
    let data: Data
    private let lock = NSLock()
    private var _requests: [(Int64, Int)] = []
    private var failures: Set<Int64>
    var delays: (Int64) -> Duration = { _ in .zero }
    var shortReads = false

    init(data: Data, failOnce: Set<Int64> = []) { self.data = data; failures = failOnce }

    var requests: [(Int64, Int)] { lock.withLock { _requests } }

    func read(_ offset: Int64, _ length: Int) async throws -> StreamFrame {
        let shouldFail = lock.withLock { () -> Bool in
            _requests.append((offset, length))
            return failures.remove(offset) != nil
        }
        try await Task.sleep(for: delays(offset))
        if shouldFail { throw RemoteLinkError.timedOut }
        let n = shortReads ? min(length, 300) : length
        let end = min(Int(offset) + n, data.count)
        let slice = offset >= Int64(data.count) ? Data() : data[Int(offset)..<end]
        return StreamFrame(request: 1, stream: 1, offset: offset, endOfStream: end >= data.count, payload: Data(slice))
    }
}

@Suite struct Downloader {
    @Test func theWholeStreamLandsInTheFileByteForByte() async throws {
        let data = Data((0..<10_500).map { UInt8(truncatingIfNeeded: $0 &* 17) })
        let reader = FakeReader(data: data)
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        let downloader = StreamDownloader(descriptor: descriptor(size: data.count), destination: url, read: reader.read)
        try await downloader.run()
        #expect(try Data(contentsOf: url) == data)
        #expect(await downloader.downloaded == Int64(data.count))
    }

    @Test func chunksFinishingOutOfOrderStillLandInPlace() async throws {
        let data = Data((0..<8_000).map { UInt8(truncatingIfNeeded: $0 &* 5) })
        let reader = FakeReader(data: data)
        reader.delays = { offset in .milliseconds(Int(8 - offset / 1000) * 10) }   // the first chunk is the slowest
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        try await StreamDownloader(descriptor: descriptor(size: data.count), destination: url, read: reader.read).run()
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func aFewReadsAreInFlightButNotAll() async throws {
        let data = Data(count: 20_000)
        let reader = FakeReader(data: data)
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        let downloader = StreamDownloader(descriptor: descriptor(size: data.count), destination: url, read: reader.read, window: 3)
        try await downloader.run()
        #expect(reader.requests.count == 20)
        let peak = await downloader.peakInFlight
        #expect(peak <= 3 && peak >= 2)
    }

    @Test func aReadThatFailsOnceIsTriedAgain() async throws {
        let data = Data((0..<5_000).map { UInt8(truncatingIfNeeded: $0) })
        let reader = FakeReader(data: data, failOnce: [2000])
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        try await StreamDownloader(descriptor: descriptor(size: data.count), destination: url, read: reader.read).run()
        #expect(try Data(contentsOf: url) == data)
        #expect(reader.requests.filter { $0.0 == 2000 }.count == 2)
    }

    @Test func aReadThatKeepsFailingEndsTheDownloadAndLeavesNoFile() async throws {
        struct Always: Error {}
        let url = tmp()
        let downloader = StreamDownloader(descriptor: descriptor(size: 5_000), destination: url, read: { _, _ in throw Always() })
        await #expect(throws: Always.self) { try await downloader.run() }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aMacThatAnswersWithLessKeepsBeingAskedForTheRest() async throws {
        let data = Data((0..<3_000).map { UInt8(truncatingIfNeeded: $0 &* 3) })
        let reader = FakeReader(data: data)
        reader.shortReads = true
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        try await StreamDownloader(descriptor: descriptor(size: data.count), destination: url, read: reader.read).run()
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func aStreamThatEndsEarlyIsAnErrorNotASilentTruncation() async throws {
        let reader = FakeReader(data: Data(count: 2_500))   // the descriptor says 5000
        let url = tmp()
        let downloader = StreamDownloader(descriptor: descriptor(size: 5_000), destination: url, read: reader.read)
        await #expect(throws: StreamDownloader.Failure.self) { try await downloader.run() }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aFrameForAnotherRangeIsRefused() async throws {
        let url = tmp()
        let downloader = StreamDownloader(descriptor: descriptor(size: 2_000), destination: url, read: { offset, _ in
            StreamFrame(request: 1, stream: 1, offset: offset + 1, endOfStream: false, payload: Data(count: 1000))
        })
        await #expect(throws: StreamDownloader.Failure.self) { try await downloader.run() }
    }

    @Test func progressNeverGoesBackwardsAndEndsAtTheSize() async throws {
        let data = Data(count: 6_000)
        let reader = FakeReader(data: data)
        let seen = Seen()
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        try await StreamDownloader(descriptor: descriptor(size: data.count), destination: url, read: reader.read).run { seen.add($0) }
        #expect(seen.values == seen.values.sorted() && seen.values.last == 6_000)
    }

    @Test func cancellingRemovesTheHalfFile() async throws {
        let reader = FakeReader(data: Data(count: 50_000))
        reader.delays = { _ in .milliseconds(200) }
        let url = tmp()
        let downloader = StreamDownloader(descriptor: descriptor(size: 50_000), destination: url, read: reader.read)
        let task = Task { try await downloader.run() }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        _ = try? await task.value
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int64] = []
    func add(_ v: Int64) { lock.withLock { _values.append(v) } }
    var values: [Int64] { lock.withLock { _values } }
}
