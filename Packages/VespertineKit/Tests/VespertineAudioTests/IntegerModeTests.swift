//
// Vespertine — integer mode: decoding straight to 32-bit integers keeps every source bit.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import SFBAudioEngine
import Testing
@testable import VespertineAudio

@Suite("Integer mode")
struct IntegerModeTests {
    /// Writes 32-bit integer PCM (the full word used) and returns the samples written.
    private func write32(_ url: URL, frames: Int) throws -> [Int32] {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 96_000, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt32, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        var x: UInt32 = 0x1234_5678
        var samples: [Int32] = []
        for i in 0..<frames * 2 {
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            let v = Int32(bitPattern: x) | 1          // odd: the lowest bit matters
            buffer.int32ChannelData![0][i] = v; samples.append(v)
        }
        try file.write(from: buffer)
        return samples
    }

    /// Decodes a file the way the engine does in integer mode: its decoder, then a converter to Int32.
    private func decodeToInt32(_ url: URL) throws -> [Int32] {
        let probed = try SourceOpener.probe(url)
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: probed.format.sampleRate, decodedSampleRate: probed.format.sampleRate,
                              physicalBitDepth: 32, channels: 2, dsdConvertedToPCM: false, reason: "")
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: url))
        let out = AVAudioFormat(commonFormat: .pcmFormatInt32, sampleRate: probed.format.sampleRate, channels: 2, interleaved: true)!
        let converter = try #require(AVAudioConverter(from: decoder.processingFormat, to: out))
        converter.dither = false
        let input = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096)!
        let output = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: 4096)!
        var result: [Int32] = []
        while true {
            try decoder.decode(into: input, length: 4096)
            if input.frameLength == 0 { break }
            try converter.convert(to: output, from: input)
            result += UnsafeBufferPointer(start: output.int32ChannelData![0], count: Int(output.frameLength) * 2)
        }
        return result
    }

    @Test("A 32-bit integer source reaches the output word for word")
    func thirtyTwoBit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("int32-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let written = try write32(url, frames: 20_000)
        #expect(try SourceOpener.probe(url).format.bitDepth == 32)
        #expect(try decodeToInt32(url) == written)
    }

    @Test("A 24-bit source arrives as its samples in the top 24 bits, nothing added")
    func twentyFourBit() throws {
        var values: [Int32] = []
        let url = try writeWAV("int24", rate: 96_000, bits: 24, seconds: 0.2) { c, i in
            // Every representable 24-bit step pattern, including the extremes.
            let v = Int32(truncatingIfNeeded: (i &* 2_654_435_761) &+ c) >> 8
            values.append(v)
            return Float(Double(v) / 8_388_608)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let decoded = try decodeToInt32(url)
        #expect(decoded.count == values.count)
        // writeWAV fills channel by channel; decoded samples are interleaved.
        let frames = values.count / 2
        for f in 0..<frames {
            for c in 0..<2 {
                let v = values[c * frames + f]
                #expect(decoded[f * 2 + c] == v << 8, "frame \(f) channel \(c)")
                if decoded[f * 2 + c] != v << 8 { return }
            }
        }
    }

    @Test("A 32-bit float file never goes out as integers (its samples would change); a 32-bit integer file can")
    func floatFileStaysFloat() throws {
        let float = FileManager.default.temporaryDirectory.appendingPathComponent("float32-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: float) }
        do {
            let f = try AVAudioFile(forWriting: float, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 96_000.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 960))
            buffer.frameLength = 960
            for c in 0..<2 { for i in 0..<960 { buffer.floatChannelData![c][i] = 0.25 } }
            try f.write(from: buffer)
        }
        #expect(try SourceOpener.probe(float).exactAsIntegers == false)
        let int = FileManager.default.temporaryDirectory.appendingPathComponent("int32-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: int) }
        _ = try write32(int, frames: 960)
        #expect(try SourceOpener.probe(int).exactAsIntegers)
    }
}
