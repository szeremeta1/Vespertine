//
// Vespertine: the conversion behind "Play on this phone": any song the phone can't open (DSD, a CUE track…) becomes a lossless
// FLAC with every channel kept, the speakers named, and the sample values untouched when the rate and depth stay.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("FLAC for the phone")
struct FLACStreamTranscoderTests {
    private func tmp(_ name: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("flac-stream-\(UUID())-\(name)") }

    /// Pseudo-random 24-bit samples (every bit used, so a truncation or a dither would show) as exact float32 values.
    private func noise(frames: Int, channels: Int, bits: Int, seed: UInt64) -> [[Float]] {
        var state = seed
        let scale = Float(1 << (bits - 1))
        return (0..<channels).map { _ in
            (0..<frames).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let v = Int(Int64(bitPattern: state) >> (64 - UInt64(bits))) // signed `bits`-bit
                return Float(max(-(1 << (bits - 1)) + 1, min((1 << (bits - 1)) - 1, v))) / scale / 2
            }
        }
    }

    private func writePCM(_ planes: [[Float]], rate: Double, bits: Int, to url: URL, layoutTag: AudioChannelLayoutTag? = nil) throws {
        var settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: planes.count,
                                       AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        if let layoutTag, let layout = AVAudioChannelLayout(layoutTag: layoutTag) { settings[AVChannelLayoutKey] = Data(bytes: layout.layout, count: layout.byteSize) }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = planes[0].count
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for (c, plane) in planes.enumerated() { for i in 0..<frames { buffer.floatChannelData![c][i] = plane[i] } }
        try file.write(from: buffer)
    }

    private func read(_ url: URL) throws -> (rate: Double, planes: [[Float]]) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        return (file.processingFormat.sampleRate, (0..<Int(file.processingFormat.channelCount)).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: n)) })
    }

    /// Power at `frequency` in `samples` (Goertzel), in dB.
    private func level(_ samples: [Float], rate: Double, at frequency: Double) -> Double {
        let w = 2 * Double.pi * frequency / rate, coeff = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for x in samples { let s = Double(x) + coeff * s1 - s2; s2 = s1; s1 = s }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return 10 * log10(max(power / Double(samples.count * samples.count), 1e-20))
    }

    @Test("Same rate and depth: every sample comes back exactly (24-bit stereo hi-res)")
    func bitExact24() throws {
        let src = tmp("a.wav"), dst = tmp("a.flac")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        let planes = noise(frames: 96_000 * 2, channels: 2, bits: 24, seed: 7)
        try writePCM(planes, rate: 96_000, bits: 24, to: src)
        let result = try FLACStreamTranscoder.transcode(PlayableItem(url: src), sampleRate: 96_000, bitDepth: 24, to: dst)
        #expect(result.sampleRate == 96_000 && result.bitDepth == 24 && result.channels == 2 && result.frames == 192_000)
        let before = try read(src), after = try read(dst)
        #expect(after.rate == 96_000 && after.planes.count == 2 && after.planes[0].count == before.planes[0].count)
        #expect(after.planes == before.planes, "bit-exact")
    }

    @Test("16-bit stays 16-bit and exact")
    func bitExact16() throws {
        let src = tmp("b.wav"), dst = tmp("b.flac")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try writePCM(noise(frames: 44_100, channels: 2, bits: 16, seed: 3), rate: 44_100, bits: 16, to: src)
        let result = try FLACStreamTranscoder.transcode(PlayableItem(url: src), sampleRate: 44_100, bitDepth: 16, to: dst)
        #expect(result.bitDepth == 16)
        #expect(try read(dst).planes == read(src).planes)
    }

    @Test("A 5.1 file at 24/96 goes to 48 kHz with every channel kept: the tones stay in their own channels")
    func multichannelDownToTheRoute() throws {
        let src = tmp("c.wav"), dst = tmp("c.flac")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        let names = ["FL", "FR", "FC", "LFE", "BL", "BR"]
        let tones = SpatialProbe.frequencies(names)
        let planes = tones.map { f in (0..<96_000 * 2).map { Float(0.2 * sin(2 * Double.pi * f * Double($0) / 96_000)) } }
        try writePCM(planes, rate: 96_000, bits: 24, to: src, layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)
        let result = try FLACStreamTranscoder.transcode(PlayableItem(url: src), sampleRate: 48_000, bitDepth: 24, to: dst)
        #expect(result.channels == 6 && result.sampleRate == 48_000)
        let out = try read(dst)
        #expect(out.rate == 48_000 && out.planes.count == 6)
        #expect(abs(out.planes[0].count - 96_000) < 2_000, "half the frames")
        for (c, own) in tones.enumerated() {
            let mine = level(out.planes[c], rate: 48_000, at: own)
            for (other, f) in tones.enumerated() where other != c {
                #expect(mine - level(out.planes[c], rate: 48_000, at: f) > 40, "channel \(c) carries tone \(own) Hz, not \(f) Hz")
            }
        }
    }

    @Test("DSD 5.1 becomes a six-channel FLAC at 44.1 kHz with its speakers named, each tone in its own channel")
    func dsd51() throws {
        let src = tmp("d.dsf"), dst = tmp("d.flac")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        let names = ["FL", "FR", "FC", "LFE", "BL", "BR"]
        let tones = SpatialProbe.frequencies(names)
        try DSDFiles.writeDSF(DSDFiles.modulate(rate: 2_822_400, seconds: 1.3, tones: tones), rate: 2_822_400, channelType: 7, to: src)
        let result = try FLACStreamTranscoder.transcode(PlayableItem(url: src), sampleRate: 44_100, bitDepth: 24, to: dst)
        #expect(result.channels == 6 && result.sampleRate == 44_100 && result.bitDepth == 24)
        #expect(result.labels == [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
                                  kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround], "the speakers the DSF named")
        let out = try read(dst)
        #expect(out.rate == 44_100 && out.planes.count == 6)
        #expect(abs(out.planes[0].count - Int(1.3 * 44_100)) < 2_000)
        for (c, own) in tones.enumerated() {
            let mine = level(out.planes[c], rate: 44_100, at: own)
            for (other, f) in tones.enumerated() where other != c {
                #expect(mine - level(out.planes[c], rate: 44_100, at: f) > 30, "channel \(c) carries tone \(own) Hz, not \(f) Hz")
            }
        }
    }

    @Test("Stereo DSD at 176.4 kHz")
    func stereoDSD() throws {
        let src = tmp("e.dsf"), dst = tmp("e.flac")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try DSDFiles.writeDSF(DSDFiles.modulate(rate: 2_822_400, seconds: 1), rate: 2_822_400, to: src)
        let result = try FLACStreamTranscoder.transcode(PlayableItem(url: src), sampleRate: 176_400, bitDepth: 24, to: dst)
        #expect(result.channels == 2 && result.labels == [kAudioChannelLabel_Left, kAudioChannelLabel_Right] && abs(result.frames - 176_400) < 4_000)
        #expect(try read(dst).rate == 176_400)
    }

    @Test("A missing file throws and leaves nothing behind")
    func missingFile() {
        let dst = tmp("f.flac")
        #expect(throws: (any Error).self) { try FLACStreamTranscoder.transcode(PlayableItem(url: tmp("nope.wav")), sampleRate: 44_100, bitDepth: 16, to: dst) }
        #expect(!FileManager.default.fileExists(atPath: dst.path))
    }

    @Test("Cancelling stops the conversion and removes the half-written file")
    func cancelled() throws {
        let src = tmp("g.wav"), dst = tmp("g.flac")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try writePCM(noise(frames: 44_100 * 4, channels: 2, bits: 16, seed: 9), rate: 44_100, bits: 16, to: src)
        #expect(throws: FLACStreamTranscoder.Failure.self) {
            try FLACStreamTranscoder.transcode(PlayableItem(url: src), sampleRate: 44_100, bitDepth: 16, to: dst, isCancelled: { true })
        }
        #expect(!FileManager.default.fileExists(atPath: dst.path))
    }

    @Test("The source file is never touched")
    func sourceUntouched() throws {
        let src = tmp("h.wav"), dst = tmp("h.flac")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try writePCM(noise(frames: 4_410, channels: 2, bits: 16, seed: 1), rate: 44_100, bits: 16, to: src)
        let before = try Data(contentsOf: src)
        _ = try FLACStreamTranscoder.transcode(PlayableItem(url: src), sampleRate: 44_100, bitDepth: 16, to: dst)
        #expect(try Data(contentsOf: src) == before)
    }
}
