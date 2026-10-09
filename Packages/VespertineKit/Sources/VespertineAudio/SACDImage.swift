//
// Vespertine — SACD images (.iso): the disc's table of contents, its stereo and multichannel areas, their
// tracks and text. The layout is the Scarlet Book's (Super Audio CD, Sony/Philips), as documented by the
// open-source SACD tools (sacd-ripper's libsacd); this reader is Vespertine's own.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The two audio areas an SACD can have: the 2-channel one every disc carries, and an optional multichannel one.
public enum SACDArea: String, Sendable, Hashable, Codable, CaseIterable {
    case stereo = "2ch"
    case multichannel = "mch"

    /// A track's place in the library: "<image path>#2ch-3", "<image path>#mch-3".
    public static func location(path: String, area: SACDArea, track: Int) -> String { "\(path)#\(area.rawValue)-\(track)" }

    /// The area a library location names; nil for every other kind of track.
    public init?(location: String) {
        guard let hash = location.lastIndex(of: "#") else { return nil }
        let tag = location[location.index(after: hash)...]
        guard let dash = tag.firstIndex(of: "-"), Int(tag[tag.index(after: dash)...]) != nil,
              let area = SACDArea(rawValue: String(tag[..<dash])) else { return nil }
        self = area
    }
}

public enum SACDError: Error, LocalizedError {
    case notSACD, damaged(String), noArea
    public var errorDescription: String? {
        switch self {
        case .notSACD: "This disc image isn't a Super Audio CD."
        case .damaged(let what): "This SACD image is damaged (\(what))."
        case .noArea: "This SACD image has no audio area Vespertine can play."
        }
    }
}

/// An SACD image's table of contents and text.
public struct SACDImage: Sendable, Hashable {
    public static let sectorSize = 2048
    /// SACD audio is divided into frames of 1/75 s.
    public static let framesPerSecond = 75
    static let masterTOCSector = 510
    /// The Master TOC and its two copies.
    static let masterTOCSectors = [masterTOCSector, masterTOCSector + 10, masterTOCSector + 20]

    /// How the file stores each 2048-byte sector: on its own (the usual .iso), or inside the disc's 2064-byte
    /// physical sector, after 12 bytes of header and before 4 of error detection (raw rips).
    public struct SectorLayout: Sendable, Hashable {
        public var stride: Int
        public var offset: Int
        public static let plain = SectorLayout(stride: 2048, offset: 0)
        public static let raw = SectorLayout(stride: 2064, offset: 12)
    }

    public struct Track: Sendable, Hashable {
        public var number: Int
        /// Where the track starts, in frames (1/75 s) of its area's time code.
        public var startFrame: Int
        /// Its length in frames, through any pause before the next track, so the tracks join without a gap.
        public var frameCount: Int
        public var title: String?
        public var performer: String?
        public var songwriter: String?
        public var composer: String?
        public var arranger: String?
        public var message: String?
        public var isrc: String?
        public var genre: String?
    }

    public struct Area: Sendable, Hashable {
        public var kind: SACDArea
        public var channels: Int
        /// The DSD rate, 2 822 400 Hz (DSD64) on every SACD.
        public var sampleRate: Double
        /// Frames compressed with DST (lossless), rather than stored as plain DSD.
        public var isDST: Bool
        /// The area's audio sectors (inclusive).
        public var firstSector: Int
        public var lastSector: Int
        public var tracks: [Track]
        public var copyright: String?
        public var layout = SectorLayout.plain

        /// DSD bytes per channel in one frame (4704 for DSD64).
        public var frameBytes: Int { Int(sampleRate) / SACDImage.framesPerSecond / 8 }
        /// DSD samples per channel in one frame (37 632 for DSD64).
        public var samplesPerFrame: Int64 { Int64(frameBytes) * 8 }
        /// From the first track's start to the last one's end.
        public var frameRange: Range<Int> {
            guard let first = tracks.first, let last = tracks.last else { return 0..<0 }
            return first.startFrame..<(last.startFrame + last.frameCount)
        }
    }

    public var albumTitle: String?
    public var albumArtist: String?
    public var albumPublisher: String?
    public var albumCopyright: String?
    public var discTitle: String?
    public var discArtist: String?
    public var catalogNumber: String?
    public var genre: String?
    public var year: Int?
    public var month: Int?
    public var day: Int?
    /// The disc's place in a set of several ("2 of 3"); nil for a single disc.
    public var discNumber: Int?
    public var discTotal: Int?
    public var areas: [Area]

    public func area(_ kind: SACDArea) -> Area? { areas.first { $0.kind == kind } }

    /// "2003-03-01", "2003-03" or "2003".
    public var releaseDate: String? {
        guard let year else { return nil }
        guard let month, (1...12).contains(month) else { return String(format: "%04d", year) }
        guard let day, (1...31).contains(day) else { return String(format: "%04d-%02d", year, month) }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Whether the file is an SACD image (it has a Master TOC where the Scarlet Book puts it).
    public static func isSACD(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return [SectorLayout.plain, .raw].contains { layout in
            masterTOCSectors.contains { sector in
                (try? Self.sectors(handle, sector, 1, layout)).map { $0.starts(with: Array("SACDMTOC".utf8)) } ?? false
            }
        }
    }

    public static func read(_ url: URL) throws -> SACDImage {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try read(handle)
    }

    /// Sectors `first` to `first + count - 1`, their 2048 bytes each, one after another (fewer at the end of the file).
    static func sectors(_ handle: FileHandle, _ first: Int, _ count: Int, _ layout: SectorLayout = .plain) throws -> [UInt8] {
        try handle.seek(toOffset: UInt64(first) * UInt64(layout.stride))
        let data = [UInt8](try handle.read(upToCount: count * layout.stride) ?? Data())
        guard layout != .plain else { return data }
        var out: [UInt8] = []
        out.reserveCapacity(count * sectorSize)
        var p = layout.offset
        while p + sectorSize <= data.count {
            out.append(contentsOf: data[p..<p + sectorSize])
            p += layout.stride
        }
        return out
    }

    static func read(_ handle: FileHandle) throws -> SACDImage {
        // The Master TOC is stored three times. The first copy whose every area can be read counts; when none is
        // whole (damage in all three), the one that leads to the most areas.
        var sawTOC = false
        var best: SACDImage?
        for layout in [SectorLayout.plain, .raw] {
            for sector in masterTOCSectors {
                let m = try sectors(handle, sector, 1, layout)
                guard m.count == sectorSize, m.starts(with: Array("SACDMTOC".utf8)) else { continue }
                sawTOC = true
                let (image, whole) = try read(handle, masterTOC: m, sector: sector, layout: layout)
                if whole { return image }
                if image.areas.count > best?.areas.count ?? 0 { best = image }
            }
            if sawTOC { break }
        }
        guard sawTOC else { throw SACDError.notSACD }
        guard let best else { throw SACDError.noArea }
        return best
    }

    /// The image one copy of the Master TOC describes, and whether that copy is whole: a Scarlet Book 1.x TOC
    /// whose every area points to a readable area TOC.
    static func read(_ handle: FileHandle, masterTOC m: [UInt8], sector tocSector: Int, layout: SectorLayout) throws -> (SACDImage, whole: Bool) {
        var image = SACDImage(areas: [])
        var whole = m[8] == 1
        let setSize = Int(be16(m, 16)), sequence = Int(be16(m, 18))
        if setSize > 1, (1...setSize).contains(sequence) { image.discNumber = sequence; image.discTotal = setSize }
        image.catalogNumber = Self.text(Array(m[24..<40]), charset: 1) ?? Self.text(Array(m[88..<104]), charset: 1)
        image.genre = genreName(m[43]) ?? genreName(m[107])
        let year = Int(be16(m, 120))
        if year > 0 { image.year = year; image.month = Int(m[122]); image.day = Int(m[123]) }

        // Album and disc text, in the first language the disc has.
        let textAreas = Int(m[128])
        if textAreas > 0 {
            let charset = m[138] & 0x07
            let t = try sectors(handle, tocSector + 1, 1, layout)
            if t.count == sectorSize, t.starts(with: Array("SACDText".utf8)) {
                func field(_ index: Int) -> String? {
                    let position = Int(be16(t, 16 + 2 * index))
                    return position > 0 ? Self.string(t, at: position, charset: charset) : nil
                }
                image.albumTitle = field(0); image.albumArtist = field(1)
                image.albumPublisher = field(2); image.albumCopyright = field(3)
                image.discTitle = field(8); image.discArtist = field(9)
            }
        }

        // The 2-channel area's TOC, then the multichannel one's (each also stored twice).
        for (start1, start2, size) in [(be32(m, 64), be32(m, 68), be16(m, 84)), (be32(m, 72), be32(m, 76), be16(m, 86))] {
            guard start1 > 0 || start2 > 0 else { continue }       // no such area
            let area = size == 0 ? nil : [start1, start2].lazy.filter { $0 > 0 }
                .compactMap { try? readArea(handle, sector: Int($0), sectors: Int(size), layout: layout) }.first
            if let area, image.area(area.kind) == nil { image.areas.append(area) } else { whole = false }
        }
        return (image, whole && !image.areas.isEmpty)
    }

    static func readArea(_ handle: FileHandle, sector: Int, sectors count: Int, layout: SectorLayout = .plain) throws -> Area {
        let data = try sectors(handle, sector, min(count, 256), layout)
        guard data.count >= sectorSize else { throw SACDError.damaged("area TOC") }
        let isTwo = data.starts(with: Array("TWOCHTOC".utf8)), isMulti = data.starts(with: Array("MULCHTOC".utf8))
        guard isTwo || isMulti else { throw SACDError.damaged("area TOC") }
        let channels = Int(data[32]), loudspeakers = Int(data[33] >> 3)
        let fs = Int(data[20])
        let frameFormat = data[21] & 0x0F
        guard (1...6).contains(channels), fs == 4 || fs == 8 || fs == 16 else { throw SACDError.damaged("area format") }
        // A 2-channel stereo area (loudspeaker setup 0) is the stereo area; anything else plays as surround.
        let kind: SACDArea = channels == 2 && loudspeakers == 0 && isTwo ? .stereo : .multichannel
        let trackCount = Int(data[69])
        let first = Int(be32(data, 72)), last = Int(be32(data, 76))
        guard trackCount > 0, last >= first else { throw SACDError.damaged("track list") }
        let charset = data[90] & 0x07
        var area = Area(kind: kind, channels: channels, sampleRate: Double(fs) * 16 * 44_100, isDST: frameFormat == 0,
                        firstSector: first, lastSector: last, tracks: [], layout: layout)
        let copyrightOffset = Int(be16(data, 146))
        if copyrightOffset > 0 { area.copyright = string(data, at: copyrightOffset, charset: charset) }

        var starts: [Int?]?, durations: [Int?]?
        var texts: [Int: [UInt8: String]] = [:]
        var isrcs: [Int: String] = [:], genres: [Int: String] = [:]
        var sawText = false
        var p = sectorSize
        while p + sectorSize <= data.count {
            let id = String(decoding: data[p..<p + 8], as: UTF8.self)
            switch id {
            case "SACDTTxt":
                // One per language: the first is used.
                if !sawText {
                    sawText = true
                    for i in 0..<trackCount {
                        let position = Int(be16(data, p + 8 + 2 * i))
                        if position > 0 { texts[i] = trackText(data, at: p + position, charset: charset) }
                    }
                }
            case "SACD_IGL":
                for i in 0..<trackCount {
                    let o = p + 8 + 12 * i
                    if o + 12 <= data.count, let isrc = text(Array(data[o..<o + 12]), charset: 1), isrc.count == 12 { isrcs[i] = isrc }
                    let g = p + 8 + 255 * 12 + 4 + 4 * i
                    if g + 4 <= data.count, let name = genreName(data[g + 3]) { genres[i] = name }
                }
            case "SACDTRL2":
                starts = (0..<trackCount).map { timecode(data, p + 8 + 4 * $0) }
                durations = (0..<trackCount).map { timecode(data, p + 8 + 255 * 4 + 4 * $0) }
            default:
                break
            }
            p += sectorSize
        }
        // Every time code valid, the tracks in order, and the last one with a length.
        guard let starts = starts.map({ $0.compactMap { $0 } }), let durations = durations.map({ $0.compactMap { $0 } }),
              starts.count == trackCount, durations.count == trackCount,
              zip(starts, starts.dropFirst()).allSatisfy({ $0 < $1 }), durations[trackCount - 1] > 0
        else { throw SACDError.damaged("track times") }
        // The area's playing time, when it has one, bounds the last track.
        let total = timecode(data, 64) ?? 0
        for i in 0..<trackCount {
            // Up to the next track's start, so a pause between tracks stays with the one before it and the
            // tracks play on without a gap; the last track ends with its own duration.
            var end = i + 1 < trackCount ? starts[i + 1] : starts[i] + durations[i]
            if i + 1 == trackCount, total > starts[i] { end = min(end, total) }
            let length = end - starts[i]
            let t = texts[i] ?? [:]
            area.tracks.append(Track(number: i + 1, startFrame: starts[i], frameCount: length, title: t[0x01], performer: t[0x02],
                                     songwriter: t[0x03], composer: t[0x04], arranger: t[0x05], message: t[0x06],
                                     isrc: isrcs[i], genre: genres[i]))
        }
        guard !area.tracks.isEmpty else { throw SACDError.damaged("track list") }
        return area
    }

    /// One track's text items (title 0x01, performer 0x02, songwriter 0x03, composer 0x04, arranger 0x05, message 0x06).
    static func trackText(_ data: [UInt8], at start: Int, charset: UInt8) -> [UInt8: String] {
        guard start + 4 <= data.count else { return [:] }
        var out: [UInt8: String] = [:]
        let count = Int(data[start])
        var p = start + 4
        for j in 0..<count {
            guard p + 2 < data.count else { break }
            let type = data[p]
            p += 2
            let end = data[p...].firstIndex(of: 0) ?? data.count
            if end > p, out[type] == nil, let s = text(Array(data[p..<end]), charset: charset) { out[type] = s }
            p = end
            if j < count - 1 { while p < data.count, data[p] == 0 { p += 1 } }
        }
        return out
    }

    static func string(_ data: [UInt8], at position: Int, charset: UInt8) -> String? {
        guard position < data.count else { return nil }
        let end = data[position...].firstIndex(of: 0) ?? data.count
        return text(Array(data[position..<end]), charset: charset)
    }

    /// SACD text in the disc's character set: ISO 646 (1), ISO 8859-1 (2, 7), Music Shift-JIS (3), KS C 5601 (4),
    /// GB 2312 (5) or Big5 (6). Control characters (some discs have them) become spaces; padding is trimmed.
    static func text(_ bytes: [UInt8], charset: UInt8) -> String? {
        let bytes = Array(bytes.prefix { $0 != 0 })
        guard !bytes.isEmpty else { return nil }
        func cf(_ e: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
        }
        let encoding: String.Encoding = switch charset {
        case 2, 7: .isoLatin1
        case 3: .shiftJIS
        case 4: cf(.EUC_KR)
        case 5: cf(.EUC_CN)
        case 6: cf(.big5)
        default: .ascii
        }
        let decoded = String(bytes: bytes, encoding: encoding) ?? String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1)
        guard let decoded else { return nil }
        let cleaned = String(String.UnicodeScalarView(decoded.unicodeScalars.map { $0.value < 0x20 ? " " : $0 }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The Scarlet Book's genre list.
    static func genreName(_ code: UInt8) -> String? {
        let names = [
            nil, nil, "Adult Contemporary", "Alternative Rock", "Children's Music", "Classical", "Contemporary Christian",
            "Country", "Dance", "Easy Listening", "Erotic", "Folk", "Gospel", "Hip-Hop", "Jazz", "Latin", "Musical",
            "New Age", "Opera", "Operetta", "Pop", "Rap", "Reggae", "Rock", "R&B", "Sound Effects", "Soundtrack",
            "Spoken Word", "World Music", "Blues",
        ]
        return Int(code) < names.count ? names[Int(code)] : nil
    }

    /// minutes, seconds, frames → frames; nil for seconds or frames out of range (a damaged TOC).
    static func timecode(_ d: [UInt8], _ o: Int) -> Int? {
        guard o + 3 <= d.count, d[o + 1] < 60, Int(d[o + 2]) < framesPerSecond else { return nil }
        return (Int(d[o]) * 60 + Int(d[o + 1])) * framesPerSecond + Int(d[o + 2])
    }

    static func be16(_ d: [UInt8], _ o: Int) -> UInt16 { o + 2 <= d.count ? UInt16(d[o]) << 8 | UInt16(d[o + 1]) : 0 }
    static func be32(_ d: [UInt8], _ o: Int) -> UInt32 {
        o + 4 <= d.count ? UInt32(d[o]) << 24 | UInt32(d[o + 1]) << 16 | UInt32(d[o + 2]) << 8 | UInt32(d[o + 3]) : 0
    }
}
