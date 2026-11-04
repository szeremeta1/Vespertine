//
// Vespertine — a DSF whose header total-size field is larger than the file.
// A tool that rewrites the ID3 tag at the end without fixing that field leaves the audio and the tag intact, but
// the tag reader (TagLib) refuses the file ("File is corrupted wrong length"). The file isn't changed: its
// header and its tag are read from a small copy whose total-size field and metadata pointer are consistent.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum DSFStandIn {
    /// The DSD chunk (28 bytes) and the format chunk (12-byte header + 52) that TagLib reads.
    static let headerSize = 28 + 64
    static let maxTagSize: UInt64 = 16 << 20

    /// A temporary DSF holding `url`'s header and ID3 tag with a consistent header, when `url`'s header claims
    /// more bytes than the file has. Nil for any other file (the caller's original error stands). The caller removes it.
    static func make(for url: URL) -> URL? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > UInt64(headerSize), (try? handle.seek(toOffset: 0)) != nil,
              let head = try? handle.read(upToCount: headerSize), head.count == headerSize,
              head.starts(with: Array("DSD ".utf8)), head[28..<32].elementsEqual(Array("fmt ".utf8)) else { return nil }
        func le64(_ at: Int) -> UInt64 { head[at..<(at + 8)].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
        let total = le64(12), pointer = le64(20)
        guard le64(4) == 28, total > size, pointer >= UInt64(headerSize), pointer < size, size - pointer <= maxTagSize,
              (try? handle.seek(toOffset: pointer)) != nil, let tag = try? handle.readToEnd(), !tag.isEmpty else { return nil }
        var out = [UInt8](head)
        func put(_ value: UInt64, at i: Int) { for k in 0..<8 { out[i + k] = UInt8(value >> (8 * UInt64(k)) & 0xFF) } }
        put(UInt64(headerSize + tag.count), at: 12)
        put(UInt64(headerSize), at: 20)
        let standIn = FileManager.default.temporaryDirectory.appendingPathComponent("dsf-\(UUID().uuidString).dsf")
        do { try (Data(out) + tag).write(to: standIn) } catch { return nil }
        return standIn
    }
}
