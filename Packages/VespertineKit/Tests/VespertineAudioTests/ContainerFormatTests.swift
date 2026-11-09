//
// Vespertine — TAK, Matroska/WebM audio (and its stream picker), and the gapless, xHE-AAC, APAC and Opus
// multichannel checks that decide whether those files play as they were made.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import CryptoKit
import Foundation
import SFBAudioEngine
import Testing
@testable import VespertineAudio

@Suite("TAK, Matroska and WebM audio")
struct ContainerFormatTests {
    static func fixture(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Formats")!
    }

    /// The whole file as Float32 per channel, decoded as the engine would for PCM output.
    static func decode(_ name: String, audioStream: Int? = nil, frames: Int = .max) throws -> (format: SourceFormat, decoder: String, audio: [[Float]], layout: AVAudioChannelLayout?) {
        let url = fixture(name)
        let probed = try SourceOpener.probe(url, audioStream: audioStream)
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: probed.format.sampleRate, decodedSampleRate: probed.format.sampleRate,
                              physicalBitDepth: 32, channels: probed.format.channels, dsdConvertedToPCM: false, reason: "")
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: url, audioStream: audioStream))
        defer { try? decoder.close() }
        let source = decoder.processingFormat
        let channels = Int(source.channelCount)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4096))
        let layout = source.channelLayout ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels))!
        let floats = try #require(AVAudioFormat(standardFormatWithSampleRate: source.sampleRate, channelLayout: layout))
        let converter = source.commonFormat == .pcmFormatFloat32 && !source.isInterleaved ? nil : AVAudioConverter(from: source, to: floats)
        var out = [[Float]](repeating: [], count: channels)
        while out[0].count < frames {
            try decoder.decode(into: buffer, length: AVAudioFrameCount(min(4096, frames - out[0].count)))
            if buffer.frameLength == 0 { break }
            var chunk = buffer
            if let converter {
                chunk = AVAudioPCMBuffer(pcmFormat: floats, frameCapacity: buffer.frameLength)!
                try converter.convert(to: chunk, from: buffer)
            }
            for c in 0..<channels { out[c] += UnsafeBufferPointer(start: chunk.floatChannelData![c], count: Int(chunk.frameLength)) }
        }
        return (probed.format, probed.decoderName, out, source.channelLayout)
    }

    static func power(_ x: ArraySlice<Float>, _ f: Double, rate: Double = 48_000) -> Double {
        var re = 0.0, im = 0.0
        for (i, v) in x.enumerated() { let p = 2 * .pi * f * Double(i) / rate; re += Double(v) * cos(p); im += Double(v) * sin(p) }
        return re * re + im * im
    }

    /// The tone (of the five-way set the fixtures use) that dominates `x`.
    static func dominantTone(_ x: ArraySlice<Float>, among tones: [Double]) -> Double {
        tones.max { power(x, $0) < power(x, $1) }!
    }

    static let surroundTones: [AudioChannelLabel: Double] = [
        kAudioChannelLabel_Left: 440, kAudioChannelLabel_Right: 550, kAudioChannelLabel_Center: 660,
        kAudioChannelLabel_LFEScreen: 60, kAudioChannelLabel_LeftSurround: 770, kAudioChannelLabel_RightSurround: 880,
        // Opus and other 5.1 in the side layout, which libopus labels as the rear surrounds (Opus 5.1 is FL FC FR BL BR LFE).
        kAudioChannelLabel_RearSurroundLeft: 770, kAudioChannelLabel_RearSurroundRight: 880]

    // MARK: TAK

    @Test("TAK decodes bit for bit, and is labelled lossless")
    func tak() throws {
        let (format, decoder, audio, _) = try Self.decode("tak-excerpt.tak")
        #expect(format.codec == "TAK" && format.encoding == .pcm)
        #expect(format.sampleRate == 44_100 && format.channels == 2 && format.bitDepth == 16)
        #expect(decoder.contains("FFmpeg"))
        #expect(audio[0].count == 44_100)
        // The 16-bit samples, interleaved, hashed: made by FFmpeg's own TAK decoder with every frame's CRC checked
        // (`ffmpeg -err_detect crccheck+explode -i tak-excerpt.tak -f s16le`).
        var pcm = Data(capacity: audio[0].count * 4)
        for i in 0..<audio[0].count {
            for c in 0..<2 {
                let v = (audio[c][i] * 32_768).rounded()
                #expect(v == (audio[c][i] * 32_768), "a TAK sample is not a whole 16-bit value")
                withUnsafeBytes(of: Int16(v).littleEndian) { pcm.append(contentsOf: $0) }
            }
        }
        let digest = SHA256.hash(data: pcm).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "65be004c0d88d3faf85456f60237d996ed0f7ced5872fe44b1db55c100c52669")
    }

    @Test("TAK, MKV, MKA and WebM are listed as playable")
    func extensions() {
        for ext in ["tak", "mka", "mkv", "webm"] { #expect(SourceOpener.supportedExtensions.contains(ext), "\(ext)") }
    }

    // MARK: Matroska lossless

    @Test("Lossless audio in Matroska decodes to exactly what was put in", arguments: [
        ("flac-stereo.mka", "FLAC", 48_000), ("alac-stereo.mka", "ALAC", 48_000), ("wavpack-stereo.mka", "WavPack", 48_000),
        ("tta-stereo.mka", "TTA", 48_000), ("pcm-stereo.mka", "PCM", 12_000),
    ])
    func losslessMatroska(name: String, codec: String, frames: Int) throws {
        let (format, _, audio, _) = try Self.decode(name)
        #expect(format.codec == codec && format.encoding == .pcm && format.bitDepth == 24)
        #expect(format.channels == 2 && format.sampleRate == 48_000)
        let (_, _, reference, _) = try Self.decode("stereo24.flac")
        #expect(audio[0].count == frames, "\(audio[0].count) frames")
        #expect(audio == reference.map { Array($0.prefix(frames)) }, "\(name) differs from the 24-bit source")
    }

    @Test("Matroska tags are read for any codec", arguments: ["flac-stereo.mka"])
    func tags(name: String) {
        let tags = SourceInspector.containerTags(Self.fixture(name))
        #expect(tags["title"] == "Matroska FLAC" && tags["artist"] == "Nocturne Test" && tags["album"] == "Formats")
    }

    @Test("Seeking in Matroska lands within its 1 ms timestamps of the target, on the same samples as playing through")
    func seeks() throws {
        let url = Self.fixture("flac-stereo.mka")
        let probed = try SourceOpener.probe(url)
        let all = try Self.decode("flac-stereo.mka").audio
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: 48_000, decodedSampleRate: 48_000, physicalBitDepth: 32, channels: 2,
                              dsdConvertedToPCM: false, reason: "")
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: url))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 1024))
        for target in [0, 5_000, 31_337, 46_900] {
            try decoder.seek(to: AVAudioFramePosition(target))
            try decoder.decode(into: buffer, length: 1024)
            #expect(buffer.frameLength == 1024)
            let got = [Float](UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 1024))
            // Matroska stores times in whole milliseconds (48 samples here), so a seek can be that far off the target.
            let offsets = (-48...48).filter { target + $0 >= 0 && got == Array(all[0][(target + $0)..<(target + $0 + 1024)]) }
            #expect(!offsets.isEmpty, "at \(target): not the file's samples at any offset within 1 ms")
        }
    }

    // MARK: Matroska lossy

    @Test("Lossy audio in Matroska and WebM plays as lossy, in tune and in the right channel", arguments: [
        ("aac-stereo.mkv", "AAC"), ("mp3-stereo.mka", "MP3"), ("vorbis-stereo.webm", "Vorbis"),
    ])
    func lossyMatroska(name: String, codec: String) throws {
        let (format, _, audio, _) = try Self.decode(name)
        #expect(format.codec == codec && format.encoding == .lossy && format.channels == 2 && format.sampleRate == 48_000)
        #expect(abs(audio[0].count - 48_000) < 2_400, "\(audio[0].count) frames")
        for (c, tone) in [440.0, 550].enumerated() {
            #expect(Self.dominantTone(audio[c][20_000..<24_096], among: [440, 550]) == tone, "\(name) channel \(c)")
        }
    }

    @Test("Opus 5.1 keeps every channel in its place, in Ogg, Matroska and WebM", arguments: ["opus-51.opus", "opus-51.mka", "opus-51.webm"])
    func opusMultichannel(name: String) throws {
        let (format, _, audio, layout) = try Self.decode(name)
        #expect(format.codec == "Opus" && format.encoding == .lossy && format.channels == 6 && format.sampleRate == 48_000)
        #expect(abs(audio[0].count - 48_000) < 2_400, "\(audio[0].count) frames")
        let labels = layout?.channelLabels ?? []
        #expect(labels.count == 6, "no channel layout")
        for (c, label) in labels.enumerated() {
            let expected = Self.surroundTones[label]
            #expect(Self.dominantTone(audio[c][20_000..<24_096], among: Array(Self.surroundTones.values)) == expected, "\(name) channel \(c) \(label)")
        }
    }

    // MARK: Stream picker

    @Test("A file with two audio streams lists both, with their titles")
    func listsStreams() throws {
        let streams = FFmpegDecoder.audioStreams(in: Self.fixture("two-streams.mka"))
        #expect(streams.map(\.channels) == [2, 6])
        #expect(streams.map(\.title) == ["Stereo mix", "Surround mix"])
        #expect(streams.map(\.language) == ["eng", "eng"])
        #expect(streams.map(\.codec) == ["FLAC", "FLAC"])
        #expect(streams.map(\.index) == [0, 1])
        #expect(FFmpegDecoder.audioStreams(in: Self.fixture("flac-stereo.mka")).count == 1)
    }

    @Test("The chosen stream is the one that plays; without a choice, the file's default (its first)")
    func picksStream() throws {
        let stereo = try Self.decode("two-streams.mka", audioStream: 0)
        let surround = try Self.decode("two-streams.mka", audioStream: 1)
        let best = try Self.decode("two-streams.mka")
        #expect(stereo.format.channels == 2 && stereo.format.bitDepth == 24)
        #expect(surround.format.channels == 6 && surround.format.bitDepth == 16)
        #expect(best.format.channels == 2)
        #expect(stereo.audio[0] == (try Self.decode("stereo24.flac")).audio[0])
        #expect(surround.audio == (try Self.decode("surround16.flac")).audio)
        #expect(throws: (any Error).self) { try SourceOpener.probe(Self.fixture("two-streams.mka"), audioStream: 2) }
    }

    @Test("A picked stream that says it has no channels is refused when opened, not played into a crash")
    func zeroChannelStream() throws {
        // mp3-stereo.mka with its track's Channels element (9F 81 02) set to 0 and every MP3 frame sync cleared, so
        // FFmpeg can't learn the channel count from the audio either.
        var bytes = [UInt8](try Data(contentsOf: Self.fixture("mp3-stereo.mka")))
        let channels = try #require((0..<bytes.count - 2).first { bytes[$0] == 0x9F && bytes[$0 + 1] == 0x81 && bytes[$0 + 2] == 2 })
        let cluster = try #require((0..<bytes.count - 3).first { bytes[$0..<$0 + 4].elementsEqual([0x1F, 0x43, 0xB6, 0x75]) })
        bytes[channels + 2] = 0
        for i in cluster..<bytes.count - 1 where bytes[i] == 0xFF && bytes[i + 1] & 0xE0 == 0xE0 { bytes[i] = 0 }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zero-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("No channels.mka")
        try Data(bytes).write(to: url)
        #expect(throws: DTSError.self) { try FFmpegDecoder(url: url, stream: 0).open() }
        #expect(throws: (any Error).self) { try SourceOpener.probe(url, audioStream: 0) }
    }

    // MARK: Gapless

    /// Largest difference from a full-scale cosine at 440 Hz, which starts on its peak so any delay shows at once.
    static func cosineError(_ x: ArraySlice<Float>, from start: Int) -> Double {
        var sum = 0.0
        for (i, v) in x.enumerated() {
            let expected = 0.5 * cos(2 * .pi * 440 * Double(start + i) / 48_000)
            sum += (Double(v) - expected) * (Double(v) - expected)
        }
        return (sum / Double(x.count)).squareRoot()
    }

    @Test("MP3, AAC and Opus play gaplessly: the exact length, starting on the first sample", arguments: [
        "gapless.mp3", "gapless.m4a", "gapless.opus",
    ])
    func gapless(name: String) throws {
        let (_, _, audio, _) = try Self.decode(name)
        #expect(audio[0].count == 96_000, "\(name): \(audio[0].count) frames, not 96000")
        #expect(Self.cosineError(audio[0][1_000..<5_000], from: 1_000) < 0.03, "\(name) is delayed at its start")
        let end = audio[0].count - 4_000
        #expect(Self.cosineError(audio[0][end...], from: end) < 0.03, "\(name) is out of step at its end")
    }

    // MARK: xHE-AAC and APAC

    /// Whether this macOS can open the xHE-AAC fixture at all. Core Audio's USAC support is the system's: GitHub's macos-26
    /// runner image rejects the file ("format not recognized"), a development Mac plays it, so the tone test only runs where
    /// the system decoder exists (a failure to open here is the machine's, not the player's).
    static let systemDecodesXHE: Bool = {
        guard let url = Bundle.module.url(forResource: "xhe-stereo", withExtension: "m4a", subdirectory: "Fixtures/Formats") else { return false }
        return (try? AVAudioFile(forReading: url)) != nil
    }()

    @Test("xHE-AAC (USAC) in MP4 plays in tune", .enabled(if: ContainerFormatTests.systemDecodesXHE))
    func xheAAC() throws {
        let (format, _, audio, _) = try Self.decode("xhe-stereo.m4a")
        #expect(format.encoding == .lossy && format.channels == 2 && format.sampleRate == 48_000)
        #expect(abs(audio[0].count - 48_000) < 2_400, "\(audio[0].count) frames")
        for (c, tone) in [440.0, 550].enumerated() {
            #expect(Self.dominantTone(audio[c][20_000..<24_096], among: [440, 550]) == tone, "channel \(c)")
        }
    }

    @Test("APAC 5.1 in CAF plays, with each channel in its place")
    func apac() throws {
        let (format, _, audio, layout) = try Self.decode("apac-51.caf")
        #expect(format.channels == 6 && format.sampleRate == 48_000)
        #expect(abs(audio[0].count - 48_000) < 2_400, "\(audio[0].count) frames")
        let labels = layout?.channelLabels ?? []
        #expect(labels.count == 6, "no channel layout")
        for (c, label) in labels.enumerated() {
            #expect(Self.dominantTone(audio[c][20_000..<24_096], among: Array(Self.surroundTones.values)) == Self.surroundTones[label], "channel \(c) \(label)")
        }
    }
}
