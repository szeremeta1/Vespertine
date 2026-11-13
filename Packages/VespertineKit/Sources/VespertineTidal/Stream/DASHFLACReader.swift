//
// Vespertine: a TIDAL DASH stream (hi-res FLAC in fragmented MP4) read as the plain FLAC file it stands for, with random access.
// At open it reads the init segment and the first bytes of every media segment, which give the FLAC header and where each
// segment's audio lies; the total size is then exact, and any byte range maps to the header or to ranges of segments.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

public final class DASHFLACReader: RemoteCacheReader, @unchecked Sendable {
    /// One stretch of the output: `length` bytes of segment `segment` from `start` (its offset in the segment).
    struct Piece: Equatable {
        var output: Int64
        var segment: Int
        var start: Int64
        var length: Int64
    }

    public let size: Int64
    public let fileExtension: String
    public var notAnsweringMessage: String? { TidalError.notAnsweringMessage }
    let header: Data
    /// In output order, contiguous, after the header.
    let pieces: [Piece]
    /// Every segment's whole length, as the CDN reported it when indexing.
    private let segmentLengths: [Int64]
    private let source: RenewableStream
    private let client: CDNClient

    /// Segments indexed at once.
    static let indexConcurrency = 8
    /// What is asked first of each segment, and the next size when that holds no complete `moof` (it doubles after).
    static let firstProbe = 4096
    static let secondProbe = 64 << 10

    public convenience init(stream: TidalStream, renew: @escaping @Sendable () throws -> TidalStream,
                            session: URLSession = TidalCDN.session) throws {
        try self.init(stream: stream, renew: renew, session: session, retryDelay: TidalCDN.retryDelay)
    }

    init(stream: TidalStream, renew: @escaping @Sendable () throws -> TidalStream, session: URLSession,
         retryDelay: @escaping @Sendable (Int) -> TimeInterval) throws {
        guard case .dash(_, let segments) = stream.kind else { throw TidalError.malformedStream("a file stream was given to the DASH reader") }
        let count = segments.count
        guard count > 0 else { throw TidalError.malformedStream("the DASH stream has no media segments") }
        let source = RenewableStream(stream, renew: renew) { fresh in
            guard case .dash(_, let renewed) = fresh.kind, renewed.count == count else {
                throw TidalError.malformedStream("the renewed stream has other segments")
            }
        }
        let client = CDNClient(session: session, retryDelay: retryDelay)
        self.source = source
        self.client = client
        fileExtension = stream.fileExtension
        let deadline = Date().addingTimeInterval(TidalCDN.openRetryLimit)

        let initData = try client.fetch(source, url: { try Self.initialization($0) }, range: nil, deadline: deadline).data
        header = try DASHFLACLayout.flacHeader(fromInit: initData)

        // The segments' layouts, 8 requests at a time. The first failure stops the rest.
        let results = Locked<[Int: Result<(payloads: [Range<Int>], length: Int64), Error>]>([:])
        let failed = Locked(false)
        DispatchQueue.concurrentPerform(iterations: min(Self.indexConcurrency, count)) { lane in
            var index = lane
            while index < count, !failed.withLock({ $0 }) {
                let result = Result { try Self.index(segment: index, source: source, client: client, deadline: deadline) }
                if case .failure = result { failed.withLock { $0 = true } }
                results.withLock { $0[index] = result }
                index += Self.indexConcurrency
            }
        }
        let indexed = results.withLock { $0 }
        if let failure = indexed.values.first(where: { if case .failure = $0 { true } else { false } }), case .failure(let error) = failure {
            throw error
        }
        var pieces: [Piece] = []
        var lengths: [Int64] = []
        var offset = Int64(header.count)
        for segment in 0..<count {
            guard case .success(let layout) = indexed[segment] else { throw TidalError.malformedStream("segment \(segment + 1) wasn't indexed") }
            lengths.append(layout.length)
            for payload in layout.payloads where !payload.isEmpty {
                pieces.append(Piece(output: offset, segment: segment, start: Int64(payload.lowerBound), length: Int64(payload.count)))
                offset += Int64(payload.count)
            }
        }
        self.pieces = pieces
        segmentLengths = lengths
        size = offset
    }

    private static func initialization(_ stream: TidalStream) throws -> URL {
        guard case .dash(let initialization, _) = stream.kind else { throw TidalError.malformedStream("the stream is not DASH") }
        return initialization
    }

    private static func segmentURL(_ stream: TidalStream, _ index: Int) throws -> URL {
        guard case .dash(_, let segments) = stream.kind, segments.indices.contains(index) else {
            throw TidalError.malformedStream("the stream has no segment \(index + 1)")
        }
        return segments[index]
    }

    /// Where segment `index`'s audio is: read from its first bytes, more when a `moof` doesn't fit, and from the end of each
    /// fragment on until the fragments reach the segment's end exactly (bytes no fragment covers are malformed, never skipped).
    static func index(segment index: Int, source: RenewableStream, client: CDNClient, deadline: Date) throws
        -> (payloads: [Range<Int>], length: Int64) {
        var payloads: [Range<Int>] = []
        var start = 0
        var ask = firstProbe
        var length: Int64?
        while true {
            let range = Int64(start)...Int64(start + ask - 1)
            let answer = try client.fetch(source, url: { try segmentURL($0, index) }, range: range, deadline: deadline)
            guard let total = answer.total ?? (answer.status == 200 ? Int64(answer.data.count) : nil) else {
                throw TidalError.malformedStream("the CDN didn't say how long segment \(index + 1) is")
            }
            if let length, length != total { throw TidalError.malformedStream("segment \(index + 1) changed length while it was indexed") }
            length = total
            let prefix: Data
            if answer.status == 206 {
                prefix = answer.data
            } else {
                guard answer.data.count >= start else { throw TidalError.malformedStream("segment \(index + 1) is cut short") }
                prefix = answer.data.subdata(in: start..<min(answer.data.count, start + ask))
            }
            let reachesEnd = Int64(start + prefix.count) >= total
            guard let info = try DASHFLACLayout.mediaPayload(segmentPrefix: prefix) else {
                guard !reachesEnd, !prefix.isEmpty else {
                    throw TidalError.malformedStream("segment \(index + 1) has bytes after \(start) that no fragment covers")
                }
                ask = ask < secondProbe ? secondProbe : ask * 2
                continue
            }
            for payload in info.payloads {
                payloads.append((start + payload.lowerBound)..<(start + payload.upperBound))
            }
            let end = Int64(start + info.endOffset)
            if end == total { return (payloads, total) }
            guard end < total, info.endOffset > 0 else {
                throw TidalError.malformedStream("segment \(index + 1)'s fragments run past its end")
            }
            // More fragments follow: read on from where this one ended.
            start += info.endOffset
            ask = firstProbe
        }
    }

    public func read(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count >= 0 else { throw TidalError.malformedStream("a read before the start of the stream") }
        let end = min(size, offset + Int64(count))
        guard end > offset else { return Data() }
        var out = Data()
        out.reserveCapacity(Int(end - offset))
        var position = offset
        if position < Int64(header.count) {
            let upTo = min(end, Int64(header.count))
            out += header.subdata(in: Int(position)..<Int(upTo))
            position = upTo
        }
        var index = pieceIndex(containing: position)
        while position < end, index < pieces.count {
            let piece = pieces[index]
            let from = piece.start + (position - piece.output)
            let to = piece.start + min(piece.length, end - piece.output)
            let answer = try client.fetch(source, url: { [segment = piece.segment] in try Self.segmentURL($0, segment) }, range: from...(to - 1))
            out += try TidalHTTPReader.bytes(of: answer, range: from..<to, size: segmentLengths[piece.segment])
            position += to - from
            index += 1
        }
        return out
    }

    public func cancel() { client.cancel() }

    /// The piece holding output byte `offset` (past the header).
    private func pieceIndex(containing offset: Int64) -> Int {
        var low = 0, high = pieces.count
        while low < high {
            let middle = (low + high) / 2
            if pieces[middle].output + pieces[middle].length <= offset { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

/// A value behind a lock (the index lanes share their results).
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}
