//
// Vespertine — formats Vespertine can't decode, named plainly instead of failing with a vague error: Dolby AC-4 and
// MPEG-H 3D Audio (no decoder in macOS or in the bundled FFmpeg), and MQA and Auro-3D, which are ordinary PCM to
// Vespertine and play as exactly that. Text only: these are trademarks, and Vespertine names the file's format.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum UndecodedFormat: String, Sendable, Hashable, CaseIterable {
    case mqa, ac4, mpegH, auro3D

    /// The name, as a codec column shows it.
    public var name: String {
        switch self {
        case .mqa: "MQA"
        case .ac4: "Dolby AC-4"
        case .mpegH: "MPEG-H 3D Audio"
        case .auro3D: "Auro-3D"
        }
    }

    /// Whether the file plays at all: MQA as the FLAC it is, Auro-3D as the PCM it is.
    public var playsAsPCM: Bool { self == .mqa || self == .auro3D }

    /// A line for the badge and the signal path: what Vespertine does with the file.
    public var note: String {
        switch self {
        case .mqa: String(localized: "Played as FLAC, not unfolded", comment: "Badge note under MQA: Vespertine can't decode MQA, so the file plays as the plain FLAC it contains.")
        case .auro3D: String(localized: "Played as PCM, not decoded", comment: "Badge note under Auro-3D: Vespertine can't decode the Auro-3D height channels, so the file plays as the ordinary surround PCM it contains.")
        case .ac4, .mpegH: String(localized: "Can't be decoded here", comment: "Badge note under Dolby AC-4 and MPEG-H: no decoder is available to Vespertine, so the file can't play.")
        }
    }

    /// What a file that can't play says when played.
    public var failure: String {
        switch self {
        case .ac4, .mpegH:
            String(localized: "\(name) can't be played: macOS has no decoder for it and Vespertine doesn't include one.",
                   comment: "Why a file can't be played, in “This file can't be played (…).” %@ is an audio format: Dolby AC-4, or MPEG-H 3D Audio (also used by Sony 360 Reality Audio).")
        case .mqa, .auro3D: note
        }
    }

    /// The decoder line of the signal path for a file that plays as PCM: the decoder, then this format's note.
    public func decoderName(_ decoder: String) -> String { "\(decoder) · \(name): \(note.lowercased())" }

    // MARK: Detection

    /// Formats found by looking at the file itself: AC-4 and MPEG-H streams and MP4 audio (sample entries `ac-4`,
    /// `mha1`, `mhm1` …), by the first bytes or the sample entry, never by name alone. (Matroska files holding them
    /// aren't recognised: the bundled FFmpeg 9.0.2 doesn't map their codec IDs.)
    public static func undecodable(at url: URL) -> UndecodedFormat? {
        switch url.pathExtension.lowercased() {
        case "ac4":
            // The AC-4 sync word 0xAC40 (CRC absent) or 0xAC41 (CRC present).
            guard let head = bytes(url, 2) else { return nil }
            return head == [0xAC, 0x40] || head == [0xAC, 0x41] ? .ac4 : nil
        case "mhas":
            // An MPEG-H audio stream (MHAS) starts with a sync packet: 0xC0 0x01 0xA5.
            guard let head = bytes(url, 3) else { return nil }
            return head == [0xC0, 0x01, 0xA5] ? .mpegH : nil
        case "mp4", "m4a", "m4b", "mov":
            return MP4.audioSampleEntry(url).flatMap(Self.init(sampleEntry:))
        default:
            return nil
        }
    }

    init?(sampleEntry: String) {
        switch sampleEntry {
        case "ac-4": self = .ac4
        case "mha1", "mha2", "mhm1", "mhm2": self = .mpegH
        default: return nil
        }
    }

    /// MQA, by what an MQA FLAC carries: the encoder's own tags (MQAENCODER, ORIGINALSAMPLERATE), or the encoder's
    /// 36-bit synchronisation word, 0xBE0498C88, which it hides in the 16th bit of 24-bit stereo samples (left XOR right).
    public static func isMQA(tags: [String: String]) -> Bool {
        let keys = Set(tags.keys.map { $0.uppercased() })
        return keys.contains("MQAENCODER") || (keys.contains("ORIGINALSAMPLERATE") && keys.contains("MQASAMPLERATE"))
    }

    /// `samples` are 24-bit stereo frames, left then right, as integers.
    public static func hasMQASync(left: [Int32], right: [Int32]) -> Bool {
        var window: UInt64 = 0
        for (l, r) in zip(left, right) {
            window = ((window << 1) | UInt64(((l ^ r) >> 16) & 1)) & 0xF_FFFF_FFFF
            if window == 0xB_E049_8C88 { return true }
        }
        return false
    }

    /// Auro-3D PCM carries its height channels in the least significant bits of an ordinary 5.1 or 7.1 file, in a way only
    /// Auro's decoder reads, and tells nothing in the file's format. Release names do ("… Auro-3D", "Auro3D" folders):
    /// that is all this goes by.
    public static func isAuro3DByName(_ text: [String], channels: Int) -> Bool {
        guard channels >= 6 else { return false }
        return text.contains { $0.range(of: #"auro[\s_.-]?3d"#, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    // MARK: Reading

    private static func bytes(_ url: URL, _ count: Int) -> [UInt8]? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: count), data.count == count else { return nil }
        return [UInt8](data)
    }

    /// The Vorbis comments of a FLAC file, name (as written) to value, without decoding anything.
    public static func flacComments(_ url: URL) -> [String: String] {
        guard let file = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? file.close() }
        guard let magic = try? file.read(upToCount: 4), magic == Data("fLaC".utf8) else { return [:] }
        var out: [String: String] = [:]
        while let header = try? file.read(upToCount: 4), header.count == 4 {
            let last = header[header.startIndex] & 0x80 != 0, type = header[header.startIndex] & 0x7F
            let length = Int(header[header.startIndex + 1]) << 16 | Int(header[header.startIndex + 2]) << 8 | Int(header[header.startIndex + 3])
            if type == 4 {
                guard length < 1 << 20, let body = try? file.read(upToCount: length), body.count == length else { break }
                let b = [UInt8](body)
                func u32(_ at: Int) -> Int? { at + 4 <= b.count ? Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24 : nil }
                guard let vendor = u32(0) else { return out }
                var p = 4 + vendor
                guard let count = u32(p) else { return out }
                p += 4
                for _ in 0..<min(count, 4096) {
                    guard let n = u32(p), p + 4 + n <= b.count else { break }
                    let entry = String(decoding: b[(p + 4)..<(p + 4 + n)], as: UTF8.self)
                    if let eq = entry.firstIndex(of: "=") { out[String(entry[..<eq])] = String(entry[entry.index(after: eq)...]) }
                    p += 4 + n
                }
            } else {
                guard let here = try? file.offset(), (try? file.seek(toOffset: here + UInt64(length))) != nil else { break }
            }
            if last { break }
        }
        return out
    }
}

/// Just enough of an MP4 file to read the first audio track's sample entry.
enum MP4 {
    /// The four-character code of the first sound track's sample description ("mp4a", "alac", "ec-3", "ac-4", "mhm1" …).
    static func audioSampleEntry(_ url: URL) -> String? {
        guard let file = try? FileHandle(forReadingFrom: url), let size = try? file.seekToEnd() else { return nil }
        defer { try? file.close() }

        func box(at offset: UInt64, end: UInt64) -> (type: String, body: UInt64, end: UInt64)? {
            guard offset + 8 <= end, (try? file.seek(toOffset: offset)) != nil, let h = try? file.read(upToCount: 16), h.count >= 8 else { return nil }
            let b = [UInt8](h)
            var length = UInt64(b[0]) << 24 | UInt64(b[1]) << 16 | UInt64(b[2]) << 8 | UInt64(b[3]), header: UInt64 = 8
            if length == 1, b.count >= 16 {
                length = b[8...15].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }; header = 16
            } else if length == 0 { length = end - offset }
            guard length >= header, offset + length <= end else { return nil }
            return (String(decoding: b[4..<8], as: UTF8.self), offset + header, offset + length)
        }
        func children(_ start: UInt64, _ end: UInt64) -> [(type: String, body: UInt64, end: UInt64)] {
            var out: [(String, UInt64, UInt64)] = [], p = start
            while let b = box(at: p, end: end), out.count < 256 { out.append(b); p = b.end }
            return out
        }
        for moov in children(0, size) where moov.type == "moov" {
            for trak in children(moov.body, moov.end) where trak.type == "trak" {
                guard let mdia = children(trak.body, trak.end).first(where: { $0.type == "mdia" }) else { continue }
                let parts = children(mdia.body, mdia.end)
                // hdlr: version/flags (4), predefined (4), handler type (4).
                guard let hdlr = parts.first(where: { $0.type == "hdlr" }), (try? file.seek(toOffset: hdlr.body + 8)) != nil,
                      let handler = try? file.read(upToCount: 4), String(decoding: handler, as: UTF8.self) == "soun",
                      let minf = parts.first(where: { $0.type == "minf" }),
                      let stbl = children(minf.body, minf.end).first(where: { $0.type == "stbl" }),
                      let stsd = children(stbl.body, stbl.end).first(where: { $0.type == "stsd" }),
                      // stsd: version/flags (4), entry count (4), then the first entry: size (4), format (4).
                      (try? file.seek(toOffset: stsd.body + 12)) != nil, let entry = try? file.read(upToCount: 4), entry.count == 4 else { continue }
                return String(decoding: entry, as: UTF8.self)
            }
        }
        return nil
    }
}
