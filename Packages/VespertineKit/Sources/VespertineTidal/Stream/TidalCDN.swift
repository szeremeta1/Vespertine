//
// Vespertine: blocking, cancellable range requests to TIDAL's CDN for the stream readers (they run on the playback cache's copy
// threads), with the retry policy of the design: an expired URL is resolved again, a lost connection is retried after growing
// waits (2 s, 4 s, 6 s…), as are a CDN's 502, 503 and 504, and any other answer fails the read.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum TidalCDN {
    /// The CDN's session: ephemeral and without a URL cache, so no audio byte lands in a cache on disk (or in memory) of the
    /// system's; the playback cache's own file is the only copy.
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: configuration)
    }()

    /// The wait before the `attempt`th retry of a transport failure (1-based): 2 s, 4 s, 6 s…, as TidalSwiftLib's `HLSDownloader`.
    public static func retryDelay(_ attempt: Int) -> TimeInterval { 2 * Double(max(1, attempt)) }

    /// How long opening a stream (its size, its DASH index) keeps retrying a lost connection: the playback cache gives up on an
    /// open after the same time (`NetworkPlaybackCache.defaultNoProgressLimit`), so an open nobody waits for ends too.
    static let openRetryLimit: TimeInterval = 120

    /// URL errors that a moment later may not happen again: the link dropped or timed out.
    static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            true
        default:
            false
        }
    }
}

/// The stream a reader fetches from, renewed when its URLs expire. Every renewal bumps `generation`, so of several reads that hit
/// the same expired URL only the first asks TIDAL again; the others retry with what it got.
final class RenewableStream: @unchecked Sendable {
    private let lock = NSLock()
    private let renewing = NSLock()
    private var stream: TidalStream
    private var generation = 0
    private let renew: @Sendable () throws -> TidalStream
    private let check: (TidalStream) throws -> Void

    init(_ stream: TidalStream, renew: @escaping @Sendable () throws -> TidalStream, check: @escaping (TidalStream) throws -> Void) {
        self.stream = stream
        self.renew = renew
        self.check = check
    }

    var current: (stream: TidalStream, generation: Int) { lock.withLock { (stream, generation) } }

    /// Resolves the stream again unless someone already did since `seen`.
    func renew(after seen: Int) throws {
        renewing.lock()
        defer { renewing.unlock() }
        guard lock.withLock({ generation == seen }) else { return }
        let fresh = try renew()
        try check(fresh)
        lock.withLock { stream = fresh; generation += 1 }
    }
}

/// One reader's requests: each blocks its thread until the answer, and `cancel()` ends every one waiting (and every wait between
/// retries) at once, with `CancellationError`.
final class CDNClient: @unchecked Sendable {
    struct Answer {
        var data: Data
        var status: Int
        /// The resource's whole length: from `Content-Range` for a 206, `Content-Length` for a 200.
        var total: Int64?
    }

    private let session: URLSession
    private let retryDelay: @Sendable (Int) -> TimeInterval
    private let condition = NSCondition()
    private var cancelled = false
    private var tasks: [Int: URLSessionTask] = [:]
    private var nextTask = 0

    init(session: URLSession, retryDelay: @escaping @Sendable (Int) -> TimeInterval) {
        self.session = session
        self.retryDelay = retryDelay
    }

    var isCancelled: Bool { condition.withLock { cancelled } }

    func cancel() {
        let running = condition.withLock { () -> [URLSessionTask] in
            cancelled = true
            condition.broadcast()
            return Array(tasks.values)
        }
        running.forEach { $0.cancel() }
    }

    /// `range` of the resource at the stream's URL (`url` picks it), or all of it. 403/410 renew the stream and retry the same
    /// range, once per renewal this read asks for; transport failures and 502/503/504 retry after growing waits, until `deadline` if there is one
    /// (otherwise for as long as the reader isn't cancelled: the cache's no-progress limit decides when a song gives up). Any other
    /// status is `TidalError.http`.
    func fetch(_ source: RenewableStream, url: (TidalStream) throws -> URL, range: ClosedRange<Int64>?, deadline: Date? = nil) throws -> Answer {
        var failures = 0
        var renewedTo: Int?
        while true {
            if isCancelled { throw CancellationError() }
            let (stream, generation) = source.current
            var request = URLRequest(url: try url(stream), cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
            if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
            let data: Data, response: HTTPURLResponse
            do {
                (data, response) = try send(request)
            } catch let error as URLError where TidalCDN.isTransient(error) {
                failures += 1
                if let deadline, Date() >= deadline { throw error }
                try pause(retryDelay(failures))
                continue
            }
            switch response.statusCode {
            case 200, 206:
                return Answer(data: data, status: response.statusCode, total: Self.total(of: response))
            case 502, 503, 504:
                // A CDN edge that is overloaded or between deployments: like a lost connection, it may answer a moment later.
                failures += 1
                if let deadline, Date() >= deadline { throw TidalError.http(status: response.statusCode, body: Self.text(data)) }
                try pause(retryDelay(failures))
            case 403, 410:
                // An expired URL. A second refusal of the URL this read itself renewed to is not expiry.
                if renewedTo == generation { throw TidalError.http(status: response.statusCode, body: Self.text(data)) }
                try source.renew(after: generation)
                renewedTo = source.current.generation
            default:
                throw TidalError.http(status: response.statusCode, body: Self.text(data))
            }
        }
    }

    private func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let done = NSCondition()
        nonisolated(unsafe) var result: Result<(Data, HTTPURLResponse), Error>?
        let task = session.dataTask(with: request) { data, response, error in
            let value: Result<(Data, HTTPURLResponse), Error>
            if let error { value = .failure(error) }
            else if let http = response as? HTTPURLResponse { value = .success((data ?? Data(), http)) }
            else { value = .failure(URLError(.badServerResponse)) }
            done.withLock { result = value; done.broadcast() }
        }
        let id = try condition.withLock { () -> Int in
            if cancelled { throw CancellationError() }
            nextTask += 1
            tasks[nextTask] = task
            return nextTask
        }
        defer { condition.withLock { tasks[id] = nil } }
        task.resume()
        let outcome = done.withLock { () -> Result<(Data, HTTPURLResponse), Error> in
            while result == nil { done.wait() }
            return result!
        }
        if isCancelled { throw CancellationError() }
        return try outcome.get()
    }

    /// Waits `seconds`, or less if the reader is cancelled meanwhile (then throws).
    private func pause(_ seconds: TimeInterval) throws {
        let until = Date().addingTimeInterval(seconds)
        try condition.withLock {
            while !cancelled && Date() < until { _ = condition.wait(until: until) }
            if cancelled { throw CancellationError() }
        }
    }

    private static func total(of response: HTTPURLResponse) -> Int64? {
        if let range = response.value(forHTTPHeaderField: "Content-Range"), let slash = range.lastIndex(of: "/") {
            return Int64(range[range.index(after: slash)...].trimmingCharacters(in: .whitespaces))
        }
        return response.expectedContentLength >= 0 ? response.expectedContentLength : nil
    }

    private static func text(_ data: Data) -> String { String(decoding: data.prefix(200), as: UTF8.self) }
}
