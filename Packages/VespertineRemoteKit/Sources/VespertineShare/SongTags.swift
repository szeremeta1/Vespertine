//
// Vespertine: what a song file says about itself (its tags, its format, its length, where its cover is), read with as
// few and as small reads as the file allows: a share is on the far side of a network, and a library has thousands of
// files. Covers the kinds of file the phone opens itself: FLAC, ALAC and AAC in MPEG-4, WAV, AIFF, MP3, and DSD in DSF and
// DSDIFF files (DSDFile.swift).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import VespertineRemoteProtocol

public struct SongTags: Codable, Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var genre: String?
    public var track: Int?
    public var disc: Int?
    public var year: Int?
    /// "FLAC", "ALAC", "AAC", "MP3", "WAV", "AIFF".
    public var codec: String
    public var sampleRate: Double
    /// nil for lossy audio.
    public var bitDepth: Int?
    public var channels: Int
    public var duration: Double
    /// Sample frames, when the file says.
    public var frames: Int64?
    /// Kilobits a second, for lossy audio.
    public var bitRate: Int?
    /// Where the embedded cover's bytes are in the file, when it has one.
    public var pictureOffset: Int64?
    public var pictureLength: Int?
    /// For a DSD file (DSF, DSDIFF): where its audio is. `sampleRate` is then the DSD rate and `bitDepth` 1.
    public var dsd: DSDLayout?
    /// The file's ReplayGain tags, when it has any. nil too in an index made before these were read.
    public var replayGain: ReplayGain?

    public var lossless: Bool { bitDepth != nil }

    public init(codec: String, sampleRate: Double, bitDepth: Int?, channels: Int, duration: Double, frames: Int64? = nil, bitRate: Int? = nil) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.duration = duration
        self.frames = frames
        self.bitRate = bitRate
    }
}

/// A file read a range at a time, remembering the last range so that small reads next to each other cost one.
final class FileWindow {
    let size: Int64
    private let fetch: (Int64, Int) throws -> Data
    private var start: Int64 = 0
    private var held: [UInt8] = []
    /// How much is read at once when little is asked for.
    private let stride: Int

    init(size: Int64, stride: Int = 64 << 10, fetch: @escaping (Int64, Int) throws -> Data) {
        self.size = size
        self.stride = stride
        self.fetch = fetch
    }

    /// `count` bytes at `offset`, or as many as the file has there.
    func bytes(_ offset: Int64, _ count: Int) throws -> [UInt8] {
        guard offset >= 0, offset < size, count > 0 else { return [] }
        let count = Int(min(Int64(count), size - offset))
        if offset >= start, offset + Int64(count) <= start + Int64(held.count) {
            let from = Int(offset - start)
            return Array(held[from..<(from + count)])
        }
        let wanted = Int(min(Int64(max(count, stride)), size - offset))
        let data = try fetch(offset, wanted)
        start = offset
        held = [UInt8](data)
        return Array(held.prefix(count))
    }
}

private func be16(_ b: [UInt8], _ at: Int) -> Int { at + 2 <= b.count ? Int(b[at]) << 8 | Int(b[at + 1]) : 0 }
private func be24(_ b: [UInt8], _ at: Int) -> Int { at + 3 <= b.count ? Int(b[at]) << 16 | Int(b[at + 1]) << 8 | Int(b[at + 2]) : 0 }
private func be32(_ b: [UInt8], _ at: Int) -> Int { at + 4 <= b.count ? Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3]) : 0 }
private func be64(_ b: [UInt8], _ at: Int) -> Int64 { at + 8 <= b.count ? Int64(be32(b, at)) << 32 | Int64(be32(b, at + 4)) : 0 }
private func le16(_ b: [UInt8], _ at: Int) -> Int { at + 2 <= b.count ? Int(b[at]) | Int(b[at + 1]) << 8 : 0 }
private func le32(_ b: [UInt8], _ at: Int) -> Int { at + 4 <= b.count ? Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24 : 0 }
private func le64(_ b: [UInt8], _ at: Int) -> Int64 { at + 8 <= b.count ? Int64(le32(b, at)) | Int64(le32(b, at + 4)) << 32 : 0 }
/// Four bytes as a name ("moov", "fmt ", "©nam": each byte a character).
private func tag(_ b: [UInt8], _ at: Int) -> String { at >= 0 && at + 4 <= b.count ? String(b[at..<(at + 4)].map { Character(Unicode.Scalar($0)) }) : "" }
private func syncsafe(_ b: [UInt8], _ at: Int) -> Int {
    at + 4 <= b.count ? Int(b[at] & 0x7f) << 21 | Int(b[at + 1] & 0x7f) << 14 | Int(b[at + 2] & 0x7f) << 7 | Int(b[at + 3] & 0x7f) : 0
}

private func clean(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    return trimmed.isEmpty ? nil : trimmed
}

/// "3", "3/12", "03" → 3.
private func leadingNumber(_ text: String?) -> Int? {
    guard let text else { return nil }
    let digits = text.trimmingCharacters(in: .whitespaces).prefix { $0.isASCII && $0.isNumber }
    guard let number = Int(digits), number > 0 else { return nil }
    return number
}

/// The year in "1997", "1997-05-02", "05/1997".
private func yearIn(_ text: String?) -> Int? {
    guard let text else { return nil }
    var run = ""
    for character in text + " " {
        if character.isASCII, character.isNumber {
            run.append(character)
        } else {
            if run.count == 4, let year = Int(run), (1000...2999).contains(year) { return year }
            run = ""
        }
    }
    return nil
}

/// The ReplayGain tags of a file as they are met, under whatever names its kind of tag gives them.
struct GainTags {
    var trackGain: Double?, trackPeak: Double?, albumGain: Double?, albumPeak: Double?

    /// "-6.20 dB", "+1.5", "0.988102": the number at the front.
    private static func number(_ text: String?) -> Double? {
        guard let text else { return nil }
        let front = text.trimmingCharacters(in: .whitespaces).prefix { $0.isASCII && ($0.isNumber || $0 == "-" || $0 == "+" || $0 == ".") }
        guard let value = Double(front), value.isFinite else { return nil }
        return value
    }

    /// Takes `value` if `name` is one of the four tags (any case). The first of each is the one kept.
    mutating func take(_ name: String, _ value: String?) {
        switch name.uppercased() {
        case "REPLAYGAIN_TRACK_GAIN": trackGain = trackGain ?? Self.number(value)
        case "REPLAYGAIN_TRACK_PEAK": trackPeak = trackPeak ?? Self.number(value)
        case "REPLAYGAIN_ALBUM_GAIN": albumGain = albumGain ?? Self.number(value)
        case "REPLAYGAIN_ALBUM_PEAK": albumPeak = albumPeak ?? Self.number(value)
        default: break
        }
    }

    var values: ReplayGain? {
        guard trackGain != nil || trackPeak != nil || albumGain != nil || albumPeak != nil else { return nil }
        return ReplayGain(trackGain: trackGain, trackPeak: trackPeak, albumGain: albumGain, albumPeak: albumPeak)
    }
}

public enum SongTagReader {
    /// The kinds of file the phone opens itself, by extension (lowercase).
    public static let playable: Set<String> = ["flac", "m4a", "mp4", "m4b", "wav", "wave", "aif", "aiff", "aifc", "mp3", "dsf", "dff"]
    /// Kinds of music file the phone can't open without the Mac converting them. (A DSD file in surround, or packed with
    /// DST, is another: `DSDLayout.playsHere`.)
    public static let needsTheMac: Set<String> = ["ape", "wv", "tta", "ogg", "oga", "opus", "wma", "dts", "thd", "mlp", "mka", "iso", "ac3", "ec3", "tak"]

    public static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    /// The tags of the file called `name`, `size` bytes long; nil when it isn't a file the phone can open (by its name,
    /// or by what it turns out to hold). `read` gives a range of it.
    public static func read(name: String, size: Int64, read: @escaping (Int64, Int) throws -> Data) throws -> SongTags? {
        let window = FileWindow(size: size, fetch: read)
        switch fileExtension(name) {
        case "flac": return try flac(window)
        case "m4a", "mp4", "m4b": return try mpeg4(window)
        case "wav", "wave": return try wave(window)
        case "aif", "aiff", "aifc": return try aiff(window)
        case "mp3": return try mp3(window)
        case "dsf": return try dsf(window)
        case "dff": return try dff(window)
        default: return nil
        }
    }

    // MARK: FLAC

    private static func flac(_ file: FileWindow) throws -> SongTags? {
        var at: Int64 = 0
        var head = try file.bytes(0, 10)
        if head.starts(with: Array("ID3".utf8)) {
            at = Int64(10 + syncsafe(head, 6))
            head = try file.bytes(at, 4)
        }
        guard head.starts(with: Array("fLaC".utf8)) else { return nil }
        at += 4
        var tags: SongTags?
        var comments: [UInt8] = []
        var picture: (Int64, Int)?
        for _ in 0..<128 {
            let header = try file.bytes(at, 4)
            guard header.count == 4 else { break }
            let kind = header[0] & 0x7f, length = be24(header, 1)
            switch kind {
            case 0:
                let info = try file.bytes(at + 4, 34)
                guard info.count >= 18 else { return nil }
                let rate = Int(info[10]) << 12 | Int(info[11]) << 4 | Int(info[12]) >> 4
                let channels = Int(info[12] >> 1 & 0x7) + 1
                let bits = (Int(info[12] & 1) << 4 | Int(info[13] >> 4)) + 1
                let frames = Int64(info[13] & 0xf) << 32 | Int64(be32(info, 14))
                guard rate > 0 else { return nil }
                tags = SongTags(codec: "FLAC", sampleRate: Double(rate), bitDepth: bits, channels: channels,
                                duration: Double(frames) / Double(rate), frames: frames > 0 ? frames : nil)
            case 4 where length <= 1 << 20:
                comments = try file.bytes(at + 4, length)
            case 6:
                // type, MIME, description, four numbers, then the picture.
                let start = try file.bytes(at + 4, min(length, 1024))
                let mime = be32(start, 4)
                let description = be32(start, 8 + mime)
                let lengthAt = 8 + mime + 4 + description + 16
                let count = be32(start, lengthAt)
                let front = be32(start, 0) == 3
                if lengthAt + 4 <= start.count, count > 0, lengthAt + 4 + count <= length, picture == nil || front {
                    picture = (at + 4 + Int64(lengthAt + 4), count)
                }
            default: break
            }
            at += Int64(4 + length)
            if header[0] & 0x80 != 0 { break }
        }
        guard var tags else { return nil }
        apply(vorbisComments: comments, to: &tags)
        if let picture {
            tags.pictureOffset = picture.0
            tags.pictureLength = picture.1
        }
        return tags
    }

    private static func apply(vorbisComments b: [UInt8], to tags: inout SongTags) {
        guard b.count >= 8 else { return }
        var at = 4 + le32(b, 0)
        let count = le32(b, at)
        at += 4
        var seen: [String: String] = [:]
        for _ in 0..<min(count, 4096) {
            let length = le32(b, at)
            at += 4
            guard length >= 0, at + length <= b.count else { break }
            let text = String(decoding: b[at..<(at + length)], as: UTF8.self)
            at += length
            guard let equals = text.firstIndex(of: "=") else { continue }
            let key = text[..<equals].uppercased()
            if seen[key] == nil, let value = clean(String(text[text.index(after: equals)...])) { seen[key] = value }
        }
        tags.title = seen["TITLE"]
        tags.artist = seen["ARTIST"]
        tags.albumArtist = seen["ALBUMARTIST"] ?? seen["ALBUM ARTIST"]
        tags.album = seen["ALBUM"]
        tags.genre = seen["GENRE"]
        tags.track = leadingNumber(seen["TRACKNUMBER"])
        tags.disc = leadingNumber(seen["DISCNUMBER"])
        tags.year = yearIn(seen["DATE"] ?? seen["YEAR"] ?? seen["ORIGINALDATE"])
        var gain = GainTags()
        for (key, value) in seen where key.hasPrefix("REPLAYGAIN_") { gain.take(key, value) }
        tags.replayGain = gain.values
    }

    // MARK: MPEG-4 (ALAC, AAC)

    /// The boxes directly inside `range` of `b`: each one's type and the range of its contents.
    private static func boxes(_ b: [UInt8], _ range: Range<Int>) -> [(type: String, body: Range<Int>)] {
        var out: [(String, Range<Int>)] = []
        var at = range.lowerBound
        while at + 8 <= range.upperBound {
            var size = be32(b, at)
            var header = 8
            if size == 1 {
                guard at + 16 <= range.upperBound else { break }
                size = Int(clamping: be64(b, at + 8))
                header = 16
            } else if size == 0 {
                size = range.upperBound - at
            }
            guard size >= header, at + size <= range.upperBound else { break }
            out.append((tag(b, at + 4), (at + header)..<(at + size)))
            at += size
        }
        return out
    }

    private static func mpeg4(_ file: FileWindow) throws -> SongTags? {
        // Find the `moov` box among the file's top boxes; it can be before the audio or after it.
        var at: Int64 = 0
        var moovAt: Int64 = -1, moovSize = 0
        var sawFileType = false
        for _ in 0..<64 {
            let header = try file.bytes(at, 16)
            guard header.count >= 8 else { break }
            var size = Int64(be32(header, 0))
            if size == 1 { size = be64(header, 8) } else if size == 0 { size = file.size - at }
            let type = tag(header, 4)
            if type == "ftyp" { sawFileType = true }
            guard size >= 8 else { break }
            if type == "moov" {
                moovAt = at
                moovSize = Int(clamping: size)
                break
            }
            at += size
        }
        guard sawFileType, moovAt >= 0, moovSize <= 64 << 20 else { return nil }
        let b = try file.bytes(moovAt, moovSize)
        guard b.count == moovSize else { return nil }

        var tags: SongTags?
        var metas: [Range<Int>] = []
        var movieDuration = 0.0
        for box in boxes(b, 8..<b.count) {
            switch box.type {
            case "mvhd":
                movieDuration = duration(b, box.body).seconds
            case "trak":
                guard tags == nil, let media = boxes(b, box.body).first(where: { $0.type == "mdia" }) else { continue }
                let inside = boxes(b, media.body)
                guard let handler = inside.first(where: { $0.type == "hdlr" }), tag(b, handler.body.lowerBound + 8) == "soun",
                      let stsd = inside.first(where: { $0.type == "minf" }).flatMap({ boxes(b, $0.body).first { $0.type == "stbl" } })
                        .flatMap({ boxes(b, $0.body).first { $0.type == "stsd" } }) else { continue }
                let length = inside.first { $0.type == "mdhd" }.map { duration(b, $0.body) }
                tags = soundEntry(b, stsd.body, length: length)
            case "udta":
                metas += boxes(b, box.body).filter { $0.type == "meta" }.map(\.body)
            case "meta":
                // QuickTime's own place for it: beside the tracks, not inside `udta`.
                metas.append(box.body)
            default: break
            }
        }
        guard var tags else { return nil }
        if tags.duration <= 0 { tags.duration = movieDuration }
        if tags.bitDepth == nil, tags.duration > 0 { tags.bitRate = Int((Double(file.size) * 8 / tags.duration / 1000).rounded()) }
        var gain = GainTags()
        var named: [(keys: [String], items: Range<Int>)] = []
        for meta in metas {
            let inside = metaBoxes(b, meta)
            guard let items = inside.first(where: { $0.type == "ilst" })?.body else { continue }
            if let keys = inside.first(where: { $0.type == "keys" }) {
                named.append((metadataKeys(b, keys.body), items))
            } else {
                apply(itemList: items, of: b, at: moovAt, to: &tags, gain: &gain)
            }
        }
        // Tags under QuickTime's own names fill in whatever the iTunes kind left unsaid.
        for list in named { apply(namedItems: list.items, keys: list.keys, of: b, at: moovAt, to: &tags, gain: &gain) }
        tags.replayGain = gain.values
        return tags
    }

    /// The boxes inside a `meta` box. MPEG-4 starts it with four bytes of version and flags; QuickTime's own files
    /// go straight to the first box, which is the handler.
    private static func metaBoxes(_ b: [UInt8], _ body: Range<Int>) -> [(type: String, body: Range<Int>)] {
        guard body.count >= 8 else { return [] }
        let plain = tag(b, body.lowerBound + 4) == "hdlr"
        return boxes(b, (plain ? body.lowerBound : body.lowerBound + 4)..<body.upperBound)
    }

    /// The iTunes kind of tags: each item's four-letter type says what it is.
    private static func apply(itemList items: Range<Int>, of b: [UInt8], at moovAt: Int64, to tags: inout SongTags, gain: inout GainTags) {
        for item in boxes(b, items) {
            guard let data = boxes(b, item.body).first(where: { $0.type == "data" }), data.body.count >= 8 else { continue }
            let payload = (data.body.lowerBound + 8)..<data.body.upperBound
            var text: String? { clean(String(decoding: b[payload], as: UTF8.self)) }
            switch item.type {
            case "\u{A9}nam": tags.title = text
            case "\u{A9}ART": tags.artist = text
            case "aART": tags.albumArtist = text
            case "\u{A9}alb": tags.album = text
            case "\u{A9}gen": tags.genre = text
            case "\u{A9}day": tags.year = yearIn(text)
            case "trkn": tags.track = be16(b, payload.lowerBound + 2) > 0 ? be16(b, payload.lowerBound + 2) : nil
            case "disk": tags.disc = be16(b, payload.lowerBound + 2) > 0 ? be16(b, payload.lowerBound + 2) : nil
            case "covr" where tags.pictureOffset == nil && !payload.isEmpty:
                tags.pictureOffset = moovAt + Int64(payload.lowerBound)
                tags.pictureLength = payload.count
            case "----":
                // A tag with a name of its own: the name is in a box beside the value, after four bytes of flags.
                guard let name = boxes(b, item.body).first(where: { $0.type == "name" }), name.body.count > 4 else { break }
                gain.take(String(decoding: b[(name.body.lowerBound + 4)..<name.body.upperBound], as: UTF8.self), text)
            default: break
            }
        }
    }

    /// A `keys` box: the names QuickTime metadata goes by, in lower case, in the order the items count them from 1.
    /// A name from a namespace other than `mdta` is left empty, and so matches nothing.
    private static func metadataKeys(_ b: [UInt8], _ body: Range<Int>) -> [String] {
        var names: [String] = []
        guard body.count >= 8 else { return names }
        let count = be32(b, body.lowerBound + 4)
        var at = body.lowerBound + 8
        for _ in 0..<min(count, 4096) {
            guard at + 8 <= body.upperBound else { break }
            let size = be32(b, at)
            guard size >= 8, at + size <= body.upperBound else { break }
            let isName = tag(b, at + 4) == "mdta"
            names.append(isName ? String(decoding: b[(at + 8)..<(at + size)], as: UTF8.self).lowercased() : "")
            at += size
        }
        return names
    }

    /// The value of a QuickTime metadata item as text: text as it is, a whole number as its digits.
    private static func namedValue(_ b: [UInt8], _ data: Range<Int>) -> String? {
        let payload = (data.lowerBound + 8)..<data.upperBound
        switch be32(b, data.lowerBound) & 0xFF_FFFF {
        case 1:
            return clean(String(decoding: b[payload], as: UTF8.self))
        case 2:
            var units: [UInt16] = []
            var at = payload.lowerBound
            while at + 2 <= payload.upperBound {
                units.append(UInt16(be16(b, at)))
                at += 2
            }
            return clean(String(decoding: units, as: UTF16.self))
        case 21, 22:
            guard (1...4).contains(payload.count) else { return nil }
            var value = 0
            for byte in b[payload] { value = value << 8 | Int(byte) }
            return String(value)
        default:
            return nil
        }
    }

    /// QuickTime's own kind of tags (FFmpeg's `-movflags use_metadata_tags`, and what Apple's apps write in movies):
    /// each item's type is a number, counting into `keys` from 1. Only what is still unknown is taken.
    private static func apply(namedItems items: Range<Int>, keys: [String], of b: [UInt8], at moovAt: Int64, to tags: inout SongTags, gain: inout GainTags) {
        for item in boxes(b, items) {
            var index = 0
            for scalar in item.type.unicodeScalars { index = index << 8 | Int(scalar.value) }
            guard index >= 1, index <= keys.count else { continue }
            guard let data = boxes(b, item.body).first(where: { $0.type == "data" }), data.body.count >= 8 else { continue }
            let key = keys[index - 1]
            if key == "com.apple.quicktime.artwork" {
                let kind = be32(b, data.body.lowerBound) & 0xFF_FFFF
                if tags.pictureOffset == nil, data.body.count > 8, kind == 13 || kind == 14 {
                    tags.pictureOffset = moovAt + Int64(data.body.lowerBound + 8)
                    tags.pictureLength = data.body.count - 8
                }
                continue
            }
            guard let text = namedValue(b, data.body) else { continue }
            switch key {
            case "title", "com.apple.quicktime.title", "com.apple.quicktime.displayname":
                tags.title = tags.title ?? text
            case "artist", "com.apple.quicktime.artist":
                tags.artist = tags.artist ?? text
            case "album_artist", "albumartist", "album artist":
                tags.albumArtist = tags.albumArtist ?? text
            case "album", "com.apple.quicktime.album":
                tags.album = tags.album ?? text
            case "genre", "com.apple.quicktime.genre":
                tags.genre = tags.genre ?? text
            case "date", "year", "originaldate", "com.apple.quicktime.year", "com.apple.quicktime.creationdate":
                tags.year = tags.year ?? yearIn(text)
            case "track", "tracknumber":
                tags.track = tags.track ?? leadingNumber(text)
            case "disc", "discnumber":
                tags.disc = tags.disc ?? leadingNumber(text)
            default:
                gain.take(key, text)
            }
        }
    }

    /// A `mvhd` or `mdhd` box: its time scale and its length.
    private static func duration(_ b: [UInt8], _ body: Range<Int>) -> (scale: Int, seconds: Double) {
        let at = body.lowerBound
        guard at < b.count else { return (0, 0) }
        let scale: Int, length: Int64
        if b[at] == 1 {
            scale = be32(b, at + 20)
            length = be64(b, at + 24)
        } else {
            scale = be32(b, at + 12)
            length = Int64(be32(b, at + 16))
        }
        return (scale, scale > 0 ? Double(length) / Double(scale) : 0)
    }

    /// The first entry of a `stsd` box, when it is ALAC or AAC.
    private static func soundEntry(_ b: [UInt8], _ body: Range<Int>, length: (scale: Int, seconds: Double)?) -> SongTags? {
        let entry = body.lowerBound + 8
        guard entry + 36 <= body.upperBound else { return nil }
        let end = min(body.upperBound, entry + be32(b, entry))
        let format = tag(b, entry + 4)
        let version = be16(b, entry + 16)
        var channels = be16(b, entry + 24)
        var rate = Double(be32(b, entry + 32)) / 65536
        let children = entry + 36 + (version == 1 ? 16 : version == 2 ? 36 : 0)
        switch format {
        case "alac":
            var depth = be16(b, entry + 26)
            if children < end, let config = boxes(b, children..<end).first(where: { $0.type == "alac" }), config.body.count >= 28 {
                let at = config.body.lowerBound + 4
                depth = Int(b[at + 5])
                channels = Int(b[at + 9])
                rate = Double(be32(b, at + 20))
            }
            guard rate > 0, channels > 0 else { return nil }
            let seconds = length?.seconds ?? 0
            return SongTags(codec: "ALAC", sampleRate: rate, bitDepth: depth, channels: channels, duration: seconds,
                            frames: seconds > 0 ? Int64((seconds * rate).rounded()) : nil)
        case "mp4a":
            // The 16.16 field can't hold a rate above 65535: the media's time scale is the rate then.
            if let scale = length?.scale, scale >= 8000 { rate = Double(scale) }
            guard rate > 0, channels > 0 else { return nil }
            return SongTags(codec: "AAC", sampleRate: rate, bitDepth: nil, channels: channels, duration: length?.seconds ?? 0)
        default:
            return nil
        }
    }

    // MARK: ID3v2

    struct ID3 {
        var title: String?, artist: String?, albumArtist: String?, album: String?, genre: String?
        var track: Int?, disc: Int?, year: Int?
        /// The cover's place in the tag's bytes.
        var picture: Range<Int>?
        var gain = GainTags()

        func apply(to tags: inout SongTags, tagOffset: Int64) {
            tags.title = title ?? tags.title
            tags.artist = artist ?? tags.artist
            tags.albumArtist = albumArtist ?? tags.albumArtist
            tags.album = album ?? tags.album
            tags.genre = genre ?? tags.genre
            tags.track = track ?? tags.track
            tags.disc = disc ?? tags.disc
            tags.year = year ?? tags.year
            tags.replayGain = gain.values ?? tags.replayGain
            if let picture {
                tags.pictureOffset = tagOffset + Int64(picture.lowerBound)
                tags.pictureLength = picture.count
            }
        }
    }

    /// The length of the ID3v2 tag that starts with these 10 bytes (header included), or 0 when they aren't one.
    static func id3Length(_ head: [UInt8]) -> Int {
        guard head.count >= 10, head.starts(with: Array("ID3".utf8)), head[3] != 0xff, head[4] != 0xff else { return 0 }
        return 10 + syncsafe(head, 6) + (head[5] & 0x10 != 0 ? 10 : 0)
    }

    private static func text(_ b: [UInt8], _ range: Range<Int>) -> String? {
        // Several values are separated by a null: the first is taken.
        clean(texts(b, range).first ?? "")
    }

    /// Every value of a text frame: they are separated by nulls. A frame the user named (TXXX) is its name, then its value.
    private static func texts(_ b: [UInt8], _ range: Range<Int>) -> [String] {
        guard let encoding = b[range].first else { return [] }
        let body = Array(b[(range.lowerBound + 1)..<range.upperBound])
        let whole: String
        switch encoding {
        case 1:
            let bigEndian = body.starts(with: [0xfe, 0xff])
            let units = Array(body.dropFirst(body.starts(with: [0xff, 0xfe]) || bigEndian ? 2 : 0))
            whole = bigEndian ? String(utf16LE: swapped(units)) : String(utf16LE: units)
        case 2: whole = String(utf16LE: swapped(body))
        case 3: whole = String(decoding: body, as: UTF8.self)
        default: whole = String(body.map { Character(Unicode.Scalar($0)) })
        }
        // In UTF-16 each value may start with its own byte order mark.
        return whole.split(separator: "\0", omittingEmptySubsequences: true).map { $0.replacingOccurrences(of: "\u{FEFF}", with: "") }
    }

    private static func swapped(_ b: [UInt8]) -> [UInt8] {
        var out = b
        var i = 0
        while i + 1 < out.count { out.swapAt(i, i + 1); i += 2 }
        return out
    }

    /// Reads a whole ID3v2 tag (its 10-byte header first).
    static func id3(_ b: [UInt8]) -> ID3? {
        guard id3Length(b) > 0 else { return nil }
        let major = Int(b[3])
        guard (2...4).contains(major) else { return nil }
        // A tag stored "unsynchronised" as a whole has bytes slipped in that move everything: its text can't be trusted to
        // be where the sizes say, so it is left alone rather than misread.
        if b[5] & 0x80 != 0, major < 4 { return nil }
        var at = 10
        let end = min(b.count, 10 + syncsafe(b, 6))
        if b[5] & 0x40 != 0 { at += major == 4 ? syncsafe(b, 10) : 4 + be32(b, 10) }
        var out = ID3()
        var front = false
        while at + (major == 2 ? 6 : 10) <= end, b[at] != 0 {
            let id: String, size: Int, header: Int
            if major == 2 {
                id = String(decoding: b[at..<(at + 3)], as: Unicode.ASCII.self)
                size = be24(b, at + 3)
                header = 6
            } else {
                id = tag(b, at)
                size = major == 4 ? syncsafe(b, at + 4) : be32(b, at + 4)
                header = 10
            }
            let body = (at + header)..<(at + header + size)
            guard size > 0, body.upperBound <= end else { break }
            switch id {
            case "TIT2", "TT2": out.title = text(b, body)
            case "TPE1", "TP1": out.artist = text(b, body)
            case "TPE2", "TP2": out.albumArtist = text(b, body)
            case "TALB", "TAL": out.album = text(b, body)
            case "TRCK", "TRK": out.track = leadingNumber(text(b, body))
            case "TPOS", "TPA": out.disc = leadingNumber(text(b, body))
            case "TYER", "TYE", "TDRC", "TDOR": out.year = out.year ?? yearIn(text(b, body))
            case "TCON", "TCO":
                // "(17)" and "17" are numbers into an old fixed list, not names: left out rather than shown as digits.
                if var genre = text(b, body), !genre.allSatisfy({ $0.isNumber || $0 == "(" || $0 == ")" }) {
                    if genre.hasPrefix("("), let close = genre.firstIndex(of: ")"), let named = clean(String(genre[genre.index(after: close)...])) { genre = named }
                    out.genre = genre
                }
            case "TXXX", "TXX":
                let parts = texts(b, body)
                if parts.count >= 2 { out.gain.take(parts[0], parts[1]) }
            case "APIC", "PIC":
                guard !front, let range = picture(b, body, old: major == 2) else { break }
                out.picture = range.range
                front = range.front
            default: break
            }
            at = body.upperBound
        }
        return out
    }

    /// The picture's bytes inside an APIC (or the older PIC) frame, and whether it is the front cover.
    private static func picture(_ b: [UInt8], _ body: Range<Int>, old: Bool) -> (range: Range<Int>, front: Bool)? {
        var at = body.lowerBound
        let encoding = b[at]
        at += 1
        if old {
            at += 3
        } else {
            while at < body.upperBound, b[at] != 0 { at += 1 }
            at += 1
        }
        guard at < body.upperBound else { return nil }
        let front = b[at] == 3
        at += 1
        // The description ends with one null, or two on an even place in UTF-16.
        if encoding == 1 || encoding == 2 {
            while at + 1 < body.upperBound, !(b[at] == 0 && b[at + 1] == 0) { at += 2 }
            at += 2
        } else {
            while at < body.upperBound, b[at] != 0 { at += 1 }
            at += 1
        }
        guard at < body.upperBound else { return nil }
        return (at..<body.upperBound, front)
    }

    // MARK: MP3

    private static func mp3(_ file: FileWindow) throws -> SongTags? {
        let head = try file.bytes(0, 10)
        let tagLength = id3Length(head)
        var id3Tags: ID3?
        if tagLength > 0, tagLength <= 16 << 20 { id3Tags = id3(try file.bytes(0, tagLength)) }

        // The first frame: a sync whose header makes sense and is followed by another where its length says.
        let audio = Int64(tagLength)
        let search = try file.bytes(audio, 128 << 10)
        var found: (at: Int, header: Frame)?
        var at = 0
        while at + 4 <= search.count {
            if search[at] == 0xff, search[at + 1] & 0xe0 == 0xe0, let frame = Frame(search, at) {
                let next = at + frame.length
                if next + 4 > search.count || (Frame(search, next).map { $0.sampleRate == frame.sampleRate } ?? false) {
                    found = (at, frame)
                    break
                }
            }
            at += 1
        }
        guard let found else { return nil }
        let frame = found.header
        let start = audio + Int64(found.at)
        let bytes = file.size - start
        var seconds = frame.bitRate > 0 ? Double(bytes) * 8 / Double(frame.bitRate * 1000) : 0
        var frames: Int64?
        // A variable bit rate file says how many frames it has in its first frame.
        let side = found.at + 4 + frame.sideInfo
        let mark = tag(search, side)
        if mark == "Xing" || mark == "Info", be32(search, side + 4) & 1 != 0 {
            frames = Int64(be32(search, side + 8)) * Int64(frame.samples)
        } else if tag(search, found.at + 36) == "VBRI" {
            frames = Int64(be32(search, found.at + 36 + 14)) * Int64(frame.samples)
        }
        if let frames, frames > 0 { seconds = Double(frames) / Double(frame.sampleRate) }
        guard seconds > 0 else { return nil }
        var tags = SongTags(codec: "MP3", sampleRate: Double(frame.sampleRate), bitDepth: nil, channels: frame.channels, duration: seconds,
                            bitRate: Int((Double(bytes) * 8 / seconds / 1000).rounded()))
        id3Tags?.apply(to: &tags, tagOffset: 0)
        return tags
    }

    /// An MPEG audio layer III frame header.
    private struct Frame {
        var sampleRate: Int
        var bitRate: Int
        var channels: Int
        var samples: Int
        var length: Int
        var sideInfo: Int

        init?(_ b: [UInt8], _ at: Int) {
            guard at + 4 <= b.count, b[at] == 0xff, b[at + 1] & 0xe0 == 0xe0 else { return nil }
            let version = Int(b[at + 1] >> 3 & 0x3), layer = Int(b[at + 1] >> 1 & 0x3)
            let bitRateIndex = Int(b[at + 2] >> 4), rateIndex = Int(b[at + 2] >> 2 & 0x3), padding = Int(b[at + 2] >> 1 & 1)
            guard version != 1, layer == 1, bitRateIndex != 0, bitRateIndex != 15, rateIndex != 3 else { return nil }
            let one = version == 3
            let rates = one ? [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320] : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
            bitRate = rates[bitRateIndex]
            sampleRate = [44100, 48000, 32000][rateIndex] >> (version == 3 ? 0 : version == 2 ? 1 : 2)
            channels = b[at + 3] >> 6 == 3 ? 1 : 2
            samples = one ? 1152 : 576
            length = (samples / 8 * bitRate * 1000) / sampleRate + padding
            sideInfo = one ? (channels == 1 ? 17 : 32) : (channels == 1 ? 9 : 17)
        }
    }

    // MARK: WAV

    private static func wave(_ file: FileWindow) throws -> SongTags? {
        let head = try file.bytes(0, 12)
        let form = tag(head, 0)
        guard form == "RIFF" || form == "RF64", tag(head, 8) == "WAVE" else { return nil }
        var at: Int64 = 12
        var format: (channels: Int, rate: Int, bits: Int, block: Int)?
        var dataSize: Int64 = -1, longData: Int64 = -1
        var info = ID3()
        var id3Tags: (ID3, Int64)?
        for _ in 0..<256 {
            let header = try file.bytes(at, 8)
            guard header.count == 8 else { break }
            let id = tag(header, 0)
            var size = Int64(UInt32(truncatingIfNeeded: le32(header, 4)))
            let body = at + 8
            switch id {
            case "ds64":
                longData = le64(try file.bytes(body, 28), 8)
            case "fmt ":
                let b = try file.bytes(body, Int(min(size, 40)))
                guard b.count >= 16 else { return nil }
                var kind = le16(b, 0)
                if kind == 0xfffe, b.count >= 26 { kind = le16(b, 24) }
                guard kind == 1 || kind == 3 else { return nil }
                format = (le16(b, 2), le32(b, 4), le16(b, 14), le16(b, 12))
            case "data":
                if size == 0xffff_ffff, longData >= 0 { size = longData }
                dataSize = min(size, file.size - body)
                size = dataSize
            case "LIST" where size <= 1 << 20:
                let b = try file.bytes(body, Int(size))
                guard tag(b, 0) == "INFO" else { break }
                var item = 4
                while item + 8 <= b.count {
                    let length = le32(b, item + 4)
                    guard length >= 0, item + 8 + length <= b.count else { break }
                    let value = clean(String(decoding: b[(item + 8)..<(item + 8 + length)], as: UTF8.self))
                    switch tag(b, item) {
                    case "INAM": info.title = value
                    case "IART": info.artist = value
                    case "IPRD": info.album = value
                    case "IGNR": info.genre = value
                    case "ICRD": info.year = yearIn(value)
                    case "ITRK", "IPRT": info.track = leadingNumber(value)
                    default: break
                    }
                    item += 8 + length + length % 2
                }
            case "id3 ", "ID3 ":
                if size <= 16 << 20, let parsed = id3(try file.bytes(body, Int(size))) { id3Tags = (parsed, body) }
            default: break
            }
            at = body + size + size % 2
            if at >= file.size { break }
        }
        guard let format, format.rate > 0, format.channels > 0, format.block > 0, dataSize > 0 else { return nil }
        let frames = dataSize / Int64(format.block)
        var tags = SongTags(codec: "WAV", sampleRate: Double(format.rate), bitDepth: format.bits, channels: format.channels,
                            duration: Double(frames) / Double(format.rate), frames: frames)
        info.apply(to: &tags, tagOffset: 0)
        id3Tags?.0.apply(to: &tags, tagOffset: id3Tags?.1 ?? 0)
        return tags
    }

    // MARK: AIFF

    private static func aiff(_ file: FileWindow) throws -> SongTags? {
        let head = try file.bytes(0, 12)
        let kind = tag(head, 8)
        guard tag(head, 0) == "FORM", kind == "AIFF" || kind == "AIFC" else { return nil }
        var at: Int64 = 12
        var tags: SongTags?
        var named = ID3()
        var id3Tags: (ID3, Int64)?
        for _ in 0..<256 {
            let header = try file.bytes(at, 8)
            guard header.count == 8 else { break }
            let size = Int64(UInt32(truncatingIfNeeded: be32(header, 4)))
            let body = at + 8
            switch tag(header, 0) {
            case "COMM":
                let b = try file.bytes(body, Int(min(size, 32)))
                guard b.count >= 18 else { return nil }
                // Only plain PCM: a compressed AIFF-C is something else.
                if kind == "AIFC", b.count >= 22, !["NONE", "sowt", "twos", "in24", "in32", "fl32", "FL32"].contains(tag(b, 18)) { return nil }
                let channels = be16(b, 0), frames = Int64(UInt32(truncatingIfNeeded: be32(b, 2))), bits = be16(b, 6)
                // The rate is an 80-bit float: a sign and exponent, then 64 bits of mantissa.
                let exponent = (Int(b[8] & 0x7f) << 8 | Int(b[9])) - 16383
                let mantissa = UInt64(bitPattern: be64(b, 10))
                let rate = Double(mantissa) * pow(2, Double(exponent - 63))
                guard channels > 0, rate > 0, rate.isFinite else { return nil }
                tags = SongTags(codec: "AIFF", sampleRate: rate, bitDepth: bits, channels: channels, duration: Double(frames) / rate, frames: frames)
            case "NAME" where size <= 4096:
                named.title = clean(String(decoding: try file.bytes(body, Int(size)), as: UTF8.self))
            case "AUTH" where size <= 4096:
                named.artist = clean(String(decoding: try file.bytes(body, Int(size)), as: UTF8.self))
            case "ID3 ", "id3 ":
                if size <= 16 << 20, let parsed = id3(try file.bytes(body, Int(size))) { id3Tags = (parsed, body) }
            default: break
            }
            at = body + size + size % 2
            if at >= file.size { break }
        }
        guard var tags else { return nil }
        named.apply(to: &tags, tagOffset: 0)
        id3Tags?.0.apply(to: &tags, tagOffset: id3Tags?.1 ?? 0)
        return tags
    }
}
