//
// Vespertine — playing from network shares: moving a streaming track to its local copy mid-track,
// and a buffer deep enough to ride out a slow server.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import SFBAudioEngine
import Testing
@testable import VespertineAudio

@Suite("Streaming from network shares")
struct StreamingTests {
    /// Deterministic noise, so every sample differs from its neighbours (any slip would show).
    private func noise(_ c: Int, _ i: Int) -> Float {
        var x = UInt32(truncatingIfNeeded: i &* 2_654_435_761 &+ c &* 40_503)
        x ^= x >> 13; x = x &* 0x5bd1e995; x ^= x >> 15
        return Float(Int32(bitPattern: x) >> 8) / Float(1 << 23) * 0.5
    }

    private func encode(_ wav: URL, as format: AudioFormatID, ext: String, bits: Int) throws -> URL {
        let source = try AVAudioFile(forReading: wav)
        let url = wav.deletingPathExtension().appendingPathExtension(ext)
        var settings: [String: Any] = [AVFormatIDKey: format, AVSampleRateKey: source.fileFormat.sampleRate,
                                       AVNumberOfChannelsKey: 2]
        if format == kAudioFormatFLAC { settings[AVEncoderBitDepthHintKey] = bits }
        let out = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length))!
        try source.read(into: buffer)
        try out.write(from: buffer)
        return url
    }

    /// Decodes into raw bytes per buffer (interleaved or not, integer or float), so any difference shows.
    private func decodeAll(_ decoder: PCMDecoding, chunk: AVAudioFrameCount, into out: inout [[UInt8]], limit: Int = .max) throws {
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: chunk)!
        let bytesPerFrame = Int(decoder.processingFormat.streamDescription.pointee.mBytesPerFrame)
        var taken = 0
        while taken < limit {
            try decoder.decode(into: buffer, length: AVAudioFrameCount(min(Int(chunk), limit - taken)))
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            taken += n
            let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            if out.count < list.count { out += Array(repeating: [], count: list.count - out.count) }
            for (i, b) in list.enumerated() {
                out[i] += UnsafeRawBufferPointer(start: b.mData, count: n * bytesPerFrame)
            }
        }
    }

    private func plan(for format: SourceFormat) -> OutputPlan {
        OutputPlan(mode: .pcm, deviceSampleRate: format.sampleRate, decodedSampleRate: format.sampleRate,
                   physicalBitDepth: 32, channels: format.channels, dsdConvertedToPCM: false, reason: "")
    }

    @Test("Moving to the local copy mid-track continues sample for sample", arguments: [
        ("flac", 96_000.0, 24), ("flac", 44_100.0, 16), ("wav", 48_000.0, 24),
    ])
    func switchIsSampleExact(ext: String, rate: Double, bits: Int) throws {
        let wav = try writeWAV("stream-\(ext)", rate: rate, bits: bits, seconds: 3, noise)
        defer { try? FileManager.default.removeItem(at: wav) }
        let share = ext == "wav" ? wav : try encode(wav, as: kAudioFormatFLAC, ext: ext, bits: bits)
        defer { if share != wav { try? FileManager.default.removeItem(at: share) } }
        let copy = share.deletingLastPathComponent().appendingPathComponent("copy-\(UUID()).\(ext)")
        try FileManager.default.copyItem(at: share, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        let item = PlayableItem(url: share)
        let probed = try SourceOpener.probe(share)
        let plan = plan(for: probed.format)
        var reference: [[UInt8]] = []
        try decodeAll(try SourceOpener.decoder(for: try SourceOpener.probe(share), plan: plan, item: item), chunk: 4096, into: &reference)

        // Stream part of the way (an odd chunk size, so the switch lands mid-frame), then switch.
        let streaming = try SourceOpener.decoder(for: probed, plan: plan, item: item)
        var joined: [[UInt8]] = []
        try decodeAll(streaming, chunk: 3001, into: &joined, limit: Int(rate * 1.37))
        let (_, local) = try #require(try PlaybackEngine.reopen(probed, decoder: streaming, at: copy, plan: plan, item: item))
        #expect(local.position == streaming.position)
        try decodeAll(local, chunk: 3001, into: &joined)

        #expect(joined.map(\.count) == reference.map(\.count))
        #expect(joined == reference)
    }

    @Test("Lossy files stay on the share (their decoders carry state across a seek)")
    func lossyStays() throws {
        let wav = try writeWAV("stream-aac", rate: 44_100, bits: 16, seconds: 2, noise)
        defer { try? FileManager.default.removeItem(at: wav) }
        let aac = try encode(wav, as: kAudioFormatMPEG4AAC, ext: "m4a", bits: 16)
        defer { try? FileManager.default.removeItem(at: aac) }
        let probed = try SourceOpener.probe(aac)
        let plan = plan(for: probed.format)
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: aac))
        #expect(try PlaybackEngine.reopen(probed, decoder: decoder, at: aac, plan: plan, item: PlayableItem(url: aac)) == nil)
    }

    @Test("The output buffer holds 20–30 s where memory allows, never under 5 s, within budget")
    func ringSizing() {
        for (rate, channels) in [(44_100.0, 2), (96_000.0, 2), (192_000.0, 2), (88_200.0, 6), (192_000.0, 8), (384_000.0, 2)] {
            let frames = Int(OutputSession.ringFrames(rate: rate, channels: channels))
            let seconds = Double(frames) / rate
            #expect(frames & (frames - 1) == 0)                       // a power of two
            #expect(seconds >= 5 && seconds <= 30)
            #expect(frames * channels * 4 <= 96 << 20 || seconds < 11) // over budget only to keep 5 s
            if channels == 2 && rate <= 192_000 { #expect(seconds >= 20) }
        }
    }
}
