//
// Vespertine: kinds of file the phone opens with a decoder library (APE, WavPack, Ogg Vorbis, Opus) rather than iOS's
// own. This module only says what a decoder is; the app brings the decoders (VespertineDecoders), so this stays plain
// Foundation. A decoded song reaches the player as a file that is never stored: a CAF header, then the samples, each
// range of it decoded when it is asked for.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

/// What a decoder found in a file.
public struct DecodedInfo: Equatable, Sendable {
    /// "APE", "WavPack", "Vorbis", "Opus".
    public var codec: String
    public var sampleRate: Double
    public var channels: Int
    /// The file's bit depth; nil for lossy audio.
    public var bitDepth: Int?
    /// How the samples are given: whole numbers of this many bytes (1 to 4), or 0 for 32-bit floating point.
    public var sampleBytes: Int
    public var frames: Int64
    /// The file's tags by lowercase name, as the format names them ("title", "artist", "album artist", "tracknumber"…).
    public var text: [String: String]

    public init(codec: String, sampleRate: Double, channels: Int, bitDepth: Int?, sampleBytes: Int, frames: Int64, text: [String: String] = [:]) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth
        self.sampleBytes = sampleBytes
        self.frames = frames
        self.text = text
    }

    /// The phone plays this itself: mono or stereo, with samples to play.
    public var playsHere: Bool { (1...2).contains(channels) && sampleRate > 0 && frames > 0 && (0...4).contains(sampleBytes) }
}

/// One open file being decoded. Used from one thread at a time.
public protocol ShareDecoder: AnyObject {
    var info: DecodedInfo { get }
    /// `count` frames from `frame`, the channels in turn, big-endian: whole numbers of `info.sampleBytes` bytes, or 32-bit
    /// floats. Fewer only at the end of the file. The same frames are the same bytes however the reads are cut up.
    func read(frame: Int64, count: Int) throws -> Data
}

public enum DecoderOpening {
    case opened(any ShareDecoder)
    /// A file of this kind that only the Mac plays (WavPack holding DSD, more than two channels).
    case needsTheMac
    /// Not a file of the kind its name says, or damaged.
    case unreadable
}

/// The decoders the app has, by file extension.
public protocol ShareDecoders: Sendable {
    /// Lowercase extensions: "ape", "wv", "ogg", "oga", "opus".
    var extensions: Set<String> { get }
    /// Opens a file of `size` bytes whose name ends in `type`. `read` gives a range of it; an error it throws is thrown
    /// from here (and from the decoder's reads) as it is.
    func open(type: String, size: Int64, read: @escaping (Int64, Int) throws -> Data) throws -> DecoderOpening
}

/// A decoded song as the player reads it: a CAF file of PCM.
public struct DecodedRendering: Equatable, Sendable {
    public var sampleRate: Double
    public var channels: Int
    /// Bytes of one sample: 1 to 4 for whole numbers, 4 for floats.
    public var sampleBytes: Int
    public var float: Bool
    public var frames: Int64

    public init(_ info: DecodedInfo) {
        sampleRate = info.sampleRate
        channels = info.channels
        float = info.sampleBytes == 0
        sampleBytes = float ? 4 : info.sampleBytes
        frames = info.frames
    }

    public var frameBytes: Int { channels * sampleBytes }
    public var byteSize: Int64 { Int64(CAFHeader.size) + frames * Int64(frameBytes) }
    public var header: [UInt8] { CAFHeader.bytes(sampleRate: sampleRate, channels: channels, sampleBytes: sampleBytes, float: float, frames: frames) }

    /// Up to `length` bytes of the file from `offset`; fewer only at its end.
    public func read(offset: Int64, length: Int, decoder: any ShareDecoder) throws -> Data {
        guard offset >= 0, offset < byteSize, length > 0 else { return Data() }
        let end = min(byteSize, offset + Int64(length))
        var out = Data(capacity: Int(end - offset))
        let head = Int64(CAFHeader.size)
        if offset < head { out.append(contentsOf: header[Int(offset)..<Int(min(end, head))]) }
        guard end > head else { return out }
        let size = Int64(frameBytes)
        let from = max(offset, head) - head, to = end - head
        let first = from / size, last = (to + size - 1) / size
        var samples = try decoder.read(frame: first, count: Int(last - first))
        // A file that ends before it said it would: silence for the rest, so the file is the size it was said to be.
        let wanted = Int(last - first) * frameBytes
        if samples.count < wanted { samples.append(Data(count: wanted - samples.count)) }
        let skip = Int(from - first * size)
        out.append(samples.subdata(in: (samples.startIndex + skip)..<(samples.startIndex + skip + Int(to - from))))
        return out
    }
}

/// The header of a CAF file of big-endian PCM. CAF, because its sizes are 64-bit.
public enum CAFHeader {
    public static let size = 68

    public static func bytes(sampleRate: Double, channels: Int, sampleBytes: Int, float: Bool, frames: Int64) -> [UInt8] {
        var out: [UInt8] = []
        func put(_ value: UInt64, _ count: Int) { for shift in stride(from: (count - 1) * 8, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: value >> UInt64(shift))) } }
        out += Array("caff".utf8)
        put(1, 2)                                   // file version
        put(0, 2)                                   // file flags
        out += Array("desc".utf8)
        put(32, 8)
        put(sampleRate.bitPattern, 8)
        out += Array("lpcm".utf8)
        put(float ? 1 : 0, 4)                       // format flags: floating point or whole numbers, big-endian
        put(UInt64(channels * sampleBytes), 4)      // bytes per packet
        put(1, 4)                                   // frames per packet
        put(UInt64(channels), 4)
        put(UInt64(sampleBytes * 8), 4)             // bits per channel
        out += Array("data".utf8)
        put(UInt64(4 + frames * Int64(channels * sampleBytes)), 8)
        put(0, 4)                                   // edit count
        return out
    }
}

extension SongTagReader {
    /// A decoded file's tags.
    static func tags(_ info: DecodedInfo, size: Int64) -> SongTags {
        let seconds = Double(info.frames) / info.sampleRate
        var tags = SongTags(codec: info.codec, sampleRate: info.sampleRate, bitDepth: info.bitDepth, channels: info.channels, duration: seconds, frames: info.frames,
                            bitRate: info.bitDepth == nil && seconds > 0 ? Int((Double(size) * 8 / seconds / 1000).rounded()) : nil)
        func first(_ names: String...) -> String? {
            for name in names {
                if let value = info.text[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
            }
            return nil
        }
        func number(_ text: String?) -> Int? {
            guard let text else { return nil }
            let digits = text.prefix { $0.isNumber }
            guard let value = Int(digits), value > 0 else { return nil }
            return value
        }
        tags.title = first("title")
        tags.artist = first("artist")
        tags.albumArtist = first("albumartist", "album artist")
        tags.album = first("album")
        tags.genre = first("genre")
        tags.track = number(first("tracknumber", "track"))
        tags.disc = number(first("discnumber", "disc"))
        if let date = first("date", "year"), let year = date.split(whereSeparator: { !$0.isNumber }).first(where: { $0.count == 4 }).flatMap({ Int($0) }) { tags.year = year }
        return tags
    }
}
