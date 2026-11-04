//
// Vespertine — library scans make way for a song playing from a network share.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// How much of a network share's connection a library scan may use. macOS sends one share's requests over a single
/// SMB session, so a scan listing a dozen folders and reading a few dozen files at once queues the playing song's
/// reads behind all of them: on a slow link a song took 40 s to start and stalled every few seconds while
/// "Finding files" ran.
///
/// Three levels, strongest first:
/// - **Paused**: a song is being read from the share and needs the link (it was just requested, its copy is still
///   arriving, a read is waiting, or a live stream's buffer is low). No scan request starts; the ones already on
///   the wire finish. Scans carry on `healthyGrace` seconds after the last song stopped needing the link, so a
///   skip, a seek or a dip in the buffer doesn't make them flap.
/// - **Narrowed**: a song streams live from the share with a healthy buffer. Scans keep one request in flight.
/// - **Open**: nothing plays from a share.
public final class ShareIOGate: @unchecked Sendable {
    public static let shared = ShareIOGate()

    private let lock = NSLock()
    private var limit: Int?
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Songs that need the link now, by owner.
    private var demanders: Set<String> = []
    /// After the last song stopped needing the link: scans stay paused until then.
    private var holdUntil: Date?
    private var generation = 0

    /// While a song streams from a share.
    public static let whileStreaming = 1
    /// Seconds a healthy buffer must last before scans resume.
    public static let defaultHealthyGrace: TimeInterval = 5
    public let healthyGrace: TimeInterval

    public init(healthyGrace: TimeInterval = ShareIOGate.defaultHealthyGrace) {
        self.healthyGrace = max(0, healthyGrace)
    }

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

    /// True while no scan request may start because a song is using, or only just stopped using, the share.
    public var isPaused: Bool { lock.withLock { paused() } }

    /// `owner` needs the share's link for a song (`true`), or no longer does (`false`: scans resume after the
    /// grace period, or at once with `grace: false`, for a request that turned out not to touch a share).
    public func setPlaybackDemand(_ demanding: Bool, from owner: String, grace: Bool = true) {
        let (resumed, wake): ([CheckedContinuation<Void, Never>], (generation: Int, after: TimeInterval)?) = lock.withLock {
            if demanding {
                if demanders.insert(owner).inserted { generation += 1 }
                holdUntil = nil
                return ([], nil)
            }
            guard demanders.remove(owner) != nil else { return ([], nil) }
            generation += 1
            guard demanders.isEmpty else { return ([], nil) }
            if grace, healthyGrace > 0 {
                holdUntil = Date().addingTimeInterval(healthyGrace)
                return ([], (generation, healthyGrace))
            }
            holdUntil = nil
            return (admit(), nil)
        }
        resumed.forEach { $0.resume() }
        if let wake {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + wake.after + 0.01) { [weak self] in
                self?.release(ifUnchangedSince: wake.generation)
            }
        }
    }

    /// The player's view of the song it plays or is starting, once per poll.
    /// - `pending`: a song on a share was requested and hasn't started yet.
    /// - `streaming`: the song plays live from a share (not from a complete local copy).
    /// - `bufferFill`: how full the output buffer is, 0...1. Below a third (or buffering) a live stream needs the
    ///   link; above two thirds it doesn't; in between it stays as it was.
    public func playerState(pending: Bool, streaming: Bool, buffering: Bool, bufferFill: Double) {
        let wasDemanding = lock.withLock { demanders.contains("player") }
        let starved = buffering || bufferFill < 1.0 / 3 || (wasDemanding && bufferFill < 2.0 / 3)
        setPlaybackDemand(pending || (streaming && starved), from: "player")
        let wanted = streaming ? Self.whileStreaming : nil
        if maxInFlight != wanted { maxInFlight = wanted }
    }

    /// Waits for a turn (at once when nothing streams). Every call is paired with `leave()`.
    public func enter() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let go: Bool = lock.withLock {
                if waiters.isEmpty, open() {
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

    private func release(ifUnchangedSince stamp: Int) {
        let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard generation == stamp, demanders.isEmpty else { return [] }
            holdUntil = nil
            return admit()
        }
        resumed.forEach { $0.resume() }
    }

    /// Called with the lock held.
    private func paused() -> Bool {
        if !demanders.isEmpty { return true }
        if let holdUntil {
            if Date() < holdUntil { return true }
            self.holdUntil = nil
        }
        return false
    }

    /// Whether another request may start. Called with the lock held.
    private func open() -> Bool {
        !paused() && (limit.map { inFlight < $0 } ?? true)
    }

    /// Hands free turns to waiters, first come first served. Called with the lock held.
    private func admit() -> [CheckedContinuation<Void, Never>] {
        var resumed: [CheckedContinuation<Void, Never>] = []
        while !waiters.isEmpty, open() {
            inFlight += 1
            resumed.append(waiters.removeFirst())
        }
        return resumed
    }
}
