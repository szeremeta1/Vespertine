//
// Vespertine: where the DSD is inside a DSF or a DSDIFF (.dff) file, read with a few small ranged reads, so the phone can
// play such a file from a share by itself: no Mac converting it first.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//
// DSF: "DSF File Format Specification" 1.01 (Sony). DSDIFF: "Direct Stream Digital Interchange File Format" 1.5 (Philips).
//

import Foundation

/// A DSD file's audio: where each channel's bits are, and how they are stored.
public struct DSDLayout: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Sony's DSF: each channel in blocks of its own, one channel's block after another's.
        case dsf
        /// Philips' DSDIFF: one byte of each channel in turn.
        case dff
    }

    public var kind: Kind
    /// DSD bits a second for each channel: 2822400 for DSD64.
    public var dsdRate: Int
    public var channels: Int
    /// Where the audio starts in the file.
    public var dataOffset: Int64
    /// Whole bytes of DSD each channel has (eight bits each).
    public var bytesPerChannel: Int64
    /// DSF: the bytes of one channel's block (4096). DSDIFF: 1.
    public var blockSize: Int
    /// The oldest bit is a byte's lowest (DSF mostly). DoP and DSDIFF have it the highest.
    public var lsbFirst: Bool
    /// The audio is packed with DST (a DSDIFF from an SACD): only the Mac unpacks that.
    public var dst: Bool

    public init(kind: Kind, dsdRate: Int, channels: Int, dataOffset: Int64, bytesPerChannel: Int64, blockSize: Int, lsbFirst: Bool, dst: Bool = false) {
        self.kind = kind
        self.dsdRate = dsdRate
        self.channels = channels
        self.dataOffset = dataOffset
        self.bytesPerChannel = bytesPerChannel
        self.blockSize = blockSize
        self.lsbFirst = lsbFirst
        self.dst = dst
    }

    /// The lowest DSD rate (DSD64 of the 44.1 kHz family).
    public static let lowestRate = 2_822_400

    /// The phone plays this file by itself: stereo or mono DSD at a usual rate (DSD64, DSD128…), not packed with DST.
    /// Surround DSD and DST need the Mac.
    public var playsHere: Bool { !dst && (1...2).contains(channels) && DSDRendering.isRegular(dsdRate: dsdRate) && bytesPerChannel > 0 }

    public var duration: Double { dsdRate > 0 ? Double(bytesPerChannel) * 8 / Double(dsdRate) : 0 }

    /// The range of the file that holds bytes `range` of every channel: `offset` in the file, `length` bytes.
    func fileRange(_ range: Range<Int64>) -> (offset: Int64, length: Int) {
        switch kind {
        case .dff:
            return (dataOffset + range.lowerBound * Int64(channels), Int(range.count) * channels)
        case .dsf:
            let block = Int64(blockSize)
            let first = range.lowerBound / block, last = (range.upperBound - 1) / block
            return (dataOffset + first * block * Int64(channels), Int(last - first + 1) * blockSize * channels)
        }
    }

    /// Takes each channel's bytes `range` out of `data`, the bytes of `fileRange(range)`, the oldest bit made the highest.
    /// Bytes the file turned out not to have are DSD silence.
    func planes(_ data: Data, _ range: Range<Int64>) -> [[UInt8]] {
        let count = Int(range.count)
        var planes = [[UInt8]](repeating: [UInt8](repeating: DSDRendering.silence, count: count), count: channels)
        guard count > 0 else { return planes }
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let available = bytes.count
            switch kind {
            case .dff:
                for channel in 0..<channels {
                    planes[channel].withUnsafeMutableBufferPointer { plane in
                        var at = channel
                        for index in 0..<count where at < available {
                            plane[index] = bytes[at]
                            at += channels
                        }
                    }
                }
            case .dsf:
                let block = Int64(blockSize)
                let firstBlock = range.lowerBound / block
                for channel in 0..<channels {
                    planes[channel].withUnsafeMutableBufferPointer { plane in
                        for index in 0..<count {
                            let byte = range.lowerBound + Int64(index)
                            let at = Int((byte / block - firstBlock) * block * Int64(channels) + Int64(channel) * block + byte % block)
                            guard at < available else { break }
                            plane[index] = lsbFirst ? DSDRendering.reversed[Int(bytes[at])] : bytes[at]
                        }
                    }
                }
            }
        }
        return planes
    }
}

private func le32(_ b: [UInt8], _ at: Int) -> Int {
    at + 4 <= b.count ? Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24 : 0
}
private func le64(_ b: [UInt8], _ at: Int) -> Int64 { at + 8 <= b.count ? Int64(le32(b, at)) | Int64(le32(b, at + 4)) << 32 : 0 }
private func be16(_ b: [UInt8], _ at: Int) -> Int { at + 2 <= b.count ? Int(b[at]) << 8 | Int(b[at + 1]) : 0 }
private func be32(_ b: [UInt8], _ at: Int) -> Int {
    at + 4 <= b.count ? Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3]) : 0
}
private func be64(_ b: [UInt8], _ at: Int) -> Int64 { at + 8 <= b.count ? Int64(be32(b, at)) << 32 | Int64(be32(b, at + 4)) : 0 }
private func name(_ b: [UInt8], _ at: Int) -> String {
    at >= 0 && at + 4 <= b.count ? String(b[at..<(at + 4)].map { Character(Unicode.Scalar($0)) }) : ""
}
private func words(_ b: [UInt8]) -> String? {
    let text = String(decoding: b, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    return text.isEmpty ? nil : text
}

extension SongTagReader {
    /// A DSD file's tags: "DSD" as the codec, the DSD rate as the rate, one bit deep, and `dsd` saying where the audio is.
    static func tags(_ layout: DSDLayout) -> SongTags {
        var tags = SongTags(codec: "DSD", sampleRate: Double(layout.dsdRate), bitDepth: 1, channels: layout.channels, duration: layout.duration)
        tags.dsd = layout
        return tags
    }

    // MARK: DSF

    static func dsf(_ file: FileWindow) throws -> SongTags? {
        let head = try file.bytes(0, 92)
        guard head.count >= 80, name(head, 0) == "DSD ", name(head, 28) == "fmt " else { return nil }
        let metadata = le64(head, 20)
        let formatSize = le64(head, 32)
        // Format version 1, raw DSD (format ID 0).
        guard formatSize >= 52, formatSize <= 4096, le32(head, 40) == 1, le32(head, 44) == 0 else { return nil }
        let channels = le32(head, 52), rate = le32(head, 56), bits = le32(head, 60)
        let samples = le64(head, 64)
        let block = le32(head, 72)
        guard channels > 0, channels <= 8, rate > 0, bits == 1 || bits == 8, block > 0, block <= 1 << 20 else { return nil }
        let dataAt = 28 + formatSize
        let data = try file.bytes(dataAt, 12)
        guard data.count == 12, name(data, 0) == "data" else { return nil }
        let audioAt = dataAt + 12
        let stored = min(le64(data, 4) - 12, file.size - audioAt)
        let group = Int64(block) * Int64(channels)
        guard stored >= group else { return nil }
        let held = stored / group * Int64(block)
        let layout = DSDLayout(kind: .dsf, dsdRate: rate, channels: channels, dataOffset: audioAt,
                               bytesPerChannel: samples > 0 ? min(samples / 8, held) : held, blockSize: block, lsbFirst: bits == 1)
        var tags = tags(layout)
        // The tags are an ID3v2 tag at the end of the file, where the header says.
        if metadata >= audioAt, metadata + 10 <= file.size {
            let length = id3Length(try file.bytes(metadata, 10))
            if length > 0, length <= 16 << 20, let parsed = id3(try file.bytes(metadata, length)) { parsed.apply(to: &tags, tagOffset: metadata) }
        }
        return tags
    }

    // MARK: DSDIFF

    static func dff(_ file: FileWindow) throws -> SongTags? {
        let head = try file.bytes(0, 16)
        guard head.count == 16, name(head, 0) == "FRM8", name(head, 12) == "DSD " else { return nil }
        var at: Int64 = 16
        var rate = 0, channels = 0
        var dst = false
        var audio: (at: Int64, size: Int64)?
        var named = ID3()
        var id3Tags: (ID3, Int64)?
        for _ in 0..<256 {
            let header = try file.bytes(at, 12)
            guard header.count == 12 else { break }
            let size = be64(header, 4)
            let body = at + 12
            guard size >= 0 else { break }
            switch name(header, 0) {
            case "PROP" where size <= 1 << 16:
                let b = try file.bytes(body, Int(size))
                guard name(b, 0) == "SND " else { break }
                var item = 4
                while item + 12 <= b.count {
                    let length = Int(clamping: be64(b, item + 4))
                    let start = item + 12
                    guard length >= 0, start + length <= b.count else { break }
                    switch name(b, item) {
                    case "FS  ": rate = be32(b, start)
                    case "CHNL": channels = be16(b, start)
                    case "CMPR": dst = name(b, start) != "DSD "
                    default: break
                    }
                    item = start + length + length % 2
                }
            case "DSD ":
                audio = (body, min(size, file.size - body))
            case "DST ":
                dst = true
                audio = audio ?? (body, 0)
            case "DIIN" where size <= 1 << 16:
                // The edited master's artist and title: a count, then the text.
                let b = try file.bytes(body, Int(size))
                var item = 0
                while item + 16 <= b.count {
                    let length = Int(clamping: be64(b, item + 4))
                    let start = item + 12
                    guard length >= 4, start + length <= b.count else { break }
                    let count = min(be32(b, start), length - 4)
                    let text = words(Array(b[(start + 4)..<(start + 4 + max(0, count))]))
                    switch name(b, item) {
                    case "DIAR": named.artist = text
                    case "DITI": named.title = text
                    default: break
                    }
                    item = start + length + length % 2
                }
            case "ID3 ", "id3 ":
                if size <= 16 << 20, let parsed = id3(try file.bytes(body, Int(size))) { id3Tags = (parsed, body) }
            default: break
            }
            at = body + size + size % 2
            if at >= file.size { break }
        }
        guard rate > 0, channels > 0, channels <= 8, let audio else { return nil }
        let layout = DSDLayout(kind: .dff, dsdRate: rate, channels: channels, dataOffset: audio.at,
                               bytesPerChannel: audio.size / Int64(channels), blockSize: 1, lsbFirst: false, dst: dst)
        guard dst || layout.bytesPerChannel > 0 else { return nil }
        var tags = tags(layout)
        named.apply(to: &tags, tagOffset: 0)
        id3Tags?.0.apply(to: &tags, tagOffset: id3Tags?.1 ?? 0)
        return tags
    }
}
