//
// Vespertine: songs whose URL has a scheme of its own (stream://track/1) are staged in the playback cache through a registered
// reader, the way a share's files are copied, and play through the same engine.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

/// A remote track whose bytes are a FLAC file's: what a stream's reader hands the cache.
private final class FakeStreamReader: RemoteCacheReader, @unchecked Sendable {
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

    /// Registers the `stream` scheme over the fixture's bytes (the registry is process-wide; every test here registers the same).
    private func register() throws {
        let bytes = try Data(contentsOf: Self.fixture)
        NetworkPlaybackCache.registerRemoteReader(scheme: "stream") { url in
            Self.opened.withLock { $0.append(url) }
            return FakeStreamReader(bytes)
        }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remote-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let track = URL(string: "stream://track/1")!

    @Test("The engine stages a stream:// item through the registry and plays the same PCM as the local file")
    func engineStagesAndRenders() async throws {
        try register()
        let rig = try PlayPauseRig(seconds: 1)
        let item = PlayableItem(url: track, cacheKey: "stream:1")
        // Judged by what the engine says happened (the song became audible, or failed), however long a busy machine takes over it.
        let outcome = await EngineOutcome.ofPlaying(item, on: rig.engine)
        #expect(outcome == .started, "plays: \(outcome), \(rig.engine.snapshot.lastError ?? "-")")
        // Started is said as the song's first frames go out; they are heard a moment later.
        #expect(Patience.until { rig.audibleFrames > 0 })
        #expect(Self.opened.withLock { $0.contains(track) })
        // The engine's staged copy is the entry under its key; decoding it gives the local file's PCM.
        let staged = try rig.cache.entry(key: "stream:1", url: track)
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
        let entry = try cache.entry(key: "stream:1", url: track)
        #expect(entry.url.pathExtension == "flac")
        try entry.prepare(full: true, lead: 0, cancelled: { false })
        #expect(try entry.read(at: 0, count: 4) == Data("fLaC".utf8))
    }

    @Test("Releasing the lease deletes the cache file")
    func leaseRelease() throws {
        try register()
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = NetworkPlaybackCache(directory: dir, budget: 64 << 20)
        var entry: NetworkPlaybackCache.Entry? = try cache.entry(key: "stream:1", url: track)
        try entry!.prepare(full: true, lead: 0, cancelled: { false })
        let path = entry!.url.path
        #expect(FileManager.default.fileExists(atPath: path))
        entry = nil
        // The file goes when the copy's storage does, which also gives the reservation back: that is the event waited for.
        #expect(Patience.until { cache.reservedBytes == 0 })
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("A scheme nobody registered throws instead of crashing")
    func unregisteredScheme() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = NetworkPlaybackCache(directory: dir, budget: 64 << 20)
        #expect(throws: (any Error).self) { _ = try cache.entry(key: "x:1", url: URL(string: "unregistered://track/1")!) }
    }

    @Test("An unregistered scheme opens nothing any more (its switch went off)")
    func unregister() throws {
        let bytes = try Data(contentsOf: Self.fixture)
        NetworkPlaybackCache.registerRemoteReader(scheme: "gone") { _ in FakeStreamReader(bytes) }
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = NetworkPlaybackCache(directory: dir, budget: 64 << 20)
        #expect(NetworkPlaybackCache.hasRemoteReader(scheme: "gone"))
        _ = try cache.entry(key: "gone:1", url: URL(string: "gone://track/1")!)
        NetworkPlaybackCache.unregisterRemoteReader(scheme: "GONE")
        #expect(!NetworkPlaybackCache.hasRemoteReader(scheme: "gone"))
        #expect(throws: (any Error).self) { _ = try cache.entry(key: "gone:2", url: URL(string: "gone://track/2")!) }
    }

    @Test("A copy whose reader died opens the track again through the same opener")
    func reopensThroughRegistry() throws {
        let bytes = try Data(contentsOf: Self.fixture)
        let opens = Locked(0)
        NetworkPlaybackCache.registerRemoteReader(scheme: "stream") { _ in
            let n = opens.withLock { $0 += 1; return $0 }
            return n == 1 ? FailingFirstReader(bytes) : FakeStreamReader(bytes)
        }
        defer { try? register() }
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = NetworkPlaybackCache(directory: dir, budget: 64 << 20, chunk: 4096)
        let entry = try cache.entry(key: "stream:1", url: track)
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
        // Its own scheme: the `stream` one belongs to the suite above, and suites run side by side.
        NetworkPlaybackCache.registerRemoteReader(scheme: "remote-early") { [share = rig.share] _ in RemoteShare(share) }
        rig.share.goQuiet(from: 8 << 20)
        defer { rig.share.goQuiet(from: nil) }
        let outcome = await EngineOutcome.ofPlaying(PlayableItem(url: URL(string: "remote-early://track/1")!, cacheKey: "remote-early:1"), on: rig.engine)
        #expect(outcome == .started, "plays on its prefix: \(outcome), \(rig.engine.snapshot.lastError ?? "-")")
        #expect(Patience.until { rig.audibleFrames > 0 })
        let entry = try rig.cache.entry(key: "remote-early:1", url: URL(string: "remote-early://track/1")!)
        #expect(!entry.isComplete && entry.url.pathExtension == "flac", "the rest is still to come")
        rig.engine.stop()
    }
}

/// A cache's clock for the tests of silence: it stands still until a read is waiting, and from then on every look at it finds ten
/// seconds gone. A block that lands just after the wait began stamps its progress with a time the next look is already past, so
/// the limit is reached whatever order the copy's lanes run in.
private final class RunawayClock: Sendable {
    private let state = Locked((now: 0.0, running: false))
    var now: TimeInterval { state.withLock { if $0.running { $0.now += 10 }; return $0.now } }
    func run() { state.withLock { $0.running = true } }
}

/// A remote reader whose reads past the first chunk wait until it is cancelled (a CDN retrying a dead link for ever).
private final class WaitingReader: RemoteCacheReader, @unchecked Sendable {
    let bytes: Data
    let condition = NSCondition()
    var cancelled = false
    let notAnsweringMessage: String?
    var silenceLimit: TimeInterval?
    /// Asked each time the cache looks (nil: this source can't say).
    var quiet: (@Sendable () -> TimeInterval?)?
    var quietFor: TimeInterval? { condition.withLock { quiet }?() }
    /// Called once, when a read first waits: the moment a test may move the cache's clock past the limit. Given when the reader
    /// is made, never after: a cache starts copying the moment it is handed the reader, so a hook set after that could be set
    /// after the first read had already begun to wait, and the clock would then never move.
    private var whenWaiting: (@Sendable () -> Void)?
    var fileExtension: String { "flac" }
    var size: Int64 { Int64(bytes.count) }
    init(_ bytes: Data, message: String? = nil, whenWaiting: (@Sendable () -> Void)? = nil) {
        self.bytes = bytes; notAnsweringMessage = message; self.whenWaiting = whenWaiting
    }
    func read(at offset: Int64, count: Int) throws -> Data {
        if offset >= 4096 {
            let first = condition.withLock { () -> (@Sendable () -> Void)? in defer { whenWaiting = nil }; return whenWaiting }
            first?()
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
        #expect(Patience.until { released.wasCancelled })

        // A copy whose reads never come back fails with "not answering" after the no-progress limit, and lets its reader go.
        let clock = RunawayClock()
        let quiet = NetworkPlaybackCache(directory: dir, budget: 64 << 20, chunk: 4096, noProgressLimit: 5, clock: { clock.now })
        let silent = WaitingReader(Data(repeating: 2, count: 64 << 10), whenWaiting: { clock.run() })
        let stuck = try quiet.entry(key: "b", url: URL(string: "x-remote://b")!, reader: silent)
        #expect(throws: (any Error).self) { try stuck.prepare(full: true, lead: 0, cancelled: { false }) }
        #expect(silent.wasCancelled)
    }

    @Test("A silent remote copy fails with the reader's own message; one without a message keeps the share's")
    func notAnsweringMessage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remote-message-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for message in ["Service X isn't answering", nil] as [String?] {
            let clock = RunawayClock()
            let cache = NetworkPlaybackCache(directory: dir, budget: 64 << 20, chunk: 4096, noProgressLimit: 5, clock: { clock.now })
            let reader = WaitingReader(Data(repeating: 3, count: 64 << 10), message: message, whenWaiting: { clock.run() })
            let entry = try cache.entry(key: "m", url: URL(string: "x-remote://m")!, reader: reader)
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

    /// How long a test's source says it has been asked and has sent nothing.
    private enum Quiet {
        /// It can't say.
        case unknown
        /// Always this long (it is still sending, or it has been silent since long before the song was waited for).
        case fixed(TimeInterval)
        /// Since its read began to wait, on the test's clock.
        case sinceAsked
    }

    @Test("A source with a silence limit of its own is given up on once it has sent nothing for that long, however long the wait has lasted, unless the cache's limit is sooner")
    func ownSilenceLimit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remote-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // (the source's limit, how long it says it has sent nothing, the cache's limit) and the seconds the song is waited for:
        // at least `from`, less than `below`.
        let cases: [(own: TimeInterval?, quiet: Quiet, cache: TimeInterval, from: TimeInterval, below: TimeInterval)] = [
            (15, .sinceAsked, 40, 15, 35),   // a server that goes as the song is waited for: its own limit
            (15, .fixed(100), 40, 0, 15),    // a server silent that long already when the wait begins: at once, not its limit again
            (15, .unknown, 40, 15, 35),      // a source that can't say: its own limit, by the blocks written
            (15, .fixed(3), 40, 40, 60),     // still sending, slowly: the cache's
            (nil, .fixed(50), 40, 40, 60),   // no limit of its own: the cache's
            (80, .fixed(500), 40, 40, 60)    // its own is later than the cache's: the cache's
        ]
        for (index, test) in cases.enumerated() {
            // Stands still until a read waits; from then on every look by the cache finds one second gone.
            let clock = Locked((now: 0.0, running: false))
            let now: @Sendable () -> TimeInterval = { clock.withLock { if $0.running { $0.now += 1 }; return $0.now } }
            let cache = NetworkPlaybackCache(directory: dir, budget: 64 << 20, chunk: 4096, noProgressLimit: test.cache, clock: now)
            let reader = WaitingReader(Data(repeating: 4, count: 64 << 10), message: "Service Z isn't answering",
                                       whenWaiting: { clock.withLock { $0.running = true } })
            reader.silenceLimit = test.own
            switch test.quiet {
            case .unknown: reader.quiet = nil
            case .fixed(let seconds): reader.quiet = { seconds }
            case .sinceAsked: reader.quiet = { clock.withLock { $0.now } }   // the clock starts when the read waits
            }
            let entry = try cache.entry(key: "limit-\(index)", url: URL(string: "x-remote://limit-\(index)")!, reader: reader)
            do {
                try entry.prepare(full: true, lead: 0, cancelled: { false })
                Issue.record("a silent copy completed")
            } catch {
                guard case NetworkPlaybackCache.Failure.notAnswering = error else { Issue.record("failed with \(error)"); continue }
                #expect(error.localizedDescription == "Service Z isn't answering")
            }
            let waited = clock.withLock { $0.now }
            // The clock moves a second a look, from several threads: the song is given up at its limit or a few looks past it.
            #expect(waited >= test.from && waited < test.below, "case \(index): waited \(waited), expected \(test.from) to \(test.below)")
            #expect(reader.wasCancelled)
        }
    }

    @Test("A registered scheme's open that never returns fails with the scheme's message")
    func silentOpenMessage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remote-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let release = DispatchSemaphore(value: 0)
        let clock = Locked(0.0)
        NetworkPlaybackCache.registerRemoteReader(scheme: "x-silent-open", notAnsweringMessage: "Service Y isn't answering") { _ in
            // The open has begun and will not return: from here on the cache's clock says the limit has passed.
            clock.withLock { $0 = 10 }
            release.wait()
            throw CancellationError()
        }
        defer { release.signal(); NetworkPlaybackCache.unregisterRemoteReader(scheme: "x-silent-open") }
        let cache = NetworkPlaybackCache(directory: dir, budget: 64 << 20, noProgressLimit: 5, clock: { clock.withLock { $0 } })
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

/// What became of a song the engine was asked to play, as the engine itself reports it.
enum EngineOutcome: Equatable, CustomStringConvertible {
    case started, failed(String), nothing

    var description: String {
        switch self {
        case .started: "started"
        case .failed(let message): "failed: \(message)"
        case .nothing: "the engine said nothing"
        }
    }

    /// Plays `item` and waits for the engine to say it became audible or failed. There is no deadline to beat: a machine running
    /// every test at once may take a minute over what takes a moment alone. The long stop only ends a run that would never end.
    static func ofPlaying(_ item: PlayableItem, on engine: PlaybackEngine, giveUpAfter: TimeInterval = 600) async -> EngineOutcome {
        let (stream, continuation) = AsyncStream.makeStream(of: EngineOutcome.self)
        engine.eventHandler = { event in
            switch event {
            case .trackStarted(let started) where started.id == item.id: continuation.yield(.started)
            case .failed(_, let message): continuation.yield(.failed(message))
            default: break
            }
        }
        let stop = Task { try? await Task.sleep(for: .seconds(giveUpAfter)); continuation.yield(.nothing) }
        defer { stop.cancel(); engine.eventHandler = nil }
        engine.play(item)
        for await outcome in stream { return outcome }
        return .nothing
    }
}

/// Waits for something that will happen, without a deadline it could miss on a busy machine.
enum Patience {
    /// True once `condition` holds. The long stop only ends a run that would never end.
    static func until(giveUpAfter: TimeInterval = 600, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(giveUpAfter)
        while !condition() {
            if Date() > end { return condition() }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return true
    }
}
