//
// Vespertine: what a renderer says it can play (ConnectionManager GetProtocolInfo, its Sink list of
// `protocol:network:contentFormat:additionalInfo` entries), and the warnings Vespertine shows when a song goes beyond it.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

public struct ProtocolInfoEntry: Sendable, Hashable {
    public var proto: String
    public var network: String
    public var contentFormat: String
    public var additional: String
    /// The content format's MIME type, normalised (`audio/x-flac` is `audio/flac`, `audio/x-wav` is `audio/wav`…).
    public var mime: String
    /// `rate=` and `channels=` parameters, which renderers state for LPCM (`audio/L16`, `audio/L24`) if at all.
    public var rate: Int?
    public var channels: Int?

    public var protocolInfo: String { "\(proto):\(network):\(contentFormat):\(additional)" }
}

public enum MediaType {
    /// Spellings of one type that renderers use interchangeably, the first being the one Vespertine sends.
    static let aliases: [[String]] = [
        ["audio/flac", "audio/x-flac"],
        ["audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave"],
        ["audio/aiff", "audio/x-aiff"],
        ["audio/mp4", "audio/m4a", "audio/x-m4a"],
        ["audio/mpeg", "audio/mp3", "audio/x-mpeg"],
        ["audio/x-dsf", "audio/dsf", "audio/x-dsd"],
        ["audio/x-dff", "audio/dff"],
        ["audio/ogg", "application/ogg", "audio/x-ogg"],
        ["audio/x-ape", "audio/ape"],
        ["audio/x-wavpack", "audio/wavpack"],
    ]

    public static func normalise(_ mime: String) -> String {
        let base = mime.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return aliases.first { $0.contains(base) }?.first ?? base
    }

    public static func mime(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "flac": "audio/flac"
        case "wav", "wave": "audio/wav"
        case "aif", "aiff", "aifc": "audio/aiff"
        case "m4a", "mp4", "alac": "audio/mp4"
        case "mp3": "audio/mpeg"
        case "dsf": "audio/x-dsf"
        case "dff": "audio/x-dff"
        case "ogg", "oga", "opus": "audio/ogg"
        case "ape": "audio/x-ape"
        case "wv": "audio/x-wavpack"
        default: nil
        }
    }

    /// "FLAC", "WAV", … for a MIME type.
    public static func shortName(_ mime: String) -> String {
        switch normalise(mime) {
        case "audio/flac": "FLAC"
        case "audio/wav": "WAV"
        case "audio/aiff": "AIFF"
        case "audio/mp4": "MP4 (ALAC/AAC)"
        case "audio/mpeg": "MP3"
        case "audio/x-dsf": "DSF"
        case "audio/x-dff": "DSDIFF"
        case "audio/ogg": "Ogg"
        case "audio/x-ape": "APE"
        case "audio/x-wavpack": "WavPack"
        case "audio/l16": "LPCM 16-bit"
        case "audio/l24": "LPCM 24-bit"
        case let other: other
        }
    }
}

public enum CapabilityWarning: Sendable, Hashable {
    case formatNotAccepted(String)
    case rateAboveMaximum(source: Double, max: Int)
    case channelsAboveMaximum(source: Int, max: Int)

    public var message: String {
        switch self {
        case .formatNotAccepted(let name):
            String(localized: "The renderer doesn't list \(name) among the formats it plays.", comment: "%@ is a format name such as FLAC.")
        case .rateAboveMaximum(let source, let max):
            String(localized: "This song is \(SampleRate.format(source)) kHz; the renderer states up to \(SampleRate.format(Double(max))) kHz.")
        case .channelsAboveMaximum(let source, let max):
            String(localized: "This song has \(source) channels; the renderer states up to \(max).")
        }
    }
}

public struct RendererCapabilities: Sendable, Hashable {
    /// The http-get entries (the only protocol Vespertine serves).
    public var entries: [ProtocolInfoEntry]

    public init(entries: [ProtocolInfoEntry] = []) { self.entries = entries }

    public static func parse(sink: String) -> RendererCapabilities {
        let entries = sink.split(separator: ",").compactMap { raw -> ProtocolInfoEntry? in
            let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, parts[0].lowercased() == "http-get" else { return nil }
            let format = parts[2]
            var rate: Int?, channels: Int?
            for parameter in format.split(separator: ";").dropFirst() {
                let pair = parameter.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                guard pair.count == 2 else { continue }
                if pair[0] == "rate" { rate = Int(pair[1]) }
                if pair[0] == "channels" { channels = Int(pair[1]) }
            }
            return ProtocolInfoEntry(proto: "http-get", network: parts[1], contentFormat: format, additional: parts[3],
                                     mime: MediaType.normalise(format), rate: rate, channels: channels)
        }
        return RendererCapabilities(entries: entries)
    }

    public func accepts(mime: String) -> Bool {
        let wanted = MediaType.normalise(mime)
        return entries.contains { $0.mime == wanted || $0.mime == "*" || $0.mime == "audio/*" }
    }

    /// The highest rate the renderer states for any type; nil when it states none (most don't).
    public var maxSampleRate: Int? { entries.compactMap(\.rate).max() }
    public var maxChannels: Int? { entries.compactMap(\.channels).max() }

    /// The formats it lists, by short name, in the order listed, once each.
    public var acceptedFormats: [String] {
        var seen = Set<String>()
        return entries.map { MediaType.shortName($0.mime) }.filter { seen.insert($0).inserted }
    }

    /// What to warn about when `source` is sent as `mime`. Rate and channel limits count only where the renderer states
    /// them for that type: an LPCM limit says nothing about FLAC.
    public func warnings(for source: SourceFormat, sending mime: String) -> [CapabilityWarning] {
        guard accepts(mime: mime) else { return [.formatNotAccepted(MediaType.shortName(mime))] }
        let wanted = MediaType.normalise(mime)
        let same = entries.filter { $0.mime == wanted }
        var warnings: [CapabilityWarning] = []
        let rates = same.compactMap(\.rate)
        if rates.count == same.count, let max = rates.max(), source.encoding != .dsd, source.sampleRate > Double(max) + 0.5 {
            warnings.append(.rateAboveMaximum(source: source.sampleRate, max: max))
        }
        let channels = same.compactMap(\.channels)
        if channels.count == same.count, let max = channels.max(), source.channels > max {
            warnings.append(.channelsAboveMaximum(source: source.channels, max: max))
        }
        return warnings
    }
}
