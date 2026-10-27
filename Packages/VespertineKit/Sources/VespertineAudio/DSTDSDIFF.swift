// Vespertine — DST-compressed DSDIFF, using the same lossless DST decoder as SACD images.
// Container: Philips DSDIFF 1.5 §§3.2, 3.4–3.5. Source files are never rewritten.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CVespertineDTS
import SFBAudioEngine

protocol InterleavedDSDSource: RawDSDSource {
    func readInterleaved(into out: UnsafeMutablePointer<UInt8>, bytes: Int) throws -> Int
}

struct DSTDSDIFFInfo: Sendable {
    struct Frame: Sendable { var offset: UInt64; var length: Int }
    var rate: Int
    var channels: Int
    var channelIDs: [String]
    var frameCount: Int
    var firstFrame: UInt64
    var end: UInt64
    var index: [Frame]
    var frameBytes: Int { rate / 75 / 8 }
    var maximumFrameLength: Int { max(65536, frameBytes * channels * 2) }

    /// nil for uncompressed DSDIFF (still handled by the existing DSD reader).
    static func read(_ url: URL) throws -> Self? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard size >= 16 else { return nil }
        let head = try read(file, at: 0, count: 16)
        guard id(head, 0) == "FRM8", id(head, 12) == "DSD " else { return nil }
        let formSize = number(head, 4, 8)
        guard formSize >= 4, formSize <= size - 12 else { throw DTSError.decoding }
        let end = formSize + 12
        var rate = 0, channels = 0, compression = "", frames = 0
        var first: UInt64 = 0, audioEnd: UInt64 = 0
        var indexData: [UInt8] = []
        var channelIDs: [String] = []
        var p: UInt64 = 16
        while p + 12 <= end {
            let h = try read(file, at: p, count: 12)
            let length = number(h, 4, 8), body = p + 12
            guard length <= end - body else { throw DTSError.decoding }
            switch id(h, 0) {
            case "PROP":
                guard length >= 4, length <= 1 << 20 else { throw DTSError.decoding }
                let data = try read(file, at: body, count: Int(length))
                guard id(data, 0) == "SND " else { break }
                var q = 4
                while q + 12 <= data.count {
                    let n = number(data, q + 4, 8)
                    guard n <= UInt64(data.count - q - 12) else { throw DTSError.decoding }
                    switch id(data, q) {
                    case "FS  " where n >= 4: rate = Int(number(data, q + 12, 4))
                    case "CHNL" where n >= 2:
                        channels = Int(number(data, q + 12, 2))
                        channelIDs = []
                        if n >= UInt64(2 + channels * 4) {
                            channelIDs = (0..<channels).map { id(data, q + 14 + $0 * 4) }
                        }
                    case "CMPR" where n >= 4: compression = id(data, q + 12)
                    default: break
                    }
                    q += 12 + Int(n) + Int(n & 1)
                }
            case "DST ":
                guard length >= 18 else { throw DTSError.decoding }
                let data = try read(file, at: body, count: 18)
                guard id(data, 0) == "FRTE", number(data, 4, 8) == 6,
                      number(data, 16, 2) == 75 else { throw DTSError.decoding }
                frames = Int(number(data, 12, 4)); first = body + 18; audioEnd = body + length
            case "DSTI":
                // Bound metadata allocation even for an untrusted file. A missing/bad index can be rebuilt lazily.
                if length <= 120_000_000 { indexData = try read(file, at: body, count: Int(length)) }
            default: break
            }
            p = body + length + (length & 1)
        }
        guard compression == "DST " else { return nil }
        guard (1...6).contains(channels), channelIDs.count == channels, [2_822_400, 5_644_800, 11_289_600, 22_579_200].contains(rate),
              (1...10_000_000).contains(frames), first > 0, audioEnd > first else { throw DTSError.decoding }
        var index: [Frame] = []
        if indexData.count == frames * 12 {
            var previous = first - 1
            for q in stride(from: 0, to: indexData.count, by: 12) {
                let offset = number(indexData, q, 8), length = number(indexData, q + 8, 4)
                guard offset >= first + 12, offset > previous, offset <= audioEnd,
                      length > 0, length <= UInt64(max(65536, rate / 75 / 8 * channels * 2)), length <= audioEnd - offset else { index.removeAll(); break }
                index.append(Frame(offset: offset, length: Int(length))); previous = offset
            }
        }
        return Self(rate: rate, channels: channels, channelIDs: channelIDs, frameCount: frames, firstFrame: first, end: audioEnd, index: index)
    }

    static func read(_ file: FileHandle, at offset: UInt64, count: Int) throws -> [UInt8] {
        try file.seek(toOffset: offset)
        let data = [UInt8](try file.read(upToCount: count) ?? Data())
        guard data.count == count else { throw DTSError.decoding }
        return data
    }
    static func id(_ data: [UInt8], _ p: Int) -> String { String(decoding: data[p..<p + 4], as: UTF8.self) }
    static func number(_ data: [UInt8], _ p: Int, _ n: Int) -> UInt64 {
        data[p..<p + n].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

final class DSTDSDIFFSource: InterleavedDSDSource {
    let url: URL
    let info: DSTDSDIFFInfo
    private let file: FileHandle
    private let decoder: OpaquePointer
    private var index: [DSTDSDIFFInfo.Frame]
    private var scan: UInt64
    private var buffer: [UInt8] = []
    private var bufferStart: UInt64 = 0
    private var frame: [UInt8]
    private var loadedFrame = -1
    private var position: Int64 = 0
    private(set) var isOpen = true

    init(url: URL, info: DSTDSDIFFInfo) throws {
        self.url = url; self.info = info
        file = try FileHandle(forReadingFrom: url)
        guard let decoder = ndst_create(Int32(info.channels), Int32(info.frameBytes)) else { throw DTSError.decoding }
        self.decoder = decoder; index = info.index; scan = info.firstFrame
        frame = [UInt8](repeating: 0, count: info.frameBytes * info.channels)
    }
    deinit { ndst_destroy(decoder); try? file.close() }
    var channelCount: Int { info.channels }
    var dsdRate: Double { Double(info.rate) }
    var dsdLength: Int64 { Int64(info.frameCount) * Int64(info.frameBytes) }
    var inputSource: InputSource { (try? InputSource(for: url)) ?? InputSource(data: Data()) }
    func close() throws { if isOpen { isOpen = false; try file.close() } }
    func seekDSD(to target: Int64) throws { position = min(max(0, target), dsdLength) }

    /// Read ahead keeps sequential playback (and building a missing index) efficient on network shares.
    private func bytes(at offset: UInt64, count: Int) throws -> [UInt8] {
        guard offset <= info.end, UInt64(count) <= info.end - offset else { throw DTSError.decoding }
        if buffer.isEmpty || offset < bufferStart || offset + UInt64(count) > bufferStart + UInt64(buffer.count) {
            let size = min(max(65536, count), Int(info.end - offset))
            buffer = try DSTDSDIFFInfo.read(file, at: offset, count: size); bufferStart = offset
        }
        let p = Int(offset - bufferStart)
        return Array(buffer[p..<p + count])
    }

    private func load(_ number: Int) throws {
        if loadedFrame == number { return }
        while index.count <= number {
            guard scan + 12 <= info.end else { throw DTSError.decoding }
            let h = try bytes(at: scan, count: 12)
            let length = DSTDSDIFFInfo.number(h, 4, 8), body = scan + 12
            guard length <= info.end - body else { throw DTSError.decoding }
            if DSTDSDIFFInfo.id(h, 0) == "DSTF" {
                guard length > 0, length <= UInt64(info.maximumFrameLength) else { throw DTSError.decoding }
                index.append(.init(offset: body, length: Int(length)))
            }
            scan = body + length + (length & 1)
        }
        let entry = index[number]
        // The optional seek index is only a hint: verify the actual frame header before decoding it.
        let header = try bytes(at: entry.offset - 12, count: 12)
        guard DSTDSDIFFInfo.id(header, 0) == "DSTF", DSTDSDIFFInfo.number(header, 4, 8) == UInt64(entry.length) else { throw DTSError.decoding }
        let data = try bytes(at: entry.offset, count: entry.length)
        let ok = data.withUnsafeBufferPointer { src in
            frame.withUnsafeMutableBufferPointer { ndst_decode(decoder, src.baseAddress!, Int32(src.count), $0.baseAddress!) }
        }
        guard ok else { throw DTSError.decoding }
        let next = entry.offset + UInt64(entry.length + (entry.length & 1))
        if next + 12 <= info.end {
            let crcHeader = try bytes(at: next, count: 12)
            if DSTDSDIFFInfo.id(crcHeader, 0) == "DSTC" {
                guard DSTDSDIFFInfo.number(crcHeader, 4, 8) == 4 else { throw DTSError.decoding }
                let expected = try bytes(at: next + 12, count: 4)
                guard Self.crc(frame) == UInt32(DSTDSDIFFInfo.number(expected, 0, 4)) else { throw DTSError.decoding }
            }
        }
        loadedFrame = number
    }

    // DSDIFF 1.5 §3.4.3: x^32 + x^31 + x^4 + 1, MSB first, zero initial remainder.
    private static let crcTable: [UInt32] = (0..<256).map { byte in
        var value = UInt32(byte) << 24
        for _ in 0..<8 { value = value & 0x8000_0000 != 0 ? (value << 1) ^ 0x8000_0011 : value << 1 }
        return value
    }
    private static func crc(_ bytes: [UInt8]) -> UInt32 {
        bytes.reduce(UInt32(0)) { ($0 << 8) ^ crcTable[Int(($0 >> 24) ^ UInt32($1))] }
    }

    func readInterleaved(into out: UnsafeMutablePointer<UInt8>, bytes: Int) throws -> Int {
        guard isOpen, bytes >= 0 else { throw DTSError.decoding }
        let wanted = Int(min(Int64(bytes), dsdLength - position)), channels = channelCount
        var written = 0
        while written < wanted {
            try load(Int(position / Int64(info.frameBytes)))
            let offset = Int(position % Int64(info.frameBytes)), n = min(wanted - written, info.frameBytes - offset)
            frame.withUnsafeBufferPointer { (out + written * channels).update(from: $0.baseAddress! + offset * channels, count: n * channels) }
            position += Int64(n); written += n
        }
        return written
    }
    func readDSD(into planes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>>, bytes: Int) throws -> Int {
        var data = [UInt8](repeating: 0, count: max(0, bytes) * channelCount)
        let n = try data.withUnsafeMutableBufferPointer { p in
            guard let base = p.baseAddress else { return 0 }
            return try readInterleaved(into: base, bytes: bytes)
        }
        for c in 0..<channelCount { for i in 0..<n { planes[c][i] = data[i * channelCount + c] } }
        return n
    }
}

/// The channel IDs in any DSDIFF file's CHNL chunk, compressed or not (DSDIFF 1.5 §3.2.2), in stored order.
enum DSDIFFChannels {
    static func ids(_ url: URL) -> [String]? {
        typealias F = DSTDSDIFFInfo
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd(), size >= 16, let head = try? F.read(file, at: 0, count: 16),
              F.id(head, 0) == "FRM8", F.id(head, 12) == "DSD " else { return nil }
        let formSize = F.number(head, 4, 8)
        guard formSize >= 4, formSize <= size - 12 else { return nil }
        let end = formSize + 12
        var p: UInt64 = 16
        while p + 12 <= end, let h = try? F.read(file, at: p, count: 12) {
            let length = F.number(h, 4, 8), body = p + 12
            guard length <= end - body else { return nil }
            if F.id(h, 0) == "PROP" {
                guard length >= 4, length <= 1 << 20, let data = try? F.read(file, at: body, count: Int(length)), F.id(data, 0) == "SND " else { return nil }
                var q = 4
                while q + 12 <= data.count {
                    let n = F.number(data, q + 4, 8)
                    guard n <= UInt64(data.count - q - 12) else { return nil }
                    if F.id(data, q) == "CHNL", n >= 2 {
                        let channels = Int(F.number(data, q + 12, 2))
                        guard n >= UInt64(2 + channels * 4) else { return nil }
                        return (0..<channels).map { F.id(data, q + 14 + $0 * 4) }
                    }
                    q += 12 + Int(n) + Int(n & 1)
                }
                return nil
            }
            p = body + length + (length & 1)
        }
        return nil
    }
}
