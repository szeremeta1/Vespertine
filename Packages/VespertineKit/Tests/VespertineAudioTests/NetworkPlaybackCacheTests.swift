import AVFAudio
import CVespertineRT
import Foundation
import SFBAudioEngine
import Testing
@testable import VespertineAudio

private final class SlowShare: PlaybackCacheReader, @unchecked Sendable {
    let bytes: Data
    let gate = NSCondition()
    var stalled = false
    var reads = 0
    var size: Int64 { Int64(bytes.count) }
    init(count: Int) { bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 * 31) }) }
    init(data: Data) { bytes = data }
    func read(at offset: Int64, count: Int) throws -> Data {
        gate.lock()
        while stalled { gate.wait() }
        reads += 1
        gate.unlock()
        Thread.sleep(forTimeInterval: 0.001)
        return bytes[Int(offset)..<min(Int(offset) + count, bytes.count)]
    }
    func stall(_ value: Bool) { gate.lock(); stalled = value; gate.broadcast(); gate.unlock() }
    var readCount: Int { gate.withLock { reads } }
}

private final class ReconnectingShare: PlaybackCacheReader, @unchecked Sendable {
    let size: Int64 = 4096
    var attempts = 0
    func read(at offset: Int64, count: Int) throws -> Data {
        attempts += 1
        if attempts <= 2 { throw POSIXError(.ETIMEDOUT) }
        return Data(repeating: 42, count: count)
    }
}

/// A share that is remounted part way through a copy: a handle opened before the remount fails every read from `dropAt` on
/// with EIO, for ever (its vnode is dead), and only a handle opened afterwards reads.
private final class RemountedShare: @unchecked Sendable {
    let bytes: Data
    let dropAt: Int64
    private let mount = Locked(0)
    init(count: Int, dropAt: Int64) { bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) }); self.dropAt = dropAt }
    var remounted: Bool { mount.withLock { $0 > 0 } }
    func open() -> any PlaybackCacheReader { Handle(self, generation: mount.withLock { $0 }) }

    final class Handle: PlaybackCacheReader, @unchecked Sendable {
        let share: RemountedShare
        let generation: Int
        var size: Int64 { Int64(share.bytes.count) }
        init(_ share: RemountedShare, generation: Int) { self.share = share; self.generation = generation }
        func read(at offset: Int64, count: Int) throws -> Data {
            if generation == 0, offset + Int64(count) > share.dropAt {
                share.mount.withLock { $0 = max($0, 1) }   // the link dropped and the share was mounted again
                throw POSIXError(.EIO)
            }
            return share.bytes.subdata(in: Int(offset)..<min(Int(offset) + count, share.bytes.count))
        }
    }
}

/// A share that answers every read with a timeout, for ever.
private final class TimedOutShare: PlaybackCacheReader, @unchecked Sendable {
    let size: Int64 = 65536
    func read(at offset: Int64, count: Int) throws -> Data { Thread.sleep(forTimeInterval: 0.01); throw POSIXError(.ETIMEDOUT) }
}

/// A file that is rewritten on the server part way through its copy: the share says so (its modification date moved).
private final class RewrittenShare: PlaybackCacheReader, @unchecked Sendable {
    let bytes: Data
    let changeAt: Int64
    private let lock = NSLock()
    private var furthest: Int64 = 0
    var size: Int64 { Int64(bytes.count) }
    init(count: Int, changeAt: Int64) { bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 * 13) }); self.changeAt = changeAt }
    func read(at offset: Int64, count: Int) throws -> Data {
        lock.withLock { furthest = max(furthest, offset + Int64(count)) }
        return bytes.subdata(in: Int(offset)..<min(Int(offset) + count, bytes.count))
    }
    /// The server rewrote the file once the copy got past `changeAt`.
    var changedSinceOpen: Bool { lock.withLock { furthest > changeAt } }
}

/// A share 100 ms away (scaled down): every read waits a round trip before its bytes come back, however few they are. It
/// remembers how many reads were outstanding at once.
private final class FarShare: PlaybackCacheReader, @unchecked Sendable {
    let bytes: Data
    let roundTrip: TimeInterval
    private let lock = NSLock()
    private var outstanding = 0
    private var most = 0
    var size: Int64 { Int64(bytes.count) }
    init(count: Int, roundTrip: TimeInterval) {
        bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ 5) }); self.roundTrip = roundTrip
    }
    func read(at offset: Int64, count: Int) throws -> Data {
        lock.withLock { outstanding += 1; most = max(most, outstanding) }
        defer { lock.withLock { outstanding -= 1 } }
        Thread.sleep(forTimeInterval: roundTrip)
        return bytes.subdata(in: Int(offset)..<min(Int(offset) + count, bytes.count))
    }
    var mostAtOnce: Int { lock.withLock { most } }
}

/// A share that notes what it is asked for: every read's size, in order, and how many bytes were asked for in all. Each read
/// takes `roundTrip`.
private final class NotingShare: PlaybackCacheReader, @unchecked Sendable {
    let bytes: Data
    let roundTrip: TimeInterval
    private let lock = NSLock()
    private var sizes: [Int] = []
    var size: Int64 { Int64(bytes.count) }
    init(count: Int, roundTrip: TimeInterval = 0) {
        bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ ($0 >> 9)) }); self.roundTrip = roundTrip
    }
    func read(at offset: Int64, count: Int) throws -> Data {
        lock.withLock { sizes.append(count) }
        if roundTrip > 0 { Thread.sleep(forTimeInterval: roundTrip) }
        return bytes.subdata(in: Int(offset)..<min(Int(offset) + count, bytes.count))
    }
    var readSizes: [Int] { lock.withLock { sizes } }
    var bytesAsked: Int { lock.withLock { sizes.reduce(0, +) } }
}

struct NetworkPlaybackCacheTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Temporary share errors retry the same bytes instead of terminating playback")
    func reconnectingShare() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20)
        let entry = try cache.entry(key: "retry", url: URL(fileURLWithPath: "/share/a.flac"), reader: ReconnectingShare())
        try entry.prepare(full: true, lead: 0, cancelled: { false })
        #expect(try entry.read(at: 0, count: 4096) == Data(repeating: 42, count: 4096))
        #expect(!entry.isWaiting)
    }

    @Test("A copy whose share handle died in a remount opens the file again and finishes, byte for byte")
    func reopensAfterRemount() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let share = RemountedShare(count: 64 * 4096 + 100, dropAt: 20 * 4096)
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096)
        cache.readerFactory = { _ in share.open() }
        let entry = try cache.entry(key: "remount", url: URL(fileURLWithPath: "/share/song.flac"))
        // Patience, not a latency bound: on the base commit the copy retried the dead handle for ever.
        let patience = Date().addingTimeInterval(60)
        try entry.prepare(full: true, lead: 0, cancelled: { Date() > patience })
        #expect(share.remounted)
        #expect(entry.isComplete)
        #expect(try entry.read(at: 0, count: share.bytes.count) == share.bytes)
    }

    @Test("A share that sends nothing for the limit fails the read with the share's message, frees the scans and stops waiting")
    func silentShareGivesUp() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let gate = ShareIOGate(healthyGrace: 0)
        let share = SlowShare(count: 65536); share.stall(true)
        defer { share.stall(false) }
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096, gate: gate, noProgressLimit: 0.3)
        let entry = try cache.entry(key: "silent", url: URL(fileURLWithPath: "/share/song.flac"), reader: share)
        #expect(gate.isPaused, "the song's copy holds the scans back")
        let failure = #expect(throws: NetworkPlaybackCache.Failure.self) { try entry.read(at: 0, count: 4096) }
        #expect(failure?.localizedDescription == NetworkPlaybackCache.Failure.notAnswering.localizedDescription)
        #expect(!entry.isWaiting)
        #expect(!gate.isPaused, "scans may go again")
    }

    @Test("A song paused half copied over a sleep of the Mac does not fail on waking: the silence counts from when a read waits")
    func sleepDoesNotCountAsSilence() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let share = SlowShare(count: 65536); share.stall(true)
        defer { share.stall(false) }
        let now = Locked(TimeInterval(0))
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096, noProgressLimit: 120, clock: { now.withLock { $0 } })
        let entry = try cache.entry(key: "paused", url: URL(fileURLWithPath: "/share/song.flac"), reader: share)
        // Paused, nothing reading; the clock jumps by eight hours (a clock that runs through sleep would).
        now.withLock { $0 += 8 * 3600 }
        let result = Locked<Result<Data, Error>?>(nil)
        let finished = DispatchSemaphore(value: 0)
        Thread {
            result.withLock { $0 = Result { try entry.read(at: 0, count: 4096) } }
            finished.signal()
        }.start()
        // The share answers once the Mac is awake and the read has asked (a hang detector, not a latency bound).
        for _ in 0..<500 where !entry.isWaiting { Thread.sleep(forTimeInterval: 0.002) }
        #expect(finished.wait(timeout: .now() + 0.2) == .timedOut, "the read waits for the share instead of failing at once")
        share.stall(false)
        #expect(finished.wait(timeout: .now() + 30) == .success)
        #expect(try result.withLock { $0 }?.get() == share.bytes[0..<4096])
    }

    @Test("How long a copy has been going is read off the cache's clock, as the share's silence is")
    func copyAgeFollowsTheClock() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let share = SlowShare(count: 65536); share.stall(true)
        defer { share.stall(false) }
        let now = Locked(TimeInterval(5))
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096, noProgressLimit: 120, clock: { now.withLock { $0 } })
        let entry = try cache.entry(key: "age", url: URL(fileURLWithPath: "/share/song.flac"), reader: share)
        #expect(entry.copyElapsed == 0)
        now.withLock { $0 += 42 }
        #expect(entry.copyElapsed == 42, "the copy's age (and so the speed its start is planned on) is not the machine's wall clock")
    }

    @Test("A share that answers every read with a temporary error fails the song after the limit instead of retrying for ever")
    func timeoutsGiveUp() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096, noProgressLimit: 0.3)
        let entry = try cache.entry(key: "timeouts", url: URL(fileURLWithPath: "/share/song.flac"), reader: TimedOutShare())
        #expect(throws: NetworkPlaybackCache.Failure.self) { try entry.prepare(full: true, lead: 0, cancelled: { false }) }
        #expect(!entry.isWaiting)
    }

    @Test("Two copies that each fit the free space alone but not together: the second is refused before anything is written")
    func freeSpaceCountsOtherCopies() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = SlowShare(count: 2_000_000); first.stall(true)
        let second = SlowShare(count: 2_000_000)
        defer { first.stall(false) }
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 30, chunk: 4096)
        cache.freeSpace = { (64 << 20) + 3_000_000 }   // what is kept free, and room for one of the two
        let current = try cache.entry(key: "current", url: URL(fileURLWithPath: "/share/a.flac"), reader: first)
        #expect(current.copiedBytes == 0, "its sparse file takes no space yet, but will")
        #expect(throws: CocoaError.self) { _ = try cache.entry(key: "next", url: URL(fileURLWithPath: "/share/b.flac"), reader: second) }
        #expect(cache.reservedBytes == 2_000_000)
    }

    @Test("A file rewritten on the server while it is copied ends the copy in an error, never a complete mixed copy")
    func rewrittenWhileCopying() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let share = RewrittenShare(count: 40 * 4096, changeAt: 10 * 4096)
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096)
        let entry = try cache.entry(key: "rewritten", url: URL(fileURLWithPath: "/share/song.flac"), reader: share)
        #expect(throws: (any Error).self) { try entry.prepare(full: true, lead: 0, cancelled: { false }) }
        #expect(!entry.isComplete)
        #expect(!entry.isWaiting)
    }

    @Test("A slow current track is completely local before output; a later outage makes no reads")
    func fullCopySurvivesOutage() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let share = SlowShare(count: 128 * 1024)
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096)
        let entry = try cache.entry(key: "song", url: URL(fileURLWithPath: "/share/song.flac"), reader: share)
        share.stall(true)
        #expect(!entry.isComplete)
        #expect(entry.isWaiting)
        share.stall(false)
        try entry.prepare(full: true, lead: 0, cancelled: { false })
        #expect(entry.isComplete)
        #expect(!entry.isWaiting)
        let before = share.readCount
        share.stall(true); defer { share.stall(false) }
        #expect(try entry.read(at: 0, count: share.bytes.count) == share.bytes)
        #expect(share.readCount == before)
    }

    @Test("A copy reports how much is local as it arrives: never backwards, ending at the whole file")
    func copyProgress() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let share = SlowShare(count: 64 * 4096 + 100)
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096)
        let entry = try cache.entry(key: "song", url: URL(fileURLWithPath: "/share/song.flac"), reader: share)
        let seen = Locked([Int64]())
        share.stall(true)
        entry.setProgress { copied in seen.withLock { $0.append(copied) } }
        share.stall(false)
        try entry.prepare(full: true, lead: 0, cancelled: { false })
        #expect(entry.copiedBytes == entry.size)
        let steps = seen.withLock { $0 }
        #expect(!steps.isEmpty && steps == steps.sorted() && steps.last == entry.size, "\(steps.suffix(3))")
        entry.setProgress(nil)
    }

    @Test("A share with a long round trip: the copy keeps several reads in flight, so it is not one chunk per round trip, and stays byte exact")
    func readsInFlight() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        // 32 chunks, each read a "round trip" of 20 ms. One read at a time is 1 chunk per round trip: what a 100 ms SMB link over a
        // VPN gave (1 MiB per round trip, ~6.7 MB/s), too slow to copy a 5.1 DSD song ahead of a start in reasonable time.
        let share = FarShare(count: 32 * 65536, roundTrip: 0.02)
        let cache = NetworkPlaybackCache(directory: dir, budget: 64 << 20, chunk: 65536)
        let entry = try cache.entry(key: "far", url: URL(fileURLWithPath: "/share/far.dsf"), reader: share)
        try entry.prepare(full: true, lead: 0, cancelled: { false })
        #expect(entry.isComplete)
        #expect(share.mostAtOnce >= 2, "reads in flight at once: \(share.mostAtOnce)")
        #expect(share.mostAtOnce <= NetworkPlaybackCache.readsInFlight)
        #expect(try Data(contentsOf: entry.url) == share.bytes)
    }

    @Test("A copy begins with small reads and goes on with whole blocks, byte for byte")
    func smallReadsAtTheStart() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        // Blocks as large as the app's, a file that is no whole number of them, and a clock on which the start's two seconds are
        // over in two microseconds (this copy from memory takes about a millisecond), so only how much is local decides. On that
        // clock the share's silence is not timed.
        let share = NotingShare(count: 9 * 1_048_576 + 70_001)
        let begun = ProcessInfo.processInfo.systemUptime
        let cache = NetworkPlaybackCache(directory: dir, budget: 64 << 20, chunk: 1 << 20, noProgressLimit: .greatestFiniteMagnitude,
                                         clock: { (ProcessInfo.processInfo.systemUptime - begun) * 1_000_000 + 100 })
        let entry = try cache.entry(key: "song", url: URL(fileURLWithPath: "/share/song.flac"), reader: share)
        try entry.prepare(full: true, lead: 0, cancelled: { false })
        #expect(entry.isComplete)
        #expect(try Data(contentsOf: entry.url) == share.bytes, "the copy is the file, byte for byte")
        let sizes = share.readSizes
        let lanes = NetworkPlaybackCache.readsInFlight
        #expect(sizes.prefix(lanes).allSatisfy { $0 <= NetworkPlaybackCache.startReadBytes }, "the first reads are small: \(sizes.prefix(lanes))")
        #expect(sizes.contains(1 << 20), "whole blocks once the start is local: largest read \(sizes.max() ?? 0)")
    }

    @Test("A copy given up on as it begins leaves little on the link: no megabyte reads on their way")
    func cancelledStartLeavesLittleInFlight() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        // Every read takes 50 ms (a share far away). The copy is given up on 120 ms in, as a skip does to the song skipped past.
        let share = NotingShare(count: 16 << 20, roundTrip: 0.05)
        let cache = NetworkPlaybackCache(directory: dir, budget: 64 << 20, chunk: 1 << 20)
        let entry = try cache.entry(key: "skipped", url: URL(fileURLWithPath: "/share/skipped.flac"), reader: share)
        Thread.sleep(forTimeInterval: 0.12)
        let before = share.bytesAsked
        entry.cancel()
        Thread.sleep(forTimeInterval: 0.3)
        let lanes = NetworkPlaybackCache.readsInFlight
        #expect(share.readSizes.allSatisfy { $0 <= NetworkPlaybackCache.startReadBytes }, "only small reads were sent: largest \(share.readSizes.max() ?? 0)")
        #expect(before <= 3 * lanes * NetworkPlaybackCache.startReadBytes, "asked for before it was given up on: \(before) bytes")
        // A lane that had just looked may still send the one small read it was about to.
        #expect(share.bytesAsked - before <= lanes * NetworkPlaybackCache.startReadBytes,
                "asked for after it was given up on: \(share.bytesAsked - before) bytes")
    }

    @Test("Large DSD uses a local lead; a stalled producer cannot interrupt reads within that reserve")
    func progressiveLead() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let share = SlowShare(count: 1024 * 1024)
        let cache = NetworkPlaybackCache(directory: dir, budget: 2 << 20, chunk: 4096)
        let entry = try cache.entry(key: "dsd", url: URL(fileURLWithPath: "/share/song.dsf"), reader: share)
        try entry.prepare(full: false, lead: 65536, cancelled: { false })
        #expect(!entry.isComplete)
        share.stall(true); defer { share.stall(false) }
        for offset in stride(from: 0, to: 65536, by: 4096) {
            #expect(try entry.read(at: Int64(offset), count: 4096) == share.bytes[offset..<offset + 4096])
        }
    }

    @Test("Unwritten sparse ranges wait, never return zeros or premature EOF; loading clears on delivery")
    func waitingTransitions() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let share = SlowShare(count: 131072)
        share.stall(true)
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096)
        let entry = try cache.entry(key: "wait", url: URL(fileURLWithPath: "/share/song.dsf"), reader: share)
        // A fresh entry reports itself as waiting while it is "starting", whoever is reading: that is cleared by the first
        // `prepare` or `read`. With no lead asked for, `prepare` only clears it, so from here `isWaiting` means a read is queued.
        try entry.prepare(full: false, lead: 0, cancelled: { false })
        #expect(!entry.isWaiting, "nothing is waiting before the read")
        let finished = DispatchSemaphore(value: 0)
        let result = Locked<Data?>(nil)
        // A dedicated thread, not the global queue: under a loaded runner the shared pool can take seconds to start a
        // block (measured 1.5 s with 24 busy processes), which made the waits below time out although the cache was fine.
        let reader = Thread {
            let data = try? entry.read(at: 98304, count: 4096)   // (not inside the lock: it blocks until the share answers)
            result.withLock { $0 = data }
            finished.signal()
        }
        reader.start()
        // The read is queued once the entry says so: wait for that (the thread signalling that it started would only say it
        // is about to call `read`, not that `read` is waiting). A hang detector, not a latency bound.
        let deadline = Date().addingTimeInterval(30)
        while !entry.isWaiting, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        #expect(entry.isWaiting, "the stalled range was never waited for")
        // Still stalled, so the read has not handed over anything (not zeros, not an early end of file).
        #expect(result.withLock { $0 } == nil)
        share.stall(false)
        #expect(finished.wait(timeout: .now() + 30) == .success)
        #expect(result.withLock { $0 } == share.bytes[98304..<102400])
        #expect(!entry.isWaiting)
    }

    @Test("A cancelled start returns promptly while the share is stuck")
    func cancellation() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let share = SlowShare(count: 65536); share.stall(true)
        defer { share.stall(false) }
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096)
        let entry = try cache.entry(key: "cancel", url: URL(fileURLWithPath: "/share/song.flac"), reader: share)
        #expect(throws: CancellationError.self) { try entry.prepare(full: true, lead: 0, cancelled: { true }) }
    }

    /// The 11-05 hang seen on a test Mac: the engine thread opened the share file itself, so while the share did
    /// not answer, skip and stop sat in its queue. A FIFO with no writer blocks `open(2)` exactly like a stuck SMB open.
    @Test("Opening a file the share does not answer for can be given up on, and gives the engine thread back")
    func cancellableOpen() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("song.flac")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        defer { let fd = open(fifo.path, O_WRONLY | O_NONBLOCK); if fd >= 0 { close(fd) } }   // lets the stuck open return
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096)
        let skipped = Locked(false)
        let result = Locked<Result<Void, Error>?>(nil)
        let returned = DispatchSemaphore(value: 0)
        let thread = Thread {
            let outcome = Result { _ = try cache.entry(key: "hung", url: fifo, cancelled: { skipped.withLock { $0 } }) }
            result.withLock { $0 = outcome }
            returned.signal()
        }
        thread.start()
        #expect(returned.wait(timeout: .now() + 0.5) == .timedOut, "still waiting for the share")
        skipped.withLock { $0 = true }
        #expect(returned.wait(timeout: .now() + 2) == .success, "the caller is free within 2 s of the skip")
        if case .failure(let error)? = result.withLock({ $0 }) { #expect(error is CancellationError) }
        else { Issue.record("the open was not cancelled") }
    }

    @Test("Play pressed on a song whose share does not answer its open, then on another song: the scans are let go at once")
    func pressThenSkipWhileOpenHangs() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("song.flac")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        defer { let fd = open(fifo.path, O_WRONLY | O_NONBLOCK); if fd >= 0 { close(fd) } }   // lets the stuck open return
        let gate = ShareIOGate(healthyGrace: 0)
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096, gate: gate)
        cache.warm(key: "stuck", url: fifo, press: true) { true }
        #expect(gate.isPaused, "pressing play on a song on a share holds the scans back")
        // Skipped to a song that turns out to be local: nothing of the stuck one should hold the share any longer.
        cache.warm(key: "local", url: dir.appendingPathComponent("local.flac"), press: true) { false }
        // Patience, not a latency bound: on the base commit the first press held the scans until the open returned.
        for _ in 0..<300 where gate.isPaused { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!gate.isPaused, "the scans go while the first open is still stuck")
    }

    @Test("A prefetch of the next song whose open hangs gives up when another next song is chosen")
    func prefetchGivesUpOnNewerNext() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("next.flac")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        defer { let fd = open(fifo.path, O_WRONLY | O_NONBLOCK); if fd >= 0 { close(fd) } }
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096)
        let waiting = cache.waitingPrefetches
        cache.prefetch(key: "stuck", url: fifo)
        for _ in 0..<300 where cache.waitingPrefetches == waiting { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cache.waitingPrefetches == waiting + 1, "the prefetch waits for the share")
        cache.prefetch(key: nil, url: nil)   // the queue changed: no next song on a share
        for _ in 0..<300 where cache.waitingPrefetches > waiting { try await Task.sleep(for: .milliseconds(20)) }
        #expect(cache.waitingPrefetches == waiting, "it stopped waiting while the open is still stuck")
    }

    @Test("Two callers opening the same file on a stuck share share one open, and each can give up alone")
    func sharedOpen() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("song.flac")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096)
        let firstGivesUp = Locked(false)
        let first = DispatchSemaphore(value: 0), second = DispatchSemaphore(value: 0)
        Thread { _ = try? cache.entry(key: "hung", url: fifo, cancelled: { firstGivesUp.withLock { $0 } }); first.signal() }.start()
        Thread {
            _ = try? cache.entry(key: "hung", url: fifo, cancelled: { false })   // (a FIFO can't be sized: it fails once opened)
            second.signal()
        }.start()
        Thread.sleep(forTimeInterval: 0.3)
        firstGivesUp.withLock { $0 = true }
        #expect(first.wait(timeout: .now() + 2) == .success)
        #expect(second.wait(timeout: .now() + 0.3) == .timedOut, "the other caller is still waiting for the share")
        let fd = open(fifo.path, O_WRONLY); close(fd)   // the share answers
        #expect(second.wait(timeout: .now() + 3) == .success)
    }

    @Test("Current and next remain leased, disk reservations are bounded, crash leftovers are cleaned")
    func budgetAndCleanup() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: dir.appendingPathComponent("abandoned.partial"))
        let cache = NetworkPlaybackCache(directory: dir, budget: 16384, chunk: 1024)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("abandoned.partial").path))
        let current = try cache.entry(key: "current", url: URL(fileURLWithPath: "/a.flac"), reader: SlowShare(count: 8192))
        let next = try cache.entry(key: "next", url: URL(fileURLWithPath: "/b.flac"), reader: SlowShare(count: 8192))
        try current.prepare(full: true, lead: 0, cancelled: { false })
        try next.prepare(full: true, lead: 0, cancelled: { false })
        #expect(cache.reservedBytes == 16384)
        #expect(throws: (any Error).self) { try cache.entry(key: "third", url: URL(fileURLWithPath: "/c.flac"), reader: SlowShare(count: 8192)) }
        #expect(try current.read(at: 0, count: 8192).count == 8192)
        #expect(try next.read(at: 0, count: 8192).count == 8192)
    }

    @Test("Cache cleanup respects another live session's lease")
    func liveSessionIsNotRemoved() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = NetworkPlaybackCache(directory: dir, budget: 1 << 20)
        let share = SlowShare(count: 8192)
        let entry = try first.entry(key: "live", url: URL(fileURLWithPath: "/live.flac"), reader: share)
        try entry.prepare(full: true, lead: 0, cancelled: { false })
        let second = NetworkPlaybackCache(directory: dir, budget: 1 << 20)
        #expect(first.directory != second.directory)
        #expect(FileManager.default.fileExists(atPath: entry.url.path))
        #expect(try entry.read(at: 0, count: 8192) == share.bytes)
    }

    @Test("DVD folder staging keeps named IFO and VOB files together and byte exact")
    func dvdFolder() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("VIDEO_TS")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let ifo = source.appendingPathComponent("VIDEO_TS.IFO")
        let vob = source.appendingPathComponent("VTS_01_1.VOB")
        try Data([1, 2, 3]).write(to: ifo)
        try Data([4, 5, 6, 7]).write(to: vob)
        let cache = NetworkPlaybackCache(directory: dir.appendingPathComponent("cache"), budget: 1 << 20)
        let folder = try cache.directoryEntry(for: ifo, cancelled: { false })
        #expect(folder.url.lastPathComponent == "VIDEO_TS.IFO")
        #expect(try Data(contentsOf: folder.url) == Data([1, 2, 3]))
        #expect(try Data(contentsOf: folder.url.deletingLastPathComponent().appendingPathComponent(vob.lastPathComponent)) == Data([4, 5, 6, 7]))
        #expect(cache.reservedBytes == 7)
    }

    @Test("Staged PCM renders the whole track with zero underruns while its share is stalled")
    func renderWithoutNetwork() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("source.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
            buffer.frameLength = 48000
            for channel in 0..<2 { for frame in 0..<48000 { buffer.floatChannelData![channel][frame] = Float(frame % 128) / 256 } }
            try file.write(from: buffer)
        }
        let share = SlowShare(data: try Data(contentsOf: url))
        let cache = NetworkPlaybackCache(directory: dir.appendingPathComponent("cache"), budget: 1 << 20, chunk: 8192)
        let entry = try cache.entry(key: "pcm", url: url, reader: share)
        try entry.prepare(full: true, lead: 0, cancelled: { false })
        share.stall(true); defer { share.stall(false) }
        let file = try AVAudioFile(forReading: entry.url, commonFormat: .pcmFormatFloat32, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 256)!
        let ring = try #require(nrt_ring_create(1024, 2))
        let context = try #require(nrt_context_create(ring, 256))
        defer { nrt_context_destroy(context); nrt_ring_destroy(ring) }
        var rendered: Int64 = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: 256)
            let n = buffer.frameLength
            #expect(nrt_ring_write(ring, buffer.floatChannelData![0], n) == n)
            var out = [Float](repeating: 0, count: Int(n) * 2)
            out.withUnsafeMutableBufferPointer { nrt_context_render_interleaved(context, $0.baseAddress!, n, 2) }
            #expect(out == Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(n) * 2)))
            rendered += Int64(n)
        }
        #expect(rendered == 48000)
        #expect(nrt_context_take_underruns(context) == 0)
    }

    @Test("A native PCM probe retains its cache lease after the engine stages another source")
    func nativeDecoderLease() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("source.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48)!
            buffer.frameLength = 48
            for c in 0..<2 { for f in 0..<48 { buffer.floatChannelData![c][f] = 0 } }
            try file.write(from: buffer)
        }
        let share = SlowShare(data: try Data(contentsOf: url))
        let cache = NetworkPlaybackCache(directory: dir.appendingPathComponent("cache"), budget: 1 << 20)
        var entry: NetworkPlaybackCache.Entry? = try cache.entry(key: "lease", url: url, reader: share)
        try entry!.prepare(full: true, lead: 0, cancelled: { false })
        weak var lease = entry
        let probed = try SourceOpener.probe(entry!.url)
        entry = nil
        withExtendedLifetime(probed) {
            #expect(lease != nil)
            #expect(cache.reservedBytes == Int64(share.bytes.count))
            #expect(FileManager.default.fileExists(atPath: probed.url.path))
        }
    }

    @Test("Guarded FFmpeg DSD→PCM and DoP match direct decoding byte for byte", arguments: [false, true])
    func dsdDecoderIdentity(dop: Bool) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("source.dsf")
        let planes = (0..<2).map { channel in (0..<16384).map { UInt8(truncatingIfNeeded: $0 * 17 + channel) } }
        try DSDFiles.writeDSF(planes, rate: 2822400, to: url)
        var data = try Data(contentsOf: url)
        data.append(Data(repeating: 0, count: 2 << 20)) // uncached tail forces the guarded AVIO path
        let share = SlowShare(data: data)
        let cache = NetworkPlaybackCache(directory: dir.appendingPathComponent("cache"), budget: 4 << 20, chunk: 1024)
        let entry = try cache.entry(key: "dsd", url: url, reader: share)
        try entry.prepare(full: false, lead: 65536, cancelled: { false })
        #expect(!entry.isComplete)
        share.stall(true); defer { share.stall(false) }
        func decode(_ path: URL) throws -> [[UInt8]] {
            let probed = try SourceOpener.probe(path)
            let rate = 2822400.0 / (dop ? 16 : 8)
            let plan = OutputPlan(mode: dop ? .dop : .pcm, deviceSampleRate: rate, decodedSampleRate: rate,
                                  physicalBitDepth: dop ? 24 : 32, channels: 2, dsdConvertedToPCM: !dop, reason: "")
            let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: path))
            let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 257)!
            var result = [[UInt8]](repeating: [], count: 2)
            while true {
                try decoder.decode(into: buffer, length: 257)
                if buffer.frameLength == 0 { return result }
                for c in 0..<2 {
                    result[c] += UnsafeRawBufferPointer(start: buffer.floatChannelData![c], count: Int(buffer.frameLength) * 4)
                }
            }
        }
        #expect(try decode(entry.url) == decode(url))
    }
}
