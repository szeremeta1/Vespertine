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
    private var order: [Kind] = []

    init(latency: TimeInterval) { self.latency = latency }

    func request(_ kind: Kind) {
        wire.sync {
            Thread.sleep(forTimeInterval: latency)
            lock.withLock { log.append((kind, Date())); order.append(kind) }
        }
    }

    /// How many requests have gone over the link so far, in order: a position to measure from, with no clock.
    var position: Int { lock.withLock { order.count } }

    /// The order the requests went over the link in, from `start` on.
    func sequence(from start: Int = 0) -> [Kind] { lock.withLock { Array(order[start...]) } }

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

/// A song whose bytes can be held back (the server stops answering) and released.
private final class StallableReader: PlaybackCacheReader, @unchecked Sendable {
    let size: Int64
    private let condition = NSCondition()
    private var stalled = true
    init(chunks: Int, chunk: Int) { size = Int64(chunks * chunk) }
    func read(at offset: Int64, count: Int) throws -> Data {
        condition.lock(); defer { condition.unlock() }
        while stalled { condition.wait() }
        return Data(repeating: 7, count: count)
    }
    func release() { condition.lock(); stalled = false; condition.broadcast(); condition.unlock() }
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
    private func copySong(link: SlowLink, gate: ShareIOGate) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: Self.chunk, gate: gate)
        let reader = LinkReader(link: link, chunks: Self.chunks, chunk: Self.chunk)
        let entry = try cache.entry(key: "song", url: URL(fileURLWithPath: "/share/song.flac"), reader: reader)
        try entry.prepare(full: true, lead: 0, cancelled: { false })
    }

    @Test("With a scan in flight, the song's copy goes over the link without the scan's requests between (the scan makes way)")
    func playbackPreemptsScan() async throws {
        let link = SlowLink(latency: Self.latency)

        // What the player does once a song is requested from a share: scans down to one request in flight.
        let gate = ShareIOGate()
        gate.maxInFlight = ShareIOGate.whileStreaming
        let scan = ScanLoad(link: link, gate: gate)
        defer { Task { await scan.stop() } }
        while link.count(.scan) < 5 { try await Task.sleep(for: .milliseconds(5)) }   // the scan is under way

        // Where on the wire play is pressed, and what goes over it until the song is local. Counted in requests,
        // not seconds: a starved test machine stretches every round trip, never the order they go in.
        let pressed = link.position
        try copySong(link: link, gate: gate)
        let wire = link.sequence(from: pressed)
        await scan.stop()

        // Before the fix the scan's requests alternate with the song's on the wire, ten of them in the copy.
        // Only requests already on their way when play was pressed may still go through (the gate admits one).
        let songs = wire.indices.filter { wire[$0] == .playback }
        #expect(songs.count == Self.chunks, "the song's copy didn't go over the link in full: \(wire)")
        guard let first = songs.first, let last = songs.last else { return }
        #expect(first <= 2, "\(first) scan requests went first over the link after play was pressed: \(wire)")
        let between = wire[first...last].filter { $0 == .scan }.count
        #expect(between == 0, "\(between) scan requests went over the link in the middle of the song's copy: \(wire)")
    }

    private func settle(_ seconds: TimeInterval = 15, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("Scans start nothing while the song's copy is arriving, and carry on a few seconds after it is local")
    func scanPausesThenResumes() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let link = SlowLink(latency: 0.001)
        let gate = ShareIOGate(healthyGrace: 0.4)
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: Self.chunk, gate: gate)
        let reader = StallableReader(chunks: Self.chunks, chunk: Self.chunk)
        let entry = try cache.entry(key: "song", url: URL(fileURLWithPath: "/share/song.flac"), reader: reader)
        #expect(gate.isPaused)

        let scan = ScanLoad(link: link, gate: gate)
        defer { Task { await scan.stop() } }
        try await Task.sleep(for: .milliseconds(150))
        #expect(link.count(.scan) == 0, "the scan ran while the song's bytes were still coming")

        reader.release()
        try entry.prepare(full: true, lead: 0, cancelled: { false })
        let local = Date()
        #expect(entry.isComplete)
        try await Task.sleep(for: .milliseconds(150))
        #expect(link.count(.scan, from: local) == 0, "scans resumed before the buffer had been healthy for a while")
        await settle { link.count(.scan, from: local) > 0 }
        #expect(link.count(.scan, from: local) > 0, "scans never resumed")
        #expect(!gate.isPaused)
        await scan.stop()
    }

    @Test("A prefetched next song doesn't hold scans back; it does once it is the one playing")
    func prefetchWaitsItsTurn() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let gate = ShareIOGate(healthyGrace: 0)
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: Self.chunk, gate: gate)
        let reader = StallableReader(chunks: Self.chunks, chunk: Self.chunk)
        let next = try cache.entry(key: "next", url: URL(fileURLWithPath: "/share/next.flac"), reader: reader, foreground: false)
        #expect(!gate.isPaused)
        let promoted = try cache.entry(key: "next", url: URL(fileURLWithPath: "/share/next.flac"), reader: reader)
        #expect(promoted === next)
        #expect(gate.isPaused)
        reader.release()
        try next.prepare(full: true, lead: 0, cancelled: { false })
        #expect(!gate.isPaused)
    }

    @Test("Cancelling or skipping the song lets scans go (after the grace period)")
    func cancelledSongReleases() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let gate = ShareIOGate(healthyGrace: 0.2)
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: Self.chunk, gate: gate)
        let reader = StallableReader(chunks: Self.chunks, chunk: Self.chunk)
        let entry = try cache.entry(key: "song", url: URL(fileURLWithPath: "/share/song.flac"), reader: reader)
        #expect(gate.isPaused)
        entry.cancel()
        #expect(gate.isPaused)   // still inside the grace period
        await settle { !gate.isPaused }
        #expect(!gate.isPaused)
        reader.release()
    }

    @Test("A progressive copy holds scans back until its reserve ahead of the decoder is half full")
    func progressiveReserve() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let gate = ShareIOGate(healthyGrace: 0)
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: Self.chunk, gate: gate)
        let share = FileShare(chunks: 40, chunk: Self.chunk)
        let entry = try cache.entry(key: "dsd", url: URL(fileURLWithPath: "/share/song.dsf"), reader: share)
        share.allow(blocks: 8)
        try entry.prepare(full: false, lead: Int64(8 * Self.chunk), cancelled: { false })
        // Reserve full: the rest of the file is copied at leisure, scans are free to run.
        await settle { !gate.isPaused }
        #expect(!gate.isPaused)
        // The decoder eats into the reserve (reads 6 of its 8 blocks): under half is left, the link is wanted.
        _ = try entry.read(at: 0, count: 6 * Self.chunk)
        #expect(gate.isPaused)
        share.allow(blocks: 40)
        await settle { entry.isComplete }
        await settle { !gate.isPaused }
        #expect(!gate.isPaused)
    }

    @Test("Pressing play opens and copies the song at once, holding scans from that instant; a local song does neither")
    func warmedOnPress() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let song = dir.appendingPathComponent("song.flac")
        try Data(repeating: 9, count: Self.chunk * Self.chunks).write(to: song)
        let gate = ShareIOGate(healthyGrace: 0)
        let cache = NetworkPlaybackCache(directory: dir.appendingPathComponent("cache"), budget: 1 << 20, chunk: Self.chunk, gate: gate)

        cache.warm(key: "song", url: song, press: true) { true }
        #expect(gate.isPaused, "scans weren't held back as play was pressed")
        // The engine thread hasn't done anything yet (no prepare, no entry request): the copy is under way anyway.
        var entry: NetworkPlaybackCache.Entry?
        await settle { (try? cache.entry(key: "song", url: song)).map { entry = $0; return $0.isComplete } ?? false }
        #expect(entry?.isComplete == true)
        #expect(entry.map { (try? $0.read(at: 0, count: 16)) == Data(repeating: 9, count: 16) } == true)
        await settle { !gate.isPaused }
        #expect(!gate.isPaused)

        // Not a share after all (a local copy is used): scans are released at once and nothing is copied.
        let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("flac")
        try Data(repeating: 1, count: 100).write(to: other); defer { try? FileManager.default.removeItem(at: other) }
        let gate2 = ShareIOGate(healthyGrace: 30)
        let cache2 = NetworkPlaybackCache(directory: dir.appendingPathComponent("cache2"), budget: 1 << 20, chunk: Self.chunk, gate: gate2)
        cache2.warm(key: "local", url: other, press: true) { false }
        await settle { !gate2.isPaused }
        #expect(!gate2.isPaused)
        #expect(cache2.reservedBytes == 0)
    }

    @Test("The scanner's folder listing stops between folders while paused and finishes when released")
    func listingSuspends() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for album in 0..<6 {
            let folder = root.appendingPathComponent("album\(album)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(count: 10).write(to: folder.appendingPathComponent("01.flac"))
        }
        let gate = ShareIOGate(healthyGrace: 0)
        gate.setPlaybackDemand(true, from: "song")
        let listed = Counter()
        let listing = Task { () -> Int in
            let result = try await LibraryScanner.list(root, network: true, gate: gate) { _ in listed.increment() }
            return result.audio.count
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(listed.value == 0, "a folder was listed while a song was being read")
        #expect(gate.running == 0)
        gate.setPlaybackDemand(false, from: "song")
        #expect(try await listing.value == 6)
    }
}

/// A server that hands out only as many blocks as it is told to.
private final class FileShare: PlaybackCacheReader, @unchecked Sendable {
    let size: Int64
    private let chunk: Int
    private let condition = NSCondition()
    private var allowed = 0
    init(chunks: Int, chunk: Int) { size = Int64(chunks * chunk); self.chunk = chunk }
    func allow(blocks: Int) { condition.lock(); allowed = max(allowed, blocks); condition.broadcast(); condition.unlock() }
    func read(at offset: Int64, count: Int) throws -> Data {
        condition.lock(); defer { condition.unlock() }
        while Int(offset) / chunk >= allowed { condition.wait() }
        return Data(repeating: 5, count: count)
    }
}
