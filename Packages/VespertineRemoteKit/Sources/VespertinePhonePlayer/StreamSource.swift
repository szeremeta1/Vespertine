//
// Vespertine: a stream that plays while it arrives. The bytes land in a file on the phone a few ranges at a time, starting where
// the decoder is reading; a read waits for its bytes, and a read far ahead (a seek into what isn't here yet) moves the fetching
// there first. Prior art on the Mac: `NetworkStart` and `NetworkPlaybackCache` (docs/NETWORK-PLAYBACK.md).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import VespertineRemoteProtocol

public final class StreamSource: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        /// The bytes did not arrive in the time the reader allowed.
        case timedOut
        /// The source was closed while the read waited.
        case closed
        /// The Mac stopped answering reads, after every retry. The text is the last error, for showing.
        case unreachable(String)
        /// The Mac answered with bytes for another range, or the stream ended before its size.
        case brokenStream(String)
        case cannotWrite(String)
    }

    public typealias Reader = StreamDownloader.Reader

    public let descriptor: StreamDescriptor
    public let file: URL
    private let reader: Reader
    private let window: Int
    private let attempts: Int
    private let readAhead: Int64?
    private let chunk: Int64
    private let size: Int64
    private let progress: (@Sendable (Int64) -> Void)?

    private let condition = NSCondition()
    private var covered: [Bool]
    private var claimed = Set<Int>()
    private var coveredBytes: Int64 = 0
    /// The chunk the fetching goes on from.
    private var priority = 0
    /// The end of the latest read: the read-ahead limit counts from here.
    private var readHead: Int64 = 0
    private var _failure: Failure?
    private var closed = false
    private var pump: Task<Void, Never>?
    /// Counts restarts, so the workers of a pump that failed stop instead of working beside the new one.
    private var generation = 0

    private let ioLock = NSLock()
    private var handle: FileHandle?

    /// `window`: ranges asked for at once. `attempts`: tries per range before the source fails. `readAhead`: how far past the
    /// latest read to fetch (nil: the whole stream, which then stays as a file for the next play).
    public init(descriptor: StreamDescriptor, file: URL, read: @escaping Reader, window: Int = 4, attempts: Int = 3,
                readAhead: Int64? = nil, progress: (@Sendable (Int64) -> Void)? = nil) throws {
        self.descriptor = descriptor
        self.file = file
        reader = read
        self.window = max(1, window)
        self.attempts = max(1, attempts)
        self.readAhead = readAhead
        self.progress = progress
        size = max(0, descriptor.byteSize)
        chunk = Int64(max(1, min(descriptor.chunkSize, RemoteProtocol.maximumChunk)))
        let count = Int((size + chunk - 1) / chunk)
        let manager = FileManager.default
        let existing = (try? manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
        if let existing, existing == size, size > 0 {
            // A whole file from an earlier play of this very stream.
            covered = Array(repeating: true, count: count)
            coveredBytes = size
        } else {
            covered = Array(repeating: false, count: count)
            try? manager.removeItem(at: file)
            guard manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw Failure.cannotWrite("\(file.lastPathComponent) can’t be created")
            }
        }
        do { handle = try FileHandle(forUpdating: file) } catch { throw Failure.cannotWrite(error.localizedDescription) }
    }

    deinit { close() }

    // MARK: State

    public var isComplete: Bool { condition.withLock { coveredBytes >= size } }
    public var bufferedBytes: Int64 { condition.withLock { coveredBytes } }
    public var failure: Failure? { condition.withLock { _failure } }

    /// The unbroken run of bytes on the phone from `offset` on: how much can play if the Mac went away now.
    public func bufferedAhead(of offset: Int64) -> Int64 {
        condition.withLock {
            guard offset >= 0, offset < size else { return 0 }
            var index = Int(offset / chunk)
            guard covered[index] else { return 0 }
            while index < covered.count, covered[index] { index += 1 }
            return min(size, Int64(index) * chunk) - offset
        }
    }

    // MARK: Fetching

    /// Starts (or, after `retry`, restarts) fetching. Does nothing when the stream is already whole.
    public func start() {
        condition.withLock {
            guard pump == nil, !closed, coveredBytes < size, _failure == nil else { return }
            let workers = window
            let mine = generation
            pump = Task.detached(priority: .userInitiated) { [weak self] in
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<workers { group.addTask { await self?.work(mine) } }
                }
                self?.pumpEnded(mine)
            }
        }
    }

    /// After a failure: forgets it and carries on from the bytes already here.
    public func retry() {
        let old: Task<Void, Never>? = condition.withLock {
            _failure = nil
            generation += 1
            let old = pump
            pump = nil
            return old
        }
        old?.cancel()
        start()
    }

    private func pumpEnded(_ mine: Int) {
        condition.withLock { if generation == mine { pump = nil } }
    }

    private enum Claim { case chunk(Int), wait, stop }

    private func claim(_ mine: Int) -> Claim {
        condition.withLock {
            if closed || generation != mine || _failure != nil || coveredBytes >= size { return .stop }
            let limit = readAhead.map { readHead + $0 } ?? Int64.max
            func free(_ i: Int) -> Bool { !covered[i] && !claimed.contains(i) }
            func allowed(_ i: Int) -> Bool { Int64(i) * chunk <= limit }
            var pick = (min(priority, covered.count)..<covered.count).first { free($0) && allowed($0) }
            if pick == nil { pick = (0..<min(priority, covered.count)).first { free($0) && allowed($0) } }
            guard let pick else { return .wait }
            claimed.insert(pick)
            return .chunk(pick)
        }
    }

    private func work(_ mine: Int) async {
        while !Task.isCancelled {
            switch claim(mine) {
            case .stop: return
            case .wait:
                try? await Task.sleep(for: .milliseconds(15))
            case .chunk(let index):
                do {
                    try await fetch(index)
                    landed(index)
                } catch {
                    failed(index, error)
                    return
                }
            }
        }
    }

    private func landed(_ index: Int) {
        let total: Int64 = condition.withLock {
            claimed.remove(index)
            if !covered[index] {
                covered[index] = true
                coveredBytes += length(of: index)
            }
            condition.broadcast()
            return coveredBytes
        }
        progress?(total)
    }

    private func failed(_ index: Int, _ error: Error) {
        condition.withLock {
            claimed.remove(index)
            if !(error is CancellationError), !closed, _failure == nil {
                _failure = (error as? Failure) ?? .unreachable((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            }
            condition.broadcast()
        }
    }

    private func length(of index: Int) -> Int64 { min(chunk, size - Int64(index) * chunk) }

    /// One chunk, in as many reads as the Mac needs to answer it in full; each read retried when it fails.
    private func fetch(_ index: Int) async throws {
        let start = Int64(index) * chunk
        let length = Int(length(of: index))
        var done = 0
        while done < length {
            let offset = start + Int64(done)
            let frame = try await readWithRetry(offset: offset, length: length - done)
            guard frame.offset == offset else { throw Failure.brokenStream("The Mac sent another part of the song than the one asked for.") }
            guard !frame.payload.isEmpty else { throw Failure.brokenStream("The song ended before its size.") }
            let usable = min(frame.payload.count, length - done)
            try write(frame.payload.prefix(usable), at: offset)
            done += usable
        }
    }

    private func readWithRetry(offset: Int64, length: Int) async throws -> StreamFrame {
        var last: Error = CancellationError()
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            do { return try await reader(offset, length) } catch {
                if error is CancellationError { throw error }
                last = error
                try? await Task.sleep(for: .milliseconds(50 * (attempt + 1)))
            }
        }
        throw last
    }

    private func write(_ data: Data, at offset: Int64) throws {
        try ioLock.withLock {
            guard let handle else { throw CancellationError() }
            do {
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: data)
            } catch {
                throw Failure.cannotWrite(error.localizedDescription)
            }
        }
    }

    // MARK: Reading

    /// Up to `length` bytes from `offset` (fewer only at the end of the stream), waiting for them to arrive. Blocks the calling
    /// thread, so it is for the decoder's thread, never the main one.
    public func read(at offset: Int64, length: Int, timeout: TimeInterval = 30) throws -> Data {
        guard offset >= 0, offset < size, length > 0 else { return Data() }
        let end = min(size, offset + Int64(length))
        let first = Int(offset / chunk)
        let last = Int((end - 1) / chunk)
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        readHead = end
        while true {
            if closed { condition.unlock(); throw Failure.closed }
            guard let missing = (first...last).first(where: { !covered[$0] }) else { break }
            if let failure = _failure { condition.unlock(); throw failure }
            // Fetch from here on: a seek into what isn't on the phone yet doesn't wait for the gap behind it.
            if !claimed.contains(missing) { priority = missing }
            if !condition.wait(until: deadline) {
                condition.unlock()
                throw Failure.timedOut
            }
        }
        condition.unlock()
        return try ioLock.withLock {
            guard let handle else { throw Failure.closed }
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: Int(end - offset)) ?? Data()
        }
    }

    /// Waits for the whole stream (tests, and "keep on this iPhone").
    public func waitUntilComplete(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if isComplete { return }
            if let failure { throw failure }
            if Date() >= deadline { throw Failure.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Stops fetching and wakes any waiting read. A stream that isn't whole leaves no file behind.
    public func close() {
        let (task, whole): (Task<Void, Never>?, Bool) = condition.withLock {
            guard !closed else { return (nil, true) }
            closed = true
            condition.broadcast()
            let task = pump
            pump = nil
            return (task, coveredBytes >= size)
        }
        task?.cancel()
        ioLock.withLock {
            try? handle?.close()
            handle = nil
        }
        if !whole { try? FileManager.default.removeItem(at: file) }
    }
}
