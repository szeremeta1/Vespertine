//
// Nocturne — CUE sheet parsing (single-file albums split into virtual tracks).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public struct CueSheet: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public var number: Int
        public var title: String?
        public var performer: String?
        public var isrc: String?
        /// INDEX 01 in CD frames (1/75 s).
        public var startCDFrames: Int
    }

    public struct File: Sendable, Hashable {
        public var name: String
        public var tracks: [Entry]
    }

    public var title: String?
    public var performer: String?
    public var genre: String?
    public var date: String?
    public var files: [File]

    public static func parse(_ text: String) -> CueSheet {
        var sheet = CueSheet(title: nil, performer: nil, genre: nil, date: nil, files: [])
        var current: Entry?

        func flush() {
            if let c = current, !sheet.files.isEmpty { sheet.files[sheet.files.count - 1].tracks.append(c) }
            current = nil
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let (command, rest) = split(line)
            switch command.uppercased() {
            case "REM":
                let (key, value) = split(rest)
                if key.uppercased() == "GENRE" { sheet.genre = unquote(value) }
                if key.uppercased() == "DATE" { sheet.date = unquote(value) }
            case "TITLE":
                if current != nil { current?.title = unquote(rest) } else { sheet.title = unquote(rest) }
            case "PERFORMER":
                if current != nil { current?.performer = unquote(rest) } else { sheet.performer = unquote(rest) }
            case "ISRC":
                current?.isrc = unquote(rest)
            case "FILE":
                flush()
                // FILE "name with spaces.flac" WAVE
                var name = rest
                if let r = rest.range(of: #"\s+(WAVE|FLAC|AIFF|MP3|BINARY|MOTOROLA)$"#, options: [.regularExpression, .caseInsensitive]) {
                    name = String(rest[..<r.lowerBound])
                }
                sheet.files.append(File(name: unquote(name), tracks: []))
            case "TRACK":
                flush()
                let (number, _) = split(rest)
                current = Entry(number: Int(number) ?? (sheet.files.last?.tracks.count ?? 0) + 1, startCDFrames: 0)
            case "INDEX":
                let (index, time) = split(rest)
                if Int(index) == 1, let frames = cdFrames(time) { current?.startCDFrames = frames }
            default:
                break
            }
        }
        flush()
        return sheet
    }

    /// "mm:ss:ff" → CD frames.
    static func cdFrames(_ time: String) -> Int? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return (parts[0] * 60 + parts[1]) * 75 + parts[2]
    }

    /// Converts CD frames to sample frames at `sampleRate`.
    public static func sampleFrame(cdFrames: Int, sampleRate: Double) -> Int64 {
        Int64((Double(cdFrames) * sampleRate / 75).rounded())
    }

    private static func split(_ s: String) -> (String, String) {
        guard let space = s.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return (s, "") }
        return (String(s[..<space]), s[space...].trimmingCharacters(in: .whitespaces))
    }

    private static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 { t = String(t.dropFirst().dropLast()) }
        return t
    }

    /// Reads a .cue file, trying UTF-8 then common legacy encodings.
    public static func load(_ url: URL) -> CueSheet? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        for encoding in [String.Encoding.utf8, .windowsCP1252, .isoLatin1, .shiftJIS] {
            if let text = String(data: data, encoding: encoding) { return parse(text) }
        }
        return nil
    }
}
