//
// Vespertine: MP3 and AAC albums play without a gap on the phone. An encoder puts silence in front of a song (its delay) and
// fills the last block out with more (padding), and says how much in the file: a LAME header or an iTunSMPB comment in an
// MP3, an edit list or an iTunSMPB tag in an M4A. Apple's decoder, which the phone's player decodes with, reads all four
// and leaves both out. These tests hold it to that: one tone cut in two and encoded as two songs comes out of the player
// as one tone, to the frame.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(AVFAudio)
import AVFAudio
import Foundation
import Testing
import VespertineRemoteProtocol
@testable import VespertinePhonePlayer

private let rate = 44_100.0

/// The tone the fixtures were cut from, at `frame` of the whole.
private func tone(_ frame: Int) -> Float {
    Float(0.5 * sin(2 * Double.pi * 440 * Double(frame) / rate))
}

/// How far a lossy encoding of the tone may be from the tone itself. The fixtures stay within 0.02 of it, most at the
/// ends of each half where the encoder had nothing before or after to work with. Delay or padding left in would put
/// silence where the tone should be (off by 0.5) or the tone out of step.
private let lossyStep: Float = 0.05

private func lossy(_ container: String) -> StreamFormat {
    StreamFormat(codec: container == "mp3" ? "MP3" : "AAC", container: container, sampleRate: rate, bitDepth: nil, channels: 2,
                 channelLabels: nil, lossless: false)
}

private func write(_ data: Data, _ container: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gapless-\(UUID()).\(container)")
    try data.write(to: url)
    return url
}

@MainActor private func offlineEngine() throws -> AVAudioEngine {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    return engine
}

@MainActor private func render(_ engine: AVAudioEngine, frames: Int) throws -> [[Float]] {
    let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
    var out: [[Float]] = [[], []]
    var left = frames
    while left > 0 {
        let status = try engine.renderOffline(AVAudioFrameCount(min(left, 4096)), to: buffer)
        guard status == .success else { break }
        for c in 0..<2 { out[c].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![c], count: Int(buffer.frameLength))) }
        left -= Int(buffer.frameLength)
    }
    return out
}

/// Counted, not timed (see PhonePlayerTests).
@MainActor private func wait(until condition: () -> Bool) async throws {
    var looks = 0
    while !condition() {
        if looks == 500 { Issue.record("the condition never held"); return }
        looks += 1
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// The frame where what came out is furthest from the tone, and by how much.
private func worst(_ samples: ArraySlice<Float>, from first: Int) -> (frame: Int, by: Float) {
    var worst = (frame: first, by: Float(0))
    for (offset, sample) in samples.enumerated() {
        let by = abs(sample - tone(first + offset))
        if by > worst.by { worst = (first + offset, by) }
    }
    return worst
}

@Suite(.serialized) @MainActor struct LossyGapless {
    /// Plays the two halves one after the other through the player and holds every frame that comes out against the tone.
    private func playsAsOneTone(_ first: Data, _ second: Data, container: String) async throws {
        let a = try write(first, container), b = try write(second, container)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let whole = GaplessFixtures.firstFrames + GaplessFixtures.secondFrames

        // Each song is as long as the music in it: the delay and the padding aren't counted.
        #expect(try StreamDecoder(source: FileByteSource(url: a), format: lossy(container)).length == Int64(GaplessFixtures.firstFrames))
        #expect(try StreamDecoder(source: FileByteSource(url: b), format: lossy(container)).length == Int64(GaplessFixtures.secondFrames))

        let engine = try offlineEngine()
        let player = PhonePlayer(engine: engine)
        player.scheduleAhead = 30
        var scheduled: [String] = [], advanced: [String] = []
        player.onScheduledNext = { scheduled.append($0) }
        player.onAdvance = { advanced.append($0) }
        player.start(.init(id: "a", source: try FileByteSource(url: a), format: lossy(container)), playing: true)
        player.setFollowing(.init(id: "b", source: try FileByteSource(url: b), format: lossy(container)))
        try await wait { scheduled == ["b"] && player.decodedAhead > Double(whole) / rate - 0.001 }
        #expect(abs(player.duration - Double(GaplessFixtures.firstFrames) / rate) < 0.0001)

        // A little more than both songs: what follows the second one must be nothing at all.
        let out = try render(engine, frames: whole + 2_048)
        #expect(out[0].count == whole + 2_048)
        for channel in out {
            let music = worst(channel[..<whole], from: 0)
            #expect(music.by < lossyStep, "frame \(music.frame) is \(music.by) from the tone: it is one tone from the first frame to the last")
            // The join itself: the second song's first frame is the tone's frame 13,000, right after the first song's last.
            let join = worst(channel[(GaplessFixtures.firstFrames - 64)..<(GaplessFixtures.firstFrames + 64)], from: GaplessFixtures.firstFrames - 64)
            #expect(join.by < lossyStep, "frame \(join.frame) at the join is \(join.by) from the tone")
            #expect(channel[whole...].allSatisfy { $0 == 0 }, "no padding is played after the last song")
        }
        player.tick()
        #expect(advanced == ["b"] && player.currentID == "b")
        #expect(abs(player.duration - Double(GaplessFixtures.secondFrames) / rate) < 0.0001)
    }

    @Test func twoMP3sWithLAMEHeadersPlayAsOneTone() async throws {
        try await playsAsOneTone(GaplessFixtures.lameFirst, GaplessFixtures.lameSecond, container: "mp3")
    }

    @Test func twoMP3sWithITunSMPBCommentsPlayAsOneTone() async throws {
        try await playsAsOneTone(GaplessFixtures.iTunesMP3First, GaplessFixtures.iTunesMP3Second, container: "mp3")
    }

    @Test func twoM4AsWithEditListsPlayAsOneTone() async throws {
        try await playsAsOneTone(GaplessFixtures.editListFirst, GaplessFixtures.editListSecond, container: "m4a")
    }

    @Test func twoM4AsWithITunSMPBTagsPlayAsOneTone() async throws {
        try await playsAsOneTone(GaplessFixtures.iTunSMPBFirst, GaplessFixtures.iTunSMPBSecond, container: "m4a")
    }

    /// A seek lands on the song's own frame, not on a frame of the file that still counts the delay.
    @Test(arguments: ["mp3", "m4a"]) func aSeekCountsFromTheMusicNotTheDelay(container: String) throws {
        let url = try write(container == "mp3" ? GaplessFixtures.lameFirst : GaplessFixtures.iTunSMPBFirst, container)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try StreamDecoder(source: FileByteSource(url: url), format: lossy(container))
        try decoder.seek(to: 6_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 2_000))
        #expect(try decoder.read(into: buffer) == 2_000)
        let heard = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 2_000))
        let off = worst(heard[...], from: 6_000)
        #expect(off.by < lossyStep, "frame \(off.frame) is \(off.by) from the tone")
    }

    /// The limit, pinned so it is known: an MP3 that says nothing about its delay or padding (no LAME header, no iTunSMPB)
    /// gives nothing to go by, so it plays whole, silence and all. No player can do better with such a file.
    @Test func anMP3ThatSaysNothingPlaysWhole() throws {
        let url = try write(GaplessFixtures.bareMP3, "mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try StreamDecoder(source: FileByteSource(url: url), format: lossy("mp3"))
        #expect(decoder.length >= Int64(GaplessFixtures.firstFrames + 576), "13 blocks of 1,152 frames: the delay and the padding are counted")
    }
}
#endif
