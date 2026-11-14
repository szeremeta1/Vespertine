//
// Vespertine: a stream that plays while it arrives: reads wait for their bytes, a read far ahead (a seek) is fetched before
// the gap behind it, and a Mac that stops answering is an error with words, not a hang.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteClient
import VespertineRemoteProtocol
@testable import VespertinePhonePlayer

private func descriptor(size: Int, chunk: Int = 1000) -> StreamDescriptor {
    StreamDescriptor(stream: 1, kind: .original, byteSize: Int64(size),
                     format: StreamFormat(codec: "FLAC", container: "flac", sampleRate: 44_100, bitDepth: 16, channels: 2, channelLabels: nil, lossless: true),
                     frames: nil, tag: "t", chunkSize: chunk)
}

private func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID()).flac") }

private func bytes(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 251) }) }

/// A Mac in memory that records what it was asked for.
private final class FakeMac: @unchecked Sendable {
    let data: Data
    private let lock = NSLock()
    private var _offsets: [Int64] = []
    private var failures: [Int64: Int]
    var delay: Duration = .zero
    var shortReads = false
    var alwaysFail = false

    init(data: Data, failing: [Int64: Int] = [:]) { self.data = data; failures = failing }

    var offsets: [Int64] { lock.withLock { _offsets } }

    func read(_ offset: Int64, _ length: Int) async throws -> StreamFrame {
        let fail = lock.withLock { () -> Bool in
            _offsets.append(offset)
            if let left = failures[offset], left > 0 { failures[offset] = left - 1; return true }
            return false
        }
        try await Task.sleep(for: delay)
        if fail || alwaysFail { throw RemoteLinkError.timedOut }
        let n = shortReads ? min(length, 300) : length
        let end = min(Int(offset) + n, data.count)
        let slice = offset >= Int64(data.count) ? Data() : data[Int(offset)..<end]
        return StreamFrame(request: 1, stream: 1, offset: offset, endOfStream: end >= data.count, payload: Data(slice))
    }
}

/// Runs a blocking read off the test's own thread, as the decoder's thread does.
private func blockingRead(_ source: StreamSource, at offset: Int64, length: Int, timeout: TimeInterval = 5) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread {
            do { continuation.resume(returning: try source.read(at: offset, length: length, timeout: timeout)) }
            catch { continuation.resume(throwing: error) }
        }
    }
}

@Suite("Stream source")
struct StreamSourceTests {
    @Test func theWholeStreamArrivesAndTheFileIsTheStream() async throws {
        let data = bytes(10_500)
        let mac = FakeMac(data: data)
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        let source = try StreamSource(descriptor: descriptor(size: data.count), file: url, read: mac.read)
        source.start()
        try await source.waitUntilComplete(timeout: 5)
        #expect(source.isComplete)
        #expect(source.bufferedBytes == Int64(data.count))
        source.close()
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func aReadGetsItsBytesBeforeTheStreamIsWhole() async throws {
        let data = bytes(40_000)
        let mac = FakeMac(data: data)
        mac.delay = .milliseconds(30)
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        let source = try StreamSource(descriptor: descriptor(size: data.count), file: url, read: mac.read, window: 2)
        source.start()
        let head = try await blockingRead(source, at: 0, length: 1500)
        #expect(head == data.prefix(1500))
        #expect(!source.isComplete)
        source.close()
    }

    @Test func aReadFarAheadIsFetchedBeforeTheGapBehindIt() async throws {
        let data = bytes(60_000)
        let mac = FakeMac(data: data)
        mac.delay = .milliseconds(20)
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        let source = try StreamSource(descriptor: descriptor(size: data.count), file: url, read: mac.read, window: 2)
        source.start()
        let far = try await blockingRead(source, at: 50_250, length: 500)
        #expect(far == data[50_250..<50_750])
        // It did not wait for the fifty chunks before it.
        #expect(mac.offsets.count < 20)
        #expect(mac.offsets.contains(50_000))
        // And the gap is still filled in afterwards.
        try await source.waitUntilComplete(timeout: 10)
        source.close()
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func aReadAcrossTheEndReturnsWhatThereIs() async throws {
        let data = bytes(2_300)
        let mac = FakeMac(data: data)
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        let source = try StreamSource(descriptor: descriptor(size: data.count), file: url, read: mac.read)
        source.start()
        #expect(try await blockingRead(source, at: 2_000, length: 1_000) == data[2_000...])
        #expect(try await blockingRead(source, at: 2_300, length: 10).isEmpty)
        source.close()
    }

    @Test func aReadThatFailsOnceIsTriedAgain() async throws {
        let data = bytes(5_000)
        let mac = FakeMac(data: data, failing: [2000: 1])
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        let source = try StreamSource(descriptor: descriptor(size: data.count), file: url, read: mac.read)
        source.start()
        try await source.waitUntilComplete(timeout: 5)
        source.close()
        #expect(try Data(contentsOf: url) == data)
        #expect(mac.offsets.filter { $0 == 2000 }.count == 2)
    }

    @Test func aMacThatStopsAnsweringFailsTheWaitingReadWithTheCause() async throws {
        let mac = FakeMac(data: bytes(5_000))
        mac.alwaysFail = true
        let url = tmp()
        let source = try StreamSource(descriptor: descriptor(size: 5_000), file: url, read: mac.read, attempts: 2)
        source.start()
        await #expect(throws: StreamSource.Failure.self) { _ = try await blockingRead(source, at: 0, length: 100) }
        #expect(source.failure != nil)
        source.close()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func afterAFailureRetryCarriesOnFromWhatIsThere() async throws {
        let data = bytes(4_000)
        let mac = FakeMac(data: data, failing: [1000: 2])
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        let source = try StreamSource(descriptor: descriptor(size: data.count), file: url, read: mac.read, window: 1, attempts: 2)
        source.start()
        await #expect(throws: StreamSource.Failure.self) { try await source.waitUntilComplete(timeout: 5) }
        source.retry()
        try await source.waitUntilComplete(timeout: 5)
        source.close()
        #expect(try Data(contentsOf: url) == data)
        // The first chunk was not fetched a second time.
        #expect(mac.offsets.filter { $0 == 0 }.count == 1)
    }

    @Test func aReadWithNoBytesInTimeTimesOutInsteadOfHanging() async throws {
        let mac = FakeMac(data: bytes(3_000))
        mac.delay = .seconds(5)
        let url = tmp()
        let source = try StreamSource(descriptor: descriptor(size: 3_000), file: url, read: mac.read)
        source.start()
        await #expect(throws: StreamSource.Failure.timedOut) { _ = try await blockingRead(source, at: 0, length: 10, timeout: 0.15) }
        source.close()
    }

    @Test func closingWakesAWaitingReadAndRemovesTheHalfFile() async throws {
        let mac = FakeMac(data: bytes(30_000))
        mac.delay = .milliseconds(300)
        let url = tmp()
        let source = try StreamSource(descriptor: descriptor(size: 30_000), file: url, read: mac.read)
        source.start()
        let waiting = Task { try await blockingRead(source, at: 20_000, length: 10) }
        try await Task.sleep(for: .milliseconds(60))
        source.close()
        await #expect(throws: StreamSource.Failure.closed) { _ = try await waiting.value }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aReadAheadLimitStopsFetchingFarPastWhatIsBeingRead() async throws {
        let data = bytes(50_000)
        let mac = FakeMac(data: data)
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        let source = try StreamSource(descriptor: descriptor(size: data.count), file: url, read: mac.read, window: 2, readAhead: 5_000)
        source.start()
        _ = try await blockingRead(source, at: 0, length: 100)
        try await Task.sleep(for: .milliseconds(200))
        #expect(source.bufferedBytes <= 8_000)
        #expect(!source.isComplete)
        // Reading on lets it fetch on.
        _ = try await blockingRead(source, at: 10_000, length: 100)
        try await Task.sleep(for: .milliseconds(200))
        #expect(source.bufferedBytes >= 10_000)
        source.close()
    }

    @Test func shortAnswersAreAskedForTheRest() async throws {
        let data = bytes(3_000)
        let mac = FakeMac(data: data)
        mac.shortReads = true
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        let source = try StreamSource(descriptor: descriptor(size: data.count), file: url, read: mac.read)
        source.start()
        try await source.waitUntilComplete(timeout: 5)
        source.close()
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func bufferedAheadCountsOnlyTheUnbrokenRunFromAnOffset() async throws {
        let data = bytes(10_000)
        let mac = FakeMac(data: data)
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        let source = try StreamSource(descriptor: descriptor(size: data.count), file: url, read: mac.read)
        #expect(source.bufferedAhead(of: 0) == 0)
        source.start()
        try await source.waitUntilComplete(timeout: 5)
        #expect(source.bufferedAhead(of: 2_500) == 7_500)
        source.close()
    }

    @Test func aWholeFileFromAnEarlierPlayNeedsNoMac() async throws {
        let data = bytes(4_200)
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let mac = FakeMac(data: data)
        let source = try StreamSource(descriptor: descriptor(size: data.count), file: url, read: mac.read)
        #expect(source.isComplete)
        source.start()
        #expect(try await blockingRead(source, at: 4_000, length: 500) == data[4_000...])
        #expect(mac.offsets.isEmpty)
        source.close()
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
