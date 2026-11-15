//
// Vespertine: a queue put back from an earlier launch waits, paused at its place, and asks the Mac for nothing until Play;
// the queue is written as it changes; and the two joins gapless playback had no test for (Repeat One, and a next song
// the Mac is slow to open) are heard sample for sample.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Network) && canImport(AVFAudio)
import AVFAudio
import Foundation
import Testing
import VespertineRemoteClient
import VespertineRemoteProtocol
@testable import VespertinePhonePlayer

private let rate = Double(DemoSound.sampleRate)

/// A Mac that sends every song as a short made sound (a different one per song), keeps what it was asked, and can be told
/// to hold a song back until it is let go.
private final class TapeMac: @unchecked Sendable {
    private let lock = NSLock()
    private var open: [Int: Data] = [:]
    private var next = 0
    private var _asks: [Int64] = []
    private var held: Set<Int64> = []
    let seconds: Double

    init(seconds: Double = 1) { self.seconds = seconds }

    var asks: [Int64] { lock.withLock { _asks } }
    func hold(_ song: Int64) { lock.withLock { _ = held.insert(song) } }
    func letGo(_ song: Int64) { lock.withLock { _ = held.remove(song) } }

    func samples(_ song: Int64) -> [Float] {
        let data = DemoSound.wave(song: song, seconds: seconds)
        return data.dropFirst(44).withUnsafeBytes { raw in
            stride(from: 0, to: raw.count - 3, by: 4).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: Int16.self))) / 32_768 }
        }
    }

    var client: PhoneStreamClient {
        PhoneStreamClient(open: { [self] song, _ in
            let data = DemoSound.wave(song: song, seconds: seconds)
            return lock.withLock {
                _asks.append(song)
                // Still "converting": the phone asks again.
                if held.contains(song) { return .streamPreparing(progress: nil) }
                next += 1
                open[next] = data
                return .streamOpened(StreamDescriptor(stream: next, kind: .original, byteSize: Int64(data.count),
                                                      format: StreamFormat(codec: "WAV", container: "wav", sampleRate: rate, bitDepth: 16, channels: 2,
                                                                           channelLabels: nil, lossless: true),
                                                      frames: Int64((data.count - 44) / 4), tag: "\(song)", chunkSize: RemoteProtocol.defaultChunkSize))
            }
        }, read: { [self] stream, offset, length in
            guard let data = lock.withLock({ open[stream] }), offset >= 0, offset <= Int64(data.count) else { throw RemoteLinkError.closed }
            let end = min(Int(offset) + max(0, length), data.count)
            return StreamFrame(request: 0, stream: stream, offset: offset, endOfStream: end >= data.count, payload: data.subdata(in: Int(offset)..<end))
        }, close: { [self] stream in lock.withLock { open[stream] = nil } }, isConnected: { true })
    }
}

private func song(_ id: Int64, seconds: Double = 1) -> TrackSummary {
    TrackSummary(id: id, title: "Song \(id)", artist: "Artist", album: "Album", albumKey: "a", duration: seconds, trackNumber: Int(id), discNumber: 1,
                 format: "WAV · 16/44.1", artworkKey: nil, favorite: false)
}

@Suite(.serialized) @MainActor struct QueueBetweenLaunches {
    private func make(_ mac: TapeMac) throws -> (PhonePlayback, AVAudioEngine) {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!,
                                             maximumFrameCount: 4096)
        let player = PhonePlayer(engine: engine)
        player.scheduleAhead = 30
        let playback = PhonePlayback(client: mac.client, player: player,
                                     cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("phone-queue-\(UUID())"))
        playback.pollInterval = .milliseconds(5)
        playback.tickInterval = .milliseconds(5)
        return (playback, engine)
    }

    private func shelf() -> QueueShelf {
        QueueShelf(directory: FileManager.default.temporaryDirectory.appendingPathComponent("queues-\(UUID())", isDirectory: true))
    }

    /// Waits for something the phone must get round to. The 1000 looks end a run where it never does; they decide nothing. They are counted, not timed: a busy
    /// machine that holds every test still for seconds uses up a clock but not a count.
    private func until(_ condition: () -> Bool) async throws {
        var looks = 0
        while !condition(), looks < 1000 { looks += 1; try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    private func render(_ engine: AVAudioEngine, frames: Int) throws -> [Float] {
        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var left: [Float] = []
        while left.count < frames {
            guard try engine.renderOffline(AVAudioFrameCount(min(4096, frames - left.count)), to: out) == .success else { break }
            left.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
        }
        return left
    }

    /// A queue of five with the second song current, left 0.4 seconds in.
    private func left() -> SavedQueue {
        var queue = PhoneQueue()
        queue.play((1...5).map { song($0) }, startAt: 1)
        return SavedQueue(queue: queue, position: 0.4)
    }

    // MARK: Putting a queue back

    @Test func aQueuePutBackWaitsPausedAtItsPlaceAndAsksTheMacForNothing() async throws {
        let mac = TapeMac()
        let (playback, _) = try make(mac)
        #expect(playback.restore(left()))
        #expect(playback.nowPlaying?.track.id == 2 && playback.queue.upcoming.count == 3)
        #expect(playback.position == 0.4 && playback.resumeAt == 0.4)
        #expect(!playback.isPlaying && playback.player.state == .idle)
        let remote = PhoneRemote(playback: playback) { _ in .failed(reason: "") }
        #expect(remote.playerState.playback == .paused, "paused at its place, not stopped at the start")
        #expect(remote.playerState.position == 0.4 && remote.playerState.duration == 1)
        // Let anything that was going to ask the Mac get its turn.
        for _ in 0..<20 { await Task.yield() }
        #expect(mac.asks.isEmpty)
    }

    @Test func playStartsTheSongWhereItWasLeftSampleForSample() async throws {
        let mac = TapeMac()
        let (playback, engine) = try make(mac)
        playback.restore(left())
        playback.resume()
        try await until { playback.player.state == .playing && playback.player.decodedAhead > 0.59 }
        #expect(playback.resumeAt == nil)
        let from = Int(0.4 * rate)
        let expected = Array(mac.samples(2)[from...])
        #expect(try render(engine, frames: expected.count) == expected)
        playback.stop()
    }

    @Test func seekingBeforePlayMovesWhereItStarts() async throws {
        let mac = TapeMac()
        let (playback, engine) = try make(mac)
        playback.restore(left())
        playback.seek(to: 0.75)
        #expect(playback.position == 0.75 && mac.asks.isEmpty)
        playback.seek(to: 99)
        #expect(playback.position == 1, "never past the song's end")
        playback.seek(to: 0.5)
        playback.resume()
        try await until { playback.player.state == .playing && playback.player.decodedAhead > 0.49 }
        let expected = Array(mac.samples(2)[Int(0.5 * rate)...])
        #expect(try render(engine, frames: expected.count) == expected)
        playback.stop()
    }

    @Test func nextOnAQueuePutBackStartsTheNextSongFromItsBeginning() async throws {
        let mac = TapeMac()
        let (playback, _) = try make(mac)
        playback.restore(left())
        playback.next()
        try await until { playback.player.state == .playing }
        #expect(playback.nowPlaying?.track.id == 3 && playback.resumeAt == nil)
        #expect(abs(playback.livePosition) < 0.001)
        playback.stop()
    }

    @Test func aQueuePutBackNeverReplacesOneThatIsAlreadyThere() async throws {
        let mac = TapeMac()
        let (playback, _) = try make(mac)
        playback.play([song(7)])
        #expect(!playback.restore(left()))
        #expect(playback.nowPlaying?.track.id == 7)
        playback.stop()
        // Stopped, the queue is still the one you made.
        #expect(!playback.restore(left()))
        #expect(playback.queue.current?.track.id == 7)
    }

    // MARK: Keeping it as it changes

    @Test func theQueueIsWrittenAsItChangesAndComesBackInANewPlayer() async throws {
        let mac = TapeMac()
        let shelf = shelf()
        defer { try? FileManager.default.removeItem(at: shelf.directory) }
        let (playback, _) = try make(mac)
        let keeper = QueueKeeper(playback: playback, shelf: shelf, owner: "mac")
        keeper.start()
        #expect(shelf.load("mac") == nil)
        playback.play((1...4).map { song($0) }, startAt: 1)
        try await until { playback.player.state == .playing }
        playback.playNext([song(9)])
        playback.setRepeat(.all)
        playback.pause()
        playback.seek(to: 0.3)
        // The keeper hears of changes on the main actor's next turns, and writes the queue off it.
        try await until { shelf.load("mac")?.queue == playback.queue && shelf.load("mac")?.position == playback.livePosition }
        await keeper.settled()
        let kept = try #require(shelf.load("mac"))
        #expect(kept.queue.current?.track.id == 2 && kept.queue.repeatMode == .all)
        #expect(kept.queue.playingNext.compactMap(\.track.id) == [9])
        #expect(abs(kept.position - 0.3) < 0.001)

        // The app is ended and opened again: another player, the same shelf.
        let (again, _) = try make(mac)
        let asksBefore = mac.asks.count
        let second = QueueKeeper(playback: again, shelf: shelf, owner: "mac")
        second.start()
        #expect(again.queue == playback.queue)
        #expect(again.nowPlaying?.track.id == 2 && abs(again.position - 0.3) < 0.001)
        #expect(!again.isPlaying && mac.asks.count == asksBefore)
        playback.stop()
    }

    @Test func puttingTheAppAwayWritesThePlaceAtOnce() async throws {
        let mac = TapeMac()
        let shelf = shelf()
        defer { try? FileManager.default.removeItem(at: shelf.directory) }
        let (playback, engine) = try make(mac)
        let keeper = QueueKeeper(playback: playback, shelf: shelf, owner: "mac")
        // The clock that writes the place while a song plays is out of this test: only the call below may write it.
        keeper.interval = .seconds(3_600)
        keeper.start()
        playback.play([song(1), song(2)])
        try await until { playback.player.state == .playing && playback.player.decodedAhead > 0.99 }
        try await until { shelf.load("mac") != nil }
        await keeper.settled()
        _ = try render(engine, frames: Int(0.5 * rate))
        keeper.saveNow()
        let kept = try #require(shelf.load("mac"))
        #expect(kept.queue.current?.track.id == 1)
        #expect(abs(kept.position - 0.5) < 0.01, "\(kept.position)")
        playback.stop()
    }

    @Test func leavingAMacKeepsThePlaceTheSongWasAtNotTheStartItIsPutBackTo() async throws {
        let mac = TapeMac()
        let shelf = shelf()
        defer { try? FileManager.default.removeItem(at: shelf.directory) }
        let (playback, engine) = try make(mac)
        let keeper = QueueKeeper(playback: playback, shelf: shelf, owner: "mac")
        keeper.interval = .seconds(3_600)
        keeper.start()
        playback.play([song(1), song(2)])
        try await until { playback.player.state == .playing && playback.player.decodedAhead > 0.99 }
        _ = try render(engine, frames: Int(0.25 * rate))
        // As the app does when another Mac is chosen: the keeper first, then the player.
        keeper.stop()
        playback.stop()
        for _ in 0..<20 { await Task.yield() }
        #expect(abs((shelf.load("mac")?.position ?? 0) - 0.25) < 0.01)
    }
}

// MARK: - Gapless joins that had no test

@Suite(.serialized) @MainActor struct GaplessJoins {
    private func make(_ mac: TapeMac) throws -> (PhonePlayback, AVAudioEngine) {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!,
                                             maximumFrameCount: 4096)
        let player = PhonePlayer(engine: engine)
        player.scheduleAhead = 30
        let playback = PhonePlayback(client: mac.client, player: player,
                                     cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("phone-gapless-\(UUID())"))
        playback.pollInterval = .milliseconds(5)
        playback.tickInterval = .milliseconds(5)
        return (playback, engine)
    }

    private func until(_ condition: () -> Bool) async throws {
        var looks = 0
        while !condition(), looks < 1000 { looks += 1; try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    private func render(_ engine: AVAudioEngine, frames: Int) throws -> [Float] {
        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var left: [Float] = []
        while left.count < frames {
            guard try engine.renderOffline(AVAudioFrameCount(min(4096, frames - left.count)), to: out) == .success else { break }
            left.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
        }
        return left
    }

    @Test func repeatOneGoesRoundWithoutAGapAndTheQueueStaysOnTheSong() async throws {
        let mac = TapeMac(seconds: 0.5)
        let (playback, engine) = try make(mac)
        playback.play([song(1, seconds: 0.5), song(2, seconds: 0.5)])
        playback.setRepeat(.one)
        let once = mac.samples(1)
        // Two and a half times round are decoded ahead before anything is rendered.
        try await until { playback.player.state == .playing && playback.player.decodedAhead > 1.24 }
        let heard = try render(engine, frames: once.count * 2 + once.count / 2)
        #expect(heard == once + once + Array(once.prefix(once.count / 2)), "the song's first sample follows its last, each time round")
        playback.tick()
        #expect(playback.nowPlaying?.track.id == 1 && playback.queue.current?.track.id == 1)
        #expect(abs(playback.livePosition - 0.25) < 0.01, "the place is the place in this time round: \(playback.livePosition)")
        #expect(!mac.asks.contains(2), "the song after it is never fetched while Repeat One is on")
        playback.stop()
    }

    @Test func aNextSongTheMacIsSlowToOpenPlaysWhenItComesAndNothingIsSkipped() async throws {
        let mac = TapeMac(seconds: 0.5)
        let (playback, engine) = try make(mac)
        mac.hold(2)
        playback.play([song(1, seconds: 0.5), song(2, seconds: 0.5), song(3, seconds: 0.5)])
        try await until { playback.player.state == .playing && playback.player.decodedAhead > 0.49 && mac.asks.contains(2) }
        let first = mac.samples(1)
        // The first song is heard to its end with the second still not here.
        #expect(try render(engine, frames: first.count) == first)
        _ = try render(engine, frames: 4_096)
        try await until { playback.nowPlaying?.track.id == 2 }
        #expect(playback.isPlaying, "waiting for the Mac, not stopped")
        #expect(playback.notice == nil)
        mac.letGo(2)
        try await until { playback.player.state == .playing && playback.player.decodedAhead > 0.99 }
        // Song 2 from its first sample, then song 3 joined to it.
        let second = mac.samples(2), third = mac.samples(3)
        #expect(try render(engine, frames: second.count + third.count) == second + third)
        playback.stop()
    }

    @Test func aNextSongThatComesJustBeforeTheEndStillJoinsWithoutAGap() async throws {
        let mac = TapeMac(seconds: 0.5)
        let (playback, engine) = try make(mac)
        mac.hold(2)
        playback.play([song(1, seconds: 0.5), song(2, seconds: 0.5)])
        // All of the first song is decoded and waiting; the second is still being asked for.
        try await until { playback.player.state == .playing && playback.player.decodedAhead > 0.49 && mac.asks.contains(2) }
        let first = mac.samples(1), second = mac.samples(2)
        let early = try render(engine, frames: first.count / 2)
        mac.letGo(2)
        try await until { playback.player.decodedAhead > 0.74 }
        let rest = try render(engine, frames: first.count / 2 + second.count)
        #expect(early + rest == first + second, "it arrived while the first song still had audio to play: no gap")
        playback.stop()
    }
}
#endif
