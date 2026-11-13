//
// Vespertine: how TIDAL's hi-res FLAC is packed in DASH (fragmented MP4) and how to unpack it. The init segment holds the FLAC
// stream header (`dfLa`); each media segment's `mdat` holds whole FLAC frames. A FLAC header followed by every segment's payload
// is the original FLAC file, byte for byte what a decoder wants.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public struct DASHFLACLayout: Sendable {
    public struct SegmentInfo: Sendable, Equatable {
        /// Where the `mdat` payload starts, counted from the first byte of the segment.
        public var payloadOffset: Int
        public var payloadLength: Int
        /// The sum of the `trun` sample sizes, when the segment states them. Always equal to `payloadLength` when present.
        public var sampleSizesTotal: Int?

        public init(payloadOffset: Int, payloadLength: Int, sampleSizesTotal: Int?) {
            self.payloadOffset = payloadOffset
            self.payloadLength = payloadLength
            self.sampleSizesTotal = sampleSizesTotal
        }
    }

    // MARK: Init segment

    /// `fLaC` followed by the metadata blocks of `moov/trak/mdia/minf/stbl/stsd/fLaC/dfLa`, the last-block flag set on the final
    /// block only.
    public static func flacHeader(fromInit data: Data) throws -> Data {
        guard let dfLa = findDfLa(in: data) else { throw TidalError.malformedStream("the init segment has no FLAC configuration (dfLa)") }
        // dfLa is a FullBox: 4 bytes of version and flags, then the FLAC metadata blocks.
        var offset = dfLa.range.lowerBound + dfLa.header + 4
        let end = dfLa.range.upperBound
        var blocks: [(type: UInt8, body: Range<Int>)] = []
        while offset + 4 <= end {
            let flagged = data[data.startIndex + offset]
            let length = MP4Box.u24(data, offset + 1)
            let body = (offset + 4)..<(offset + 4 + length)
            guard body.upperBound <= end else { throw TidalError.malformedStream("a FLAC metadata block runs past the end of dfLa") }
            blocks.append((flagged & 0x7F, body))
            offset = body.upperBound
            if flagged & 0x80 != 0 { break }
        }
        guard let first = blocks.first, first.type == 0, first.body.count == 34 else {
            throw TidalError.malformedStream("dfLa doesn't start with a STREAMINFO block")
        }
        var header = Data("fLaC".utf8)
        for (index, block) in blocks.enumerated() {
            let length = block.body.count
            header.append(block.type | (index == blocks.count - 1 ? 0x80 : 0))
            header.append(contentsOf: [UInt8(length >> 16 & 255), UInt8(length >> 8 & 255), UInt8(length & 255)])
            header.append(data[(data.startIndex + block.body.lowerBound)..<(data.startIndex + block.body.upperBound)])
        }
        return header
    }

    private static func findDfLa(in data: Data) -> MP4Box.Item? {
        guard let moov = MP4Box.scan(data).items.first(where: { $0.type == "moov" }) else { return nil }
        for trak in MP4Box.children(of: moov, in: data) where trak.type == "trak" {
            guard let mdia = MP4Box.child("mdia", of: trak, in: data),
                  let minf = MP4Box.child("minf", of: mdia, in: data),
                  let stbl = MP4Box.child("stbl", of: minf, in: data),
                  let stsd = MP4Box.child("stsd", of: stbl, in: data) else { continue }
            // stsd: version/flags (4) + entry count (4), then the sample entries.
            for entry in MP4Box.children(of: stsd, in: data, skipping: 8) where entry.type == "fLaC" {
                // An audio sample entry has 28 bytes of fixed fields before its child boxes.
                if let dfLa = MP4Box.child("dfLa", of: entry, in: data, skipping: 28) { return dfLa }
            }
        }
        return nil
    }

    // MARK: Media segment

    /// Where the audio is in a media segment, from its first bytes. Nil when `segmentPrefix` ends before the `moof` is complete
    /// and the `mdat` header has been read (ask for more bytes: a `moof` can be larger than any fixed guess).
    /// Throws `malformedStream` when the sample sizes the segment states don't add up to its `mdat`.
    public static func mediaPayload(segmentPrefix: Data) throws -> SegmentInfo? {
        let (items, garbage) = MP4Box.scan(segmentPrefix)
        var sampleTotal: Int??
        for item in items {
            switch item.type {
            case "moof":
                guard let declaredEnd = item.declaredEnd, declaredEnd <= segmentPrefix.count else { return nil }
                sampleTotal = .some(try sampleSizesTotal(moof: item, in: segmentPrefix))
            case "mdat":
                guard let known = sampleTotal else { throw TidalError.malformedStream("a media data box comes before any movie fragment") }
                let payloadOffset = item.range.lowerBound + item.header
                let payloadLength: Int
                if let declaredEnd = item.declaredEnd {
                    payloadLength = declaredEnd - payloadOffset
                } else if let known {
                    payloadLength = known
                } else {
                    throw TidalError.malformedStream("a media data box of unknown size with no sample sizes")
                }
                if let known, known != payloadLength {
                    throw TidalError.malformedStream("the sample sizes add up to \(known) bytes but the media data holds \(payloadLength)")
                }
                return SegmentInfo(payloadOffset: payloadOffset, payloadLength: payloadLength, sampleSizesTotal: known)
            default:
                continue
            }
        }
        if garbage { throw TidalError.malformedStream("the segment has a box with an impossible size") }
        return nil
    }

    /// The sum of all `trun` sample sizes in the `moof`, or nil when a run doesn't state its sizes and `tfhd` has no default.
    private static func sampleSizesTotal(moof: MP4Box.Item, in data: Data) throws -> Int? {
        var total = 0
        var sawRun = false
        for traf in MP4Box.children(of: moof, in: data) where traf.type == "traf" {
            let boxes = MP4Box.children(of: traf, in: data)
            let defaultSize = try boxes.first { $0.type == "tfhd" }.flatMap { try defaultSampleSize(tfhd: $0, in: data) }
            for trun in boxes where trun.type == "trun" {
                sawRun = true
                guard let sum = try runTotal(trun: trun, defaultSize: defaultSize, in: data) else { return nil }
                total += sum
            }
        }
        return sawRun ? total : nil
    }

    private static func defaultSampleSize(tfhd: MP4Box.Item, in data: Data) throws -> Int? {
        var offset = tfhd.range.lowerBound + tfhd.header
        let end = tfhd.range.upperBound
        guard end - offset >= 8 else { throw TidalError.malformedStream("a track fragment header is too short") }
        let flags = Int(MP4Box.u32(data, offset)) & 0xFFFFFF
        offset += 8   // version/flags, track ID
        if flags & 0x01 != 0 { offset += 8 }   // base data offset
        if flags & 0x02 != 0 { offset += 4 }   // sample description index
        if flags & 0x08 != 0 { offset += 4 }   // default sample duration
        guard flags & 0x10 != 0 else { return nil }
        guard offset + 4 <= end else { throw TidalError.malformedStream("a track fragment header is cut short") }
        return Int(MP4Box.u32(data, offset))
    }

    private static func runTotal(trun: MP4Box.Item, defaultSize: Int?, in data: Data) throws -> Int? {
        var offset = trun.range.lowerBound + trun.header
        let end = trun.range.upperBound
        guard end - offset >= 8 else { throw TidalError.malformedStream("a track run is too short") }
        let flags = Int(MP4Box.u32(data, offset)) & 0xFFFFFF
        let count = Int(MP4Box.u32(data, offset + 4))
        offset += 8
        if flags & 0x001 != 0 { offset += 4 }   // data offset
        if flags & 0x004 != 0 { offset += 4 }   // first sample flags
        let hasDuration = flags & 0x100 != 0, hasSize = flags & 0x200 != 0, hasFlags = flags & 0x400 != 0, hasOffset = flags & 0x800 != 0
        let stride = (hasDuration ? 4 : 0) + (hasSize ? 4 : 0) + (hasFlags ? 4 : 0) + (hasOffset ? 4 : 0)
        guard hasSize else { return defaultSize.map { $0 * count } }
        guard offset <= end, count <= (end - offset) / max(stride, 1) else { throw TidalError.malformedStream("a track run is cut short") }
        var total = 0
        for sample in 0..<count {
            var position = offset + sample * stride
            if hasDuration { position += 4 }
            total += Int(MP4Box.u32(data, position))
        }
        return total
    }
}
