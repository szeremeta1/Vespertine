//
// Vespertine: going back to a song on a share whose copy was given up before it finished. A song skipped past while it was
// still arriving has its copy given up, and something can still hold that copy (the press's warm-up does, for as long as the
// songs played since are on this Mac). Asked for again, the song was handed that same copy: it started on what was local and
// failed where the copy had stopped, with "The operation was cancelled", every time it was gone back to.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

/// A share's file that sends its first `quietFrom` bytes and nothing after them until `openUp()`.
private final class StoppingShare: PlaybackCacheReader, @unchecked Sendable {
    let bytes: Data
    private let gate = NSCondition()
    private var quietFrom: Int64?
    var size: Int64 { Int64(bytes.count) }
    init(bytes: Data, quietFrom: Int64?) { self.bytes = bytes; self.quietFrom = quietFrom }
    func read(at offset: Int64, count: Int) throws -> Data {
        gate.lock()
        while let quietFrom, offset >= quietFrom { gate.wait() }
        gate.unlock()
        return bytes.subdata(in: Int(offset)..<min(Int(offset) + count, bytes.count))
    }
    func openUp() { gate.withLock { quietFrom = nil; gate.broadcast() } }
}

@Suite("A song's copy that was given up before it finished", .serialized)
struct GivenUpCopyTests {
    private static let block = 4096
    private static let song = Data((0..<block * 6 + 100).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ 7) })

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("given-up-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Asked for again while something still holds the copy that was given up, the song gets a copy of its own and reads to its end")
    func aNewCopyForTheSong() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: Self.block, readsInFlight: 1)
        let url = URL(fileURLWithPath: "/share/song.flac")
        let first = StoppingShare(bytes: Self.song, quietFrom: Int64(Self.block))
        defer { first.openUp() }
        // The song starts on its first block; the rest has not arrived when it is skipped past.
        let skipped = try cache.entry(key: "song", url: url, reader: first)
        try skipped.prepare(full: false, lead: Int64(Self.block), cancelled: { false })
        skipped.cancel()
        #expect(skipped.isGivenUp)
        #expect(throws: NetworkPlaybackCache.Failure.self, "what the given-up copy lacks never arrives") {
            try skipped.read(at: Int64(Self.block), count: Self.block)
        }

        // Gone back to, with the old copy still held (`skipped`): the song is copied afresh.
        let again = try cache.entry(key: "song", url: url, reader: StoppingShare(bytes: Self.song, quietFrom: nil))
        #expect(again !== skipped, "the copy that was given up is not handed out again")
        #expect(!again.isGivenUp)
        #expect(try again.read(at: 0, count: Self.song.count) == Self.song)
        // And it is the song's copy from here on: the next one to ask gets it, not the old one.
        #expect(try cache.entry(key: "song", url: url, reader: StoppingShare(bytes: Self.song, quietFrom: nil)) === again)
    }

    @Test("A copy that had finished before it was let go is still the song's copy: nothing is copied twice")
    func aFinishedCopyIsKept() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = NetworkPlaybackCache(directory: dir, budget: 1 << 20, chunk: Self.block, readsInFlight: 1)
        let url = URL(fileURLWithPath: "/share/song.flac")
        let whole = try cache.entry(key: "song", url: url, reader: StoppingShare(bytes: Self.song, quietFrom: nil))
        try whole.prepare(full: true, lead: 0, cancelled: { false })
        whole.cancel()
        #expect(!whole.isGivenUp, "every byte is local: nothing was given up")
        let again = try cache.entry(key: "song", url: url, reader: StoppingShare(bytes: Self.song, quietFrom: nil))
        #expect(again === whole)
        #expect(try again.read(at: 0, count: Self.song.count) == Self.song)
    }

    @Test("Back to a song on a share that was skipped past while it was still arriving, with a song on this Mac played in between: it plays")
    func backToTheSongSkippedPast() async throws {
        let rig = try PlayPauseRig(seconds: 12)
        let onShare = rig.item()
        let onThisMac = PlayableItem(url: rig.directory.appendingPathComponent("song.wav"))
        // The share sends nothing yet: the song is still arriving when it is skipped past.
        rig.share.stall(true)
        defer { rig.share.stall(false) }
        rig.engine.play(onShare)
        // The scene is set once the engine waits on the song's copy and the press's warm-up holds that copy too.
        do {
            let copy = try rig.cache.entry(key: "song", url: onShare.url)
            let waiting = await rig.wait(timeout: 60) { _ in copy.readsWaiting > 0 && rig.cache.holdsNext }
            #expect(waiting, "the song waits on its copy from the share")
        }

        // On to a song that plays from this Mac: nothing of the share is asked for, and the share song's copy is given up.
        rig.engine.play(onThisMac)
        let moved = await rig.wait(timeout: 60) { $0.state == .playing && $0.item?.id == onThisMac.id && $0.position > 0.2 }
        #expect(moved, "the song on this Mac plays: \(rig.engine.snapshot.state), \(rig.engine.snapshot.lastError ?? "-")")

        // Back to the song on the share, which answers now.
        rig.share.stall(false)
        rig.engine.play(onShare)
        let settled = await rig.wait(timeout: 60) {
            $0.lastError != nil || ($0.state == .playing && $0.item?.id == onShare.id && $0.position > 0.2)
        }
        let snapshot = rig.engine.snapshot
        #expect(snapshot.lastError == nil, "going back to the song did not fail")
        #expect(settled && snapshot.state == .playing && snapshot.item?.id == onShare.id,
                "the song gone back to plays: \(snapshot.state), \(snapshot.item?.url.lastPathComponent ?? "-")")
        rig.engine.stop()
    }
}
