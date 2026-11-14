//
// Vespertine: "Play on this phone" end to end on loopback: the phone asks the Mac for a song, downloads it over the real transport
// (TLS-PSK, binary frames), and plays it through its engine. The samples that come out are the file's.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Network) && canImport(AVFAudio)
import AVFAudio
import Foundation
import Testing
import VespertinePhonePlayer
import VespertineRemoteClient
@testable import VespertineRemoteProtocol

@Suite(.serialized) @MainActor struct PhonePlaybackOverTheWire {
    private func offlineEngine() throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!,
                                             maximumFrameCount: 4096)
        return engine
    }

    private func song(_ id: Int64) -> TrackSummary {
        TrackSummary(id: id, title: "Song \(id)", artist: "Artist", album: "Album", albumKey: "a", duration: 1, trackNumber: Int(id), discNumber: 1,
                     format: "WAV · 16/44.1", artworkKey: nil, favorite: false)
    }

    private func decoded(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return (0..<2).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength))) }
    }

    private func render(_ engine: AVAudioEngine, frames: Int) throws -> [[Float]] {
        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var rendered: [[Float]] = [[], []]
        while rendered[0].count < frames {
            guard try engine.renderOffline(AVAudioFrameCount(min(4096, frames - rendered[0].count)), to: out) == .success else { break }
            for c in 0..<2 { rendered[c].append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![c], count: Int(out.frameLength))) }
        }
        return rendered
    }

    private func rigged(_ rig: WireRig, ahead: Double = 30) throws -> (PhonePlayback, AVAudioEngine) {
        let engine = try offlineEngine()
        let player = PhonePlayer(engine: engine)
        player.scheduleAhead = ahead
        let playback = PhonePlayback(session: rig.session, player: player, cacheDirectory: rig.dir.appendingPathComponent("phone-cache"))
        playback.pollInterval = .milliseconds(20)
        playback.tickInterval = .milliseconds(20)
        return (playback, engine)
    }

    @Test func aSongFromTheMacPlaysOnThePhoneSampleForSample() async throws {
        let rig = try await WireRig.make(); defer { try? FileManager.default.removeItem(at: rig.dir) }
        let (playback, engine) = try rigged(rig)
        playback.play([song(3)])
        #expect(await waitUntil { playback.player.state == .playing && playback.player.decodedAhead > 0.999 })
        #expect(abs(playback.player.duration - 1) < 0.01)
        #expect(playback.stream?.format.container == "wav" && playback.stream?.kind == .original)
        // What the engine renders is what the Mac's file decodes to.
        let expected = try decoded(rig.dir.appendingPathComponent("c.wav"))
        let out = try render(engine, frames: expected[0].count)
        #expect(out == expected)
        playback.stop()
    }

    @Test func anAlbumPlaysThroughWithoutAGapAndTheQueueFollowsWhatIsHeard() async throws {
        let rig = try await WireRig.make(); defer { try? FileManager.default.removeItem(at: rig.dir) }
        let (playback, engine) = try rigged(rig)
        playback.play([song(3), song(4)])
        #expect(await waitUntil { playback.player.state == .playing && playback.player.decodedAhead > 1.499 })
        #expect(playback.nowPlaying?.track.id == 3)
        let first = try decoded(rig.dir.appendingPathComponent("c.wav")), second = try decoded(rig.dir.appendingPathComponent("d.wav"))
        let out = try render(engine, frames: first[0].count + second[0].count)
        #expect(out[0] == first[0] + second[0], "the second song's first sample follows the first song's last")
        #expect(out[1] == first[1] + second[1])
        #expect(await waitUntil { playback.nowPlaying?.track.id == 4 })
        #expect(playback.queue.current?.track.id == 4 && playback.queue.upcoming.isEmpty)
        #expect(playback.stream?.byteSize == Int64(try Data(contentsOf: rig.dir.appendingPathComponent("d.wav")).count))
        playback.stop()
    }

    @Test func aSongAtAnotherRateStartsAfterTheOneBeforeItEnds() async throws {
        let rig = try await WireRig.make(); defer { try? FileManager.default.removeItem(at: rig.dir) }
        let (playback, engine) = try rigged(rig)
        playback.play([song(4), song(5)])
        #expect(await waitUntil { playback.player.state == .playing && playback.player.decodedAhead > 0.499 })
        _ = try render(engine, frames: 22_050 + 4_096)
        #expect(await waitUntil { playback.nowPlaying?.track.id == 5 && playback.player.state == .playing })
        #expect(playback.stream?.format.sampleRate == 48_000)
        playback.stop()
    }

    @Test func aSongThatPlaysOnTheMacOnlyIsPassedOverAndSaidSoInWords() async throws {
        let rig = try await WireRig.make(); defer { try? FileManager.default.removeItem(at: rig.dir) }
        let (playback, _) = try rigged(rig)
        playback.play([song(404), song(3)])
        #expect(await waitUntil { playback.nowPlaying?.track.id == 3 && playback.player.state == .playing })
        #expect(playback.notice?.isEmpty == false)
        playback.stop()
    }

    @Test func theLastSongRefusedStopsWithItsReason() async throws {
        let rig = try await WireRig.make(); defer { try? FileManager.default.removeItem(at: rig.dir) }
        let (playback, _) = try rigged(rig)
        playback.play([song(404)])
        #expect(await waitUntil { playback.notice != nil })
        #expect(playback.player.state == .idle && !playback.isPlaying)
    }

    @Test func nextAndPreviousMoveThroughThePhonesQueue() async throws {
        let rig = try await WireRig.make(); defer { try? FileManager.default.removeItem(at: rig.dir) }
        let (playback, _) = try rigged(rig, ahead: 0.25)
        playback.play([song(3), song(4)])
        #expect(await waitUntil { playback.player.state == .playing })
        playback.next()
        #expect(playback.nowPlaying?.track.id == 4)
        #expect(await waitUntil { playback.player.state == .playing && playback.stream?.format.container == "wav" })
        playback.previous()
        #expect(playback.nowPlaying?.track.id == 3)
        #expect(await waitUntil { playback.player.state == .playing })
        playback.stop()
        #expect(playback.player.state == .idle)
    }

    @Test func playNextDuringASongChangesWhatFollowsIt() async throws {
        let rig = try await WireRig.make(); defer { try? FileManager.default.removeItem(at: rig.dir) }
        let (playback, engine) = try rigged(rig, ahead: 0.25)
        playback.play([song(3), song(3)])
        #expect(await waitUntil { playback.player.state == .playing })
        playback.playNext([song(4)])
        #expect(playback.queue.playingNext.map(\.track.id) == [4])
        // Heard to its end, the first song is followed by the one just added.
        for _ in 0..<40 where playback.nowPlaying?.track.id == 3 {
            _ = try render(engine, frames: 4_096)
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(await waitUntil { playback.nowPlaying?.track.id == 4 })
        playback.stop()
    }
}
#endif
