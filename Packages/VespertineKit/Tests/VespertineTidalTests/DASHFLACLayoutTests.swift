//
// Vespertine: the fragmented-MP4 reading that turns TIDAL's DASH FLAC segments back into a plain FLAC byte stream, checked
// against a real ffmpeg-made fixture (docs/fixtures/make-tidal-dash-fixture.sh) and hand-built segments.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import SFBAudioEngine
import Testing
@testable import VespertineTidal

@Suite("DASH FLAC layout")
struct DASHFLACLayoutTests {
    // MARK: Fixture

    private func fixtureDirectory() throws -> URL { try Fixture.url("dash") }

    private func initSegment() throws -> Data { try Data(contentsOf: fixtureDirectory().appendingPathComponent("init.mp4")) }

    /// The media segments, in number order (ffmpeg picks the names; the trailing number is what counts).
    private func chunks() throws -> [Data] {
        let directory = try fixtureDirectory()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("chunk-") && $0.hasSuffix(".m4s") }
        func number(_ name: String) -> Int {
            // The last run of digits before the extension: "chunk-stream0-00012.m4s" is 12.
            (name as NSString).deletingPathExtension.split(whereSeparator: { !$0.isNumber }).last.flatMap { Int($0) } ?? 0
        }
        return try names.sorted { number($0) < number($1) }.map { try Data(contentsOf: directory.appendingPathComponent($0)) }
    }

    // MARK: Hand-built segments

    private func be32(_ value: Int) -> Data { Data([UInt8(value >> 24 & 255), UInt8(value >> 16 & 255), UInt8(value >> 8 & 255), UInt8(value & 255)]) }

    private func box(_ type: String, _ payload: Data = Data()) -> Data { be32(8 + payload.count) + Data(type.utf8) + payload }

    /// One movie fragment: moof(mfhd, traf(tfhd, trun)) + mdat, with `sizes` in the trun and `payload` in the mdat. The trun's
    /// data_offset points at the mdat payload, as a real encoder writes it unless `dataOffsetDelta` skews it.
    private func fragment(sizes: [Int], payload: Data, trunSizeFlag: Bool = true, dataOffsetDelta: Int = 0) -> Data {
        func moof(dataOffset: Int) -> Data {
            let mfhd = box("mfhd", be32(0) + be32(1))
            let tfhd = box("tfhd", be32(0x020000) + be32(1))
            var trunBody = be32(trunSizeFlag ? 0x000201 : 0x000001) + be32(sizes.count) + be32(dataOffset)
            if trunSizeFlag { for size in sizes { trunBody += be32(size) } }
            return box("moof", mfhd + box("traf", tfhd + box("trun", trunBody)))
        }
        let moofSize = moof(dataOffset: 0).count
        return moof(dataOffset: moofSize + 8 + dataOffsetDelta) + box("mdat", payload)
    }

    /// styp + one fragment.
    private func segment(sizes: [Int], payload: Data, trunSizeFlag: Bool = true, dataOffsetDelta: Int = 0) -> Data {
        box("styp", Data("msdh".utf8) + be32(0)) + fragment(sizes: sizes, payload: payload, trunSizeFlag: trunSizeFlag, dataOffsetDelta: dataOffsetDelta)
    }

    // MARK: Header

    @Test("the FLAC header from the init segment is fLaC + a STREAMINFO for 96 kHz / 24 bit")
    func header() throws {
        let header = try DASHFLACLayout.flacHeader(fromInit: initSegment())
        #expect(Array(header.prefix(4)) == Array("fLaC".utf8))
        // Block header: last-block flag + type 0 (STREAMINFO), length 34.
        #expect(header[4] == 0x80 && Array(header[5...7]) == [0, 0, 34])
        #expect(header.count == 4 + 4 + 34)
        let info = Array(header[8..<42])
        let sampleRate = Int(info[10]) << 12 | Int(info[11]) << 4 | Int(info[12]) >> 4
        let channels = Int(info[12] >> 1 & 7) + 1
        let bits = (Int(info[12] & 1) << 4 | Int(info[13]) >> 4) + 1
        #expect(sampleRate == 96000 && bits == 24 && channels == 1)
    }

    @Test("only the final metadata block carries the last-block flag")
    func lastBlockFlag() throws {
        // An init segment whose dfLa holds STREAMINFO and a VORBIS_COMMENT; the flags come out right whichever way they were written.
        let streamInfo = Data([0x00, 0, 0, 34]) + Data(repeating: 7, count: 34)
        let comment = Data([0x84, 0, 0, 3]) + Data([1, 2, 3])
        let dfLa = box("dfLa", be32(0) + streamInfo + comment)
        let entry = box("fLaC", Data(repeating: 0, count: 28) + dfLa)
        let stsd = box("stsd", be32(0) + be32(1) + entry)
        let moov = box("moov", box("trak", box("mdia", box("minf", box("stbl", stsd)))))
        let header = try DASHFLACLayout.flacHeader(fromInit: box("ftyp", Data("iso5".utf8) + be32(0)) + moov)
        #expect(header[4] == 0x00 && header[4 + 4 + 34] == 0x84)
        #expect(header.count == 4 + 4 + 34 + 4 + 3)
    }

    @Test("an init segment without a dfLa is malformed")
    func noDfLa() {
        let moov = box("moov", box("trak", box("mdia", box("minf", box("stbl", box("stsd", be32(0) + be32(0)))))))
        #expect(throws: TidalError.self) { try DASHFLACLayout.flacHeader(fromInit: moov) }
        #expect(throws: TidalError.self) { try DASHFLACLayout.flacHeader(fromInit: Data()) }
    }

    // MARK: Media payload

    @Test("fLaC header + the payloads of every chunk decodes to the source FLAC's samples, sample for sample")
    func roundTrip() throws {
        var stream = try DASHFLACLayout.flacHeader(fromInit: initSegment())
        for chunk in try chunks() {
            let info = try #require(try DASHFLACLayout.mediaPayload(segmentPrefix: chunk))
            #expect(info.payloads.count == 1 && info.payloads[0].upperBound == chunk.count)
            #expect(info.endOffset == chunk.count)
            #expect(info.sampleSizesTotal == info.totalPayloadLength)
            for range in info.payloads { stream += chunk[range] }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dashflac-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rebuilt = directory.appendingPathComponent("rebuilt.flac")
        try stream.write(to: rebuilt)

        let expected = try decode(fixtureDirectory().appendingPathComponent("source.flac"))
        let actual = try decode(rebuilt)
        #expect(expected.frames == 3 * 96000)
        #expect(actual.frames == expected.frames)
        #expect(actual.bytes == expected.bytes)
    }

    @Test("the fixture has three chunks, matching the MPD's segment count")
    func chunkCountMatchesManifest() throws {
        let mpd = try String(contentsOf: fixtureDirectory().appendingPathComponent("manifest.mpd"), encoding: .utf8)
        let info = try MPDParser.parse(mpd)
        #expect(info.segmentCount == (try chunks().count))
        #expect(info.codecs == "flac" && info.sampleRate == 96000)
    }

    @Test("a prefix of 100 bytes needs more")
    func shortPrefix() throws {
        let chunk = try #require(try chunks().first)
        #expect(try DASHFLACLayout.mediaPayload(segmentPrefix: chunk.prefix(100)) == nil)
        #expect(try DASHFLACLayout.mediaPayload(segmentPrefix: Data()) == nil)
        #expect(try DASHFLACLayout.mediaPayload(segmentPrefix: chunk.prefix(4)) == nil)
    }

    @Test("the payload is found as soon as the prefix reaches the mdat header, with the full length")
    func prefixThroughMdatHeader() throws {
        let chunk = try #require(try chunks().first)
        let full = try #require(try DASHFLACLayout.mediaPayload(segmentPrefix: chunk))
        let needed = full.payloads[0].lowerBound
        #expect(try DASHFLACLayout.mediaPayload(segmentPrefix: chunk.prefix(needed - 1)) == nil)
        #expect(try DASHFLACLayout.mediaPayload(segmentPrefix: chunk.prefix(needed)) == full)
        #expect(try DASHFLACLayout.mediaPayload(segmentPrefix: chunk.prefix(needed + 10)) == full)
    }

    @Test("a moof larger than 4 KiB asks for more bytes until all of it has arrived")
    func largeMoof() throws {
        let sizes = Array(repeating: 100, count: 1500)   // trun entries alone are 6000 bytes
        let payload = Data(repeating: 0xAB, count: sizes.reduce(0, +))
        let data = segment(sizes: sizes, payload: payload)
        let full = try #require(try DASHFLACLayout.mediaPayload(segmentPrefix: data))
        let start = full.payloads[0].lowerBound
        #expect(full.totalPayloadLength == payload.count && full.sampleSizesTotal == payload.count)
        #expect(start > 4096)
        #expect(data[start...].count == payload.count)
        #expect(try DASHFLACLayout.mediaPayload(segmentPrefix: data.prefix(4096)) == nil)
        #expect(try DASHFLACLayout.mediaPayload(segmentPrefix: data.prefix(start - 1)) == nil)
        #expect(try DASHFLACLayout.mediaPayload(segmentPrefix: data.prefix(start)) == full)
    }

    @Test("trun sizes that don't add up to the mdat payload are malformed, never a payload")
    func corruptedSum() throws {
        let payload = Data(repeating: 1, count: 300)
        let good = segment(sizes: [100, 100, 100], payload: payload)
        #expect(try DASHFLACLayout.mediaPayload(segmentPrefix: good)?.totalPayloadLength == 300)
        let short = segment(sizes: [100, 100, 99], payload: payload)
        #expect(throws: TidalError.self) { try DASHFLACLayout.mediaPayload(segmentPrefix: short) }
        let long = segment(sizes: [100, 100, 101], payload: payload)
        #expect(throws: TidalError.self) { try DASHFLACLayout.mediaPayload(segmentPrefix: long) }

        // And on the real fixture: bump one sample size inside the first chunk's trun.
        var chunk = try #require(try chunks().first)
        let moof = try #require(MP4Box.boxes(in: chunk).first { $0.type == "moof" })
        let traf = try #require(MP4Box.boxes(in: chunk, within: (moof.range.lowerBound + moof.header)..<moof.range.upperBound).first { $0.type == "traf" })
        let trun = try #require(MP4Box.boxes(in: chunk, within: (traf.range.lowerBound + traf.header)..<traf.range.upperBound).first { $0.type == "trun" })
        // version/flags (4) + sample_count (4) + data_offset (4), then the first sample size.
        let sizeOffset = trun.range.lowerBound + trun.header + 12
        chunk[sizeOffset + 3] &+= 1
        #expect(throws: TidalError.self) { try DASHFLACLayout.mediaPayload(segmentPrefix: chunk) }
    }

    @Test("a trun without per-sample sizes leaves the total unknown and trusts the mdat")
    func noSampleSizes() throws {
        let data = segment(sizes: [10, 10], payload: Data(repeating: 3, count: 20), trunSizeFlag: false)
        let info = try #require(try DASHFLACLayout.mediaPayload(segmentPrefix: data))
        #expect(info.sampleSizesTotal == nil && info.totalPayloadLength == 20)
    }

    @Test("a segment with an mdat but no moof is malformed")
    func mdatWithoutMoof() {
        let data = box("styp", Data("msdh".utf8) + be32(0)) + box("mdat", Data(repeating: 1, count: 10))
        #expect(throws: TidalError.self) { try DASHFLACLayout.mediaPayload(segmentPrefix: data) }
    }

    // MARK: Fix round 1

    @Test("a segment of several fragments yields every payload, in order, and decodes sample for sample")
    func multiFragmentSegment() throws {
        let all = try chunks()
        #expect(all.count == 3)
        // Chunked CMAF: three moof/mdat pairs in one segment (the second and third keep their styp/sidx, which are skipped).
        let combined = all.reduce(Data(), +)
        let info = try #require(try DASHFLACLayout.mediaPayload(segmentPrefix: combined))
        #expect(info.payloads.count == 3)
        #expect(info.endOffset == combined.count)
        var single: [Int] = []
        for chunk in all { single.append(try #require(try DASHFLACLayout.mediaPayload(segmentPrefix: chunk)).totalPayloadLength) }
        #expect(info.payloads.map(\.count) == single)
        #expect(info.payloads == info.payloads.sorted { $0.lowerBound < $1.lowerBound })

        var stream = try DASHFLACLayout.flacHeader(fromInit: initSegment())
        for range in info.payloads { stream += combined[range] }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dashflac-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rebuilt = directory.appendingPathComponent("rebuilt.flac")
        try stream.write(to: rebuilt)
        let expected = try decode(fixtureDirectory().appendingPathComponent("source.flac"))
        let actual = try decode(rebuilt)
        #expect(actual.frames == expected.frames && actual.bytes == expected.bytes)
    }

    @Test("with hand-built fragments: both payloads in order; a prefix ending inside the second fragment stops after the first")
    func twoFragments() throws {
        let a = Data(repeating: 0xA1, count: 200), b = Data(repeating: 0xB2, count: 300)
        let first = fragment(sizes: [100, 100], payload: a), second = fragment(sizes: [150, 150], payload: b)
        let data = box("styp", Data("msdh".utf8) + be32(0)) + first + second
        let info = try #require(try DASHFLACLayout.mediaPayload(segmentPrefix: data))
        #expect(info.payloads.map { Data(data[$0]) } == [a, b])
        #expect(info.sampleSizesTotal == 500 && info.endOffset == data.count)
        // Cut inside the second moof: the first fragment is reported, and endOffset says where the unparsed bytes begin.
        let cut = data.prefix(data.count - 300 - 20)
        let partial = try #require(try DASHFLACLayout.mediaPayload(segmentPrefix: cut))
        #expect(partial.payloads.count == 1)
        #expect(partial.endOffset == 16 + first.count)
        #expect(Data(data[partial.payloads[0]]) == a)
    }

    @Test("a second mdat with no moof before it is malformed")
    func orphanMdat() {
        let first = fragment(sizes: [10], payload: Data(repeating: 1, count: 10))
        #expect(throws: TidalError.self) { try DASHFLACLayout.mediaPayload(segmentPrefix: first + box("mdat", Data(repeating: 2, count: 4))) }
    }

    @Test("a trun data_offset that doesn't point at the mdat payload is malformed")
    func badDataOffset() throws {
        let payload = Data(repeating: 5, count: 40)
        #expect(try DASHFLACLayout.mediaPayload(segmentPrefix: segment(sizes: [20, 20], payload: payload)) != nil)
        for delta in [-4, 1, 16] {
            let skewed = segment(sizes: [20, 20], payload: payload, dataOffsetDelta: delta)
            #expect(throws: TidalError.self) { try DASHFLACLayout.mediaPayload(segmentPrefix: skewed) }
        }
    }

    @Test("a crafted trun whose default size times count overflows is malformed, not a crash")
    func overflowingRun() {
        let mfhd = box("mfhd", be32(0) + be32(1))
        // tfhd: default-base-is-moof + default-sample-size-present, size 0xFFFFFFFF.
        let tfhd = box("tfhd", be32(0x020010) + be32(1) + be32(0xFFFF_FFFF))
        // trun without sizes: count 0xFFFFFFFF.
        let trun = box("trun", be32(0) + be32(0xFFFF_FFFF))
        let data = box("moof", mfhd + box("traf", tfhd + trun)) + box("mdat", Data(repeating: 0, count: 8))
        #expect(throws: TidalError.self) { try DASHFLACLayout.mediaPayload(segmentPrefix: data) }
    }

    @Test("an mdat of size 0 whose sample sizes add up to Int.max is malformed, not a crash when its end is computed")
    func overflowingPayloadEnd() {
        let mfhd = box("mfhd", be32(0) + be32(1))
        // tfhd: default-base-is-moof + default-sample-size-present, size 0x7FFFFFFF.
        let tfhd = box("tfhd", be32(0x020010) + be32(1) + be32(0x7FFF_FFFF))
        // Run 1 takes the default size: 0x7FFFFFFF × 0xFFFFFFFF bytes. Run 2 states two sizes that bring the total to exactly Int.max.
        let first = box("trun", be32(0) + be32(0xFFFF_FFFF))
        let second = box("trun", be32(0x000200) + be32(2) + be32(0xFFFF_FFFF) + be32(0x7FFF_FFFF))
        // mdat of size 0 runs to the end of the segment: its length is the runs' total.
        let data = box("moof", mfhd + box("traf", tfhd + first + second)) + be32(0) + Data("mdat".utf8) + Data(repeating: 0, count: 8)
        #expect(throws: TidalError.self) { try DASHFLACLayout.mediaPayload(segmentPrefix: data) }
    }

    // MARK: Boxes

    @Test("a box with a 64-bit largesize parses, header 16 bytes")
    func largesize() {
        let payload = Data(repeating: 9, count: 5)
        let wide = be32(1) + Data("free".utf8) + be32(0) + be32(16 + payload.count) + payload
        let data = box("ftyp", Data("iso5".utf8) + be32(0)) + wide + box("mdat", Data([1]))
        let boxes = MP4Box.boxes(in: data)
        #expect(boxes.map(\.type) == ["ftyp", "free", "mdat"])
        #expect(boxes[1].header == 16)
        #expect(boxes[1].range == 16..<(16 + 16 + 5))
        #expect(boxes[2].range.lowerBound == 37 && boxes[2].header == 8)
    }

    @Test("box scanning stops at a truncated box and clamps its range to the data")
    func truncatedBox() {
        let data = box("free", Data(repeating: 0, count: 4)) + be32(100) + Data("mdat".utf8) + Data(repeating: 0, count: 6)
        let boxes = MP4Box.boxes(in: data)
        #expect(boxes.map(\.type) == ["free", "mdat"])
        #expect(boxes[1].range == 12..<data.count)
        // Fewer than 8 bytes of header: not a box yet.
        #expect(MP4Box.boxes(in: Data([0, 0, 0])).isEmpty)
        // A size smaller than its own header is garbage: scanning stops.
        #expect(MP4Box.boxes(in: be32(4) + Data("free".utf8)).isEmpty)
    }

    @Test("boxes in a slice of Data with a non-zero start index report offsets relative to the slice")
    func sliceIndices() {
        let inner = box("free", Data([1, 2, 3]))
        let padded = Data(repeating: 0xFF, count: 10) + inner
        let slice = padded[10...]
        #expect(MP4Box.boxes(in: slice).first?.range == 0..<inner.count)
    }

    // MARK: Decoding

    private func decode(_ url: URL) throws -> (frames: Int, bytes: Data) {
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
}
