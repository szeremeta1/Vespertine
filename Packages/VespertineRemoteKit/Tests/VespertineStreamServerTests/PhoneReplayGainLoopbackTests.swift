//
// Vespertine: ReplayGain on the phone, end to end on loopback: a real Mac side with ReplayGain values in its library, the
// real transport, the phone's player rendered offline. Off (where it starts), not a sample differs from the file. On,
// every sample is the file's times one number, the number the file's values and the choice come to.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Network) && canImport(AVFAudio)
import AVFAudio
import Foundation
import Testing
import VespertinePhonePlayer
import VespertineRemoteClient
@testable import VespertineRemoteProtocol

@Suite(.serialized) @MainActor struct ReplayGainOverTheWire {
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
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!,
                                             maximumFrameCount: 4096)
        let player = PhonePlayer(engine: engine)
        player.scheduleAhead = ahead
        let playback = PhonePlayback(session: rig.session, player: player, cacheDirectory: rig.dir.appendingPathComponent("phone-cache"))
        playback.pollInterval = .milliseconds(20)
        playback.tickInterval = .milliseconds(20)
        return (playback, engine)
    }

    /// `samples`, each times `scale`: the very multiplication the player does, so the comparison is exact.
    private func scaled(_ samples: [Float], by scale: Float) -> [Float] { samples.map { $0 * scale } }

    @Test func itStartsOffAndOffNotASampleDiffersFromTheFile() async throws {
        let rig = try await WireRig.make(); defer { try? FileManager.default.removeItem(at: rig.dir) }
        let (playback, engine) = try rigged(rig)
        #expect(playback.replayGain == .off, "nobody is levelled who didn't ask")
        // The Mac has values for these songs and would say so if asked.
        guard case .streamInfo(let items) = await rig.session.send(.streamInfo(ids: [3], maxSampleRate: nil)) else { Issue.record("no info"); return }
        #expect(items.first?.replayGain == WireRig.gainOfSong3)

        playback.play([song(3), song(4)])
        #expect(await waitUntil { playback.player.state == .playing && playback.player.decodedAhead > 1.499 })
        #expect(playback.appliedGain == nil && !playback.replayGainHasNothing)
        #expect(!playback.player.isProcessing && playback.player.gain == 1 && playback.player.isUntouchedPath)
        let first = try decoded(rig.dir.appendingPathComponent("c.wav")), second = try decoded(rig.dir.appendingPathComponent("d.wav"))
        let out = try render(engine, frames: first[0].count + second[0].count)
        #expect(out[0] == first[0] + second[0], "the samples that come out are the decoded samples, every one")
        #expect(out[1] == first[1] + second[1])
        playback.stop()
    }

    @Test func aSongIsScaledByExactlyItsTrackGain() async throws {
        let rig = try await WireRig.make(); defer { try? FileManager.default.removeItem(at: rig.dir) }
        let (playback, engine) = try rigged(rig)
        playback.replayGain = .track
        playback.play([song(3)])
        #expect(await waitUntil { playback.player.state == .playing && playback.player.decodedAhead > 0.999 })
        let applied = try #require(playback.appliedGain)
        #expect(applied.decibels == -6.2 && !applied.heldByPeak)
        #expect(applied.scale == Float(pow(10, -6.2 / 20)))
        #expect(playback.player.isProcessing && playback.player.gain == applied.scale)
        #expect(!playback.player.isUntouchedPath, "a gain is processing: the path is not called untouched while it is on")
        let expected = try decoded(rig.dir.appendingPathComponent("c.wav"))
        let out = try render(engine, frames: expected[0].count)
        #expect(out[0] == scaled(expected[0], by: applied.scale), "every sample is the file's times 10^(-6.2/20), and nothing else")
        #expect(out[1] == scaled(expected[1], by: applied.scale))
        playback.stop()
    }

    @Test func albumUsesTheAlbumsGain() async throws {
        let rig = try await WireRig.make(); defer { try? FileManager.default.removeItem(at: rig.dir) }
        let (playback, engine) = try rigged(rig)
        playback.replayGain = .album
        playback.play([song(3)])
        #expect(await waitUntil { playback.player.state == .playing && playback.player.decodedAhead > 0.999 })
        #expect(playback.appliedGain?.decibels == -3)
        let expected = try decoded(rig.dir.appendingPathComponent("c.wav"))
        let out = try render(engine, frames: expected[0].count)
        #expect(out[0] == scaled(expected[0], by: Float(pow(10, -3.0 / 20))))
        playback.stop()
    }

    @Test func eachSongOfAGaplessPairHasItsOwnGainFromItsFirstFrameAndAPeakIsNeverPushedPastFullScale() async throws {
        let rig = try await WireRig.make(); defer { try? FileManager.default.removeItem(at: rig.dir) }
        let (playback, engine) = try rigged(rig)
        playback.replayGain = .track
        playback.play([song(3), song(4)])
        #expect(await waitUntil { playback.player.state == .playing && playback.player.decodedAhead > 1.499 })
        let first = try decoded(rig.dir.appendingPathComponent("c.wav")), second = try decoded(rig.dir.appendingPathComponent("d.wav"))
        let quieter = Float(pow(10, -6.2 / 20))
        // Song 4 asks for +15 dB, and its peak of 0.25 leaves room for 12.04: it is held at four times, no more.
        let held = try #require(PhoneReplayGain.applied(WireRig.gainOfSong4, choice: .track))
        #expect(held.heldByPeak && abs(held.decibels - 20 * log10(4)) < 1e-9 && held.scale <= 4 && held.scale > 3.9999)
        let out = try render(engine, frames: first[0].count + second[0].count)
        #expect(out[0] == scaled(first[0], by: quieter) + scaled(second[0], by: held.scale), "the gain changes on the join's own frame, with no gap")
        #expect(out[1] == scaled(first[1], by: quieter) + scaled(second[1], by: held.scale))
        #expect(out.joined().allSatisfy { abs($0) <= 1 }, "nothing clips")
        #expect((out[0].map { abs($0) }.max() ?? 0) > 0.99, "and the held song does reach full scale")
        #expect(await waitUntil { playback.nowPlaying?.track.id == 4 })
        #expect(playback.appliedGain == held && playback.player.gain == held.scale)
        playback.stop()
    }

    @Test func aSongWithNoValuesIsLeftAloneAndSaidToHaveNone() async throws {
        let rig = try await WireRig.make(); defer { try? FileManager.default.removeItem(at: rig.dir) }
        let (playback, engine) = try rigged(rig)
        playback.replayGain = .track
        playback.play([song(5)])
        #expect(await waitUntil { playback.player.state == .playing && playback.player.decodedAhead > 0.499 })
        #expect(playback.appliedGain == nil && playback.replayGainHasNothing && !playback.player.isProcessing)
        // The song is at 48 kHz and the offline output at 44.1: only that it plays, unprocessed, is checked here.
        _ = try render(engine, frames: 4_096)
        playback.stop()
    }

    @Test func turningItOnMidSongCarriesOnFromTheSamePlaceWithTheGainAndOffAgainWithout() async throws {
        let rig = try await WireRig.make(); defer { try? FileManager.default.removeItem(at: rig.dir) }
        let (playback, engine) = try rigged(rig)
        playback.play([song(3)])
        #expect(await waitUntil { playback.player.state == .playing && playback.player.decodedAhead > 0.999 })
        let expected = try decoded(rig.dir.appendingPathComponent("c.wav"))
        let before = try render(engine, frames: 8_192)
        #expect(before[0] == Array(expected[0][..<8_192]))

        playback.replayGain = .track
        #expect(await waitUntil { playback.player.state == .playing && playback.appliedGain != nil && playback.player.decodedAhead > 0.7 })
        let scale = try #require(playback.appliedGain).scale
        let with = try render(engine, frames: 4_096)
        // The song carries on from where it was heard to, give or take the frame the place is rounded to.
        let from = try #require((8_190...8_194).first { Array(expected[0][$0..<($0 + 4_096)]).map { $0 * scale } == with[0] })
        #expect(playback.player.isProcessing)

        playback.replayGain = .off
        #expect(await waitUntil { playback.player.state == .playing && playback.appliedGain == nil && !playback.player.isProcessing && playback.player.decodedAhead > 0.5 })
        let without = try render(engine, frames: 4_096)
        let next = from + 4_096
        #expect((next - 2...next + 2).contains { Array(expected[0][$0..<($0 + 4_096)]) == without[0] }, "off again, the samples are the file's own again")
        playback.stop()
    }
}
#endif
