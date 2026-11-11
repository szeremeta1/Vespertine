//
// Vespertine: CUE sheet parsing (single-file albums split into virtual tracks).
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
        /// Where the track starts in the file's own samples, when the sheet says (a FLAC CUESHEET block does): exact for
        /// offsets that aren't a whole number of CD frames.
        public var startSample: Int64? = nil
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
        var currentFile: Int?

        func flush() {
            if let c = current, !sheet.files.isEmpty {
                sheet.files[currentFile ?? (sheet.files.count - 1)].tracks.append(c)
            }
            current = nil
            currentFile = nil
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
                // EAC can put FILE between TRACK (or INDEX 00) and INDEX 01.
                // The track belongs to the file containing its INDEX 01.
                if currentFile != nil { flush() }
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
                if Int(index) == 1, let frames = cdFrames(time) {
                    current?.startCDFrames = frames
                    if !sheet.files.isEmpty { currentFile = sheet.files.count - 1 }
                }
            default:
                break
            }
        }
        flush()
        return sheet
    }

    /// "mm:ss:ff" → CD frames.
    static func cdFrames(_ time: String) -> Int? {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let minutes = Int(parts[0]), let seconds = Int(parts[1]),
              let frames = Int(parts[2]), minutes >= 0, (0..<60).contains(seconds), (0..<75).contains(frames) else { return nil }
        let (m, overflow1) = minutes.multipliedReportingOverflow(by: 4500)
        let (total, overflow2) = m.addingReportingOverflow(seconds * 75 + frames)
        return overflow1 || overflow2 ? nil : total
    }

    /// Converts CD frames to sample frames at `sampleRate`.
    public static func sampleFrame(cdFrames: Int, sampleRate: Double) -> Int64 {
        let frame = (Double(cdFrames) * sampleRate / 75).rounded()
        guard cdFrames >= 0, sampleRate.isFinite, sampleRate > 0, frame.isFinite,
              frame >= 0, frame < Double(Int64.max) else { return 0 }
        return Int64(frame)
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

    /// Reads a .cue file (see `text(of:)` for its encoding).
    public static func load(_ url: URL) -> CueSheet? {
        guard let data = try? Data(contentsOf: url), let text = text(of: data) else { return nil }
        return parse(text)
    }

    /// The text of a .cue file (see `decode(_:)` for its encoding).
    public static func text(of data: Data) -> String? { decode(data)?.text }

    /// The text of a .cue file and the encoding it was read in. A UTF-8 BOM or valid UTF-8 settles it. Otherwise the
    /// legacy encodings that tell themselves apart by shape (Shift-JIS, GB 18030/GBK, Windows-1251) each score how much
    /// of the sheet's high bytes make sense in them, and the best score of at least 0.6 wins (a tie goes to the earlier
    /// of Shift-JIS, GB 18030, Windows-1251), so a Chinese sheet is not taken by whichever guess happens to run first.
    /// Windows-1252 and Latin-1 accept almost any bytes, so they come last, or every other sheet would read as mojibake.
    /// Writing a sheet back in the encoding it was read in keeps every byte the reader didn't change, even when the
    /// guess was wrong.
    public static func decode(_ data: Data) -> (text: String, encoding: String.Encoding)? {
        let bytes = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        if let text = String(data: bytes, encoding: .utf8) { return (text, .utf8) }
        let candidates: [(text: String, encoding: String.Encoding, score: Double)] = [
            shiftJISScore(bytes).map { ($0.text, .shiftJIS, $0.score) },
            gb18030Score(bytes).map { ($0.text, .gb18030, $0.score) },
            cyrillicScore(bytes).map { ($0.text, .windowsCP1251, $0.score) },
        ].compactMap { $0 }.filter { $0.score >= 0.6 }
        var best: (text: String, encoding: String.Encoding, score: Double)?
        for candidate in candidates where candidate.score > (best?.score ?? 0) { best = candidate }
        if let best { return (best.text, best.encoding) }
        // Cyrillic, loosely: whole words of high bytes, where a Western sheet has an accented letter here and there.
        let high = bytes.indices.filter { bytes[$0] >= 0xC0 }
        let inWords = high.filter { i in (i > bytes.startIndex && bytes[i - 1] >= 0xC0) || (i + 1 < bytes.endIndex && bytes[i + 1] >= 0xC0) }
        if high.count >= 4, Double(inWords.count) / Double(high.count) > 0.6, let text = String(data: bytes, encoding: .windowsCP1251) {
            return (text, .windowsCP1251)
        }
        if let text = String(data: bytes, encoding: .windowsCP1252) { return (text, .windowsCP1252) }
        if let text = String(data: bytes, encoding: .isoLatin1) { return (text, .isoLatin1) }
        return nil
    }

    /// Japanese: the bytes decode as Shift-JIS and the sheet says something in kana or kanji. Score: the share of its
    /// non-ASCII characters that are kana, kanji, full-width punctuation or the usual symbols and Greek/Cyrillic letters. (Western text that happens to decode gives
    /// half-width katakana and stray kanji, never real words, and a GBK sheet's leads decode as half-width katakana.)
    private static func shiftJISScore(_ bytes: Data.SubSequence) -> (text: String, score: Double)? {
        guard let text = String(data: bytes, encoding: .shiftJIS) else { return nil }
        let wide = text.unicodeScalars.filter { $0.value >= 0x80 }
        let japanese = wide.filter { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }.count
        let halfWidth = wide.filter { (0xFF61...0xFF9F).contains($0.value) }.count
        guard japanese >= 2, halfWidth == 0 else { return nil }
        let sensible = wide.filter { (0x3000...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0xFF01...0xFF60).contains($0.value)
            || (0x0370...0x04FF).contains($0.value) || (0x2000...0x2BFF).contains($0.value) }.count
        return (text, Double(sensible) / Double(wide.count))
    }

    /// Chinese (GBK/GB 18030, what Chinese-market rips are written in): the bytes decode and say something in hanzi.
    /// Score: the share of its two-byte characters that are GB 2312 punctuation or common hanzi (lead A1-D7, trail
    /// A1-FE); Cyrillic text decoded this way lands mostly on the rare rows (lowercase is E0-FF). Capital Cyrillic and
    /// capital accented Latin (C0-DF) do land on common ones, so a sheet whose high bytes are nearly all C0-DF, which
    /// real Chinese text, with its trails and lead rows from A1 up, never is, scores 0. Kana means a Japanese sheet.
    private static func gb18030Score(_ bytes: Data.SubSequence) -> (text: String, score: Double)? {
        guard let text = String(data: bytes, encoding: .gb18030) else { return nil }
        let scalars = text.unicodeScalars
        guard scalars.filter({ (0x4E00...0x9FFF).contains($0.value) }).count >= 2,
              !scalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) else { return nil }
        var characters = 0, common = 0, high = 0, capitals = 0
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let lead = bytes[i]
            if lead < 0x80 { i += 1; continue }
            characters += 1
            let trail = i + 1 < bytes.endIndex ? bytes[i + 1] : 0
            let width = (0x30...0x39).contains(trail) ? 4 : 2  // GB 18030's four-byte sequences
            for byte in bytes[i..<min(i + width, bytes.endIndex)] where byte >= 0x80 {
                high += 1
                if (0xC0...0xDF).contains(byte) { capitals += 1 }
            }
            if width == 2, (0xA1...0xD7).contains(lead), trail >= 0xA1 { common += 1 }
            i += width
        }
        guard Double(capitals) / Double(high) < 0.8 else { return nil }
        return (text, Double(common) / Double(characters))
    }

    /// Cyrillic: Windows-1251 text is made of whole words, a capital and lowercase letters or capitals alone (a Western
    /// sheet has an accented letter here and there, and Chinese bytes make runs that aren't words). Score: the share of
    /// the sheet's high bytes that are in such words of two letters or more.
    private static func cyrillicScore(_ bytes: Data.SubSequence) -> (text: String, score: Double)? {
        let high = bytes.filter { $0 >= 0x80 }.count
        guard high >= 4, let text = String(data: bytes, encoding: .windowsCP1251) else { return nil }
        func isLetter(_ b: UInt8) -> Bool { b >= 0xC0 || [0xA8, 0xB8, 0xAA, 0xBA, 0xAF, 0xBF, 0xB2, 0xB3].contains(b) }
        func isCapital(_ b: UInt8) -> Bool { (0xC0...0xDF).contains(b) || [0xA8, 0xAA, 0xAF, 0xB2].contains(b) }
        var inWords = 0
        var i = bytes.startIndex
        while i < bytes.endIndex {
            guard isLetter(bytes[i]) else { i += 1; continue }
            var end = i
            while end < bytes.endIndex, isLetter(bytes[end]) { end += 1 }
            let word = bytes[i..<end]
            if word.count >= 2, word.dropFirst().allSatisfy({ !isCapital($0) }) || word.allSatisfy(isCapital) { inWords += word.count }
            i = end
        }
        return (text, Double(inWords) / Double(high))
    }

    /// The audio file a sheet's FILE line names: as written or, as rips often end up, the same name with another
    /// extension (a sheet written for "Album.wav" beside the "Album.flac" it was compressed to), or else the one audio
    /// file named like the sheet itself.
    public static func audioFile(named name: String, besideSheet sheet: URL) -> URL? {
        let folder = sheet.deletingLastPathComponent()
        let named = folder.appendingPathComponent(name, isDirectory: false)
        if FileManager.default.fileExists(atPath: named.path) { return named }
        let extensions = ["flac", "wav", "ape", "wv", "tta", "tak", "aiff", "aif", "m4a", "dsf", "dff"]
        for base in [named.deletingPathExtension().lastPathComponent, sheet.deletingPathExtension().lastPathComponent] {
            let found = extensions.map { folder.appendingPathComponent(base, isDirectory: false).appendingPathExtension($0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if found.count == 1 { return found[0] }
        }
        return nil
    }
}

public extension String.Encoding {
    /// GB 18030, the superset of GBK and GB 2312 that Chinese CD rips are usually written in. Foundation has no named
    /// constant for it.
    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
}
