//
// Vespertine: the DASH FLAC fixture (init + three chunks of source.flac) and hand-built fMP4 boxes, shared by the reader,
// playback and download tests, and a decoder that gives a file's PCM bytes for sample-exact comparisons.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import SFBAudioEngine
import Testing
@testable import VespertineTidal

enum DASHFixture {
    static func directory() throws -> URL { try Fixture.url("dash") }
    static func initSegment() throws -> Data { try Data(contentsOf: directory().appendingPathComponent("init.mp4")) }
    static func source() throws -> Data { try Data(contentsOf: directory().appendingPathComponent("source.flac")) }

    /// The media segments, in number order.
    static func chunks() throws -> [Data] {
        let directory = try directory()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("chunk-") && $0.hasSuffix(".m4s") }
        func number(_ name: String) -> Int {
            (name as NSString).deletingPathExtension.split(whereSeparator: { !$0.isNumber }).last.flatMap { Int($0) } ?? 0
        }
        return try names.sorted { number($0) < number($1) }.map { try Data(contentsOf: directory.appendingPathComponent($0)) }
    }

    static func be32(_ value: Int) -> Data { Data([UInt8(value >> 24 & 255), UInt8(value >> 16 & 255), UInt8(value >> 8 & 255), UInt8(value & 255)]) }

    static func box(_ type: String, _ payload: Data = Data()) -> Data { be32(8 + payload.count) + Data(type.utf8) + payload }

    /// styp + moof(mfhd, traf(tfhd, trun with `sizes`)) + mdat(`payload`), the trun's data offset pointing at the payload.
    static func segment(sizes: [Int], payload: Data) -> Data {
        func moof(dataOffset: Int) -> Data {
            let mfhd = box("mfhd", be32(0) + be32(1))
            let tfhd = box("tfhd", be32(0x020000) + be32(1))
            var trunBody = be32(0x000201) + be32(sizes.count) + be32(dataOffset)
            for size in sizes { trunBody += be32(size) }
            return box("moof", mfhd + box("traf", tfhd + box("trun", trunBody)))
        }
        let moofSize = moof(dataOffset: 0).count
        return box("styp", Data("msdh".utf8) + be32(0)) + moof(dataOffset: moofSize + 8) + box("mdat", payload)
    }

    /// The FLAC the fixture's init and chunks stand for: the header, then every chunk's payload.
    static func remuxed() throws -> Data {
        var stream = try DASHFLACLayout.flacHeader(fromInit: initSegment())
        for chunk in try chunks() {
            let info = try #require(try DASHFLACLayout.mediaPayload(segmentPrefix: chunk))
            for range in info.payloads { stream += chunk[range] }
        }
        return stream
    }

    /// Every decoded frame's bytes, and how many frames.
    static func decode(_ url: URL) throws -> (frames: Int, bytes: Data) {
        let decoder = try AudioDecoder(url: url)
        try decoder.open()
        let format = decoder.processingFormat
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        var frames = 0
        var bytes = Data()
        while true {
            try decoder.decode(into: buffer, length: 4096)
            if buffer.frameLength == 0 { break }
            frames += Int(buffer.frameLength)
            let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let perFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
            for audioBuffer in list {
                if let data = audioBuffer.mData { bytes.append(Data(bytes: data, count: Int(buffer.frameLength) * perFrame)) }
            }
        }
        return (frames, bytes)
    }

    static func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Deterministic noise: bytes no two offsets share by accident, so a misplaced read shows.
func noise(_ count: Int, seed: UInt32 = 7) -> Data {
    var state = seed
    var data = Data(count: count)
    data.withUnsafeMutableBytes { buffer in
        for i in 0..<count {
            state = state &* 1_664_525 &+ 1_013_904_223
            buffer[i] = UInt8(truncatingIfNeeded: state >> 24)
        }
    }
    return data
}
