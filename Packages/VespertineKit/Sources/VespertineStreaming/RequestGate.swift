//
// Vespertine: the one door a provider's requests go through. At most a few are in flight, playback ahead of browsing ahead of
// sync, and when the server says to wait (429, or a Retry-After) everything is held back until it said, so an account is never
// hammered. Generalised from the gate marcocebrian wrote for TIDAL in #323: the slots, the priorities and the backoff are his.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

/// Who is waiting. A smaller value goes first.
public enum RequestPriority: Int, Comparable, Sendable {
    /// Something the song about to play needs.
    case playback = 0
    /// Something the listener is looking at (search, an album page, a sign-in).
    case browsing = 1
    /// Library sync in the background.
    case sync = 2

    public static func < (lhs: RequestPriority, rhs: RequestPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

public actor RequestGate {
    /// What the gate did, in order, for tests that judge it by events.
    public enum Event: Sendable, Equatable {
        case queued(RequestPriority)
        case started(RequestPriority)
        case finished(RequestPriority)
        case refused
        case waitBegan(seconds: TimeInterval)
    }

    public static let defaultWait: TimeInterval = 60

    private let maxInFlight: Int
    private let clock: @Sendable () -> Date
    private let onEvent: (@Sendable (Event) -> Void)?
    /// Read without waiting for the actor: a stream is opened on a thread that can't.
    private nonisolated let waiting = Locked<Date?>(nil)

    private var inFlight = 0
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0

    private struct Waiter {
        let id: UInt64
        let priority: RequestPriority
        let continuation: CheckedContinuation<Void, Error>
    }

    public init(maxInFlight: Int = 4, clock: @escaping @Sendable () -> Date = Date.init, onEvent: (@Sendable (Event) -> Void)? = nil) {
        self.maxInFlight = max(1, maxInFlight)
        self.clock = clock
        self.onEvent = onEvent
    }

    /// Until when the server asked to wait; nil while requests flow.
    public nonisolated var waitingUntil: Date? {
        guard let until = waiting.withLock({ $0 }), until > clock() else { return nil }
        return until
    }

    /// Requests waiting for a free slot.
    public var queuedCount: Int { waiters.count }

    /// Runs `body` when a slot is free, the most urgent first. While the server has asked to wait it is refused at once
    /// (`StreamingError.askedToWait`) and never sent.
    public func run<T: Sendable>(_ priority: RequestPriority, _ body: @Sendable () async throws -> T) async throws -> T {
        try throwIfWaiting()
        try await acquireSlot(priority)
        defer {
            onEvent?(.finished(priority))
            releaseSlot()
        }
        // The server may have asked to wait while this request stood in line.
        try throwIfWaiting()
        onEvent?(.started(priority))
        return try await body()
    }

    /// The server asked to wait: `retryAfter` seconds when it said how long. Extends a wait that is running, never shortens it.
    public nonisolated func askedToWait(retryAfter: TimeInterval?) {
        let seconds = retryAfter.flatMap { $0 > 0 ? $0 : nil } ?? Self.defaultWait
        let now = clock()
        let until = now.addingTimeInterval(seconds)
        let extended = waiting.withLock { current -> Bool in
            if let running = current, running > now, running >= until { return false }
            current = until
            return true
        }
        if extended { onEvent?(.waitBegan(seconds: seconds)) }
    }

    /// The seconds in a `Retry-After` header that gives seconds; nil for a date or nothing.
    public static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Double(value.trimmingCharacters(in: .whitespaces)), seconds > 0 else { return nil }
        return seconds
    }

    public nonisolated func throwIfWaiting() throws {
        guard let until = waitingUntil else { return }
        onEvent?(.refused)
        throw StreamingError.askedToWait(seconds: until.timeIntervalSince(clock()))
    }

    // MARK: Slots

    private func acquireSlot(_ priority: RequestPriority) async throws {
        try Task.checkCancellation()
        if inFlight < maxInFlight && waiters.isEmpty {
            inFlight += 1
            return
        }
        let id = nextWaiterID
        nextWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
                onEvent?(.queued(priority))
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
