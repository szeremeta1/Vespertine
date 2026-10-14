// Vespertine — compressed DSDIFF must preserve the DSD, PCM and DoP of its uncompressed equivalent.
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFAudio
import Foundation
import SFBAudioEngine
import Testing
import VespertineTestSupport
@testable import VespertineAudio

@Suite("DST-compressed DSDIFF")
struct DSTDSDIFFTests {
    private func decode(_ url: URL, mode: OutputPlan.Mode, seek: Int64 = 0, limit: Int = .max) throws -> [[Float]] {
        let p = try SourceOpener.probe(url)
        let rate = p.format.sampleRate / (mode == .dop ? 16 : 8)
        let plan = OutputPlan(mode: mode, deviceSampleRate: rate, decodedSampleRate: rate,
                              physicalBitDepth: mode == .dop ? 24 : 32, channels: p.format.channels,
                              dsdConvertedToPCM: mode == .pcm, reason: "")
        let d = try SourceOpener.decoder(for: p, plan: plan, item: PlayableItem(url: url))
        defer { try? d.close() }
        try d.seek(to: seek)
        let b = try #require(AVAudioPCMBuffer(pcmFormat: d.processingFormat, frameCapacity: 4096))
        var out = [[Float]](repeating: [], count: p.format.channels)
        while out[0].count < limit {
            try d.decode(into: b, length: AVAudioFrameCount(min(4096, limit - out[0].count)))
            if b.frameLength == 0 { break }
            for c in out.indices { out[c] += UnsafeBufferPointer(start: b.floatChannelData![c], count: Int(b.frameLength)) }
        }
        return out
    }

    @Test("Indexed and unindexed stereo/surround preserve every DSD byte, PCM and DoP", arguments: [2, 5, 6], [false, true])
    func roundTrip(channels: Int, indexed: Bool) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dst-dff-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dst = dir.appendingPathComponent("compressed.dff"), plain = dir.appendingPathComponent("plain.dff")
        let planes = SACDFixture.modulate(channels: channels, frames: 3)
        try DSDIFFFixture.writeDST(planes, indexed: indexed, withCRC: indexed, to: dst)
        try DSDIFFFixture.write(planes, to: plain)
        let info = try #require(try DSTDSDIFFInfo.read(dst))
        if channels > 2 { #expect(try SourceOpener.probe(dst).format.channelLabels?.count == channels) }
        #expect(info.index.count == (indexed ? 3 : 0))
        let source = try DSTDSDIFFSource(url: dst, info: info)
        var inter = [UInt8](repeating: 0, count: planes[0].count * channels)
        let n = try inter.withUnsafeMutableBufferPointer { try source.readInterleaved(into: $0.baseAddress!, bytes: planes[0].count) }
        #expect(n == planes[0].count)
        for c in 0..<channels { #expect(stride(from: c, to: inter.count, by: channels).map { inter[$0] } == planes[c]) }
        #expect(try SourceInspector.inspectWithDuration(dst).duration == 3.0 / 75)
        #expect(try DSTDSDIFFInfo.read(plain) == nil)
        for mode in [OutputPlan.Mode.pcm, .dop] {
            let actual = try decode(dst, mode: mode), expected = try decode(plain, mode: mode)
            #expect(actual == expected)
            let offset = Int64(actual[0].count / 2)
            let seeked = try decode(dst, mode: mode, seek: offset, limit: 129)
            if mode == .dop {
                // The marker starts anew on a seek; use the same seek in the independent plain source.
                #expect(seeked == (try decode(plain, mode: mode, seek: offset, limit: 129)))
            } else {
                #expect(seeked == expected.map { Array($0[Int(offset)..<Int(offset) + 129]) })
            }
        }
        try source.seekDSD(to: source.dsdLength)
        var end = [UInt8](repeating: 0, count: channels)
        #expect(try end.withUnsafeMutableBufferPointer { try source.readInterleaved(into: $0.baseAddress!, bytes: 1) } == 0)
    }

    @Test("Truncated containers and invalid DST frames are errors")
    func damage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dst-damage-\(UUID()).dff")
        defer { try? FileManager.default.removeItem(at: url) }
        try DSDIFFFixture.writeDST(SACDFixture.modulate(channels: 2, frames: 2), indexed: true, to: url)
        let data = try Data(contentsOf: url), info = try #require(try DSTDSDIFFInfo.read(url))
        // A malformed optional seek index falls back to the frame headers.
        var badIndex = data
        if let marker = badIndex.range(of: Data("DSTI".utf8)) {
            badIndex.replaceSubrange(marker.lowerBound + 12..<marker.lowerBound + 20, with: [UInt8](repeating: 0, count: 8))
        }
        try badIndex.write(to: url)
        let rebuilt = try #require(try DSTDSDIFFInfo.read(url))
        #expect(rebuilt.index.isEmpty)
        #expect(try decode(url, mode: .dop).first?.isEmpty == false)
        try data.dropLast(1).write(to: url)
        #expect(throws: (any Error).self) { try DSTDSDIFFInfo.read(url) }
        var damaged = data
        damaged[Int(info.index[0].offset)] = 0x80
        try damaged.write(to: url)
        #expect(throws: (any Error).self) { try decode(url, mode: .dop) }
        try DSDIFFFixture.writeDST(SACDFixture.modulate(channels: 2, frames: 2), indexed: false, withCRC: true, to: url)
        var crcDamage = try Data(contentsOf: url)
        let crc = try #require(crcDamage.range(of: Data("DSTC".utf8)))
        crcDamage[crc.lowerBound + 12] ^= 1
        try crcDamage.write(to: url)
        #expect(throws: (any Error).self) { try decode(url, mode: .pcm) }
    }
}
