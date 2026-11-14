//
// Vespertine: surround on the phone. A 5.1 or 7.1 song is decoded onto the bed Apple's spatial mixer takes, each channel on
// the speaker of its own place, and is rendered for headphones (Fixed or Head Tracked) or folded to stereo (Off). Checked by
// rendering the engine offline: every channel is heard, and on the side it belongs to.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(AVFAudio)
import AudioToolbox
import AVFAudio
import Foundation
import Testing
import VespertineChannels
import VespertineRemoteProtocol
@testable import VespertinePhonePlayer

private let rate = 48_000.0

/// A WAV of `channels` channels, silent except for a tone on `only` (or a different tone on each when nil).
private func surroundFile(channels: Int, only: Int?, seconds: Double = 0.4) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("surround-\(UUID()).wav")
    let frames = Int(seconds * rate)
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                                   AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for c in 0..<channels {
        let hertz = 300 + 100 * Double(c)
        for i in 0..<frames {
            buffer.floatChannelData![c][i] = only == nil || only == c ? Float(0.4 * sin(2 * Double.pi * hertz * Double(i) / rate)) : 0
        }
    }
    try file.write(from: buffer)
    return url
}

private func format(_ labels: [AudioChannelLabel]) -> StreamFormat {
    StreamFormat(codec: "WAV", container: "wav", sampleRate: rate, bitDepth: 24, channels: labels.count, channelLabels: labels, lossless: true)
}

private let L = kAudioChannelLabel_Left, R = kAudioChannelLabel_Right, C = kAudioChannelLabel_Center, LFE = kAudioChannelLabel_LFEScreen
private let Ls = kAudioChannelLabel_LeftSurround, Rs = kAudioChannelLabel_RightSurround
private let fivePointOne = [L, R, C, LFE, Ls, Rs]

private func level(_ samples: [Float]) -> Float {
    samples.isEmpty ? 0 : (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
}

@MainActor private func rendered(_ player: PhonePlayer, _ engine: AVAudioEngine, seconds: Double = 0.3) throws -> (left: Float, right: Float) {
    let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
    var out: [[Float]] = [[], []]
    var left = Int(seconds * rate)
    while left > 0 {
        guard try engine.renderOffline(AVAudioFrameCount(min(left, 4096)), to: buffer) == .success else { break }
        for c in 0..<2 { out[c].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![c], count: Int(buffer.frameLength))) }
        left -= Int(buffer.frameLength)
    }
    return (level(out[0]), level(out[1]))
}

@MainActor private func offline() throws -> AVAudioEngine {
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!,
                                         maximumFrameCount: 4096)
    return engine
}

@Suite(.serialized) @MainActor struct Surround {
    @Test func aSongsChannelsAreDecodedOntoTheBedInTheirOwnPlaces() throws {
        // The channels come as C L R Ls Rs LFE (the order AAC uses); the bed is 5.1 in L R C LFE Ls Rs.
        let labels = [C, L, R, Ls, Rs, LFE]
        let url = try surroundFile(channels: 6, only: 3)   // the tone is on the song's Ls
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try StreamDecoder(source: try FileByteSource(url: url), format: format(labels))
        #expect(decoder.processingFormat.channelLayout?.layoutTag == kAudioChannelLayoutTag_MPEG_5_1_A)
        #expect(decoder.processingFormat.channelCount == 6)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4800))
        #expect(try decoder.read(into: buffer) == 4800)
        let levels = (0..<6).map { level(Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: 4800))) }
        #expect(levels[4] > 0.2, "the bed's Ls")
        for other in [0, 1, 2, 3, 5] { #expect(levels[other] == 0, "bed speaker \(other)") }
    }

    @Test func unlabeledSevenPointOneIsTakenInWaveOrder() throws {
        // FLAC and WAVE put the back pair fifth and sixth. With no labels from the Mac, that order is assumed.
        let url = try surroundFile(channels: 8, only: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let plain = StreamFormat(codec: "WAV", container: "wav", sampleRate: rate, bitDepth: 24, channels: 8, channelLabels: nil, lossless: true)
        let decoder = try StreamDecoder(source: try FileByteSource(url: url), format: plain)
        let bed = try #require(decoder.processingFormat.channelLayout).channelLabels
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4800))
        _ = try decoder.read(into: buffer)
        let rearLeft = try #require(bed.firstIndex(of: kAudioChannelLabel_RearSurroundLeft))
        #expect(level(Array(UnsafeBufferPointer(start: buffer.floatChannelData![rearLeft], count: 4800))) > 0.2)
    }

    @Test(arguments: [SpatialMode.fixed, .headTracked])
    func everyChannelIsHeardThroughTheSpatialMixer(mode: SpatialMode) throws {
        for channel in [0, 1, 2, 4, 5] {
            let url = try surroundFile(channels: 6, only: channel)
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = try offline()
            let player = PhonePlayer(engine: engine)
            player.spatialMode = mode
            try player.load(url, format: format(fivePointOne))
            try player.play()
            #expect(player.rendering == .spatial(headTracked: mode == .headTracked))
            #expect(!player.isUntouchedPath)
            let heard = try rendered(player, engine)
            #expect(max(heard.left, heard.right) > 0.01, "channel \(channel) is silent in \(mode)")
            // The surrounds stay on their own side.
            if channel == 4 { #expect(heard.left > heard.right, "Ls") }
            if channel == 5 { #expect(heard.right > heard.left, "Rs") }
            player.halt()
        }
    }

    @Test func withSpatialOffSurroundIsFoldedToStereoWithEveryChannelHeard() throws {
        for channel in [0, 1, 2, 4, 5] {
            let url = try surroundFile(channels: 6, only: channel)
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = try offline()
            let player = PhonePlayer(engine: engine)
            player.spatialMode = .off
            try player.load(url, format: format(fivePointOne))
            try player.play()
            #expect(player.rendering == .downmix)
            let heard = try rendered(player, engine)
            #expect(max(heard.left, heard.right) > 0.01, "channel \(channel) is silent")
            switch channel {
            case 0, 4: #expect(heard.left > heard.right * 4, "channel \(channel) belongs on the left")
            case 1, 5: #expect(heard.right > heard.left * 4, "channel \(channel) belongs on the right")
            default: #expect(abs(heard.left - heard.right) < 0.01, "the centre is in the middle")
            }
            player.halt()
        }
    }

    @Test func stereoIsLeftAlone() throws {
        let url = try surroundFile(channels: 2, only: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PhonePlayer(engine: try offline())
        player.spatialMode = .headTracked
        try player.load(url, format: StreamFormat(codec: "WAV", container: "wav", sampleRate: rate, bitDepth: 24, channels: 2, channelLabels: nil, lossless: true))
        #expect(player.rendering == .untouched && player.isUntouchedPath)
    }

    @Test func changingTheModeWhileASurroundSongPlaysCarriesOn() throws {
        let url = try surroundFile(channels: 6, only: nil, seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try offline()
        let player = PhonePlayer(engine: engine)
        player.spatialMode = .fixed
        try player.load(url, format: format(fivePointOne))
        try player.play()
        _ = try rendered(player, engine, seconds: 0.5)
        player.spatialMode = .off
        #expect(player.rendering == .downmix && player.state == .playing)
        #expect(abs(player.position - 0.5) < 0.1)
        let heard = try rendered(player, engine, seconds: 0.2)
        #expect(heard.left > 0.01 && heard.right > 0.01)
    }
}
#endif
