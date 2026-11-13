//
// Vespertine: a small reader for the ISO base media (MP4) box structure, enough to find the FLAC setup in an init segment and the
// sample data in a media segment, including when only the first bytes of a segment have arrived.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum MP4Box {
    struct Item {
        var type: String
        /// The box from its first header byte to its end, clamped to the data scanned.
        var range: Range<Int>
        /// 8 bytes, or 16 when the box carries a 64-bit `largesize`.
        var header: Int
        /// Where the box ends according to its header; nil for a box that runs to the end of the data (size 0).
        var declaredEnd: Int?
    }

    /// The boxes at one level of `data`, with offsets relative to `data`'s first byte (a slice's `startIndex` doesn't matter).
    /// With `within`, only that range of `data` is read, which is how to look inside a container box. A box cut off by the end of
    /// the data is reported with its range clamped; scanning stops at a header it can't read.
    static func boxes(in data: Data, within range: Range<Int>? = nil) -> [(type: String, range: Range<Int>, header: Int)] {
        scan(data, within: range).items.map { ($0.type, $0.range, $0.header) }
    }

    /// Like `boxes`, with each box's declared end, and whether scanning hit a header that can't be right (a size smaller than
    /// the header itself), as opposed to simply running out of bytes.
    static func scan(_ data: Data, within range: Range<Int>? = nil) -> (items: [Item], garbage: Bool) {
        let end = min(range?.upperBound ?? data.count, data.count)
        var offset = max(range?.lowerBound ?? 0, 0)
        var items: [Item] = []
        while end - offset >= 8 {
            let size32 = Int(u32(data, offset))
            let type = String(decoding: (4..<8).map { data[data.startIndex + offset + $0] }, as: UTF8.self)
            let name = type.isEmpty ? "????" : type
            var header = 8
            var declaredEnd: Int?
            if size32 == 1 {
                guard end - offset >= 16 else { break }
                let wide = u64(data, offset + 8)
                guard wide <= UInt64(Int.max / 2) else { return (items, true) }
                header = 16
                declaredEnd = offset + Int(wide)
            } else if size32 == 0 {
                declaredEnd = nil
            } else {
                declaredEnd = offset + size32
            }
            if let declaredEnd, declaredEnd - offset < header { return (items, true) }
            items.append(Item(type: name, range: offset..<min(declaredEnd ?? end, end), header: header, declaredEnd: declaredEnd))
            guard let declaredEnd, declaredEnd < end else { break }
            offset = declaredEnd
        }
        return (items, false)
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16 | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    }

    static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(u32(data, offset)) << 32 | UInt64(u32(data, offset + 4))
    }

    static func u24(_ data: Data, _ offset: Int) -> Int {
        let base = data.startIndex + offset
        return Int(data[base]) << 16 | Int(data[base + 1]) << 8 | Int(data[base + 2])
    }

    /// The first box of `type` directly inside `item`, skipping `skip` bytes of box fields (a FullBox's version/flags, a sample
    /// entry's fixed fields) between the header and the children.
    static func child(_ type: String, of item: Item, in data: Data, skipping skip: Int = 0) -> Item? {
        children(of: item, in: data, skipping: skip).first { $0.type == type }
    }

    static func children(of item: Item, in data: Data, skipping skip: Int = 0) -> [Item] {
        let start = item.range.lowerBound + item.header + skip
        guard start <= item.range.upperBound else { return [] }
        return scan(data, within: start..<item.range.upperBound).items
    }
}
