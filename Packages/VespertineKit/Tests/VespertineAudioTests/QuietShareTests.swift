//
// Vespertine: a share that is mounted and has stopped answering. A song on it is given up after a bounded wait, with the
// reason, whether it was the open or a read that never came back; and the songs after it are not each waited for in turn.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

/// A file on a share that opens and then sends nothing until `release()`.
private final class SilentFile: PlaybackCacheReader, @unchecked Sendable {
    let size: Int64
    private let gate = NSCondition()
    private var silent = true
    init(size: Int64) { self.size = size }
    func read(at offset: Int64, count: Int) throws -> Data {
        gate.lock()
        while silent { gate.wait() }
        gate.unlock()
        throw POSIXError(.EIO)
    }
    func release() { gate.withLock { silent = false; gate.broadcast() } }
}

@Suite("A share that stopped answering", .serialized)
struct QuietShareTests {
    @Test("A song whose file the share never opens is given up after the share's silence limit, not waited for without end")
    func openThatNeverAnswers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quiet-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Opening a FIFO nobody writes to does not return, as an open on a share that has stopped answering does not.
        let fifo = dir.appendingPathComponent("song.flac")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        defer { let fd = open(fifo.path, O_WRONLY | O_NONBLOCK); if fd >= 0 { close(fd) } }   // lets the stuck open return
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: 4096, noProgressLimit: 0.5)
        let result = Locked<Result<Void, Error>?>(nil)
        let returned = DispatchSemaphore(value: 0)
        Thread {
            let outcome = Result { _ = try cache.entry(key: "hung", url: fifo, cancelled: { false }) }
            result.withLock { $0 = outcome }
            returned.signal()
        }.start()
        // Patience, not a bound: before, this never came back while the open was stuck.
        #expect(returned.wait(timeout: .now() + 30) == .success, "the wait for the open ended")
        guard case .failure(let error)? = result.withLock({ $0 }) else { Issue.record("no error for a file that never opened"); return }
        guard case NetworkPlaybackCache.Failure.notAnswering = error else { Issue.record("gave up with \(error), not with the share's silence"); return }
    }

    /// A rig whose share opens every song and then sends nothing; `opened` lists the files it was asked for.
    private func quietRig() throws -> (rig: PlayPauseRig, opened: Locked<[String]>, files: Locked<[SilentFile]>) {
        let rig = try PlayPauseRig(seconds: 12)
        let cache = NetworkPlaybackCache(directory: rig.directory.appendingPathComponent("quiet-cache"), budget: 256 << 20, chunk: 1 << 16,
                                         noProgressLimit: 1)
        let opened = Locked<[String]>([]), files = Locked<[SilentFile]>([])
        let size = rig.share.size
        cache.readerFactory = { url in
            let file = SilentFile(size: size)
            opened.withLock { $0.append(url.lastPathComponent) }
            files.withLock { $0.append(file) }
            return file
        }
        rig.engine.cacheOverride = cache
        return (rig, opened, files)
    }

    @Test("After a share did not answer for one song, the songs after it on a share are not each waited for: playback stops with the reason")
    func noWaitForEachSongInTurn() async throws {
        let (rig, opened, files) = try quietRig()
        defer { files.withLock { $0.forEach { $0.release() } } }
        let songs = ["a", "b", "c", "d"].map { (name: String) in PlayableItem(url: URL(fileURLWithPath: "/share/\(name).wav"), cacheKey: name) }
        rig.engine.nextItemProvider = { finished in
            songs.firstIndex { $0.id == finished.id }.flatMap { $0 + 1 < songs.count ? songs[$0 + 1] : nil }
        }
        rig.engine.play(songs[0])
        let stopped = await rig.wait(timeout: 60) { $0.state == .stopped && $0.lastError != nil }
        #expect(stopped, "playback stopped with a reason: \(rig.engine.snapshot.state), \(rig.engine.snapshot.lastError ?? "-")")
        #expect(rig.engine.snapshot.lastError == NetworkPlaybackCache.Failure.notAnswering().localizedDescription)
        // Give a wrong engine the time to go on to the next song (it would open it within moments of the first one's failure).
        await rig.sleep(ms: 1500)
        #expect(Set(opened.withLock { $0 }) == ["a.wav"], "only the song asked for was waited for: \(opened.withLock { $0 })")
        #expect(rig.engine.snapshot.state == .stopped)
    }

    @Test("After a share did not answer for one song, a song after it that is on this Mac plays")
    func localSongAfterQuietShare() async throws {
        let (rig, opened, files) = try quietRig()
        defer { files.withLock { $0.forEach { $0.release() } } }
        let onShare = PlayableItem(url: URL(fileURLWithPath: "/share/a.wav"), cacheKey: "a")
        let local = PlayableItem(url: rig.directory.appendingPathComponent("song.wav"))
        rig.engine.nextItemProvider = { finished in finished.id == onShare.id ? local : nil }
        rig.engine.play(onShare)
        let plays = await rig.wait(timeout: 60) { $0.state == .playing && $0.item?.id == local.id && $0.position > 0.2 }
        #expect(plays, "the song on this Mac plays: \(rig.engine.snapshot.state), \(rig.engine.snapshot.item?.url.lastPathComponent ?? "-")")
        #expect(Set(opened.withLock { $0 }) == ["a.wav"])
        rig.engine.stop()
    }
}
