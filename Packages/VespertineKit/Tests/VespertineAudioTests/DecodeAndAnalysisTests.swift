//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import SFBAudioEngine
import Testing
@testable import VespertineAudio

/// Writes a stereo integer WAV from a sample generator (values in -1…1, pre-quantized by the caller).
func writeWAV(_ name: String, rate: Double, bits: Int, seconds: Double, _ sample: (Int, Int) -> Float) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-test-\(name)-\(UUID().uuidString).wav")
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = Int(rate * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for c in 0..<2 { for i in 0..<frames { buffer.floatChannelData![c][i] = sample(c, i) } }
    try file.write(from: buffer)
    return url
}

private func quantize(_ x: Double, bits: Int) -> Float {
    let q = Double(1 << (bits - 1))
    return Float((x * q).rounded() / q)
}

@Suite("Decoding and analysis")
struct DecodeAndAnalysisTests {
    @Test("A 24/96 WAV is probed as lossless 24-bit 96 kHz")
    func probe() throws {
        let url = try writeWAV("probe", rate: 96_000, bits: 24, seconds: 0.2) { _, i in quantize(0.5 * sin(Double(i) * 0.05), bits: 24) }
        defer { try? FileManager.default.removeItem(at: url) }
        let probed = try SourceOpener.probe(url)
        #expect(probed.format.encoding == .pcm)
        #expect(probed.format.sampleRate == 96_000)
        #expect(probed.format.bitDepth == 24)
        #expect(probed.format.codec == "WAV")
    }

    @Test("Same-rate conversion to Float32 reproduces every 24-bit sample exactly")
    func bitExactDecode() throws {
        var rng = SystemRandomNumberGenerator()
        let values: [[Float]] = (0..<2).map { _ in (0..<9600).map { _ in Float(Int.random(in: -8_388_608...8_388_607, using: &rng)) / 8_388_608 } }
        let url = try writeWAV("exact", rate: 96_000, bits: 24, seconds: 0.1) { c, i in values[c][i] }
        defer { try? FileManager.default.removeItem(at: url) }

        let probed = try SourceOpener.probe(url)
        let plan = FormatPlanner.plan(source: probed.format, device: DeviceCapabilities(
            sampleRates: [96_000], physicalFormats: [PhysicalFormat(minRate: 96_000, maxRate: 96_000, bitDepth: 24, isInteger: true, isMixable: true, channels: 2)],
            outputChannels: 2, supportsDoP: false))
        #expect(!plan.resamples)
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: url))
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 96_000, channels: 2, interleaved: true)!
        let converter = AVAudioConverter(from: decoder.processingFormat, to: outFormat)!
        let input = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 16_384)!
        let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 16_384)!
        var done = false
        _ = converter.convert(to: output, error: nil) { n, status in
            if done { status.pointee = .endOfStream; return nil }
            try? decoder.decode(into: input, length: min(n, input.frameCapacity))
            if input.frameLength == 0 { done = true; status.pointee = .endOfStream; return nil }
            status.pointee = .haveData
            return input
        }
        #expect(output.frameLength == 9600)
        let data = output.floatChannelData![0]
        var mismatches = 0
        for i in 0..<9600 { for c in 0..<2 where data[i * 2 + c] != values[c][i] { mismatches += 1 } }
        #expect(mismatches == 0)
    }

    @Test("16-bit audio padded into a 24-bit file is detected")
    func paddedBitDepth() throws {
        let url = try writeWAV("padded", rate: 44_100, bits: 24, seconds: 1) { c, i in quantize(0.4 * sin(Double(i) * (0.03 + Double(c) * 0.01)), bits: 16) }
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try FileAnalyzer.analyze(url: url)
        #expect(result.claimedBitDepth == 24)
        #expect(result.effectiveBitDepth == 16)
        #expect(result.verdict == .paddedBitDepth)
    }

    @Test("A 44.1 kHz master upsampled to 96 kHz is flagged, with its cutoff reported")
    func upsampled() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-upsampled-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        // Full-band music-like content with a natural tilt, ending at the resampler's ~21.5 kHz wall.
        try TestSignals.writeShapedNoise(url, rate: 96_000, seconds: 6) { f in f < 21_500 ? -3 * f / 1000 : nil }
        let result = try FileAnalyzer.analyze(url: url)
        #expect(result.verdict == .upsampled, "\(result.summary)")
        #expect(result.bandwidthHz > 17_000 && result.bandwidthHz < 24_500, "bandwidth \(result.bandwidthHz)")
    }
}
