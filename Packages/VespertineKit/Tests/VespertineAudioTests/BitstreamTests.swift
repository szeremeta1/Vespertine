//
// Vespertine — IEC 61937 bursts carry Dolby and DTS frames exactly.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Bitstream (IEC 61937)")
struct BitstreamTests {
    private func fixture(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!))
    }

    /// Reads bursts back: preamble, type, length, payload (the inverse of the packer).
    private func unpack(_ samples: [Int16], lengthInBytes: Bool) -> [(type: UInt16, payload: [UInt8])] {
        var out: [(UInt16, [UInt8])] = [], i = 0
        while i + 4 <= samples.count {
            guard UInt16(bitPattern: samples[i]) == 0xF872, UInt16(bitPattern: samples[i + 1]) == 0x4E1F else { i += 2; continue }
            let type = UInt16(bitPattern: samples[i + 2]), pd = Int(UInt16(bitPattern: samples[i + 3]))
            let bytes = lengthInBytes ? pd : pd / 8
            var payload: [UInt8] = []
            var w = i + 4
            while payload.count < bytes { let v = UInt16(bitPattern: samples[w]); payload += [UInt8(v >> 8), UInt8(v & 0xFF)]; w += 1 }
            out.append((type, Array(payload.prefix(bytes))))
            i = w
        }
        return out
    }

    @Test("Dolby Digital frames are parsed and each fills one 1536-frame burst")
    func ac3() throws {
        let stream = try fixture("dolby-digital-tones.ac3")
        let frames = DolbyFrames.frames(in: stream)
        #expect(frames.count > 40)
        #expect(frames.allSatisfy { !$0.isEnhanced && $0.blocks == 6 && $0.sampleRate == 48_000 })
        #expect(frames.reduce(0) { $0 + $1.bytes.count } == stream.count)            // nothing skipped
        let bursts = frames.map { IEC61937.ac3Burst($0.bytes) }
        #expect(bursts.allSatisfy { $0.count == 1536 * 2 })
        let back = unpack(bursts.flatMap { $0 }, lengthInBytes: false)
        #expect(back.map(\.payload) == frames.map(\.bytes))
        #expect(back.allSatisfy { $0.type & 0x1F == 1 })
    }

    @Test("Dolby Digital Plus frames are grouped into six-block bursts at four times the rate")
    func eac3() throws {
        let stream = try fixture("dolby-digital-plus-tones.ec3")
        let frames = DolbyFrames.frames(in: stream)
        #expect(frames.allSatisfy { $0.isEnhanced && $0.sampleRate == 48_000 })
        #expect(frames.reduce(0) { $0 + $1.bytes.count } == stream.count)
        let groups = BitstreamPacker.eac3Groups(frames)
        #expect(groups.allSatisfy { $0.reduce(0) { $0 + $1.blocks } == 6 })
        let bursts = groups.map { IEC61937.eac3Burst($0.map(\.bytes)) }
        #expect(bursts.allSatisfy { $0.count == 6144 * 2 })
        let back = unpack(bursts.flatMap { $0 }, lengthInBytes: true)
        #expect(back.map(\.payload) == groups.map { $0.flatMap(\.bytes) })
        #expect(BitstreamFormat.eac3.carrierRate(for: 48_000) == 192_000)
    }

    private func carrier(_ decoder: BitstreamDecoder) throws -> [Int16] {
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 5000)!
        var out: [Int16] = []
        while true {
            try decoder.decode(into: buffer, length: 5000)
            if buffer.frameLength == 0 { break }
            out += UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * 2)
        }
        return out
    }

    @Test("The carrier for a file holds its frames exactly, at the right rate", arguments: [
        ("dolby-digital-tones.ac3", 48_000.0, false), ("dolby-digital-plus-tones.ec3", 192_000.0, true),
        ("dolby-digital-plus-tones.m4a", 192_000.0, true),
    ])
    func carrierFromFile(name: String, rate: Double, enhanced: Bool) throws {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
        let decoder = try BitstreamDecoder.open(url: url)
        #expect(decoder.processingFormat.sampleRate == rate)
        #expect(decoder.processingFormat.commonFormat == .pcmFormatInt16 && decoder.processingFormat.channelCount == 2)
        let samples = try carrier(decoder)
        let elementary = try fixture(name.replacingOccurrences(of: ".m4a", with: ".ec3"))
        let frames = DolbyFrames.frames(in: elementary)
        let expected = enhanced ? BitstreamPacker.eac3Groups(frames).map { $0.flatMap(\.bytes) } : frames.map(\.bytes)
        #expect(unpack(samples, lengthInBytes: enhanced).map(\.payload) == expected)
        #expect(Int64(samples.count / 2) == decoder.length)
    }

    @Test("Seeking lands on the requested carrier frame, inside the burst that holds it")
    func seek() throws {
        let url = Bundle.module.url(forResource: "dolby-digital-tones.ac3", withExtension: nil, subdirectory: "Fixtures")!
        let whole = try carrier(try BitstreamDecoder.open(url: url))
        let decoder = try BitstreamDecoder.open(url: url)
        for target in [0, 1536, 5000, 30_000] {
            try decoder.seek(to: AVAudioFramePosition(target))
            #expect(decoder.position == AVAudioFramePosition(target))
            let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 3072)!
            try decoder.decode(into: buffer, length: 3072)
            let got = Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * 2))
            #expect(got == Array(whole[(target * 2)..<(target * 2 + got.count)]))
        }
    }

    // MARK: Dependent substreams (7.1 and up: an independent frame, then a dependent one with the extra channels)

    /// A synthetic E-AC-3 frame: header fields that matter here, numbered filler after it (so frames can be told apart).
    private func eac3Frame(bytes: Int, blocks: Int, dependent: Bool = false, substream: Int = 0, tag: UInt8) -> [UInt8] {
        let frmsiz = bytes / 2 - 1
        let numblkscod = [1: 0, 2: 1, 3: 2, 6: 3][blocks]!
        var f = [UInt8](repeating: tag, count: bytes)
        f[0] = 0x0B; f[1] = 0x77
        f[2] = UInt8((dependent ? 1 : 0) << 6 | substream << 3 | frmsiz >> 8)
        f[3] = UInt8(frmsiz & 0xFF)
        f[4] = UInt8(numblkscod << 4)          // fscod 0 (48 kHz)
        f[5] = 16 << 3                         // bsid 16
        return f
    }

    /// `units` stretches of audio, each an independent frame of `blocks` blocks and a dependent one of another size.
    private func dependentStream(units: Int, blocks: Int) -> [UInt8] {
        (0..<units).flatMap { u in
            eac3Frame(bytes: 200, blocks: blocks, tag: UInt8(2 * u % 256)) + eac3Frame(bytes: 120, blocks: blocks, dependent: true, tag: UInt8((2 * u + 1) % 256))
        }
    }

    private func temporaryFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-\(UUID().uuidString).ec3")
        try Data(bytes).write(to: url)
        return url
    }

    @Test("Dependent substreams ride in their independent frame's burst and add no blocks")
    func dependentGrouping() {
        let frames = DolbyFrames.frames(in: dependentStream(units: 4, blocks: 6))
        #expect(frames.count == 8 && frames.map(\.isDependent) == [false, true, false, true, false, true, false, true])
        let groups = BitstreamPacker.eac3Groups(frames)
        #expect(groups.count == 4 && groups.allSatisfy { $0.count == 2 && !$0[0].isDependent && $0[1].isDependent })
        // One-block frames: six independent ones (and their dependents) make a burst.
        let small = BitstreamPacker.eac3Groups(DolbyFrames.frames(in: dependentStream(units: 12, blocks: 1)))
        #expect(small.map(\.count) == [12, 12])
        // An independent frame of another substream (a second program) adds no blocks either.
        let second = DolbyFrames.frames(in: eac3Frame(bytes: 100, blocks: 6, tag: 0) + eac3Frame(bytes: 100, blocks: 6, substream: 1, tag: 1)
                                             + eac3Frame(bytes: 100, blocks: 6, tag: 2))
        #expect(BitstreamPacker.eac3Groups(second).map(\.count) == [2, 1])
    }

    @Test("A stream with dependent substreams: every frame goes out, the length and seeks hold with alternating sizes")
    func dependentCarrier() throws {
        let stream = dependentStream(units: 10, blocks: 6)
        let url = try temporaryFile(stream)
        defer { try? FileManager.default.removeItem(at: url) }
        let whole = try carrier(try BitstreamDecoder.open(url: url))
        let groups = BitstreamPacker.eac3Groups(DolbyFrames.frames(in: stream))
        #expect(unpack(whole, lengthInBytes: true).map(\.payload) == groups.map { $0.flatMap(\.bytes) })
        let decoder = try BitstreamDecoder.open(url: url)
        #expect(decoder.length == 10 * 6144 && Int64(whole.count / 2) == decoder.length)
        for target in [6144 * 3, 6144 * 7 + 100] {
            try decoder.seek(to: AVAudioFramePosition(target))
            #expect(decoder.position == AVAudioFramePosition(target))
            let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 6144)!
            try decoder.decode(into: buffer, length: 6144)
            let got = Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * 2))
            #expect(!got.isEmpty && got == Array(whole[(target * 2)..<(target * 2 + got.count)]))
        }
    }

    @Test("A seek drops a burst that was half collected")
    func seekClearsGroup() throws {
        let url = try temporaryFile(dependentStream(units: 30, blocks: 1))
        defer { try? FileManager.default.removeItem(at: url) }
        let whole = try carrier(try BitstreamDecoder.open(url: url))
        let decoder = try BitstreamDecoder.open(url: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 6144)!
        try decoder.decode(into: buffer, length: 100)     // one burst out, part of the next collected
        try decoder.seek(to: 0)
        #expect(try carrier(decoder) == whole)
    }
}

/// Writes the carriers as WAV files (VESPERTINE_IEC_OUT=dir) for checking with FFmpeg's S/PDIF demuxer:
/// `ffmpeg -f spdif -i file.wav -f null -`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_IEC_OUT"] != nil))
func writeCarriersForFFmpeg() throws {
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VESPERTINE_IEC_OUT"]!)
    for name in ["dolby-digital-tones.ac3", "dolby-digital-plus-tones.ec3"] {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
        let decoder = try BitstreamDecoder.open(url: url)
        let out = try AVAudioFile(forWriting: dir.appendingPathComponent(name + ".iec.wav"),
                                  settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: decoder.processingFormat.sampleRate,
                                             AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false],
                                  commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 8192)!
        while true {
            try decoder.decode(into: buffer, length: 8192)
            if buffer.frameLength == 0 { break }
            try out.write(from: buffer)
        }
    }
}
