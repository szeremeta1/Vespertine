//
// Vespertine — ID3v2 frames the tag reader doesn't pass on (it only maps the common fields for MP3):
// release and original dates (TDRC / TYER, TDOR / TORY), label (TPUB) and TXXX user fields
// (e.g. "originalyear"). Also DSF, whose reader drops the dates.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum ID3Extras {
    /// Extra tags from an ID3v2 tag at the start of the file, keyed like Vorbis comments
    /// ("ORIGINALDATE", "LABEL", TXXX descriptions uppercased).
    static func read(_ url: URL) -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        return read(handle)
    }

    /// DSF keeps its ID3v2 tag at the end, where the header's metadata pointer says (0 = none).
    static func readDSF(_ url: URL) -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 28), header.count == 28, header.starts(with: Array("DSD ".utf8)) else { return [:] }
        let pointer = header[20..<28].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard pointer >= 28, (try? handle.seek(toOffset: pointer)) != nil else { return [:] }
        return read(handle)
    }

    private static func read(_ handle: FileHandle) -> [String: String] {
        guard let header = try? handle.read(upToCount: 10), header.count == 10,
              header.starts(with: Array("ID3".utf8)) else { return [:] }
        let h = [UInt8](header)
        let version = h[3]
        guard version == 3 || version == 4 else { return [:] }
        let size = h[6...9].reduce(0) { $0 << 7 | Int($1 & 0x7F) }
        guard size > 0, size < 64 << 20, let body = try? handle.read(upToCount: size) else { return [:] }
        var b = [UInt8](body)
        if h[5] & 0x80 != 0, version == 3 { b = unsynchronized(b) }
        var p = 0
        if h[5] & 0x40 != 0, b.count >= 4 {       // extended header
            let ext = version == 4 ? b[0...3].reduce(0) { $0 << 7 | Int($1 & 0x7F) } : (b[0...3].reduce(0) { $0 << 8 | Int($1) } + 4)
            p = ext
        }
        var out: [String: String] = [:]
        while p + 10 <= b.count {
            let id = String(bytes: b[p..<(p + 4)], encoding: .ascii) ?? ""
            guard id.allSatisfy({ $0.isUppercase || $0.isNumber }), !id.isEmpty, b[p] != 0 else { break }
            let length = version == 4 ? b[(p + 4)...(p + 7)].reduce(0) { $0 << 7 | Int($1 & 0x7F) }
                                      : b[(p + 4)...(p + 7)].reduce(0) { $0 << 8 | Int($1) }
            let start = p + 10, end = start + length
            guard length > 0, end <= b.count else { break }
            let data = Array(b[start..<end])
            switch id {
            case "TDOR": if let v = text(data) { out["ORIGINALDATE"] = v }
            case "TDRC", "TYER": if let v = text(data), out["DATE"] == nil { out["DATE"] = v }
            case "TORY": if let v = text(data), out["ORIGINALDATE"] == nil { out["ORIGINALYEAR"] = v }
            case "TPUB": if let v = text(data) { out["LABEL"] = v }
            case "TXXX":
                let parts = strings(data)
                if parts.count >= 2, !parts[0].isEmpty { out[parts[0].uppercased()] = parts[1] }
            default: break
            }
            p = end
        }
        return out
    }

    private static func unsynchronized(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []; out.reserveCapacity(b.count)
        var i = 0
        while i < b.count { out.append(b[i]); if b[i] == 0xFF, i + 1 < b.count, b[i + 1] == 0 { i += 1 }; i += 1 }
        return out
    }

    /// A text frame's first value.
    private static func text(_ data: [UInt8]) -> String? { strings(data).first.flatMap { $0.isEmpty ? nil : $0 } }

    /// The NUL-separated strings of a text frame, in its encoding.
    private static func strings(_ data: [UInt8]) -> [String] {
        guard let encoding = data.first else { return [] }
        let payload = Array(data.dropFirst())
        switch encoding {
        case 1, 2:   // UTF-16 with BOM / UTF-16BE: split on 16-bit NULs
            var parts: [String] = [], current: [UInt8] = [], i = 0
            while i + 1 < payload.count {
                if payload[i] == 0, payload[i + 1] == 0 {
                    parts.append(decode16(current, bigEndianDefault: encoding == 2)); current = []
                } else { current += [payload[i], payload[i + 1]] }
                i += 2
            }
            if !current.isEmpty { parts.append(decode16(current, bigEndianDefault: encoding == 2)) }
            return parts
        default:     // 0 Latin-1, 3 UTF-8
            return payload.split(separator: 0, omittingEmptySubsequences: false).map {
                String(bytes: $0, encoding: encoding == 3 ? .utf8 : .isoLatin1) ?? ""
            }.filter { !$0.isEmpty }
        }
    }

    private static func decode16(_ bytes: [UInt8], bigEndianDefault: Bool) -> String {
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE { return String(bytes: bytes.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF { return String(bytes: bytes.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        return String(bytes: bytes, encoding: bigEndianDefault ? .utf16BigEndian : .utf16LittleEndian) ?? ""
    }
}
