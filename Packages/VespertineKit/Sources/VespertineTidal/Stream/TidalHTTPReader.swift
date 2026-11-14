//
// Vespertine: a TIDAL stream that is one file on the CDN (a BTS manifest), read by byte ranges into the playback cache, which
// then gives it progressive start and seeking like a file on a share.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

public final class TidalHTTPReader: RemoteCacheReader, @unchecked Sendable {
    public let size: Int64
    public let fileExtension: String
    public var notAnsweringMessage: String? { TidalError.notAnsweringMessage }
    private let source: RenewableStream
    private let client: CDNClient

    /// Asks the CDN for the file's size (a one-byte range). `renew` resolves the track again when its URL has expired.
    public convenience init(stream: TidalStream, renew: @escaping @Sendable () throws -> TidalStream,
                            session: URLSession = TidalCDN.session) throws {
        try self.init(stream: stream, renew: renew, session: session, retryDelay: TidalCDN.retryDelay)
    }

    init(stream: TidalStream, renew: @escaping @Sendable () throws -> TidalStream, session: URLSession,
         retryDelay: @escaping @Sendable (Int) -> TimeInterval) throws {
        guard case .file = stream.kind else { throw TidalError.malformedStream("a DASH stream was given to the file reader") }
        source = RenewableStream(stream, renew: renew) { fresh in
            guard case .file = fresh.kind else { throw TidalError.malformedStream("the renewed stream is no longer one file") }
        }
        client = CDNClient(session: session, retryDelay: retryDelay)
        fileExtension = stream.fileExtension
        let answer = try client.fetch(source, url: Self.url, range: 0...0, deadline: Date().addingTimeInterval(TidalCDN.openRetryLimit))
        guard let total = answer.total ?? (answer.status == 200 ? Int64(answer.data.count) : nil), total >= 0 else {
            throw TidalError.malformedStream("the CDN didn't say how long the file is")
        }
        size = total
    }

    private static func url(_ stream: TidalStream) throws -> URL {
        guard case .file(let url) = stream.kind else { throw TidalError.malformedStream("the stream is not one file") }
        return url
    }

    public func read(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count >= 0 else { throw TidalError.malformedStream("a read before the start of the file") }
        let end = min(size, offset + Int64(count))
        guard end > offset else { return Data() }
        let answer = try client.fetch(source, url: Self.url, range: offset...(end - 1))
        return try Self.bytes(of: answer, range: offset..<end, size: size)
    }

    public func cancel() { client.cancel() }

    /// The bytes of `range` from an answer to a range request: a 206's body, or the matching slice of a 200 (a server that ignored
    /// the range). An answer for a file of another length means the URL now names other bytes: never mixed into the copy.
    static func bytes(of answer: CDNClient.Answer, range: Range<Int64>, size: Int64) throws -> Data {
        if let total = answer.total, total != size { throw TidalError.malformedStream("the stream changed length (\(size) to \(total) bytes)") }
        let wanted = Int(range.count)
        if answer.status == 206 {
            guard answer.data.count == wanted else { throw TidalError.malformedStream("the CDN sent \(answer.data.count) bytes of \(wanted)") }
            return answer.data
        }
        let start = Int(range.lowerBound)
        guard answer.data.count >= start + wanted else { throw TidalError.malformedStream("the CDN's answer is cut short") }
        return answer.data.subdata(in: start..<(start + wanted))
    }
}
