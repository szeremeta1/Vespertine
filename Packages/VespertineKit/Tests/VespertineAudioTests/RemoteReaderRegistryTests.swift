//
// Vespertine: songs whose URL has a scheme of its own (tidal://track/1) are staged in the playback cache through a registered
// reader, the way a share's files are copied, and play through the same engine.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

/// A remote track whose bytes are a FLAC file's: what a streaming service's reader hands the cache.
private final class FakeTidalReader: RemoteCacheReader, @unchecked Sendable {
    let bytes: Data
    let fileExtension: String
    var size: Int64 { Int64(bytes.count) }
    init(_ bytes: Data, fileExtension: String = "flac") { self.bytes = bytes; self.fileExtension = fileExtension }
    func read(at offset: Int64, count: Int) throws -> Data {
        bytes.subdata(in: Int(offset)..<min(Int(offset) + count, bytes.count))
    }
}

@Suite("Remote readers in the playback cache", .serialized)
struct RemoteReaderRegistryTests {
    private static let fixture = Bundle.module.url(forResource: "stereo24", withExtension: "flac", subdirectory: "Fixtures/Formats")!
    private static let opened = Locked<[URL]>([])

    /// Registers the `tidal` scheme over the fixture's bytes (the registry is process-wide; every test here registers the same).
    private func register() throws {
        let bytes = try Data(contentsOf: Self.fixture)
        NetworkPlaybackCache.registerRemoteReader(scheme: "tidal") { url in
            Self.opened.withLock { $0.append(url) }
            return FakeTidalReader(bytes)
        }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remote-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let track = URL(string: "tidal://track/1")!

    @Test("The engine stages a tidal:// item through the registry and plays the same PCM as the local file")
    func engineStagesAndRenders() async throws {
        try register()
        let rig = try PlayPauseRig(seconds: 1)
        let item = PlayableItem(url: track, cacheKey: "tidal:1")
        rig.engine.play(item)
        let playing = await rig.wait(timeout: 30) { $0.state == .playing && $0.position > 0.1 }
        #expect(playing, "plays: \(rig.engine.snapshot.state), \(rig.engine.snapshot.lastError ?? "-")")
        #expect(rig.audibleFrames > 0)
        #expect(Self.opened.withLock { $0.contains(track) })
        // The engine's staged copy is the entry under its key; decoding it gives the local file's PCM.
        let staged = try rig.cache.entry(key: "tidal:1", url: track)
        try staged.prepare(full: true, lead: 0, cancelled: { false })
        #expect(staged.url.pathExtension == "flac")
        let local = try GoldenRender.render([PlayableItem(url: Self.fixture)], device: GoldenDevices.dac)
        let remote = try GoldenRender.render([PlayableItem(url: staged.url)], device: GoldenDevices.dac)
        #expect(!local.sessions.isEmpty && local.sessions.allSatisfy { $0.frames > 0 })
        #expect(remote.sha256 == local.sha256)
        rig.engine.stop()
    }

    @Test("The cache file takes the reader's extension, not the URL's")
    func cacheFileExtension() throws {
        try register()
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = NetworkPlaybackCache(directory: dir, budget: 64 << 20)
        let entry = try cache.entry(key: "tidal:1", url: track)
        #expect(entry.url.pathExtension == "flac")
        try entry.prepare(full: true, lead: 0, cancelled: { false })
        #expect(try entry.read(at: 0, count: 4) == Data("fLaC".utf8))
    }

    @Test("Releasing the lease deletes the cache file")
    func leaseRelease() throws {
        try register()
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = NetworkPlaybackCache(directory: dir, budget: 64 << 20)
        var entry: NetworkPlaybackCache.Entry? = try cache.entry(key: "tidal:1", url: track)
        try entry!.prepare(full: true, lead: 0, cancelled: { false })
        let path = entry!.url.path
        #expect(FileManager.default.fileExists(atPath: path))
        entry = nil
        let end = Date().addingTimeInterval(10)
        while FileManager.default.fileExists(atPath: path), Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(cache.reservedBytes == 0)
    }

    @Test("A scheme nobody registered throws instead of crashing")
    func unregisteredScheme() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = NetworkPlaybackCache(directory: dir, budget: 64 << 20)
        #expect(throws: (any Error).self) { _ = try cache.entry(key: "x:1", url: URL(string: "unregistered://track/1")!) }
    }

    @Test("A copy whose reader died opens the track again through the same opener")
    func reopensThroughRegistry() throws {
        let bytes = try Data(contentsOf: Self.fixture)
        let opens = Locked(0)
        NetworkPlaybackCache.registerRemoteReader(scheme: "tidal") { _ in
            let n = opens.withLock { $0 += 1; return $0 }
            return n == 1 ? FailingFirstReader(bytes) : FakeTidalReader(bytes)
        }
        defer { try? register() }
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = NetworkPlaybackCache(directory: dir, budget: 64 << 20, chunk: 4096)
        let entry = try cache.entry(key: "tidal:1", url: track)
        try entry.prepare(full: true, lead: 0, cancelled: { false })
        #expect(try entry.read(at: 0, count: bytes.count) == bytes)
        #expect(opens.withLock { $0 } >= 2)
    }
}

/// A share's file handed to the cache as a remote track: what a streaming reader of a big FLAC looks like to it.
private final class RemoteShare: RemoteCacheReader, @unchecked Sendable {
    let share: ControlledShare
    var fileExtension: String { "flac" }
    var size: Int64 { share.size }
    init(_ share: ControlledShare) { self.share = share }
    func read(at offset: Int64, count: Int) throws -> Data { try share.read(at: offset, count: count) }
}

@Suite("A big remote FLAC starts on a prefix")
struct RemoteEarlyStartTests {
    @Test("A remote FLAC over 12 MiB plays while everything past its first 8 MiB is still to come (NetworkStart's early start)")
    func startsOnPrefix() async throws {
        let rig = try PlayPauseRig(seconds: 26, fileExtension: "flac", cacheClock: PlayPauseRig.slowCacheClock())
        try #require(rig.share.size > NetworkStart.smallestEarlyFile, "the fixture must be big enough to start early: \(rig.share.size)")
        // Its own scheme: the `tidal` one belongs to the suite above, and suites run side by side.
        NetworkPlaybackCache.registerRemoteReader(scheme: "remote-early") { [share = rig.share] _ in RemoteShare(share) }
        rig.share.goQuiet(from: 8 << 20)
        defer { rig.share.goQuiet(from: nil) }
        rig.engine.play(PlayableItem(url: URL(string: "remote-early://track/1")!, cacheKey: "remote-early:1"))
        let playing = await rig.wait(timeout: 30) { $0.state == .playing && $0.position > 0.2 }
        #expect(playing, "plays on its prefix: \(rig.engine.snapshot.state), \(rig.engine.snapshot.lastError ?? "-")")
        #expect(rig.audibleFrames > 0)
        let entry = try rig.cache.entry(key: "remote-early:1", url: URL(string: "remote-early://track/1")!)
        #expect(!entry.isComplete && entry.url.pathExtension == "flac", "the rest is still to come")
        rig.engine.stop()
    }
}

/// A remote reader whose reads past the first chunk wait until it is cancelled (a CDN retrying a dead link for ever).
private final class WaitingReader: RemoteCacheReader, @unchecked Sendable {
    let bytes: Data
    let condition = NSCondition()
    var cancelled = false
    let notAnsweringMessage: String?
    var fileExtension: String { "flac" }
    var size: Int64 { Int64(bytes.count) }
    init(_ bytes: Data, message: String? = nil) { self.bytes = bytes; notAnsweringMessage = message }
    func read(at offset: Int64, count: Int) throws -> Data {
        if offset >= 4096 {
            try condition.withLock {
                while !cancelled { condition.wait() }
                throw CancellationError()
            }
        }
        return bytes.subdata(in: Int(offset)..<min(Int(offset) + count, bytes.count))
    }
    func cancel() { condition.withLock { cancelled = true; condition.broadcast() } }
    var wasCancelled: Bool { condition.withLock { cancelled } }
}

@Suite("Remote readers are told when their copy is over")
struct RemoteReaderCancelTests {
    @Test("Releasing the lease, and giving up on a silent copy, both cancel the remote reader so its waiting reads return")
    func cancelsReader() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remote-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = NetworkPlaybackCache(directory: dir, budget: 64 << 20, chunk: 4096)
        let released = WaitingReader(Data(repeating: 1, count: 64 << 10))
        var entry: NetworkPlaybackCache.Entry? = try cache.entry(key: "a", url: URL(string: "x-remote://a")!, reader: released)
        try entry!.prepare(full: false, lead: 4096, cancelled: { false })
        entry = nil
        let end = Date().addingTimeInterval(5)
        while !released.wasCancelled, Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        #expect(released.wasCancelled)

        // A copy whose reads never come back fails with "not answering" after the no-progress limit, and lets its reader go.
        let clock = Locked(0.0)
        let quiet = NetworkPlaybackCache(directory: dir, budget: 64 << 20, chunk: 4096, noProgressLimit: 5, clock: { clock.withLock { $0 } })
        let silent = WaitingReader(Data(repeating: 2, count: 64 << 10))
        let stuck = try quiet.entry(key: "b", url: URL(string: "x-remote://b")!, reader: silent)
        Thread { Thread.sleep(forTimeInterval: 0.2); clock.withLock { $0 = 10 } }.start()
        #expect(throws: (any Error).self) { try stuck.prepare(full: true, lead: 0, cancelled: { false }) }
        #expect(silent.wasCancelled)
    }

    @Test("A silent remote copy fails with the reader's own message; one without a message keeps the share's")
    func notAnsweringMessage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remote-message-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for message in ["Service X isn't answering", nil] as [String?] {
            let clock = Locked(0.0)
            let cache = NetworkPlaybackCache(directory: dir, budget: 64 << 20, chunk: 4096, noProgressLimit: 5, clock: { clock.withLock { $0 } })
            let entry = try cache.entry(key: "m", url: URL(string: "x-remote://m")!, reader: WaitingReader(Data(repeating: 3, count: 64 << 10), message: message))
            Thread { Thread.sleep(forTimeInterval: 0.2); clock.withLock { $0 = 10 } }.start()
            do {
                try entry.prepare(full: true, lead: 0, cancelled: { false })
                Issue.record("a silent copy completed")
            } catch {
                guard case NetworkPlaybackCache.Failure.notAnswering = error else { Issue.record("failed with \(error)"); continue }
                #expect(error.localizedDescription == (message ?? NetworkPlaybackCache.Failure.notAnswering().localizedDescription))
                #expect(message != nil || error.localizedDescription.contains("share"))
            }
        }
    }

    @Test("A registered scheme's open that never returns fails with the scheme's message")
    func silentOpenMessage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remote-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let release = DispatchSemaphore(value: 0)
        NetworkPlaybackCache.registerRemoteReader(scheme: "x-silent-open", notAnsweringMessage: "Service Y isn't answering") { _ in
            release.wait()
            throw CancellationError()
        }
        defer { release.signal() }
        let clock = Locked(0.0)
        let cache = NetworkPlaybackCache(directory: dir, budget: 64 << 20, noProgressLimit: 5, clock: { clock.withLock { $0 } })
        Thread { Thread.sleep(forTimeInterval: 0.2); clock.withLock { $0 = 10 } }.start()
        do {
            _ = try cache.entry(key: "o", url: URL(string: "x-silent-open://o")!)
            Issue.record("opened")
        } catch {
            #expect(error.localizedDescription == "Service Y isn't answering")
        }
    }
}

/// A reader that fails every read with EIO from its second chunk on, for ever: only a fresh one reads.
private final class FailingFirstReader: RemoteCacheReader, @unchecked Sendable {
    let bytes: Data
    let notAnsweringMessage: String?
    var fileExtension: String { "flac" }
    var size: Int64 { Int64(bytes.count) }
    init(_ bytes: Data, message: String? = nil) { self.bytes = bytes; notAnsweringMessage = message }
    func read(at offset: Int64, count: Int) throws -> Data {
        if offset >= 4096 { throw POSIXError(.EIO) }
        return bytes.subdata(in: Int(offset)..<min(Int(offset) + count, bytes.count))
    }
}
