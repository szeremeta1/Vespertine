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
        let bursts = try frames.map { try IEC61937.ac3Burst($0.bytes) }
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
        let bursts = try groups.map { try IEC61937.eac3Burst($0.map(\.bytes)) }
        #expect(bursts.allSatisfy { $0.count == 6144 * 2 })
        let back = unpack(bursts.flatMap { $0 }, lengthInBytes: true)
        #expect(back.map(\.payload) == groups.map { $0.flatMap(\.bytes) })
        #expect(BitstreamFormat.eac3.carrierRate(for: 48_000) == 192_000)
    }

    private static func carrier(_ decoder: BitstreamDecoder) throws -> [Int16] {
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 5000)!
        var out: [Int16] = []
        while true {
            try decoder.decode(into: buffer, length: 5000)
            if buffer.frameLength == 0 { break }
            out += UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * 2)
        }
        return out
    }

    /// What a decoder made of a whole file.
    private struct Played: Sendable {
        var rate: Double, int16Stereo: Bool, samples: [Int16], length: Int64, concealed: Int
    }

    /// Opens `url` and plays it through on a thread of its own. AVFoundation's MP4 reader waits for work that needs a
    /// thread of Swift's concurrency pool, so reading from a pool thread (any test) can wait forever once every pool
    /// thread is busy the same way: CI's three-core runners hung on exactly that. Playback reads on its own thread.
    private func play(_ url: URL) async throws -> Played {
        return try await withCheckedThrowingContinuation { done in
            Thread {
                done.resume(with: Result {
                    let decoder = try BitstreamDecoder.open(url: url)
                    let format = decoder.processingFormat
                    let samples = try Self.carrier(decoder)
                    return Played(rate: format.sampleRate, int16Stereo: format.commonFormat == .pcmFormatInt16 && format.channelCount == 2,
                                  samples: samples, length: decoder.length, concealed: decoder.concealedFrames)
                })
            }.start()
        }
    }

    @Test("The carrier for a file holds its frames exactly, at the right rate", arguments: [
        ("dolby-digital-tones.ac3", 48_000.0, false), ("dolby-digital-plus-tones.ec3", 192_000.0, true),
        ("dolby-digital-plus-tones.m4a", 192_000.0, true),
    ])
    func carrierFromFile(name: String, rate: Double, enhanced: Bool) async throws {
        let played = try await play(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!)
        #expect(played.rate == rate)
        #expect(played.int16Stereo)
        let samples = played.samples
        let elementary = try fixture(name.replacingOccurrences(of: ".m4a", with: ".ec3"))
        let frames = DolbyFrames.frames(in: elementary)
        let expected = enhanced ? BitstreamPacker.eac3Groups(frames).map { $0.flatMap(\.bytes) } : frames.map(\.bytes)
        #expect(unpack(samples, lengthInBytes: enhanced).map(\.payload) == expected)
        #expect(Int64(samples.count / 2) == played.length)
    }

    @Test("Seeking lands on the requested carrier frame, inside the burst that holds it")
    func seek() throws {
        let url = Bundle.module.url(forResource: "dolby-digital-tones.ac3", withExtension: nil, subdirectory: "Fixtures")!
        let whole = try Self.carrier(try BitstreamDecoder.open(url: url))
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
        let strmtyp: Int = dependent ? 1 : 0
        f[2] = UInt8(strmtyp << 6 | substream << 3 | frmsiz >> 8)
        f[3] = UInt8(frmsiz & 0xFF)
        f[4] = UInt8(numblkscod << 4)          // fscod 0 (48 kHz)
        f[5] = 16 << 3                         // bsid 16
        return f
    }

    /// `units` stretches of audio, each an independent frame of `blocks` blocks and a dependent one of another size.
    private func dependentStream(units: Int, blocks: Int) -> [UInt8] {
        var stream: [UInt8] = []
        for u in 0..<units {
            let tag = UInt8(truncatingIfNeeded: 2 * u)
            stream += eac3Frame(bytes: 200, blocks: blocks, tag: tag)
            stream += eac3Frame(bytes: 120, blocks: blocks, dependent: true, tag: tag &+ 1)
        }
        return stream
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
        let whole = try Self.carrier(try BitstreamDecoder.open(url: url))
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
        let whole = try Self.carrier(try BitstreamDecoder.open(url: url))
        let decoder = try BitstreamDecoder.open(url: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 6144)!
        try decoder.decode(into: buffer, length: 100)     // one burst out, part of the next collected
        try decoder.seek(to: 0)
        #expect(try Self.carrier(decoder) == whole)
    }

    // MARK: The framers check their input (blind-agent findings B-01 to B-03, docs/VERIFICATION-BLIND.md)

    /// A synthetic AC-3 syncframe: 48 kHz, frmsizecod 16 (256 words), bsid 8, `bsmod`.
    private func ac3Frame(bsmod: UInt8 = 0) -> [UInt8] {
        var f = [UInt8](repeating: 0x5A, count: 512)
        f[0] = 0x0B; f[1] = 0x77; f[4] = 16; f[5] = 8 << 3 | bsmod
        return f
    }

    /// A synthetic DTS core frame (16-bit big-endian): NBLKS and FSIZE as given, the rest filler.
    private func dtsFrame(nblks: Int, bytes: Int) -> [UInt8] {
        let bits: UInt32 = 1 << 31 | 31 << 26 | UInt32(nblks) << 18 | UInt32(bytes - 1) << 4
        var f: [UInt8] = [0x7F, 0xFE, 0x80, 0x01, UInt8(bits >> 24), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits & 0xFF)]
        f += [UInt8](repeating: 0x33, count: bytes - 8)
        return f
    }

    /// The burst's Pd in bytes, and the payload bytes the burst has room for.
    private func pdBytes(_ burst: [Int16], lengthInBytes: Bool) -> Int {
        let pd = Int(UInt16(bitPattern: burst[3]))
        return lengthInBytes ? pd : (pd + 7) / 8
    }

    @Test("Dolby Digital: a frame without its sync word, cut short, or of the wrong codec is refused")
    func ac3Refusals() throws {
        let good = ac3Frame(bsmod: 2)
        let burst = try IEC61937.ac3Burst(good)
        #expect(UInt16(bitPattern: burst[2]) == 1 | 2 << 8 && Int(burst[3]) == good.count * 8)
        var badSync = good; badSync[1] = 0x78
        #expect(throws: BurstError.noSync) { try IEC61937.ac3Burst(badSync) }
        #expect(throws: BurstError.notAFrame) { try IEC61937.ac3Burst(Array(good.prefix(300))) }
        #expect(throws: BurstError.notAFrame) { try IEC61937.ac3Burst(good + [0]) }
        #expect(throws: BurstError.wrongCodec) { try IEC61937.ac3Burst(eac3Frame(bytes: 200, blocks: 6, tag: 1)) }
    }

    @Test("Dolby Digital Plus: a burst must hold exactly six audio blocks of valid frames (B-02)")
    func eac3Refusals() throws {
        let oneBlock = (0..<6).map { eac3Frame(bytes: 200, blocks: 1, tag: UInt8($0)) }
        #expect(try IEC61937.eac3Burst(oneBlock).count == 6144 * 2)
        #expect(throws: BurstError.blocks(3)) { try IEC61937.eac3Burst(Array(oneBlock.prefix(3))) }
        #expect(throws: BurstError.blocks(7)) { try IEC61937.eac3Burst(oneBlock + [eac3Frame(bytes: 200, blocks: 1, tag: 9)]) }
        var badSync = eac3Frame(bytes: 200, blocks: 6, tag: 1); badSync[0] = 0x77; badSync[1] = 0x0B
        #expect(throws: BurstError.noSync) { try IEC61937.eac3Burst([badSync]) }
        #expect(throws: BurstError.wrongCodec) { try IEC61937.eac3Burst([ac3Frame()]) }
        // An MP4 sample holds the independent frame and its dependent one back to back: both are checked.
        let sample = eac3Frame(bytes: 200, blocks: 6, tag: 1) + eac3Frame(bytes: 120, blocks: 6, dependent: true, tag: 2)
        #expect(try IEC61937.eac3Burst([sample]).count == 6144 * 2)
        #expect(throws: BurstError.notAFrame) { try IEC61937.eac3Burst([Array(sample.dropLast(10))]) }
    }

    @Test("A payload too big for its burst is refused, never cut short under a Pd that claims all of it (B-01)")
    func overCapacity() throws {
        // Six 4096-byte one-block frames: 24 576 bytes, 8 more than fit after the preamble in 6144 frames.
        let big = (0..<6).map { eac3Frame(bytes: 4096, blocks: 1, tag: UInt8($0)) }
        #expect(throws: BurstError.tooBig(bytes: 24_576, room: 24_568)) { try IEC61937.eac3Burst(big) }
        // The biggest that fits goes out whole, Pd and payload agreeing.
        let fits = try IEC61937.eac3Burst([eac3Frame(bytes: 4096, blocks: 6, tag: 1)])
        #expect(pdBytes(fits, lengthInBytes: true) == 4096)
        // DTS: a 512-sample frame has room for 2040 bytes.
        #expect(try IEC61937.dtsBurst(dtsFrame(nblks: 15, bytes: 2040)).count == 512 * 2)
        #expect(throws: BurstError.tooBig(bytes: 2044, room: 2040)) { try IEC61937.dtsBurst(dtsFrame(nblks: 15, bytes: 2044)) }

        // In playback the refused burst goes out as silence of the same length, so the carrier keeps its timing.
        let good = (0..<6).map { eac3Frame(bytes: 200, blocks: 1, tag: UInt8(10 + $0)) }
        let url = try temporaryFile((good + big + good).flatMap { $0 })
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try BitstreamDecoder.open(url: url)
        let samples = try Self.carrier(decoder)
        #expect(samples.count == 3 * 6144 * 2)
        #expect(samples[(6144 * 2)..<(2 * 6144 * 2)].allSatisfy { $0 == 0 })
        #expect(unpack(samples, lengthInBytes: true).map(\.payload) == [good.flatMap { $0 }, good.flatMap { $0 }])
        #expect(decoder.concealedFrames == 1)
    }

    @Test("DTS: the frame header decides the burst; no sync, a cut header, or an unsupported length is refused")
    func dtsRefusals() throws {
        for (nblks, type, period) in [(15, 11, 512), (31, 12, 1024), (63, 13, 2048)] {
            let frame = dtsFrame(nblks: nblks, bytes: 1007)
            let burst = try IEC61937.dtsBurst(frame)
            #expect(burst.count == period * 2 && burst[2] == Int16(type) && Int(burst[3]) == 1007 * 8)
        }
        var noSync = dtsFrame(nblks: 31, bytes: 1000); noSync[0...3] = [0, 0, 0, 0]
        #expect(throws: BurstError.noSync) { try IEC61937.dtsBurst(noSync) }
        #expect(throws: BurstError.notAFrame) { try IEC61937.dtsBurst(Array(dtsFrame(nblks: 31, bytes: 1000).prefix(6))) }
        #expect(throws: BurstError.notAFrame) { try IEC61937.dtsBurst(Array(dtsFrame(nblks: 31, bytes: 1000).prefix(900))) }
        #expect(throws: BurstError.samples(256)) { try IEC61937.dtsBurst(dtsFrame(nblks: 7, bytes: 600)) }
        #expect(throws: BurstError.samples(4096)) { try IEC61937.dtsBurst(dtsFrame(nblks: 127, bytes: 3000)) }
    }

    @Test("A stream ending on fewer than six blocks ends in silence for those blocks, not a short burst (B-02)")
    func shortLastGroup() throws {
        let stream = (0..<8).flatMap { eac3Frame(bytes: 200, blocks: 1, tag: UInt8($0)) }
        let url = try temporaryFile(stream)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try BitstreamDecoder.open(url: url)
        let samples = try Self.carrier(decoder)
        // One burst of six blocks, then two blocks' worth (2 × 256 samples × 4 carrier frames) of silence.
        #expect(samples.count == (6144 + 2 * 256 * 4) * 2 && Int64(samples.count / 2) == decoder.length)
        #expect(samples[(6144 * 2)...].allSatisfy { $0 == 0 })
        #expect(unpack(samples, lengthInBytes: true).map(\.payload) == [Array(stream.prefix(6 * 200))])
        #expect(decoder.concealedFrames == 0)        // the stream just ends there; nothing was damaged
    }

    @Test("A damaged MP4 sample is dropped: its burst plays as silence and the rest stays in place (B-03)")
    func damagedMP4Sample() async throws {
        let m4a = try fixture("dolby-digital-plus-tones.m4a")
        let frames = DolbyFrames.frames(in: try fixture("dolby-digital-plus-tones.ec3"))
        #expect(frames.allSatisfy { $0.blocks == 6 && !$0.isDependent })
        // Break the sync word of the fourth frame where the MP4 holds it.
        let target = frames[3].bytes
        let at = try #require((0...(m4a.count - target.count)).first { m4a[$0..<($0 + target.count)].elementsEqual(target) })
        var damaged = m4a
        damaged[at] = 0; damaged[at + 1] = 0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-\(UUID().uuidString).m4a")
        try Data(damaged).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let played = try await play(url)
        let samples = played.samples
        let groups = BitstreamPacker.eac3Groups(frames)
        #expect(samples.count == groups.count * 6144 * 2)
        #expect(samples[(3 * 6144 * 2)..<(4 * 6144 * 2)].allSatisfy { $0 == 0 })
        var expected = groups.map { $0.flatMap(\.bytes) }
        expected.remove(at: 3)
        #expect(unpack(samples, lengthInBytes: true).map(\.payload) == expected)
        #expect(played.concealed == 1)
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
