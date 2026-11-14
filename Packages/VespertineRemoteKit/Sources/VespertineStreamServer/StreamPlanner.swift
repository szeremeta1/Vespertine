//
// Vespertine: what the Mac sends for a song. Its own file when Core Audio on the phone opens it as it is; otherwise a FLAC
// the Mac makes, keeping every channel, the rate family and (up to the phone's ceiling) the rate.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//
// Pure rules, no files: the tests pin each one.
//

import Foundation
import VespertineRemoteProtocol

public struct StreamPlan: Sendable, Equatable {
    /// nil: this song plays on the Mac only (`macOnlyReason` says why).
    public var kind: StreamKind?
    public var delivered: StreamFormat?
    /// Set when `kind` is `.flac`.
    public var transcode: TranscodeRequest?
    public var macOnlyReason: String?
}

public enum StreamPlanner {
    /// Containers iOS opens (Core Audio): extension → the extension the phone should give the bytes.
    static let native: [String: String] = [
        "flac": "flac", "m4a": "m4a", "mp4": "m4a", "m4b": "m4a", "wav": "wav", "wave": "wav", "aiff": "aiff", "aif": "aiff",
        "aifc": "aiff", "caf": "caf", "mp3": "mp3",
    ]
    /// What the Mac's decoders open that the phone can't.
    static let macDecodable: Set<String> = [
        "dsf", "dff", "ape", "wv", "tta", "ogg", "oga", "opus", "spx", "wma", "mpc", "ofr", "shn", "mka", "mkv", "webm", "dts", "dtshd",
        "thd", "mlp", "ac3", "ec3", "eac3", "w64", "rf64", "iso", "ifo", "vob", "sacd",
    ]
    /// Codecs that live inside a container the phone opens (DTS in a WAV) and still need the Mac to decode them.
    static let macDecodedCodecs = ["DTS", "TRUEHD", "MLP"]
    /// FLAC's limit, and the most channels this channel carries.
    public static let maximumChannels = 8
    /// The highest rate a DSD conversion makes unless the phone allows more.
    public static let defaultDSDCeiling = 192_000.0

    /// `smaller`: the phone keeps this song and asked for less of it: a lossless file above `maxSampleRate` is converted down.
    public static func plan(_ facts: StreamSourceFacts, maxSampleRate: Double?, smaller: Bool = false) -> StreamPlan {
        let source = sourceFormat(facts)
        guard facts.channels >= 1, facts.channels <= maximumChannels else {
            return StreamPlan(kind: nil, delivered: nil, transcode: nil,
                              macOnlyReason: StreamWords.say(.tooManyChannels(facts.channels, most: maximumChannels)))
        }
        let ext = facts.fileExtension.lowercased()
        let nativeContainer = native[ext]
        let insideNeedsMac = macDecodedCodecs.contains { facts.codec.uppercased().contains($0) }
        let mustConvert = facts.needsMacDecoder || facts.isRegion || facts.isDSD || nativeContainer == nil || insideNeedsMac
        let tooDeep = ext == "flac" && (facts.bitDepth ?? 0) > 24
        let aboveRate = maxSampleRate.map { facts.sampleRate > $0 + 0.5 } == true
        let tooWide = facts.channels > 2 && aboveRate
        let tooBig = smaller && facts.isLossless && aboveRate

        if !mustConvert && !tooDeep && !tooWide && !tooBig, let container = nativeContainer {
            let delivered = StreamFormat(codec: source.codec, container: container, sampleRate: facts.sampleRate, bitDepth: facts.bitDepth,
                                         channels: facts.channels, channelLabels: nil, lossless: facts.isLossless)
            return StreamPlan(kind: .original, delivered: delivered, transcode: nil, macOnlyReason: nil)
        }
        guard facts.needsMacDecoder || facts.isRegion || nativeContainer != nil || macDecodable.contains(ext) else {
            return StreamPlan(kind: nil, delivered: nil, transcode: nil,
                              macOnlyReason: StreamWords.say(.cannotConvert(fileExtension: ext)))
        }
        let rate = targetRate(source: facts.sampleRate, isDSD: facts.isDSD, ceiling: maxSampleRate)
        let depth = (facts.bitDepth ?? 16) <= 16 && !facts.isDSD ? 16 : 24
        let request = TranscodeRequest(source: facts.url, sourceSize: facts.fileSize, sourceModified: facts.modifiedAt, regionKey: facts.regionKey,
                                       trackID: facts.id, sampleRate: rate, bitDepth: depth, channels: facts.channels)
        let delivered = StreamFormat(codec: "FLAC", container: "flac", sampleRate: rate, bitDepth: depth, channels: facts.channels,
                                     channelLabels: nil, lossless: facts.isLossless)
        return StreamPlan(kind: .flac, delivered: delivered, transcode: request, macOnlyReason: nil)
    }

    /// The rate of a conversion: the source's own rate (DSD: a PCM rate of its family), never raised, never above the phone's
    /// ceiling, and never below the family's base (44.1 or 48 kHz): 96 kHz sources go to 48 and 88.2 kHz ones to 44.1, so the
    /// phone's last resample is the only one.
    static func targetRate(source: Double, isDSD: Bool, ceiling: Double?) -> Double {
        let family = source.truncatingRemainder(dividingBy: 44_100) == 0 ? 44_100.0 : 48_000.0
        let reach = isDSD ? source / 8 : source
        let limit = min(reach, ceiling ?? (isDSD ? defaultDSDCeiling : reach))
        var rate = family
        while rate * 2 <= limit + 0.5 { rate *= 2 }
        return min(rate, max(reach, family)) // PCM below its own family base (8 kHz voice) stays as it is, below
    }

    /// What `streamInfo` says about a song.
    public static func info(for facts: StreamSourceFacts, maxSampleRate: Double?) -> StreamInfo {
        let plan = plan(facts, maxSampleRate: maxSampleRate)
        let rate = plan.delivered?.sampleRate ?? facts.sampleRate
        return StreamInfo(id: facts.id, streamable: plan.kind != nil, kind: plan.kind, source: sourceFormat(facts), delivered: plan.delivered,
                          macOnlyReason: plan.macOnlyReason, byteSize: plan.kind == .original ? facts.fileSize : nil,
                          totalFrames: plan.kind == nil ? nil : Int64((facts.duration * rate).rounded()), replayGain: facts.replayGain,
                          encoderDelay: nil, endPadding: nil)
    }

    static func sourceFormat(_ facts: StreamSourceFacts) -> StreamFormat {
        StreamFormat(codec: facts.isDSD ? "DSD" : facts.codec, container: native[facts.fileExtension.lowercased()] ?? facts.fileExtension.lowercased(),
                     sampleRate: facts.sampleRate, bitDepth: facts.bitDepth, channels: facts.channels, channelLabels: nil, lossless: facts.isLossless)
    }
}
