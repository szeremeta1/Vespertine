//
// Vespertine: the phone's first player (stereo): plays a downloaded stream's file through AVAudioEngine with nothing in the
// path but a mixer at unity, checked by rendering the engine offline and comparing every sample with the file.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import AVFAudio
import Foundation
import Testing
import VespertineRemoteProtocol
@testable import VespertinePhonePlayer

private func stereo(rate: Double = 44_100) -> StreamFormat {
    StreamFormat(codec: "WAV", container: "wav", sampleRate: rate, bitDepth: 24, channels: 2, channelLabels: nil, lossless: true)
}

/// A file of `seconds` of two different tones, written and closed.
private func makeFile(seconds: Double, rate: Double = 44_100, channels: Int = 2) throws -> (url: URL, planes: [[Float]]) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("phoneplayer-\(UUID()).wav")
    let frames = Int(seconds * rate)
    let planes: [[Float]] = (0..<channels).map { c in (0..<frames).map { Float(0.4 * sin(2 * Double.pi * (330 + 110 * Double(c)) * Double($0) / rate)) } }
    do {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                                       AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for c in 0..<channels { for i in 0..<frames { buffer.floatChannelData![c][i] = planes[c][i] } }
        try file.write(from: buffer)
    }
    return (url, planes)
}

@MainActor private func offlineEngine(rate: Double) throws -> AVAudioEngine {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    return engine
}

/// Renders `frames` frames from the engine, as the device would pull them.
@MainActor private func render(_ engine: AVAudioEngine, frames: Int) throws -> [[Float]] {
    let format = engine.manualRenderingFormat
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
    var out: [[Float]] = [[], []]
    var left = frames
    while left > 0 {
        let n = AVAudioFrameCount(min(left, 4096))
        let status = try engine.renderOffline(n, to: buffer)
        guard status == .success else { break }
        for c in 0..<2 { out[c].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![c], count: Int(buffer.frameLength))) }
        left -= Int(buffer.frameLength)
    }
    return out
}

@Suite(.serialized) @MainActor struct Player {
    @Test func theSamplesOutAreTheSamplesInUntouched() async throws {
        let (url, planes) = try makeFile(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try offlineEngine(rate: 44_100)
        let player = PhonePlayer(engine: engine)
        try player.load(url, format: stereo())
        #expect(player.state == .ready && abs(player.duration - 1) < 0.001)
        try player.play()
        #expect(player.state == .playing)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let expected = (0..<2).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength))) }
        #expect(expected[0].count == planes[0].count)
        let out = try render(engine, frames: expected[0].count)
        #expect(out[0].count == expected[0].count)
        #expect(out == expected, "bit-exact through the player node and a unity mixer")
    }

    @Test func thePathHasNoGainAndNoEffects() throws {
        let (url, _) = try makeFile(seconds: 0.2)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try offlineEngine(rate: 44_100)
        let player = PhonePlayer(engine: engine)
        try player.load(url, format: stereo())
        #expect(engine.mainMixerNode.outputVolume == 1 && engine.mainMixerNode.volume == 1)
        #expect(player.isUntouchedPath)
    }

    @Test func seekingPlaysFromThere() async throws {
        let (url, planes) = try makeFile(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try offlineEngine(rate: 44_100)
        let player = PhonePlayer(engine: engine)
        try player.load(url, format: stereo())
        try player.play()
        try player.seek(to: 1.0)
        let out = try render(engine, frames: 2_000)
        let start = 44_100
        let maxDiff = (0..<2_000).map { abs(out[0][$0] - planes[0][start + $0]) }.max() ?? 1
        #expect(maxDiff < 1e-6, "the first frame out is frame 44100 of the file")
        #expect(abs(player.position - 1.0) < 0.2)
    }

    @Test func pausingKeepsThePlaceAndPlayingResumes() throws {
        let (url, _) = try makeFile(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try offlineEngine(rate: 44_100)
        let player = PhonePlayer(engine: engine)
        try player.load(url, format: stereo())
        try player.play()
        _ = try render(engine, frames: 8_192)
        player.pause()
        #expect(player.state == .paused)
        let held = player.position
        #expect(held > 0.1 && held < 0.3)
        try player.play()
        #expect(player.state == .playing && abs(player.position - held) < 0.05)
    }

    @Test func stoppingGoesBackToTheStart() throws {
        let (url, _) = try makeFile(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PhonePlayer(engine: try offlineEngine(rate: 44_100))
        try player.load(url, format: stereo())
        try player.play()
        player.stop()
        #expect(player.state == .ready && player.position == 0)
    }

    @Test func multichannelWaitsForTheSpatialPath() throws {
        // Stereo first: a six-channel stream is refused with a clear reason until the 5.1 path (see the plan addendum) is built.
        let (url, _) = try makeFile(seconds: 0.2, channels: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PhonePlayer(engine: try offlineEngine(rate: 44_100))
        let sixChannels = StreamFormat(codec: "WAV", container: "wav", sampleRate: 44_100, bitDepth: 24, channels: 6, channelLabels: [1, 2, 3, 4, 5, 6], lossless: true)
        #expect(throws: PhonePlayer.Failure.multichannelNotYet(6)) { try player.load(url, format: sixChannels) }
        #expect(player.state == .idle)
    }

    @Test func aFileThatIsNotAudioFailsWithWords() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phoneplayer-\(UUID()).flac")
        try Data(repeating: 1, count: 100).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PhonePlayer(engine: try offlineEngine(rate: 44_100))
        #expect(throws: PhonePlayer.Failure.self) { try player.load(url, format: stereo()) }
        #expect(player.state == .idle)
    }
}

@Suite struct Flag {
    @Test func offUnlessTurnedOn() {
        let defaults = UserDefaults(suiteName: "phoneplayer-flag-\(UUID())")!
        #expect(!PhonePlayerFlag.isEnabled(defaults: defaults, arguments: []))
        defaults.set(true, forKey: PhonePlayerFlag.defaultsKey)
        #expect(PhonePlayerFlag.isEnabled(defaults: defaults, arguments: []))
    }

    @Test func theLaunchArgumentWinsEitherWay() {
        let defaults = UserDefaults(suiteName: "phoneplayer-flag-\(UUID())")!
        #expect(PhonePlayerFlag.isEnabled(defaults: defaults, arguments: ["app", "-VespertinePhonePlayer", "YES"]))
        defaults.set(true, forKey: PhonePlayerFlag.defaultsKey)
        #expect(!PhonePlayerFlag.isEnabled(defaults: defaults, arguments: ["app", "-VespertinePhonePlayer", "NO"]))
    }
}
