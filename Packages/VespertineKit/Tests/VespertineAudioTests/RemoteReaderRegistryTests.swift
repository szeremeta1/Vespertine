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

/// A reader that fails every read with EIO from its second chunk on, for ever: only a fresh one reads.
private final class FailingFirstReader: RemoteCacheReader, @unchecked Sendable {
    let bytes: Data
    var fileExtension: String { "flac" }
    var size: Int64 { Int64(bytes.count) }
    init(_ bytes: Data) { self.bytes = bytes }
    func read(at offset: Int64, count: Int) throws -> Data {
        if offset >= 4096 { throw POSIXError(.EIO) }
        return bytes.subdata(in: Int(offset)..<min(Int(offset) + count, bytes.count))
    }
}
