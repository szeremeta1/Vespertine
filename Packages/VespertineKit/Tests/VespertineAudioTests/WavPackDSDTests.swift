//
// Vespertine: DSD inside WavPack plays as the DSD it was made from: the bytes, DoP and the PCM conversion are
// identical to a DSDIFF file of the same DSD.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import CryptoKit
import Foundation
import Testing
import VespertineTestSupport
@testable import VespertineAudio

@Suite("DSD in WavPack")
struct WavPackDSDTests {
    /// The file, the SHA-256 of its DSD (bytes per channel interleaved, most significant bit first) as it was before
    /// WavPack encoded it, and the shape. The WavPack files were made by WavPack 5.8.1's `wavpack` from synthesized
    /// DSDIFF and DSF files (docs/fixtures/make-wavpack-dsd-fixtures.py), and `wvunpack --dff` gives those DSDIFF
    /// files back byte for byte.
    static let cases: [(name: String, hash: String, channels: Int, rate: Double, bytes: Int)] = [
        ("dsd64-stereo-from-dsdiff.wv", "024a411b9c68707f78cb94c8994a678bbdac70e290711c1c10ce24f23f513b1f", 2, 2_822_400, 28_224),
        // The same DSD from a DSF file, which stores each byte least significant bit first.
        ("dsd64-stereo-from-dsf.wv", "024a411b9c68707f78cb94c8994a678bbdac70e290711c1c10ce24f23f513b1f", 2, 2_822_400, 28_224),
        ("dsd128-stereo.wv", "c9a353c0627ab3012ea01123c68dc1878a18bec3abcddc2a795220904a345557", 2, 5_644_800, 28_224),
        ("dsd64-5.1.wv", "89938a531229aafa98df104d8a01f12edcbc2c5df57340398390d3a4e8213fd9", 6, 2_822_400, 14_112),
    ]

    static func fixture(_ name: String) -> URL { ContainerFormatTests.fixture(name) }

    static func hex(_ data: [UInt8]) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// All of a file's DSD, interleaved.
    static func nativeBytes(_ url: URL) throws -> (bytes: [UInt8], source: WavPackDSDSource) {
        let source = try #require(try WavPackDSDSource(url: url))
        var out = [UInt8](repeating: 0, count: Int(source.dsdLength) * source.channelCount)
        var got = 0
        while got < Int(source.dsdLength) {
            let n = try out.withUnsafeMutableBufferPointer { try source.readInterleaved(into: $0.baseAddress! + got * source.channelCount, bytes: 1000) }
            if n == 0 { break }
            got += n
        }
        #expect(got == Int(source.dsdLength))
        return (out, source)
    }

    static func decode(_ url: URL, mode: OutputPlan.Mode) throws -> (audio: [[Float]], format: SourceFormat) {
        let probed = try SourceOpener.probe(url)
        let rate = probed.format.sampleRate / (mode == .dop ? 16 : 8)
        let plan = OutputPlan(mode: mode, deviceSampleRate: rate, decodedSampleRate: rate, physicalBitDepth: mode == .dop ? 24 : 32,
                              channels: probed.format.channels, dsdConvertedToPCM: mode == .pcm, reason: "")
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: url))
        defer { try? decoder.close() }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096))
        var out = [[Float]](repeating: [], count: probed.format.channels)
        while true {
            try decoder.decode(into: buffer, length: 4096)
            if buffer.frameLength == 0 { break }
            for c in out.indices { out[c] += UnsafeBufferPointer(start: buffer.floatChannelData![c], count: Int(buffer.frameLength)) }
        }
        return (out, probed.format)
    }

    @Test("The DSD comes out as it went in, whichever bit order the source file had", arguments: cases)
    func nativeBitstream(c: (name: String, hash: String, channels: Int, rate: Double, bytes: Int)) throws {
        let (bytes, source) = try Self.nativeBytes(Self.fixture(c.name))
        #expect(source.channelCount == c.channels && source.dsdRate == c.rate && source.dsdLength == Int64(c.bytes))
        #expect(Self.hex(bytes) == c.hash)
    }

    @Test("It is probed as DSD, with its rate and speakers", arguments: cases)
    func probes(c: (name: String, hash: String, channels: Int, rate: Double, bytes: Int)) throws {
        let (format, duration) = try SourceInspector.inspectWithDuration(Self.fixture(c.name))
        #expect(format.encoding == .dsd && format.codec == "WavPack" && format.bitDepth == 1)
        #expect(format.sampleRate == c.rate && format.channels == c.channels)
        #expect(format.dsdName == (c.rate == 2_822_400 ? "DSD64" : "DSD128"))
        #expect(abs(duration - Double(c.bytes) * 8 / c.rate) < 1e-9)
        if c.channels == 6 {
            #expect(format.channelLabels == [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                                             kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround])
        }
        #expect(try SourceOpener.probe(Self.fixture(c.name)).decoderName.contains("WavPack"))
    }

    @Test("DoP and the PCM conversion equal a DSDIFF file of the same DSD, bit for bit", arguments: cases)
    func sameAsDSDIFF(c: (name: String, hash: String, channels: Int, rate: Double, bytes: Int)) throws {
        let (inter, source) = try Self.nativeBytes(Self.fixture(c.name))
        let channels = source.channelCount, bytes = Int(source.dsdLength)
        let planes = (0..<channels).map { ch in (0..<bytes).map { inter[$0 * channels + ch] } }
        let dff = FileManager.default.temporaryDirectory.appendingPathComponent("wv-\(UUID()).dff")
        defer { try? FileManager.default.removeItem(at: dff) }
        try DSDIFFFixture.write(planes, rate: c.rate, to: dff)
        for mode in [OutputPlan.Mode.dop, .pcm] {
            let actual = try Self.decode(Self.fixture(c.name), mode: mode).audio, expected = try Self.decode(dff, mode: mode).audio
            #expect(actual.count == channels && actual[0].count == expected[0].count && actual[0].count > 0)
            #expect(actual == expected, "\(c.name) \(mode)")
        }
        // DoP, from first principles: 16 DSD bits a frame behind the alternating marker, nothing else changed.
        let dop = try DoP.pack(planes)
        let played = try Self.decode(Self.fixture(c.name), mode: .dop).audio
        for ch in 0..<channels {
            let words = played[ch].map { UInt32(bitPattern: Int32($0 * 8_388_608)) & 0xFFFFFF }
            #expect(words == dop.map { $0[ch] }, "channel \(ch)")
        }
    }

    @Test("A seek lands on the byte asked for, and playing on from it matches playing through")
    func seeks() throws {
        let (inter, source) = try Self.nativeBytes(Self.fixture("dsd64-stereo-from-dsf.wv"))
        for target in [0, 1, 4_095, 4_096, 9_999, 20_000, 28_000, 28_223] {
            try source.seekDSD(to: Int64(target))
            var out = [UInt8](repeating: 0, count: 2 * 500)
            let n = try out.withUnsafeMutableBufferPointer { try source.readInterleaved(into: $0.baseAddress!, bytes: 500) }
            #expect(n == min(500, 28_224 - target))
            #expect(Array(out.prefix(n * 2)) == Array(inter[target * 2..<(target + n) * 2]), "at \(target)")
        }
        try source.seekDSD(to: 28_224)
        var one = [UInt8](repeating: 0, count: 2)
        #expect(try one.withUnsafeMutableBufferPointer { try source.readInterleaved(into: $0.baseAddress!, bytes: 1) } == 0)
    }

    @Test("A WavPack file of PCM is not claimed, and still plays as lossless PCM")
    func pcmIsLeftAlone() throws {
        #expect(try WavPackDSDSource(url: Self.fixture("pcm-stereo24.wv")) == nil)
        let (format, _) = try SourceInspector.inspectWithDuration(Self.fixture("pcm-stereo24.wv"))
        #expect(format.encoding == .pcm)
        #expect(format.codec == "WavPack")
        #expect(format.bitDepth == 24, "bit depth \(String(describing: format.bitDepth))")
        #expect(format.sampleRate == 48_000)
    }

    @Test("A truncated file is an error, not a shorter track")
    func truncated() throws {
        let data = try Data(contentsOf: Self.fixture("dsd64-stereo-from-dsdiff.wv"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wv-cut-\(UUID()).wv")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.prefix(data.count / 2).write(to: url)
        #expect(throws: (any Error).self) { _ = try Self.nativeBytes(url) }
    }
}
