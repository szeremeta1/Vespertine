//
// Vespertine — library scans make way for a song playing from a network share.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// How much of a network share's connection a library scan may use. macOS sends one share's requests over a single
/// SMB session, so a scan listing a dozen folders and reading a few dozen files at once queues the playing song's
/// reads behind all of them: on a slow link a song took 40 s to start and stalled every few seconds while
/// "Finding files" ran. While a song streams from a share, scans keep one request in flight (they still finish,
/// just more slowly) and the song's reads go next.
public final class ShareIOGate: @unchecked Sendable {
    public static let shared = ShareIOGate()

    private let lock = NSLock()
    private var limit: Int?
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// While a song streams from a share.
    public static let whileStreaming = 1

    public init() {}

    /// The most scan requests on network shares at once, nil for no limit (nothing streams).
    public var maxInFlight: Int? {
        get { lock.withLock { limit } }
        set {
            let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
                limit = newValue.map { max(1, $0) }
                return admit()
            }
            resumed.forEach { $0.resume() }
        }
    }

    /// Scan requests in flight on network shares now.
    public var running: Int { lock.withLock { inFlight } }

    /// Waits for a turn (at once when nothing streams). Every call is paired with `leave()`.
    public func enter() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let go: Bool = lock.withLock {
                if waiters.isEmpty, limit.map({ inFlight < $0 }) ?? true {
                    inFlight += 1
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if go { continuation.resume() }
        }
    }

    public func leave() {
        let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
            inFlight -= 1
            return admit()
        }
        resumed.forEach { $0.resume() }
    }

    /// Hands free turns to waiters, first come first served. Called with the lock held.
    private func admit() -> [CheckedContinuation<Void, Never>] {
        var resumed: [CheckedContinuation<Void, Never>] = []
        while !waiters.isEmpty, limit.map({ inFlight < $0 }) ?? true {
            inFlight += 1
            resumed.append(waiters.removeFirst())
        }
        return resumed
    }
}
