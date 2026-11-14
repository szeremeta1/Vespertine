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
            // The surrounds stay on their own side. Head tracked, the side depends on where a real head is turned when
            // head-tracking headphones are connected to the machine running this, so only the fixed scene is held to it.
            if mode == .fixed {
                if channel == 4 { #expect(heard.left > heard.right, "Ls") }
                if channel == 5 { #expect(heard.right > heard.left, "Rs") }
            }
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

// MARK: - A multichannel interface

/// An engine rendering offline to `channels` discrete outputs, as an interface with that many would be fed.
@MainActor private func offline(outputs channels: Int) throws -> AVAudioEngine {
    let engine = AVAudioEngine()
    let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels))!
    try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: layout),
                                         maximumFrameCount: 4096)
    return engine
}

/// What each output carried.
@MainActor private func outputs(_ engine: AVAudioEngine, seconds: Double = 0.3) throws -> [[Float]] {
    let count = Int(engine.manualRenderingFormat.channelCount)
    let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
    var out = [[Float]](repeating: [], count: count)
    var left = Int(seconds * rate)
    while left > 0 {
        guard try engine.renderOffline(AVAudioFrameCount(min(left, 4096)), to: buffer) == .success else { break }
        for c in 0..<count { out[c].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![c], count: Int(buffer.frameLength))) }
        left -= Int(buffer.frameLength)
    }
    return out
}

@Suite(.serialized) @MainActor struct MultichannelOutput {
    @Test func theOutputsOfAnInterfaceAreTakenInUSBOrder() {
        let Rls = kAudioChannelLabel_RearSurroundLeft, Rrs = kAudioChannelLabel_RearSurroundRight
        #expect(ChannelLayouts.outputSpeakers(channels: 2) == nil)
        #expect(ChannelLayouts.outputSpeakers(channels: 6) == fivePointOne)
        // Eight: the back pair fifth and sixth, the side pair last, as USB Audio and WAVE order them.
        #expect(ChannelLayouts.outputSpeakers(channels: 8) == [L, R, C, LFE, Rls, Rrs, Ls, Rs])
        // More than eight: 7.1 on the first eight, nothing on the rest.
        let many = ChannelLayouts.outputSpeakers(channels: 10)
        #expect(many?.count == 10 && Array(many?.suffix(2) ?? []) == [kAudioChannelLabel_Unused, kAudioChannelLabel_Unused])
        // An output that names its speakers is believed; one that only numbers them isn't.
        #expect(ChannelLayouts.outputSpeakers(channels: 6, described: [C, L, R, Ls, Rs, LFE]) == [C, L, R, Ls, Rs, LFE])
        #expect(ChannelLayouts.outputSpeakers(channels: 6, described: [1, 2, 3, 4, 5, 6]) == fivePointOne)
    }

    @Test func eachChannelOfAFivePointOneSongGoesToItsOwnOutputUnchanged() throws {
        // The song's channels come as C L R Ls Rs LFE; the interface is L R C LFE Ls Rs.
        let labels = [C, L, R, Ls, Rs, LFE]
        let home = [2, 0, 1, 4, 5, 3]
        for channel in 0..<6 {
            let url = try surroundFile(channels: 6, only: channel)
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = try offline(outputs: 6)
            let player = PhonePlayer(engine: engine)
            player.spatialMode = .headTracked
            player.outputSpeakers = ChannelLayouts.outputSpeakers(channels: 6)
            try player.load(url, format: format(labels))
            try player.play()
            #expect(player.rendering == .discrete(outputs: 6))
            let heard = try outputs(engine).map(level)
            for output in 0..<6 {
                if output == home[channel] {
                    // A 0.4 sine: 0.283 RMS, with no gain anywhere on the way.
                    #expect(abs(heard[output] - 0.2828) < 0.002, "song channel \(channel) on output \(output)")
                } else {
                    #expect(heard[output] == 0, "song channel \(channel) leaked onto output \(output)")
                }
            }
            player.halt()
        }
    }

    @Test func theSamplesReachTheOutputsBitForBit() throws {
        let url = try surroundFile(channels: 6, only: nil, seconds: 0.3)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        let original = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 9600)!
        try file.read(into: original, frameCount: 9600)
        let engine = try offline(outputs: 6)
        let player = PhonePlayer(engine: engine)
        player.outputSpeakers = ChannelLayouts.outputSpeakers(channels: 6)
        try player.load(url, format: format(fivePointOne))
        try player.play()
        let heard = try outputs(engine, seconds: 0.2)
        for c in 0..<6 {
            let want = Array(UnsafeBufferPointer(start: original.floatChannelData![c], count: 9600))
            #expect(Array(heard[c].prefix(9600)) == want, "output \(c)")
        }
    }

    @Test func sevenPointOneOnAFivePointOneInterfaceFoldsItsBackPairOntoTheSurrounds() throws {
        // WAVE order for eight: L R C LFE, back pair, side pair.
        for (channel, output) in [(4, 4), (5, 5), (6, 4), (7, 5)] {
            let url = try surroundFile(channels: 8, only: channel)
            defer { try? FileManager.default.removeItem(at: url) }
            let engine = try offline(outputs: 6)
            let player = PhonePlayer(engine: engine)
            player.outputSpeakers = ChannelLayouts.outputSpeakers(channels: 6)
            let plain = StreamFormat(codec: "WAV", container: "wav", sampleRate: rate, bitDepth: 24, channels: 8, channelLabels: nil, lossless: true)
            try player.load(url, format: plain)
            try player.play()
            #expect(player.rendering == .discrete(outputs: 6))
            let heard = try outputs(engine).map(level)
            #expect(heard[output] > 0.15, "song channel \(channel)")
            for other in 0..<6 where other != output { #expect(heard[other] == 0) }
            player.halt()
        }
    }

    @Test func fivePointOneOnASevenPointOneInterfaceUsesItsSidePair() throws {
        let url = try surroundFile(channels: 6, only: 4)   // Ls
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try offline(outputs: 8)
        let player = PhonePlayer(engine: engine)
        player.outputSpeakers = ChannelLayouts.outputSpeakers(channels: 8)
        try player.load(url, format: format(fivePointOne))
        try player.play()
        let heard = try outputs(engine).map(level)
        #expect(heard[6] > 0.2)
        for other in 0..<8 where other != 6 { #expect(heard[other] == 0) }
    }

    @Test func aStereoSongOnAnInterfaceIsStillLeftAlone() throws {
        let url = try surroundFile(channels: 2, only: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try offline(outputs: 6)
        let player = PhonePlayer(engine: engine)
        player.outputSpeakers = ChannelLayouts.outputSpeakers(channels: 6)
        try player.load(url, format: StreamFormat(codec: "WAV", container: "wav", sampleRate: rate, bitDepth: 24, channels: 2, channelLabels: nil, lossless: true))
        try player.play()
        #expect(player.rendering == .untouched && player.isUntouchedPath)
        let heard = try outputs(engine).map(level)
        #expect(heard[0] > 0.2 && heard[1] > 0.2, "left and right on the first two outputs")
        for other in 2..<6 { #expect(heard[other] == 0, "output \(other)") }
    }

    @Test func stereoAfterSurroundAndSurroundAgainOnOneEngine() throws {
        let surround = try surroundFile(channels: 6, only: 4)
        let stereo = try surroundFile(channels: 2, only: nil)
        defer { try? FileManager.default.removeItem(at: surround); try? FileManager.default.removeItem(at: stereo) }
        let engine = try offline(outputs: 6)
        let player = PhonePlayer(engine: engine)
        player.outputSpeakers = ChannelLayouts.outputSpeakers(channels: 6)
        try player.load(surround, format: format(fivePointOne))
        try player.play()
        #expect(try outputs(engine).map(level)[4] > 0.2)
        try player.load(stereo, format: StreamFormat(codec: "WAV", container: "wav", sampleRate: rate, bitDepth: 24, channels: 2, channelLabels: nil, lossless: true))
        try player.play()
        #expect(player.rendering == .untouched)
        #expect(try outputs(engine).map(level)[0] > 0.2)
        try player.load(surround, format: format(fivePointOne))
        try player.play()
        #expect(player.rendering == .discrete(outputs: 6))
        let heard = try outputs(engine).map(level)
        #expect(heard[4] > 0.2 && heard[0] == 0)
    }

    @Test func anInterfaceAppearingWhileASurroundSongPlaysCarriesOnFromTheSamePlace() throws {
        let url = try surroundFile(channels: 6, only: nil, seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try offline(outputs: 6)
        let player = PhonePlayer(engine: engine)
        player.spatialMode = .off
        try player.load(url, format: format(fivePointOne))
        try player.play()
        _ = try outputs(engine, seconds: 0.5)
        player.outputSpeakers = ChannelLayouts.outputSpeakers(channels: 6)
        #expect(player.rendering == .discrete(outputs: 6) && player.state == .playing)
        #expect(abs(player.position - 0.5) < 0.1)
        let heard = try outputs(engine, seconds: 0.2).map(level)
        for output in 0..<6 { #expect(heard[output] > 0.2, "output \(output)") }
    }
}
#endif
