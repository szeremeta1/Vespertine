//
// Vespertine: songs as AirPlay frames. A 16/44.1 file comes out as its own samples; anything else is converted and says so.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import Testing
import VespertineAudio
import VespertineUPnP
@testable import VespertineAirPlay

/// A WAV of random-ish integer samples, and the samples written (interleaved, at the file's word length).
func writeWAV(seconds: Double, rate: Double = 44_100, channels: Int = 2, bits: Int = 16, seed: UInt64 = 1,
              name: String = UUID().uuidString) throws -> (URL, [Int32]) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-airplay-\(name).wav")
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                                   AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt32, interleaved: true)
    let frames = Int(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    var rng = Xorshift(seed: seed)
    var written: [Int32] = []
    let words = buffer.int32ChannelData![0]
    let max = Int64(1) << (bits - 1)
    for i in 0..<(frames * channels) {
        // A sine plus noise, never clipping.
        let t = Double(i / channels) / rate
        let v = Int64((sin(2 * .pi * 440 * t + Double(i % channels)) * 0.6 + (rng.unit() - 0.5) * 0.3) * Double(max))
        written.append(Int32(v))
        words[i] = Int32(truncatingIfNeeded: v << (32 - bits))
    }
    try file.write(from: buffer)
    return (url, written)
}

func allFrames(_ frames: AirPlayFrames) -> [Int16] {
    var out: [Int16] = []
    while true {
        let chunk = frames.next(maxFrames: 1000)
        if chunk.isEmpty { return out }
        out += chunk
    }
}

@Suite("AirPlay frames", .serialized)
struct AirPlayFramesTests {
    @Test("A 16-bit / 44.1 kHz stereo file comes out as its own samples, nothing done to it")
    func untouchedStereo() throws {
        let (url, samples) = try writeWAV(seconds: 0.4)
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = try AirPlayFrames(item: PlayableItem(url: url), url: url, settings: RendererSettings())
        #expect(frames.steps.isEmpty)
        let out = allFrames(frames)
        #expect(out.count == samples.count)
        #expect(out.map(Int32.init) == samples)
        #expect(frames.inexactSamples == 0)
    }

    @Test("A 16-bit mono file is copied to both channels, unchanged")
    func untouchedMono() throws {
        let (url, samples) = try writeWAV(seconds: 0.2, channels: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = try AirPlayFrames(item: PlayableItem(url: url), url: url, settings: RendererSettings())
        #expect(frames.steps.isEmpty)
        let out = allFrames(frames)
        #expect(out.count == samples.count * 2)
        #expect(stride(from: 0, to: out.count, by: 2).allSatisfy { out[$0] == out[$0 + 1] })
        #expect(stride(from: 0, to: out.count, by: 2).map { Int32(out[$0]) } == samples)
    }

    @Test("24-bit at 44.1 kHz is dithered to 16 bits: within a step of the exact value, not equal to plain rounding")
    func dithered24() throws {
        let (url, samples) = try writeWAV(seconds: 0.2, bits: 24)
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = try AirPlayFrames(item: PlayableItem(url: url), url: url, settings: RendererSettings())
        #expect(frames.steps == [.dithered])
        let out = allFrames(frames)
        #expect(out.count == samples.count)
        var differs = 0
        for (o, s) in zip(out, samples) {
            let exact = Double(s) / 256
            #expect(abs(Double(o) - exact) < 1.5)
            if Double(o) != exact.rounded() { differs += 1 }
        }
        #expect(differs > samples.count / 10)
    }

    @Test("48 kHz is resampled to 44.1 kHz and dithered")
    func resampled() throws {
        let (url, samples) = try writeWAV(seconds: 0.5, rate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = try AirPlayFrames(item: PlayableItem(url: url), url: url, settings: RendererSettings())
        #expect(frames.steps == [.resampled, .dithered])
        let out = allFrames(frames)
        let expected = Double(samples.count / 2) * 44_100 / 48_000
        #expect(abs(Double(out.count / 2) - expected) < 100)
    }

    @Test("Digital volume or ReplayGain convert a 16/44.1 file; the steps say so")
    func effects() throws {
        let (url, _) = try writeWAV(seconds: 0.1)
        defer { try? FileManager.default.removeItem(at: url) }
        let quiet = try AirPlayFrames(item: PlayableItem(url: url), url: url, settings: RendererSettings(digitalVolumeDB: -6))
        #expect(quiet.steps == [.volume, .dithered])
        let item = PlayableItem(url: url, replayGainDB: -3)
        #expect(try AirPlayFrames(item: item, url: url, settings: RendererSettings()).steps == [.replayGain, .dithered])
    }

    @Test("The decision for formats not opened here")
    func decisions() {
        let none = RendererSettings()
        func steps(_ f: SourceFormat) -> [AirPlayStep] { AirPlayConversion.steps(source: f, settings: none, replayGainDB: nil) }
        #expect(steps(SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 44_100, bitDepth: 16, channels: 2)) == [])
        #expect(steps(SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 96_000, bitDepth: 24, channels: 2)) == [.resampled, .dithered])
        #expect(steps(SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 44_100, bitDepth: 16, channels: 6)) == [.dithered, .downmix])
        #expect(steps(SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: 2_822_400, bitDepth: 1, channels: 2)) == [.resampled, .dithered, .dsdToPCM])
        #expect(steps(SourceFormat(encoding: .lossy, codec: "AAC", sampleRate: 44_100, bitDepth: nil, channels: 2)) == [.dithered])
        #expect(steps(SourceFormat(encoding: .pcm, codec: "WAV", sampleRate: 44_100, bitDepth: 32, channels: 2)) == [.dithered])
    }
}

@Suite("AirPlay badges")
struct AirPlayBadgeTests {
    func path(_ steps: [AirPlayStep], source: SourceFormat) -> SignalPath {
        let stage = SignalPath.RendererStage(name: "moOde", protocolName: "AirPlay", processing: steps, sentCodec: "ALAC", sentSampleRate: 44_100,
                                             sentBitDepth: 16, sentChannels: 2, gapless: true, transport: .airPlay)
        return SignalPath.renderer(stage, source: source, decoderName: "", volume: .fixed)
    }

    @Test("Untouched: BIT-PERFECT · 16/44.1 SENT and brass, but never isBitPerfect")
    func untouched() {
        let p = path([], source: SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 44_100, bitDepth: 16, channels: 2))
        #expect(p.statusLine == "BIT-PERFECT · 16/44.1 SENT")
        #expect(p.isUntouched)
        #expect(!p.isBitPerfect)
        #expect(p.deviceProfile.tag == "AIRPLAY" && p.deviceProfile.symbol == "airplay.audio" && !p.deviceProfile.canBeBitPerfect)
    }

    @Test("Converted: CONVERTED · 16/44.1 SENT with the steps as badges; lossy says so")
    func converted() {
        let p = path([.resampled, .dithered], source: SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 96_000, bitDepth: 24, channels: 2))
        #expect(p.statusLine == "CONVERTED · 16/44.1 SENT")
        #expect(p.renderer?.stepBadges == ["RESAMPLED", "DITHERED"])
        #expect(!p.isUntouched && !p.isBitPerfect)
        let eq = path([.equalizer, .dithered], source: SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 44_100, bitDepth: 16, channels: 2))
        #expect(eq.statusLine == "CONVERTED · 16/44.1 SENT")
        #expect(eq.renderer?.stepBadges == ["EQ", "DITHERED"])
        let dsd = path([.resampled, .dithered, .dsdToPCM], source: SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: 2_822_400, bitDepth: 1, channels: 2))
        #expect(dsd.renderer?.stepBadges == ["RESAMPLED", "DITHERED", "DSD→PCM"])
        let lossy = path([.dithered], source: SourceFormat(encoding: .lossy, codec: "AAC", sampleRate: 44_100, bitDepth: nil, channels: 2))
        #expect(lossy.statusLine == "LOSSY SOURCE · 16/44.1 SENT")
        #expect(!lossy.isUntouched)
    }

    @Test("UPnP renderer badges are as before")
    func renderersUnchanged() {
        let stage = SignalPath.RendererStage(name: "r", protocolName: "OpenHome", processing: [], sentCodec: "FLAC", sentSampleRate: 96_000,
                                             sentBitDepth: 24, sentChannels: 2, gapless: true)
        let p = SignalPath.renderer(stage, source: SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 96_000, bitDepth: 24, channels: 2), decoderName: "", volume: .fixed)
        #expect(p.statusLine == "BIT-PERFECT · 24/96 SENT")
        #expect(p.deviceProfile.tag == "OPENHOME")
    }
}
