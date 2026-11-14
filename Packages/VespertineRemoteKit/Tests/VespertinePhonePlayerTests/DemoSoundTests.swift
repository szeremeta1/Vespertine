//
// Vespertine: the demo plays on this device. Its songs are sound the app makes itself (a few soft notes, different for each
// song), so App Review and anyone without a Mac can hear the player work: the lock screen, the queue, playing in the background.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Network) && canImport(AVFAudio)
import AVFAudio
import Foundation
import Testing
import VespertineRemoteClient
import VespertineRemoteProtocol
@testable import VespertinePhonePlayer

@Suite(.serialized) @MainActor struct DemoSoundTests {
    @Test func aDemoSongIsAWholeWaveFileOfQuietSound() throws {
        let data = DemoSound.wave(song: 7, seconds: 4)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID()).wav")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 44_100 && file.fileFormat.channelCount == 2)
        #expect(file.length == 4 * 44_100)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let left = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        let peak = left.map(abs).max() ?? 0
        // Heard, and well under full scale.
        #expect(peak > 0.05 && peak < 0.5)
        // It begins and ends in silence, so songs follow one another without a click.
        #expect(abs(left[0]) < 0.001 && abs(left[left.count - 1]) < 0.001)
    }

    @Test func eachSongSoundsDifferentAndTheSameEveryTime() {
        #expect(DemoSound.wave(song: 1, seconds: 1) == DemoSound.wave(song: 1, seconds: 1))
        #expect(DemoSound.wave(song: 1, seconds: 1) != DemoSound.wave(song: 2, seconds: 1))
    }

    @Test func theDemoPlaysOnThePhoneThroughTheSamePlayerAsAMacsSongs() async throws {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!,
                                             maximumFrameCount: 4096)
        let playback = PhonePlayback(client: DemoSound.client(seconds: 2), player: PhonePlayer(engine: engine),
                                     cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID())"))
        let track = TrackSummary(id: 3, title: "Song", artist: "Artist", album: "Album", albumKey: "a", duration: 200, trackNumber: 1, discNumber: 1,
                                 format: "FLAC · 24/96", artworkKey: nil, favorite: false)
        playback.play([track])
        let deadline = Date().addingTimeInterval(5)
        while playback.player.state != .playing, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(playback.player.state == .playing)
        #expect(playback.stream?.format.container == "wav" && playback.stream?.kind == .original)
        // The song is as long as its sound, not as long as the made-up library says.
        #expect(abs(playback.duration - 2) < 0.05)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        var peak: Float = 0
        for _ in 0..<12 {
            _ = try engine.renderOffline(4096, to: buffer)
            peak = max(peak, UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)).map(abs).max() ?? 0)
        }
        #expect(peak > 0.02)
        playback.stop()
    }
}
#endif
