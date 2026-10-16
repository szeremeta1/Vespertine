//
// Vespertine — DoP packing: whole frames only, and an odd last DSD byte padded with DSD silence rather than dropped
// (blind-agent finding B-04, docs/VERIFICATION-BLIND.md).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("DoP packing")
struct DoPPackingTests {
    /// Raw DSD from memory, one plane per channel, handed out at most `chunk` bytes per read (odd chunks end reads on
    /// half a frame).
    final class MemoryDSD: RawDSDSource {
        let planes: [[UInt8]]
        let chunk: Int
        var position = 0
        init(_ planes: [[UInt8]], chunk: Int = .max) { self.planes = planes; self.chunk = chunk }
        var channelCount: Int { planes.count }
        var dsdRate: Double { 2_822_400 }
        var dsdLength: Int64 { Int64(planes[0].count) }
        var isOpen: Bool { true }
        var inputSource: InputSource { InputSource(data: Data()) }
        func readDSD(into out: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>>, bytes: Int) throws -> Int {
            let n = max(0, min(bytes, chunk, planes[0].count - position))
            for (c, plane) in planes.enumerated() where n > 0 {
                plane.withUnsafeBufferPointer { out[c].update(from: $0.baseAddress! + position, count: n) }
            }
            position += n
            return n
        }
        func seekDSD(to position: Int64) throws { self.position = Int(position) }
        func close() throws {}
    }

    /// Everything a RawDoPDecoder produces, as frames[n][c] 24-bit words, read `length` frames at a time.
    private func decode(_ source: MemoryDSD, firstMarker: UInt8 = 0x05, length: AVAudioFrameCount = 1000) throws -> [[UInt32]] {
        let decoder = try RawDoPDecoder(source: source)
        decoder.nextMarker = firstMarker == 0x05 ? 0 : 1
        let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: length)!
        var frames: [[UInt32]] = []
        while true {
            try decoder.decode(into: buffer, length: length)
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { break }
            for i in 0..<n {
                frames.append((0..<source.planes.count).map { c in
                    UInt32(bitPattern: Int32((Double(data[c][i]) * 2_147_483_648).rounded())) >> 8
                })
            }
        }
        #expect(Int64(frames.count) == decoder.length)
        return frames
    }

    private let left: [UInt8] = [0x80, 0x01, 0x12, 0x34, 0xFF, 0x00, 0xA5]
    private let right: [UInt8] = [0x00, 0x7F, 0x56, 0x78, 0x0F, 0xF0, 0x5A]

    @Test("The packer refuses half frames, unequal channels and markers other than 0x05 / 0xFA")
    func packRefusals() throws {
        #expect(try DoP.pack([[0x80, 0x01], [0x12, 0x34]]) == [[0x05_8001, 0x05_1234]])
        #expect(try DoP.pack([[0x80, 0x01, 0x00, 0x02]], firstMarker: 0xFA) == [[0xFA_8001], [0x05_0002]])
        #expect(throws: DoPError.oddByteCount(7)) { try DoP.pack([left, right]) }
        #expect(throws: DoPError.unequalChannels) { try DoP.pack([left, Array(right.prefix(6))]) }
        #expect(throws: DoPError.noChannels) { try DoP.pack([]) }
        #expect(throws: DoPError.marker(0x06)) { try DoP.pack([[0, 0]], firstMarker: 0x06) }
    }

    @Test("Playback packs exactly as the packer does", arguments: [0x05, 0xFA] as [UInt8])
    func decoderMatchesPacker(firstMarker: UInt8) throws {
        let planes = (0..<3).map { c in (0..<2_050).map { UInt8(truncatingIfNeeded: $0 * 7 + c * 31) } }
        #expect(try decode(MemoryDSD(planes), firstMarker: firstMarker) == DoP.pack(planes, firstMarker: firstMarker))
    }

    @Test("An odd last byte is padded with DSD silence into a last whole frame, not dropped")
    func oddLastByte() throws {
        let padded = try DoP.pack([left + [DoP.silence], right + [DoP.silence]])
        #expect(padded.count == 4 && padded[3] == [0xFA_A569, 0xFA_5A69])
        #expect(try decode(MemoryDSD([left, right])) == padded)
        // Reads that end on half a frame mid-track read on: same frames, same markers.
        for chunk in [1, 3, 5] {
            #expect(try decode(MemoryDSD([left, right], chunk: chunk), length: 2) == padded)
        }
    }
}
