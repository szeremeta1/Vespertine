//
// Vespertine — RF64 and Sony Wave64: the WAV containers for files past 4 GB, which multichannel hi-res albums need.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import Testing
@testable import VespertineAudio

enum LargeWAVFiles {
    enum Container: String, CaseIterable, CustomTestStringConvertible {
        case rf64InWAV, rf64, wave64
        var pathExtension: String { switch self { case .rf64InWAV: "wav"; case .rf64: "rf64"; case .wave64: "w64" } }
        var testDescription: String { rawValue }
    }

    private static func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }

    /// Channel `c` of frame `f`, 24-bit. Frame 0 starts with the bytes FF FB 50, an MPEG audio frame header (24-bit
    /// music has such byte runs everywhere: the MP3 decoder's header check finds one in the first 2 KB of most files).
    static func sample(frame f: Int, channel c: Int) -> Int32 {
        if f == 0, c == 0 { return 0x50FBFF }
        return Int32((c + 1) * 100_000) * (f % 2 == 0 ? 1 : -1)
    }

    /// WAVE_FORMAT_EXTENSIBLE, 24-bit, with the speaker mask for `channels` (5.1 back or 7.1).
    static func format(channels: Int, rate: Int) -> [UInt8] {
        let mask: UInt32 = channels == 8 ? 0x63F : 0x3F
        let align = 3 * channels
        return le(UInt16(0xFFFE)) + le(UInt16(channels)) + le(UInt32(rate)) + le(UInt32(rate * align)) + le(UInt16(align)) + le(UInt16(24))
            + le(UInt16(22)) + le(UInt16(24)) + le(mask)
            + [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]
    }

    static func samples(channels: Int, frames: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(frames * channels * 3)
        for f in 0..<frames { for c in 0..<channels {
            let v = UInt32(bitPattern: sample(frame: f, channel: c))
            out += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF)]
        } }
        return out
    }

    static func write(_ container: Container, channels: Int, frames: Int, rate: Int = 48_000, to url: URL) throws {
        let fmt = format(channels: channels, rate: rate), data = samples(channels: channels, frames: frames)
        var out: [UInt8]
        switch container {
        case .rf64InWAV, .rf64:
            // EBU Tech 3306: the 32-bit sizes are 0xFFFFFFFF and the real ones are in the ds64 chunk.
            let riffSize = UInt64(4 + (8 + 28) + (8 + fmt.count) + (8 + data.count))
            out = Array("RF64".utf8) + le(UInt32.max) + Array("WAVE".utf8)
            out += Array("ds64".utf8) + le(UInt32(28)) + le(riffSize) + le(UInt64(data.count)) + le(UInt64(frames)) + le(UInt32(0))
            out += Array("fmt ".utf8) + le(UInt32(fmt.count)) + fmt
            out += Array("data".utf8) + le(UInt32.max) + data
        case .wave64:
            // Sony Wave64: GUID chunk IDs, 64-bit sizes that include the 24-byte header, chunks on 8-byte boundaries.
            let tail: [UInt8] = [0xF3, 0xAC, 0xD3, 0x11, 0x8C, 0xD1, 0x00, 0xC0, 0x4F, 0x8E, 0xDB, 0x8A]
            func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
                let pad = (8 - body.count % 8) % 8
                return Array(id.utf8) + tail + le(UInt64(24 + body.count)) + body + [UInt8](repeating: 0, count: pad)
            }
            let body = Array("wave".utf8) + tail + chunk("fmt ", fmt) + chunk("data", data)
            out = Array("riff".utf8) + [0x2E, 0x91, 0xCF, 0x11, 0xA5, 0xD6, 0x28, 0xDB, 0x04, 0xC1, 0x00, 0x00] + le(UInt64(24 + body.count)) + body
        }
        try Data(out).write(to: url)
    }
}

@Suite("RF64 and Wave64")
struct LargeWAVTests {
    private func tmp(_ ext: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("largewav-\(UUID()).\(ext)") }

    // The studio evidence run (2026-10-23): every RF64 file failed to open ("not a valid MP3 file") and 24-bit 5.1 and
    // 7.1 Wave64 music opened as 2-channel MP3 of 0.0 s. RF64's 0xFFFFFFFF size reads as an MPEG frame header, so
    // the MP3 decoder outbid Core Audio for the file.
    @Test("RF64 and Wave64 open with every channel, every frame and the exact 24-bit samples",
          arguments: LargeWAVFiles.Container.allCases, [6, 8])
    func opensEveryChannel(container: LargeWAVFiles.Container, channels: Int) throws {
        let url = tmp(container.pathExtension), frames = 4_800
        defer { try? FileManager.default.removeItem(at: url) }
        try LargeWAVFiles.write(container, channels: channels, frames: frames, to: url)

        let probed = try SourceOpener.probe(url)
        #expect(probed.decoderName != "mpg123")
        #expect(probed.format.channels == channels)
        #expect(probed.format.bitDepth == 24)
        #expect(probed.format.encoding == .pcm)
        #expect(probed.format.sampleRate == 48_000)
        #expect(ChannelLayouts.name(labels: probed.format.channelLabels, channels: channels) == (channels == 8 ? "7.1" : "5.1"))

        let decoder = try SourceOpener.decoder(for: probed, plan: OutputPlan(mode: .pcm, deviceSampleRate: 48_000, decodedSampleRate: 48_000,
                                                                              physicalBitDepth: 24, channels: channels, dsdConvertedToPCM: false, reason: ""),
                                               item: PlayableItem(url: url))
        #expect(decoder.length == Int64(frames))
        // Read to the end, as Float32 per channel (24-bit integers convert exactly).
        let format = decoder.processingFormat
        #expect(Int(format.channelCount) == channels)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        let layout = format.channelLayout ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels))!
        let floatFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channelLayout: layout)
        let converter = format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved ? nil : AVAudioConverter(from: format, to: floatFormat)
        var read = [[Int32]](repeating: [], count: Int(format.channelCount))
        while true {
            try decoder.decode(into: buffer, length: buffer.frameCapacity)
            if buffer.frameLength == 0 { break }
            var floats = buffer
            if let converter {
                floats = try #require(AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: buffer.frameLength))
                try converter.convert(to: floats, from: buffer)
            }
            let planes = try #require(floats.floatChannelData)
            for c in read.indices { read[c] += (0..<Int(floats.frameLength)).map { Int32((planes[c][$0] * 8_388_608).rounded()) } }
        }
        #expect(read.allSatisfy { $0.count == frames })
        var mismatches = 0
        for c in read.indices { for (f, v) in read[c].enumerated() where v != LargeWAVFiles.sample(frame: f, channel: c) { mismatches += 1 } }
        #expect(mismatches == 0)
    }
}
