//
// Vespertine: what the Mac knows about a song it may stream, what converts it, and what a conversion returns.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import VespertineRemoteProtocol

/// A library song as the stream channel needs it. The Mac app fills it from its `Track`; a phone never sends any of it.
public struct StreamSourceFacts: Sendable, Equatable {
    public var id: Int64
    public var url: URL
    /// Lowercased, without the dot.
    public var fileExtension: String
    /// The library's codec name ("FLAC", "Apple Lossless", "DTS"…), for the few decisions that depend on what's inside a container.
    public var codec: String
    public var isDSD: Bool
    /// The music is lossless (not whether the container is).
    public var isLossless: Bool
    public var sampleRate: Double
    public var bitDepth: Int?
    public var channels: Int
    public var duration: Double
    public var fileSize: Int64
    public var modifiedAt: Date
    /// The song is a stretch of a bigger file (a CUE track, an SACD or DVD track): the file's bytes are the whole album.
    public var isRegion: Bool
    /// Only the Mac's own decoders open it (a disc image, a DVD-Video track).
    public var needsMacDecoder: Bool
    public var replayGain: ReplayGain?
    /// Tells a region apart in a cache key (the library's `location`, which ends in "#2" for the second CUE track).
    public var regionKey: String?

    public init(id: Int64, url: URL, fileExtension: String, codec: String, isDSD: Bool, isLossless: Bool, sampleRate: Double, bitDepth: Int?,
                channels: Int, duration: Double, fileSize: Int64, modifiedAt: Date, isRegion: Bool, needsMacDecoder: Bool,
                replayGain: ReplayGain?, regionKey: String? = nil) {
        self.id = id
        self.url = url
        self.fileExtension = fileExtension
        self.codec = codec
        self.isDSD = isDSD
        self.isLossless = isLossless
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.duration = duration
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.isRegion = isRegion
        self.needsMacDecoder = needsMacDecoder
        self.replayGain = replayGain
        self.regionKey = regionKey
    }
}

/// One conversion to FLAC: what to read and what to make.
public struct TranscodeRequest: Sendable, Equatable {
    public var source: URL
    public var sourceSize: Int64
    public var sourceModified: Date
    /// The CUE/SACD/DVD region, when the song is one (nil: the whole file).
    public var regionKey: String?
    /// The library song, for a converter that needs more than the file to open it.
    public var trackID: Int64?
    /// The FLAC's rate, depth and channel count. Channels are kept as the source has them: nothing is folded.
    public var sampleRate: Double
    public var bitDepth: Int
    public var channels: Int

    public init(source: URL, sourceSize: Int64, sourceModified: Date, regionKey: String?, trackID: Int64? = nil,
                sampleRate: Double, bitDepth: Int, channels: Int) {
        self.source = source
        self.sourceSize = sourceSize
        self.sourceModified = sourceModified
        self.regionKey = regionKey
        self.trackID = trackID
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
    }
}

public struct TranscodeResult: Sendable, Equatable {
    /// What was written, with the speaker of each channel in the FLAC's order.
    public var format: StreamFormat
    public var frames: Int64?

    public init(format: StreamFormat, frames: Int64?) {
        self.format = format
        self.frames = frames
    }
}

/// Why the Mac won't send something, before it is put into words.
public enum StreamRefusal: Sendable, Equatable {
    case notInLibrary
    case cannotStream
    case cannotReadNow
    case tooManyChannels(Int, most: Int)
    /// A kind of file the Mac's decoders can't turn into FLAC (`fileExtension` without the dot).
    case cannotConvert(fileExtension: String)
    case streamNotOpen
    case badRange
    case readFailed
    case streamingOff
    case olderPhone

    /// The sentence in English: what a phone is told unless the server says it in another language (`StreamWords.say`).
    public var english: String {
        switch self {
        case .notInLibrary: "That song isn’t in the Mac’s library."
        case .cannotStream: "This can’t be streamed."
        case .cannotReadNow: "The Mac can’t read this file right now."
        case .tooManyChannels(let channels, let most): "This has \(channels) channels; Vespertine streams up to \(most). It plays on the Mac."
        case .cannotConvert(let ext): "Vespertine on the Mac can’t convert this kind of file (.\(ext)) for the phone. It plays on the Mac."
        case .streamNotOpen: "That stream isn’t open."
        case .badRange: "That range isn’t valid."
        case .readFailed: "The Mac couldn’t read the file."
        case .streamingOff: "Streaming to phones is off on this Mac. Turn on Stream to Phones in Vespertine › Settings › Remote."
        case .olderPhone: "This Mac’s connection with the phone is the older kind, which can’t stream. Update Vespertine on the phone."
        }
    }
}

/// How a refusal is worded. The Mac's server sets `say` around each phone's command to answer in that phone's language;
/// left alone, a refusal is said in English.
public enum StreamWords {
    @TaskLocal public static var say: @Sendable (StreamRefusal) -> String = { $0.english }
}

/// A conversion that didn't work, in a sentence for the phone to show.
public struct TranscodeFailure: Error, Sendable, Equatable {
    public var message: String
    public init(message: String) { self.message = message }
}

/// The Mac's decoders, as the stream channel uses them. The app implements it over VespertineAudio.
public protocol StreamTranscoding: Sendable {
    /// Writes a FLAC of the request to `destination` (which doesn't exist yet), reporting 0…1 as it goes.
    func transcode(_ request: TranscodeRequest, to destination: URL, progress: @Sendable (Double) -> Void) async throws -> TranscodeResult
    /// The speakers of a multichannel original's channels (Core Audio `AudioChannelLabel` values, in the file's order), if the
    /// decoder knows them.
    func channelLabels(of facts: StreamSourceFacts) async -> [UInt32]?
}

public extension StreamTranscoding {
    func channelLabels(of facts: StreamSourceFacts) async -> [UInt32]? { nil }
}
