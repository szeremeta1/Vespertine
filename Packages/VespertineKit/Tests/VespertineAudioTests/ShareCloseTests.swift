//
// Vespertine: closing a file on a share is a request to the server, and a share that has stopped answering holds it for as long
// as it stays quiet. Letting go of a song's copy must never make the thread that does it wait for that: not the caller's thread
// (play pressed again: the interface), and not the engine's.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

/// The share's answer to closes: while held, a handle being let go waits (as `close` does on a mount whose server is quiet).
private final class CloseLatch: @unchecked Sendable {
    private let state = NSCondition()
    private var held = false
    private var waiting = 0
    private var done = 0
    func hold() { state.withLock { held = true } }
    func release() { state.withLock { held = false; state.broadcast() } }
    /// Closes waiting on the share right now, and closes that went through.
    var closesWaiting: Int { state.withLock { waiting } }
    var closesDone: Int { state.withLock { done } }
    func close() {
        state.lock()
        waiting += 1
        while held { state.wait() }
        waiting -= 1
        done += 1
        state.unlock()
    }
}

/// One open file on the share: reads answer at once, letting go of it asks the share (`CloseLatch`).
private final class ShareHandle: PlaybackCacheReader, @unchecked Sendable {
    let bytes: Data
    let latch: CloseLatch
    var size: Int64 { Int64(bytes.count) }
    init(_ bytes: Data, _ latch: CloseLatch) { self.bytes = bytes; self.latch = latch }
    deinit { latch.close() }
    func read(at offset: Int64, count: Int) throws -> Data {
        bytes.subdata(in: Int(offset)..<min(Int(offset) + count, bytes.count))
    }
}

@Suite("Closing a file on a share that stopped answering", .serialized)
struct ShareCloseTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("share-close-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Runs `press` on a thread of its own and says whether it came back within `patience` (a wait on the event, not a deadline:
    /// the close it must not wait for is held the whole time).
    private func returns(within patience: TimeInterval = 10, _ press: @escaping @Sendable () -> Void) -> Bool {
        let back = DispatchSemaphore(value: 0)
        Thread { press(); back.signal() }.start()
        return back.wait(timeout: .now() + patience) == .success
    }

    /// Waits until `condition` holds (false after `patience`).
    private func eventually(_ patience: TimeInterval = 20, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(patience)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("Play pressed twice while the share is quiet: the second press does not wait for the copied next song's file to close")
    func pressWhileCloseWaits() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let latch = CloseLatch()
        defer { latch.release() }
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096, gate: ShareIOGate(healthyGrace: 0))
        let bytes = Data((0..<16_384).map { UInt8(truncatingIfNeeded: $0 * 13) })
        cache.readerFactory = { _ in ShareHandle(bytes, latch) }

        // The next song, copied whole ahead of time (nothing reads it any more: only the cache holds its open file).
        let next = URL(fileURLWithPath: "/share/next.flac")
        cache.prefetch(key: "next", url: next)
        let copied = await eventually { (try? cache.entry(key: "next", url: next, reader: nil, foreground: false))?.isComplete == true }
        #expect(copied, "the next song was copied")
        try await Task.sleep(for: .milliseconds(300))   // its copy threads have ended

        // The share goes quiet. Play is pressed on some other song: the copied next one is let go, and its file closed.
        latch.hold()
        cache.warm(key: "other", url: URL(fileURLWithPath: "/share/other.flac"), press: true) { true }
        let closing = await eventually { latch.closesWaiting > 0 }
        #expect(closing, "the next song's file is being closed on the quiet share")

        // Play pressed again (the caller's thread: the interface). It must come back while that close still waits.
        let back = returns { cache.warm(key: "third", url: URL(fileURLWithPath: "/share/third.flac"), press: true) { true } }
        #expect(latch.closesWaiting > 0, "the share was still quiet")
        #expect(back, "the press came back while the close waited on the share")
    }

    @Test("A song skipped to while the share is quiet plays, though the files of the songs before it cannot be closed yet")
    func skipWhileCloseWaits() async throws {
        let rig = try PlayPauseRig(seconds: 12)
        let latch = CloseLatch()
        defer { latch.release() }
        let song = rig.share.bytes
        rig.cache.readerFactory = { _ in ShareHandle(song, latch) }
        let nextItem = rig.nextItem()
        rig.engine.nextItemProvider = { _ in nextItem }

        rig.engine.play(rig.item())
        let playing = await rig.wait(timeout: 60) { $0.state == .playing && $0.position > 0.2 }
        #expect(playing, "the first song plays: \(rig.engine.snapshot.state)")
        // The song after it is copied whole ahead of time.
        let copied = await eventually(60) {
            (try? rig.cache.entry(key: "next", url: nextItem.url, reader: nil, foreground: false))?.isComplete == true
        }
        #expect(copied, "the next song was copied ahead")
        try await Task.sleep(for: .milliseconds(300))   // its copy threads have ended

        // The share goes quiet for closes; the songs chosen from here on are ones it still sends (as a link that drops some
        // requests and answers others does). Play pressed on a song that is neither of the two: both are let go.
        latch.hold()
        let third = PlayableItem(url: URL(fileURLWithPath: "/share/third.wav"), cacheKey: "third")
        let fourth = PlayableItem(url: URL(fileURLWithPath: "/share/fourth.wav"), cacheKey: "fourth")
        let engine = rig.engine
        #expect(returns { engine.play(third) }, "the first press came back")
        let closing = await eventually { latch.closesWaiting > 0 }
        #expect(closing, "a file of an earlier song is being closed on the quiet share")

        // Pressed again, as one does when nothing seems to happen.
        #expect(returns { engine.play(fourth) }, "the second press came back while the close waited on the share")
        let plays = await rig.wait(timeout: 60) { $0.state == .playing && $0.item?.id == fourth.id && $0.position > 0.2 }
        #expect(latch.closesWaiting > 0, "the share was still quiet")
        #expect(plays, "the song skipped to plays while the closes wait: \(rig.engine.snapshot.state), \(rig.engine.snapshot.item?.url.lastPathComponent ?? "-")")
        rig.engine.stop()
        let stopped = await rig.wait(timeout: 30) { $0.state == .stopped }
        #expect(stopped, "stop gets through too")
    }
}
