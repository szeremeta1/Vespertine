//
// Vespertine: telling the listener that a share has stopped answering, well before the song is given up on. The notice is for a
// song that is waiting on its share (its open, its start or a decoder's read), counted from the last byte that arrived or the
// start of the wait; a slow share that keeps delivering never trips it, and a stall inside the local lead (nothing is waiting)
// is no notice at all.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

/// A share that answers one read per `allow()`, and otherwise sends nothing.
private final class GatedShare: PlaybackCacheReader, @unchecked Sendable {
    let bytes: Data
    private let gate = NSCondition()
    private var permits = 0
    var size: Int64 { Int64(bytes.count) }
    init(count: Int) { bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 3) }) }
    func read(at offset: Int64, count: Int) throws -> Data {
        gate.lock()
        while permits == 0 { gate.wait() }
        permits -= 1
        gate.unlock()
        return bytes.subdata(in: Int(offset)..<min(Int(offset) + count, bytes.count))
    }
    func allow(_ reads: Int = 1) { gate.withLock { permits += reads; gate.broadcast() } }
    func openUp() { allow(1 << 20) }
}

@Suite("Share not answering: the notice", .serialized)
struct ShareNoticeTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("share-notice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waiting(_ entry: NetworkPlaybackCache.Entry) {
        for _ in 0..<1000 where !entry.isWaiting { Thread.sleep(forTimeInterval: 0.002) }
    }

    @Test("A read waiting on a share: nothing at 9 s, the notice at 10 s counted from the wait, none once it is over")
    func noticeAfterTenSeconds() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let share = GatedShare(count: 8192)
        defer { share.openUp() }
        let now = Locked(TimeInterval(1000))
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096, readsInFlight: 1, noProgressLimit: 120,
                                         clock: { now.withLock { $0 } })
        let entry = try cache.entry(key: "quiet", url: URL(fileURLWithPath: "/share/song.flac"), reader: share)
        #expect(cache.shareSilence == nil, "nothing is waiting yet")
        let done = DispatchSemaphore(value: 0)
        Thread { _ = try? entry.read(at: 0, count: 4096); done.signal() }.start()
        waiting(entry)
        now.withLock { $0 += 9 }
        #expect(cache.shareSilence == nil, "9 s is not yet a notice")
        now.withLock { $0 += 1 }
        #expect(cache.shareSilence == 10)
        now.withLock { $0 += 20 }
        #expect(cache.shareSilence == 30)
        share.allow()   // the share answers
        #expect(done.wait(timeout: .now() + 30) == .success)
        #expect(cache.shareSilence == nil, "the read is served: no notice")
    }

    @Test("A slow share that keeps delivering never trips the notice: each byte that arrives restarts the count")
    func slowButMovingIsNotSilence() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let share = GatedShare(count: 4096 * 6)
        defer { share.openUp() }
        let now = Locked(TimeInterval(0))
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096, readsInFlight: 1, noProgressLimit: 120,
                                         clock: { now.withLock { $0 } })
        let entry = try cache.entry(key: "slow", url: URL(fileURLWithPath: "/share/song.flac"), reader: share)
        let done = DispatchSemaphore(value: 0)
        Thread { _ = try? entry.read(at: 0, count: 4096 * 6); done.signal() }.start()
        waiting(entry)
        for step in 1...5 {
            now.withLock { $0 += 9 }
            #expect(cache.shareSilence == nil, "9 s after the last byte, step \(step)")
            share.allow()   // one more block, every 9 s
            for _ in 0..<1000 where entry.copiedBytes < Int64(4096 * step) { Thread.sleep(forTimeInterval: 0.002) }
        }
        share.allow()
        #expect(done.wait(timeout: .now() + 30) == .success)
        #expect(cache.shareSilence == nil)
    }

    @Test("Nothing waiting on the copy, no notice: a stall inside the local lead, and a prefetched next song, are not the listener's wait")
    func onlyWhatIsWaitedFor() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let share = GatedShare(count: 4096 * 4)
        defer { share.openUp() }
        let now = Locked(TimeInterval(0))
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096, readsInFlight: 1, noProgressLimit: 120,
                                         clock: { now.withLock { $0 } })
        let entry = try cache.entry(key: "lead", url: URL(fileURLWithPath: "/share/lead.flac"), reader: share)
        share.allow()
        try entry.prepare(full: false, lead: 4096, cancelled: { false })   // the start is served; the rest of the copy is stuck
        now.withLock { $0 += 60 }
        #expect(!entry.isWaiting)
        #expect(cache.shareSilence == nil, "the decoder is reading the lead: the share's silence is not waited on")
        let nextShare = GatedShare(count: 8192)
        defer { nextShare.openUp() }
        let next = try cache.entry(key: "next", url: URL(fileURLWithPath: "/share/next.flac"), reader: nextShare, foreground: false)
        now.withLock { $0 += 60 }
        #expect(next.copiedBytes == 0)
        #expect(cache.shareSilence == nil, "a prefetched next song is waited for by no one")
    }

    @Test("A file on a share that does not open: the notice counts from when the open began waiting")
    func noticeDuringStuckOpen() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("song.flac")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        defer { let fd = open(fifo.path, O_WRONLY | O_NONBLOCK); if fd >= 0 { close(fd) } }   // lets the stuck open return
        let now = Locked(TimeInterval(500))
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096, noProgressLimit: 120, clock: { now.withLock { $0 } })
        let skipped = Locked(false)
        let returned = DispatchSemaphore(value: 0)
        Thread { _ = try? cache.entry(key: "hung", url: fifo, cancelled: { skipped.withLock { $0 } }); returned.signal() }.start()
        for _ in 0..<1000 where cache.openingSilence == nil { Thread.sleep(forTimeInterval: 0.002) }
        now.withLock { $0 += 9 }
        #expect(cache.shareSilence == nil)
        now.withLock { $0 += 1 }
        #expect(cache.shareSilence == 10)
        skipped.withLock { $0 = true }
        #expect(returned.wait(timeout: .now() + 2) == .success)
        #expect(cache.shareSilence == nil, "the wait ended with the skip, though the open is still stuck")
    }

    @Test("The engine reports the share's silence in its snapshot while a song waits, and not once the wait is over")
    func snapshotCarriesIt() async throws {
        let rig = try PlayPauseRig(seconds: 12)
        let cache = NetworkPlaybackCache(directory: rig.directory.appendingPathComponent("notice-cache"), budget: 256 << 20, chunk: 1 << 16,
                                         noProgressLimit: 600, noticeAfter: 0.4)
        let size = rig.share.size
        let gated = Locked<[GatedShare]>([])
        cache.readerFactory = { _ in
            let file = GatedShare(count: Int(size))
            gated.withLock { $0.append(file) }
            return file
        }
        rig.engine.cacheOverride = cache
        defer { gated.withLock { $0.forEach { $0.openUp() } } }
        #expect(rig.engine.snapshot.shareStalledSeconds == nil)
        rig.engine.play(PlayableItem(url: URL(fileURLWithPath: "/share/quiet.wav"), cacheKey: "quiet"))
        let noticed = await rig.wait(timeout: 30) { $0.shareStalledSeconds != nil }
        #expect(noticed, "the snapshot says the share is not answering")
        rig.engine.stop()   // the wait is over (the cache's own give-up is covered by `QuietShareTests`)
        // Patience, not a latency bound: the engine thread leaves its wait within a poll or two of the stop.
        let quiet = await rig.wait(timeout: 30) { $0.shareStalledSeconds == nil }
        #expect(quiet, "no longer waiting, no notice: \(rig.engine.snapshot.state), buffering \(rig.engine.snapshot.isBuffering)")
    }
}
