//
// Nocturne — fast tag reading over high-latency network shares.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tag readers make many small reads, each a full round trip on a network share
// (≈20 per file, ~2 s at 100 ms). Instead, fetch the regions that hold metadata in a few
// large reads — walking the container structure (FLAC blocks, ID3v2, MP4 atoms, RIFF/AIFF
// chunks, DSF) — into a sparse local file of the same size, and read tags from that.
//

import Foundation

public enum RemoteMetadata {
    static let firstRead = 256 * 1024
    static let tailRead = 128 * 1024

    /// A byte-range reader over one open file.
    final class Source {
        let fd: Int32
        let size: Int64
        static let lookahead = 64 * 1024
        private(set) var ranges: [(offset: Int64, data: Data)] = []
        private(set) var requests = 0

        init(url: URL, size: Int64) throws {
            fd = open(url.path, O_RDONLY)
            guard fd >= 0 else { throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
            _ = fcntl(fd, F_NOCACHE, 1) // no read-ahead: fetch only what's asked for
            self.size = size
        }

        deinit { close(fd) }

        /// Bytes at [offset, offset+length), fetched once.
        @discardableResult
        func read(_ offset: Int64, _ length: Int) throws -> Data {
            let start = max(0, min(offset, size))
            let count = Int(min(Int64(length), size - start))
            guard count > 0 else { return Data() }
            if let hit = cached(start, count) { return hit }
            // Every request is a round trip; small ones fetch ahead so the next header comes along.
            let fetch = Int(min(Int64(max(count, Self.lookahead)), size - start))
            var buffer = Data(count: fetch)
            let got = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, fetch, off_t(start)) }
            requests += 1
            guard got >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            buffer.count = got
            ranges.append((start, buffer))
            return buffer.prefix(count)
        }

        private func cached(_ offset: Int64, _ count: Int) -> Data? {
            for r in ranges where offset >= r.offset && offset + Int64(count) <= r.offset + Int64(r.data.count) {
                let lo = Int(offset - r.offset)
                return r.data.subdata(in: lo..<(lo + count))
            }
            return nil
        }

        /// Makes sure [offset, offset+length) is fetched, reading only the missing part.
        func ensure(_ offset: Int64, _ length: Int) throws {
            let end = min(size, offset + Int64(length))
            var covered = offset
            for r in ranges.sorted(by: { $0.offset < $1.offset }) where r.offset <= covered && r.offset + Int64(r.data.count) > covered {
                covered = r.offset + Int64(r.data.count)
            }
            if covered < end { try read(covered, Int(end - covered) + Self.lookahead) }
        }
    }

    /// Fetches the metadata regions of `url` into a sparse copy at `shadow` (same name, same size).
    /// Returns the number of read requests it took.
    @discardableResult
    public static func makeShadow(of url: URL, size: Int64, at shadow: URL) throws -> Int {
        let src = try Source(url: url, size: size)
        try plan(src, ext: url.pathExtension.lowercased())

        let fd = open(shadow.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard ftruncate(fd, off_t(size)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for r in src.ranges {
            let written = r.data.withUnsafeBytes { pwrite(fd, $0.baseAddress, r.data.count, off_t(r.offset)) }
            guard written == r.data.count else { throw POSIXError(.EIO) }
        }
        return src.requests
    }

    static func plan(_ src: Source, ext: String) throws {
        let head = try src.read(0, firstRead)
        var needsTail = true
        var p: Int64 = 0

        // ID3v2 in front (MP3, and sometimes FLAC/AIFF/WAV writers).
        if head.count >= 10, head.starts(with: Array("ID3".utf8)) {
            let size = synchsafe(head, at: 6)
            let footer: Int64 = head[5] & 0x10 != 0 ? 10 : 0
            p = 10 + size + footer
            try src.ensure(0, Int(p) + 64 * 1024) // the tag plus the first audio frames (Xing/LAME headers)
        }

        let at = try src.read(p, 16)
        if at.count >= 4, at.starts(with: Array("fLaC".utf8)) {
            try walkFLAC(src, from: p + 4)
            needsTail = false
        } else if at.count >= 8, at[at.startIndex + 4..<at.startIndex + 8].elementsEqual(Array("ftyp".utf8)) {
            try walkAtoms(src)
            needsTail = false
        } else if at.count >= 12, at.starts(with: Array("RIFF".utf8)) || at.starts(with: Array("RF64".utf8)) {
            try walkChunks(src, from: 12, bigEndian: false)
            needsTail = false
        } else if at.count >= 12, at.starts(with: Array("FORM".utf8)) {
            try walkChunks(src, from: 12, bigEndian: true)
            needsTail = false
        } else if at.count >= 4, at.starts(with: Array("DSD ".utf8)) {
            let header = try src.read(0, 28)
            let metadata = header.count >= 28 ? le64(header, at: 20) : 0
            if metadata > 0, metadata < src.size { try src.ensure(metadata, Int(src.size - metadata)) }
            needsTail = false
        }
        // ID3v1, APE, Lyrics3, Ogg's last page (duration), WavPack/Musepack trailers…
        if needsTail || ext == "mp3" { try src.ensure(max(0, src.size - Int64(tailRead)), tailRead) }
    }

    static func walkFLAC(_ src: Source, from start: Int64) throws {
        var o = start
        for _ in 0..<256 {
            let h = try src.read(o, 4)
            guard h.count == 4 else { return }
            let last = h[h.startIndex] & 0x80 != 0
            let length = Int64(h[h.startIndex + 1]) << 16 | Int64(h[h.startIndex + 2]) << 8 | Int64(h[h.startIndex + 3])
            try src.ensure(o, Int(4 + length))
            o += 4 + length
            if last { break }
        }
        try src.ensure(o, 64 * 1024) // first frames, for the decoder
    }

    static func walkAtoms(_ src: Source) throws {
        var o: Int64 = 0
        for _ in 0..<64 where o < src.size {
            let h = try src.read(o, 16)
            guard h.count >= 8 else { return }
            var size = Int64(be32(h, at: 0))
            let type = String(decoding: h[h.startIndex + 4..<h.startIndex + 8], as: UTF8.self)
            if size == 1, h.count >= 16 { size = Int64(bitPattern: be64(h, at: 8)) }
            if size == 0 { size = src.size - o }
            guard size >= 8 else { return }
            if type != "mdat" && type != "free" && type != "skip" && type != "wide" {
                try src.ensure(o, Int(min(size, 64 * 1024 * 1024)))
            }
            o += size
        }
    }

    static func walkChunks(_ src: Source, from start: Int64, bigEndian: Bool) throws {
        var o = start
        for _ in 0..<256 where o + 8 <= src.size {
            let h = try src.read(o, 8)
            guard h.count == 8 else { return }
            let id = String(decoding: h[h.startIndex..<h.startIndex + 4], as: UTF8.self)
            var size = Int64(bigEndian ? be32(h, at: 4) : le32(h, at: 4))
            if id == "data" || id == "SSND" {
                try src.ensure(o, 64 * 1024) // format headers the decoder checks at the start of audio
                if size == 0xFFFFFFFF { return } // RF64: real size lives in ds64, audio runs to the end
            } else {
                try src.ensure(o, Int(8 + min(size, 64 * 1024 * 1024)))
            }
            size += size & 1
            o += 8 + size
        }
    }

    static func synchsafe(_ d: Data, at i: Int) -> Int64 {
        let b = d.startIndex + i
        return Int64(d[b] & 0x7F) << 21 | Int64(d[b + 1] & 0x7F) << 14 | Int64(d[b + 2] & 0x7F) << 7 | Int64(d[b + 3] & 0x7F)
    }
    static func be32(_ d: Data, at i: Int) -> UInt32 { d[d.startIndex + i..<d.startIndex + i + 4].reduce(0) { $0 << 8 | UInt32($1) } }
    static func be64(_ d: Data, at i: Int) -> UInt64 { d[d.startIndex + i..<d.startIndex + i + 8].reduce(0) { $0 << 8 | UInt64($1) } }
    static func le32(_ d: Data, at i: Int) -> UInt32 { d[d.startIndex + i..<d.startIndex + i + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
    static func le64(_ d: Data, at i: Int) -> Int64 { Int64(bitPattern: d[d.startIndex + i..<d.startIndex + i + 8].reversed().reduce(0) { $0 << 8 | UInt64($1) }) }

    /// Reads tags for a file on a network share via a sparse local shadow, then points the
    /// record back at the real file. Falls back to reading the file directly.
    public static func readTrack(url: URL, size: Int64, modified: Date, artwork: ArtworkStore?, folderArt: FolderArtCache?) throws -> Track {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nocturne-shadow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shadow = dir.appendingPathComponent(url.lastPathComponent, isDirectory: false)
        var track: Track
        do {
            try makeShadow(of: url, size: size, at: shadow)
            track = try MetadataReader.read(url: shadow, artwork: artwork, folderArt: folderArt, original: url)
        } catch {
            track = try MetadataReader.read(url: url, artwork: artwork, folderArt: folderArt)
        }
        track.location = url.path
        track.filePath = url.path
        track.fileSize = size
        track.modifiedAt = modified
        return track
    }
}
