//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio
@testable import VespertineLibrary

/// One SMB session to a slow server: requests are answered one at a time, in the order they arrive, each after
/// the round trip. A scan's requests and a song's reads share it, as they do over a real share.
private final class SlowLink: @unchecked Sendable {
    enum Kind { case scan, playback }
    let latency: TimeInterval
    private let wire = DispatchQueue(label: "test.slow-link")
    private let lock = NSLock()
    private var log: [(kind: Kind, at: Date)] = []

    init(latency: TimeInterval) { self.latency = latency }

    func request(_ kind: Kind) {
        wire.sync {
            Thread.sleep(forTimeInterval: latency)
            lock.withLock { log.append((kind, Date())) }
        }
    }

    func count(_ kind: Kind, from start: Date = .distantPast, to end: Date = .distantFuture) -> Int {
        lock.withLock { log.filter { $0.kind == kind && $0.at >= start && $0.at <= end }.count }
    }
}

/// The song's side of the link: every read of the staging copy is one request.
private final class LinkReader: PlaybackCacheReader, @unchecked Sendable {
    let size: Int64
    let link: SlowLink
    init(link: SlowLink, chunks: Int, chunk: Int) { self.link = link; size = Int64(chunks * chunk) }
    func read(at offset: Int64, count: Int) throws -> Data {
        link.request(.playback)
        return Data(repeating: 7, count: count)
    }
}

/// A library scan of the same share: a dozen folder listings and tag reads at once, each a few requests, going
/// through the scanner's own choke point (`LibraryScanner.onIOQueue`) until stopped.
private final class ScanLoad: @unchecked Sendable {
    private let stopped = Locked(false)
    private var tasks: [Task<Void, Never>] = []

    init(link: SlowLink, gate: ShareIOGate, width: Int = 12, requestsPerOp: Int = 1) {
        let stopped = self.stopped
        tasks = (0..<width).map { _ in
            Task.detached {
                while !stopped.withLock({ $0 }) {
                    await LibraryScanner.onIOQueue(network: true, gate: gate) {
                        for _ in 0..<requestsPerOp { link.request(.scan) }
                    }
                }
            }
        }
    }

    func stop() async {
        stopped.withLock { $0 = true }
        for task in tasks { await task.value }
    }
}

@Suite("Playing a song from a share comes before the library scan of it")
struct NetworkPriorityTests {
    private static let chunk = 4096
    private static let chunks = 10
    private static let latency = 0.02

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Press play: the staging copy of the song starts and the engine waits for all of it (output starts after).
    private func timeToAudioReady(link: SlowLink, gate: ShareIOGate) throws -> TimeInterval {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: Self.chunk, gate: gate)
        let reader = LinkReader(link: link, chunks: Self.chunks, chunk: Self.chunk)
        let pressed = Date()
        let entry = try cache.entry(key: "song", url: URL(fileURLWithPath: "/share/song.flac"), reader: reader)
        try entry.prepare(full: true, lead: 0, cancelled: { false })
        return Date().timeIntervalSince(pressed)
    }

    @Test("With a scan in flight, a play request is ready about as fast as with none (the scan makes way)")
    func playbackPreemptsScan() async throws {
        let link = SlowLink(latency: Self.latency)
        let idle = try timeToAudioReady(link: link, gate: ShareIOGate())

        // What the player does once a song is requested from a share: scans down to one request in flight.
        let gate = ShareIOGate()
        gate.maxInFlight = ShareIOGate.whileStreaming
        let scan = ScanLoad(link: link, gate: gate)
        defer { Task { await scan.stop() } }
        while link.count(.scan) < 5 { try await Task.sleep(for: .milliseconds(5)) }   // the scan is under way

        let pressed = Date()
        let busy = try timeToAudioReady(link: link, gate: gate)
        let during = link.count(.scan, from: pressed, to: Date())
        await scan.stop()

        // Before the fix the scan's requests alternate with the song's on the wire: about twice as long.
        #expect(busy < idle * 1.3 + 0.03, "ready after \(busy) s with a scan, \(idle) s without")
        // Only requests already on their way when play was pressed may still go through.
        #expect(during <= 2, "\(during) scan requests went over the link while the song was being copied")
    }
}
