//
// Vespertine: the stream channel (protocol 2): what a phone is told about a song it may play itself, the descriptor of an
// open stream, and the binary frame a ranged read is answered with.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//
// A phone asks `streamInfo` about songs, `streamOpen`s one (the Mac may need a while to convert it), then reads it in ranges
// with `streamRead`. A read is answered with a `StreamFrame`, not JSON: a message whose first byte is `StreamFrame.magic` (0x01)
// is a frame, one that starts with `{` is JSON. A version 1 phone never sends a stream command, so it never gets a frame.
//

import Foundation

/// What is sent for a song.
public enum StreamKind: String, Codable, Sendable, Equatable {
    /// The library file's own bytes, ranged.
    case original
    /// A FLAC the Mac made from the song (DSD, a format the phone can't decode, a CUE track, a multichannel file above the
    /// phone's rate), speakers and channel count kept.
    case flac
}

/// An audio format, as the phone needs to open it.
public struct StreamFormat: Codable, Sendable, Equatable {
    /// "FLAC", "ALAC", "AAC", "MP3", "PCM", "DSD"…
    public var codec: String
    /// The file extension to give the bytes so that Core Audio opens them: "flac", "m4a", "wav", "aiff", "caf", "mp3".
    public var container: String
    public var sampleRate: Double
    /// nil for lossy audio.
    public var bitDepth: Int?
    public var channels: Int
    /// The speaker of each channel, in the file's order, as Core Audio's `AudioChannelLabel` values (1 left, 2 right, 3 centre,
    /// 4 LFE, 5 left surround, 6 right surround…). nil: not known yet, or not told: the standard order for the channel count.
    /// The phone builds its channel layout from these rather than trusting the file's own tags.
    public var channelLabels: [UInt32]?
    public var lossless: Bool

    public init(codec: String, container: String, sampleRate: Double, bitDepth: Int?, channels: Int, channelLabels: [UInt32]?, lossless: Bool) {
        self.codec = codec
        self.container = container
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.channelLabels = channelLabels
        self.lossless = lossless
    }
}

/// How a song would be streamed.
public struct ReplayGain: Codable, Sendable, Equatable {
    public var trackGain: Double?
    public var trackPeak: Double?
    public var albumGain: Double?
    public var albumPeak: Double?

    public init(trackGain: Double?, trackPeak: Double?, albumGain: Double?, albumPeak: Double?) {
        self.trackGain = trackGain
        self.trackPeak = trackPeak
        self.albumGain = albumGain
        self.albumPeak = albumPeak
    }
}

public struct StreamInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: Int64
    public var streamable: Bool
    /// nil when `streamable` is false.
    public var kind: StreamKind?
    /// The library file.
    public var source: StreamFormat
    /// What arrives (nil when not streamable). For a conversion the layout is known only once it has been made.
    public var delivered: StreamFormat?
    /// Why this song plays on the Mac only, in a sentence for showing as it is.
    public var macOnlyReason: String?
    /// The file's size when `kind` is `.original`; a conversion's size is known when it is made (`StreamDescriptor`).
    public var byteSize: Int64?
    /// The length in sample frames of what arrives, for gapless joins.
    public var totalFrames: Int64?
    public var replayGain: ReplayGain?
    /// Encoder delay and end padding in frames, when the Mac knows them (nil: not known, treat as none).
    public var encoderDelay: Int?
    public var endPadding: Int?

    public init(id: Int64, streamable: Bool, kind: StreamKind?, source: StreamFormat, delivered: StreamFormat?, macOnlyReason: String?,
                byteSize: Int64?, totalFrames: Int64?, replayGain: ReplayGain?, encoderDelay: Int?, endPadding: Int?) {
        self.id = id
        self.streamable = streamable
        self.kind = kind
        self.source = source
        self.delivered = delivered
        self.macOnlyReason = macOnlyReason
        self.byteSize = byteSize
        self.totalFrames = totalFrames
        self.replayGain = replayGain
        self.encoderDelay = encoderDelay
        self.endPadding = endPadding
    }
}

/// An open stream: what the phone reads ranges of.
public struct StreamDescriptor: Codable, Sendable, Equatable {
    /// Its number on this connection, for `streamRead` and `streamClose`.
    public var stream: Int
    public var kind: StreamKind
    /// The size of the stream in bytes: reads are in 0..<byteSize.
    public var byteSize: Int64
    /// What the bytes are, with the speaker labels of the file as it is.
    public var format: StreamFormat
    /// Sample frames in the stream.
    public var frames: Int64?
    /// Changes whenever the bytes would (the file changed, another conversion setting): a phone that cached a stream keeps it
    /// only while the tag is the same.
    public var tag: String
    /// A good read size for this stream.
    public var chunkSize: Int
    /// For a `.flac` stream: the Mac only cut the song out of a longer lossless file (a CUE track), at the file's own rate
    /// and depth, so the samples are the file's own. nil from a Mac that doesn't say.
    public var cut: Bool?
    /// The phone asked for a smaller form to keep, and this is one: the Mac brought the rate down. nil from a Mac that
    /// doesn't say, and for a song that needed no reducing.
    public var reduced: Bool?

    public init(stream: Int, kind: StreamKind, byteSize: Int64, format: StreamFormat, frames: Int64?, tag: String, chunkSize: Int,
                cut: Bool? = nil, reduced: Bool? = nil) {
        self.cut = cut
        self.reduced = reduced
        self.stream = stream
        self.kind = kind
        self.byteSize = byteSize
        self.format = format
        self.frames = frames
        self.tag = tag
        self.chunkSize = chunkSize
    }
}

/// The answer to a `streamRead`: one range of an open stream's bytes.
///
/// ```
/// byte 0       0x01 (the magic: JSON messages start with '{')
/// bytes 1…4    the id of the `streamRead` this answers (UInt32)
/// bytes 5…8    the stream (UInt32)
/// bytes 9…16   the offset of the first payload byte (UInt64)
/// byte 17      flags: bit 0 = this range reaches the end of the stream
/// bytes 18…    the payload (empty past the end)
/// ```
/// Integers are big-endian.
public struct StreamFrame: Sendable, Equatable {
    public static let magic: UInt8 = 0x01
    public static let headerSize = 18
    private static let endFlag: UInt8 = 0b0000_0001

    public var request: Int
    public var stream: Int
    public var offset: Int64
    public var endOfStream: Bool
    public var payload: Data

    public init(request: Int, stream: Int, offset: Int64, endOfStream: Bool, payload: Data) {
        self.request = request
        self.stream = stream
        self.offset = offset
        self.endOfStream = endOfStream
        self.payload = payload
    }

    /// Whether a received message is a frame (and not JSON).
    public static func isFrame(_ message: Data) -> Bool {
        message.first == magic
    }

    public func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        out.append(Self.magic)
        Self.append(UInt64(truncatingIfNeeded: request), bytes: 4, to: &out)
        Self.append(UInt64(truncatingIfNeeded: stream), bytes: 4, to: &out)
        Self.append(UInt64(bitPattern: offset), bytes: 8, to: &out)
        out.append(endOfStream ? Self.endFlag : 0)
        out.append(payload)
        return out
    }

    /// nil for anything that isn't a frame of this version: too short, another first byte, a flag it doesn't know.
    public init?(decoding message: Data) {
        let bytes = Array(message.prefix(Self.headerSize))
        guard bytes.count == Self.headerSize, bytes[0] == Self.magic, bytes[17] & ~Self.endFlag == 0 else { return nil }
        func integer(_ range: Range<Int>) -> UInt64 { bytes[range].reduce(0) { $0 << 8 | UInt64($1) } }
        request = Int(integer(1..<5))
        stream = Int(integer(5..<9))
        offset = Int64(bitPattern: integer(9..<17))
        endOfStream = bytes[17] & Self.endFlag != 0
        payload = Data(message.dropFirst(Self.headerSize))
    }

    private static func append(_ value: UInt64, bytes count: Int, to data: inout Data) {
        for shift in stride(from: (count - 1) * 8, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift))) }
    }
}
