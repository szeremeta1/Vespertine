//
// Vespertine: the one door every TIDAL API call goes through. It adds the token and headers, keeps at most four calls in flight
// (playback first), refreshes an expired token once, and holds everything back after a rate-limit or abuse answer, so the
// account isn't flagged.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Who is waiting. A smaller value goes first.
public enum TidalPriority: Int, Comparable, Sendable {
    /// Resolving the stream of a track about to play.
    case playback = 0
    /// Something the user is looking at (search, an album page).
    case interactive = 1
    /// Library sync in the background.
    case sync = 2
    case download = 3

    public static func < (lhs: TidalPriority, rhs: TidalPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

public actor TidalGate {
    static let baseURL = "https://api.tidal.com/v1/"
    static let userAgent = "Mozilla/5.0 (Linux; Android 12; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/91.0.4472.114 Safari/537.36"
    static let clientVersion = "2025.7.16"
    static let maxInFlight = 4
    static let rateLimitBackoff: TimeInterval = 60
    static let abuseBackoff: TimeInterval = 1800

    private let auth: TidalAuth
    private let transport: HTTPTransport
    private let clock: @Sendable () -> Date
    /// Not used by the gate itself: a backoff refuses requests instead of sleeping through them. Kept so callers that build a
    /// gate for a retry policy of their own (the downloader's pause) can share one injected sleep.
    let sleep: @Sendable (TimeInterval) async throws -> Void

    private var inFlight = 0
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0
    private var currentBackoff: (until: Date, reason: String)?

    private struct Waiter {
        let id: UInt64
        let priority: TidalPriority
        let continuation: CheckedContinuation<Void, Error>
    }

    public init(auth: TidalAuth, transport: HTTPTransport,
                clock: @escaping @Sendable () -> Date = Date.init,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.auth = auth
        self.transport = transport
        self.clock = clock
        self.sleep = sleep
    }

    /// The backoff in force, for the UI; nil when requests are flowing.
    public var backoff: (until: Date, reason: String)? {
        guard let currentBackoff, currentBackoff.until > clock() else { return nil }
        return currentBackoff
    }

    /// Requests waiting for a free slot.
    var queuedCount: Int { waiters.count }

    // MARK: Public requests

    public func get(_ path: String, query: [String: String] = [:], priority: TidalPriority) async throws -> Data {
        try await perform(method: "GET", path: path, query: query, form: nil, priority: priority, ifMatch: nil).0
    }

    public func get<T: Decodable>(_ path: String, query: [String: String] = [:], priority: TidalPriority, as type: T.Type) async throws -> T {
        let data = try await get(path, query: query, priority: priority)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TidalError.http(status: 200, body: "Undecodable \(T.self): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
    }

    /// A GET whose answer's headers matter too (the `ETag` of a playlist).
    public func getResponse(_ path: String, query: [String: String] = [:], priority: TidalPriority) async throws -> (Data, HTTPURLResponse) {
        try await perform(method: "GET", path: path, query: query, form: nil, priority: priority, ifMatch: nil)
    }

    /// POST/PUT/DELETE with a form body. `ifMatch` is the playlist ETag; TIDAL reads it from `If-None-Match`.
    public func send(method: String, path: String, form: [String: String], priority: TidalPriority,
                     ifMatch: String? = nil) async throws -> (Data, HTTPURLResponse) {
        try await perform(method: method, path: path, query: [:], form: form, priority: priority, ifMatch: ifMatch)
    }

    // MARK: One request

    private func perform(method: String, path: String, query: [String: String], form: [String: String]?,
                         priority: TidalPriority, ifMatch: String?) async throws -> (Data, HTTPURLResponse) {
        try throwIfBackingOff()
        try await acquireSlot(priority)
        defer { releaseSlot() }
        // A backoff may have started while this request waited for its slot.
        try throwIfBackingOff()

        var token = try await auth.validAccessToken()
        var (data, response) = try await attempt(token: token, method: method, path: path, query: query, form: form, ifMatch: ifMatch)
        if response.statusCode == 401 {
            try await auth.forceRefresh(staleToken: token)
            try throwIfBackingOff()
            token = try await auth.validAccessToken()
            (data, response) = try await attempt(token: token, method: method, path: path, query: query, form: form, ifMatch: ifMatch)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw TidalError.http(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return (data, response)
    }

    private func attempt(token: String, method: String, path: String, query: [String: String], form: [String: String]?,
                         ifMatch: String?) async throws -> (Data, HTTPURLResponse) {
        var fields = query
        if let country = await auth.session?.countryCode { fields["countryCode"] = country }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var components = URLComponents(string: Self.baseURL + trimmed)!
        components.percentEncodedQuery = FormEncoding.encode(fields)
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.clientVersion, forHTTPHeaderField: "x-tidal-client-version")
        if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-None-Match") }
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(FormEncoding.encode(form).utf8)
        }
        let (data, response) = try await transport.send(request)
        // Look at every answer, the 401 included, before deciding anything: a rate limit must never be missed.
        try startBackoffIfNeeded(response, data)
        return (data, response)
    }

    // MARK: Backoff

    private func throwIfBackingOff() throws {
        guard let current = backoff else { return }
        throw TidalError.backingOff(remaining: current.until.timeIntervalSince(clock()), reason: current.reason)
    }

    /// Starts (or extends, never shortens) a backoff after a 429 or an abuse 403, and throws for it.
    private func startBackoffIfNeeded(_ response: HTTPURLResponse, _ data: Data) throws {
        let retryAfter = Self.retryAfter(response)
        let seconds: TimeInterval
        let reason: String
        let abuse: Bool
        if response.statusCode == 429 {
            seconds = retryAfter ?? Self.rateLimitBackoff
            reason = "rate limited (HTTP 429)"
            abuse = false
        } else if response.statusCode == 403, Self.isAbuse(data) {
            seconds = retryAfter ?? Self.abuseBackoff
            reason = "abuse detected (HTTP 403): \(String(decoding: data.prefix(200), as: UTF8.self))"
            abuse = true
        } else {
            return
        }
        let now = clock()
        let until = now.addingTimeInterval(seconds)
        // Never shorten a backoff that is already running.
        if let running = currentBackoff, running.until > now, running.until >= until {
            // keep it
        } else {
            currentBackoff = (until, reason)
        }
        if abuse { throw TidalError.abuse(retryAfter: seconds) }
        let held = currentBackoff!
        throw TidalError.backingOff(remaining: held.until.timeIntervalSince(now), reason: held.reason)
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Double(value.trimmingCharacters(in: .whitespaces)), seconds > 0 else { return nil }
        return seconds
    }

    private static func isAbuse(_ body: Data) -> Bool {
        let text = String(decoding: body, as: UTF8.self).lowercased()
        return text.contains("abuse") || text.contains("suspend")
    }

    // MARK: Slots

    private func acquireSlot(_ priority: TidalPriority) async throws {
        try Task.checkCancellation()
        if inFlight < Self.maxInFlight && waiters.isEmpty {
            inFlight += 1
            return
        }
        let id = nextWaiterID
        nextWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Hands the slot to the most urgent waiter (the oldest within a level), or frees it.
    private func releaseSlot() {
        guard let index = waiters.indices.min(by: { (waiters[$0].priority, waiters[$0].id) < (waiters[$1].priority, waiters[$1].id) }) else {
            inFlight -= 1
            return
        }
        waiters.remove(at: index).continuation.resume()
    }
}
