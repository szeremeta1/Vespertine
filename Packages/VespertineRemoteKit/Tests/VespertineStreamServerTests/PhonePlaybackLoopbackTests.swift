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

    @Test func aSongFromTheMacPlaysOnThePhoneSampleForSample() async throws {
        let rig = try await WireRig.make(); defer { try? FileManager.default.removeItem(at: rig.dir) }
        let engine = try offlineEngine()
        let player = PhonePlayer(engine: engine)
        let cache = rig.dir.appendingPathComponent("phone-cache")
        let playback = PhonePlayback(session: rig.session, player: player, cacheDirectory: cache)
        try await playback.play(song: 3, maxSampleRate: nil)
        #expect(player.state == .playing && abs(player.duration - 1) < 0.01)
        #expect(player.format?.container == "wav")

        // What the engine renders is what the Mac's file decodes to.
        let wavURL = rig.dir.appendingPathComponent("c.wav")
        let file = try AVAudioFile(forReading: wavURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let expected = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: expected)
        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var rendered: [[Float]] = [[], []]
        while rendered[0].count < Int(file.length) {
            guard try engine.renderOffline(AVAudioFrameCount(min(4096, Int(file.length) - rendered[0].count)), to: out) == .success else { break }
            for c in 0..<2 { rendered[c].append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![c], count: Int(out.frameLength))) }
        }
        for c in 0..<2 { #expect(rendered[c] == Array(UnsafeBufferPointer(start: expected.floatChannelData![c], count: Int(expected.frameLength)))) }
    }

    @Test func aSongThatPlaysOnTheMacOnlyIsSaidSoInWords() async throws {
        let rig = try await WireRig.make(); defer { try? FileManager.default.removeItem(at: rig.dir) }
        let playback = PhonePlayback(session: rig.session, player: PhonePlayer(engine: try offlineEngine()), cacheDirectory: rig.dir.appendingPathComponent("c"))
        await #expect(throws: PhonePlayback.Failure.self) { try await playback.play(song: 404, maxSampleRate: nil) }
    }
}
#endif
