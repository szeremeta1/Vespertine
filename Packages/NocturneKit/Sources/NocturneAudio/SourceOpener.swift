//
// Nocturne — opens any supported file as a PCM decoder suited to an output plan.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import SFBAudioEngine

/// A playable file (or a region of one, for CUE sheets).
public struct PlayableItem: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let url: URL
    public let trackID: Int64?
    /// Region in source frames (CUE tracks). nil = whole file.
    public let regionStartFrame: Int64?
    public let regionFrameLength: Int64?
    /// ReplayGain adjustment the app decided on (dB), nil = none.
    public let replayGainDB: Double?
    /// Identifies a local copy of a network file (see the engine's urlResolver); nil = always open `url`.
    public let cacheKey: String?

    public init(id: UUID = UUID(), url: URL, trackID: Int64? = nil, regionStartFrame: Int64? = nil,
                regionFrameLength: Int64? = nil, replayGainDB: Double? = nil, cacheKey: String? = nil) {
        self.cacheKey = cacheKey
        self.id = id
        self.url = url
        self.trackID = trackID
        self.regionStartFrame = regionStartFrame
        self.regionFrameLength = regionFrameLength
        self.replayGainDB = replayGainDB
    }
}

public enum SourceOpenerError: Error, LocalizedError {
    case unsupported(URL)
    public var errorDescription: String? {
        switch self { case .unsupported(let url): "Unsupported file: \(url.lastPathComponent)" }
    }
}

/// Opened source before a plan is known.
final class ProbedSource: @unchecked Sendable {
    let url: URL
    let format: SourceFormat
    let decoderName: String
    fileprivate let pcm: PCMDecoding?
    fileprivate let dsd: DSDDecoding?

    fileprivate init(url: URL, format: SourceFormat, decoderName: String, pcm: PCMDecoding?, dsd: DSDDecoding?) {
        self.url = url
        self.format = format
        self.decoderName = decoderName
        self.pcm = pcm
        self.dsd = dsd
    }
}

private let mpegOpenLock = NSLock()

enum SourceOpener {
    static var supportedExtensions: Set<String> {
        AudioDecoder.supportedPathExtensions.union(DSDDecoder.supportedPathExtensions)
    }

    static func probe(_ url: URL) throws -> ProbedSource {
        let ext = url.pathExtension.lowercased()
        if DSDDecoder.handlesPaths(withExtension: ext) {
            let decoder = try DSDDecoder(url: url)
            try decoder.open()
            let asbd = decoder.processingFormat.streamDescription.pointee
            let format = SourceFormat(encoding: .dsd, codec: ext == "dff" ? "DSDIFF" : "DSF",
                                      sampleRate: asbd.mSampleRate, bitDepth: 1,
                                      channels: Int(asbd.mChannelsPerFrame))
            return ProbedSource(url: url, format: format, decoderName: "Native DSD reader", pcm: nil, dsd: decoder)
        }
        guard AudioDecoder.handlesPaths(withExtension: ext) || !ext.isEmpty else { throw SourceOpenerError.unsupported(url) }
        let decoder = try AudioDecoder(url: url)
        if String(describing: type(of: decoder)).contains("MPEG") {
            // mpg123's CPU-feature detection in mpg123_parnew isn't thread-safe: concurrent opens
            // crash in wrap_getcpuflags (seen with parallel library scans). Serialize opening only.
            try mpegOpenLock.withLock { try decoder.open() }
        } else {
            try decoder.open()
        }
        let processing = decoder.processingFormat.streamDescription.pointee
        let source = decoder.sourceFormat.streamDescription.pointee
        let lossless = decoder.decodingIsLossless
        var bits: Int? = nil
        if lossless {
            if source.mBitsPerChannel > 0 { bits = Int(source.mBitsPerChannel) }
            else if processing.mFormatFlags & kAudioFormatFlagIsFloat == 0 { bits = Int(processing.mBitsPerChannel) }
            else if processing.mFormatFlags & kAudioFormatFlagIsFloat != 0 { bits = Int(processing.mBitsPerChannel) }
            // ALAC reports its bit depth in the format flags.
            if source.mFormatID == kAudioFormatAppleLossless {
                switch source.mFormatFlags {
                case kAppleLosslessFormatFlag_16BitSourceData: bits = 16
                case kAppleLosslessFormatFlag_20BitSourceData: bits = 20
                case kAppleLosslessFormatFlag_24BitSourceData: bits = 24
                case kAppleLosslessFormatFlag_32BitSourceData: bits = 32
                default: break
                }
            }
        }
        let format = SourceFormat(encoding: lossless ? .pcm : .lossy,
                                  codec: codecName(ext: ext, formatID: source.mFormatID),
                                  sampleRate: processing.mSampleRate, bitDepth: bits,
                                  channels: Int(processing.mChannelsPerFrame))
        return ProbedSource(url: url, format: format, decoderName: decoderName(for: decoder), pcm: decoder, dsd: nil)
    }

    /// Wraps the probed decoder for the plan (DoP / DSD→PCM) and applies a CUE region.
    static func decoder(for probed: ProbedSource, plan: OutputPlan, item: PlayableItem) throws -> PCMDecoding {
        var decoder: PCMDecoding
        if let dsd = probed.dsd {
            if plan.mode == .dop {
                decoder = try DoPDecoder(decoder: dsd)
            } else {
                decoder = try DSDPCMDecoder(decoder: dsd)
            }
            try decoder.open()
        } else if let pcm = probed.pcm {
            decoder = pcm
        } else {
            throw SourceOpenerError.unsupported(probed.url)
        }
        if let start = item.regionStartFrame {
            let length = item.regionFrameLength ?? max(0, decoder.length - start)
            let region = try AudioRegionDecoder(decoder: decoder, startFrame: start, frameLength: length)
            try region.open()
            decoder = region
        }
        return decoder
    }

    static func codecName(ext: String, formatID: AudioFormatID) -> String {
        switch formatID {
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatAppleLossless: return "ALAC"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD: return "AAC"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatOpus: return "Opus"
        default: break
        }
        switch ext {
        case "flac", "oga": return "FLAC"
        case "wav", "wave", "w64", "rf64", "bwf": return "WAV"
        case "aif", "aiff", "aifc": return "AIFF"
        case "caf": return "CAF"
        case "ape": return "APE"
        case "wv": return "WavPack"
        case "mp3": return "MP3"
        case "m4a", "mp4", "m4b": return "AAC"
        case "ogg": return "Vorbis"
        case "opus": return "Opus"
        case "mpc": return "Musepack"
        case "tta": return "TTA"
        case "shn": return "Shorten"
        case "spx": return "Speex"
        default: return ext.uppercased()
        }
    }

    static func decoderName(for decoder: AnyObject) -> String {
        let name = String(describing: type(of: decoder))
        let table: [(String, String)] = [
            ("FLAC", "libFLAC"), ("CoreAudio", "Apple Core Audio"), ("WavPack", "WavPack"),
            ("MonkeysAudio", "Monkey's Audio SDK"), ("MPEG", "mpg123"), ("OggVorbis", "libvorbis"),
            ("OggOpus", "libopus"), ("OggSpeex", "libspeex"), ("Musepack", "libmpcdec"), ("TrueAudio", "TTA"),
            ("Libsndfile", "libsndfile"), ("Shorten", "Shorten"), ("Module", "DUMB"),
        ]
        return table.first { name.contains($0.0) }?.1 ?? name.replacingOccurrences(of: "SFB", with: "")
    }
}

/// Public, read-only inspection used by the library scanner.
public enum SourceInspector {
    public static var supportedExtensions: Set<String> { SourceOpener.supportedExtensions }

    /// Opens the file just far enough to learn its true format and decoder.
    public static func inspect(_ url: URL) throws -> (format: SourceFormat, decoderName: String) {
        let probed = try SourceOpener.probe(url)
        return (probed.format, probed.decoderName)
    }

    /// Format plus duration in seconds (from the decoder's frame/packet count).
    public static func inspectWithDuration(_ url: URL) throws -> (format: SourceFormat, duration: Double) {
        let probed = try SourceOpener.probe(url)
        var seconds = 0.0
        if let pcm = probed.pcm {
            let rate = pcm.processingFormat.sampleRate
            if rate > 0, pcm.length > 0 { seconds = Double(pcm.length) / rate }
        } else if let dsd = probed.dsd {
            // One DSD packet carries 8 one-bit frames per channel.
            let rate = dsd.processingFormat.sampleRate
            if rate > 0 { seconds = Double(dsd.count) * 8 / rate }
        }
        return (probed.format, seconds)
    }
}
