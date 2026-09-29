//
// Vespertine — cover art stored as a METADATA_BLOCK_PICTURE Vorbis comment inside a FLAC file
// (a base64 FLAC picture structure; some taggers write art this way instead of a PICTURE block,
// and TagLib doesn't report it for FLAC).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum CommentPictures {
    /// The image data of the first (preferably front-cover) METADATA_BLOCK_PICTURE comment in a FLAC file.
    static func flacCover(at url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        func read(_ n: Int) -> Data? { let d = try? handle.read(upToCount: n); return d?.count == n ? d : nil }
        guard let magic = read(4) else { return nil }
        var offset: UInt64 = 0
        if magic.starts(with: Array("ID3".utf8)), let header = read(6) {
            let size = header.dropFirst(2).reduce(0) { $0 << 7 | UInt64($1 & 0x7F) }
            offset = 10 + size
            try? handle.seek(toOffset: offset)
            guard read(4)?.elementsEqual(Array("fLaC".utf8)) == true else { return nil }
        } else if !magic.elementsEqual(Array("fLaC".utf8)) {
            return nil
        }
        for _ in 0..<128 {
            guard let h = read(4) else { return nil }
            let last = h[h.startIndex] & 0x80 != 0, type = h[h.startIndex] & 0x7F
            let length = Int(h[h.startIndex + 1]) << 16 | Int(h[h.startIndex + 2]) << 8 | Int(h[h.startIndex + 3])
            if type == 4 {
                guard let body = read(length) else { return nil }
                return cover(inVorbisComment: body)
            }
            guard let here = try? handle.offset() else { return nil }
            try? handle.seek(toOffset: here + UInt64(length))
            if last { return nil }
        }
        return nil
    }

    /// Parses a Vorbis comment block and decodes its picture comments; front cover first.
    static func cover(inVorbisComment body: Data) -> Data? {
        let b = [UInt8](body)
        var p = 0
        func u32le() -> Int? {
            guard p + 4 <= b.count else { return nil }
            defer { p += 4 }
            return Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24
        }
        guard let vendor = u32le(), p + vendor <= b.count else { return nil }
        p += vendor
        guard let count = u32le() else { return nil }
        var pictures: [(type: Int, data: Data)] = []
        let key = Array("METADATA_BLOCK_PICTURE=".utf8)
        for _ in 0..<count {
            guard let length = u32le(), p + length <= b.count else { break }
            let entry = b[p..<(p + length)]
            p += length
            guard entry.count > key.count,
                  entry.prefix(key.count).map({ $0 >= 97 && $0 <= 122 ? $0 - 32 : $0 }).elementsEqual(key),
                  let raw = Data(base64Encoded: Data(entry.dropFirst(key.count)), options: .ignoreUnknownCharacters),
                  let picture = parsePicture(raw) else { continue }
            pictures.append(picture)
        }
        return (pictures.first { $0.type == 3 } ?? pictures.first)?.data
    }

    /// A FLAC picture structure: type, MIME, description, dimensions, then the image.
    static func parsePicture(_ raw: Data) -> (type: Int, data: Data)? {
        let b = [UInt8](raw)
        var p = 0
        func u32be() -> Int? {
            guard p + 4 <= b.count else { return nil }
            defer { p += 4 }
            return Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
        }
        guard let type = u32be(), let mime = u32be(), p + mime <= b.count else { return nil }
        p += mime
        guard let description = u32be(), p + description <= b.count else { return nil }
        p += description
        p += 16   // width, height, depth, colours
        guard let length = u32be(), length > 0, p + length <= b.count else { return nil }
        return (type, Data(b[p..<(p + length)]))
    }
}
