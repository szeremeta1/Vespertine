//
// Vespertine: fetches a stream's bytes into a file on the phone, a few ranges at a time. The skeleton of the phone's source: the
// first player plays a finished file; reading ahead while it plays (and seeking inside what isn't here yet) builds on `downloaded`.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import VespertineRemoteProtocol

public actor StreamDownloader {
    public enum Failure: Error, Equatable {
        /// The Mac sent bytes for another range than the one asked for.
        case wrongRange(asked: Int64, got: Int64)
        /// The stream ended before the descriptor's size.
        case endedEarly(expected: Int64, got: Int64)
        case cannotWrite(String)
    }

    /// Reads up to `length` bytes of the stream from `offset`.
    public typealias Reader = @Sendable (_ offset: Int64, _ length: Int) async throws -> StreamFrame

    public let descriptor: StreamDescriptor
    public let destination: URL
    private let read: Reader
    private let window: Int
    private let attempts: Int
    private(set) public var downloaded: Int64 = 0
    private(set) public var peakInFlight = 0
    private var inFlight = 0
    private var handle: FileHandle?

    /// `window`: how many ranges are asked for at once. `attempts`: tries per range before the download fails.
    public init(descriptor: StreamDescriptor, destination: URL, read: @escaping Reader, window: Int = 4, attempts: Int = 3) {
        self.descriptor = descriptor
        self.destination = destination
        self.read = read
        self.window = max(1, window)
        self.attempts = max(1, attempts)
    }

    /// Downloads the whole stream to `destination` (which must not exist), reporting the bytes in so far. On failure or
    /// cancellation the half-written file is removed.
    public func run(progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.cannotWrite("\(destination.lastPathComponent) can’t be created")
        }
        do {
            let file = try FileHandle(forWritingTo: destination)
            handle = file
            let size = descriptor.byteSize
            let chunk = Int64(max(1, min(descriptor.chunkSize, RemoteProtocol.maximumChunk)))
            let count = Int((size + chunk - 1) / chunk)
            try await withThrowingTaskGroup(of: Int64.self) { group in
                var next = 0
                func startNext() {
                    guard next < count else { return }
                    let offset = Int64(next) * chunk
                    let length = Int(min(chunk, size - offset))
                    next += 1
                    group.addTask { [self] in try await fetch(offset: offset, length: length) }
                }
                for _ in 0..<min(window, count) { startNext() }
                while let bytes = try await group.next() {
                    downloaded += bytes
                    progress?(downloaded)
                    startNext()
                }
            }
            try handle?.close()
            handle = nil
            guard downloaded == size else { throw Failure.endedEarly(expected: size, got: downloaded) }
        } catch {
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// One range, in as many reads as the Mac needs to answer it in full; retried when a read fails.
    private func fetch(offset: Int64, length: Int) async throws -> Int64 {
        var done = 0
        while done < length {
            try Task.checkCancellation()
            let frame = try await readWithRetry(offset: offset + Int64(done), length: length - done)
            guard frame.offset == offset + Int64(done) else { throw Failure.wrongRange(asked: offset + Int64(done), got: frame.offset) }
            if frame.payload.isEmpty { throw Failure.endedEarly(expected: descriptor.byteSize, got: offset + Int64(done)) }
            let usable = min(frame.payload.count, length - done)
            try write(frame.payload.prefix(usable), at: offset + Int64(done))
            done += usable
        }
        return Int64(length)
    }

    private func readWithRetry(offset: Int64, length: Int) async throws -> StreamFrame {
        var lastError: Error?
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            inFlight += 1
            peakInFlight = max(peakInFlight, inFlight)
            defer { inFlight -= 1 }
            do { return try await read(offset, length) } catch {
                lastError = error
                if error is CancellationError { throw error }
                try? await Task.sleep(for: .milliseconds(50 * (attempt + 1)))
            }
        }
        throw lastError ?? Failure.cannotWrite("")
    }

    private func write(_ data: Data, at offset: Int64) throws {
        guard let handle else { throw CancellationError() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
        } catch {
            throw Failure.cannotWrite(error.localizedDescription)
        }
    }
}
