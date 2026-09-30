//
// Vespertine — opens any supported file as a PCM decoder suited to an output plan.
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
        var format = format
        if format.channelLabels == nil {
            format.channelLabels = ChannelLayouts.speakerLabels(pcm?.processingFormat.channelLayout ?? dsd?.processingFormat.channelLayout)
        }
        self.format = format
        self.decoderName = decoderName
        self.pcm = pcm
        self.dsd = dsd
    }
}

private let mpegOpenLock = NSLock()

enum SourceOpener {
    static var supportedExtensions: Set<String> {
        AudioDecoder.supportedPathExtensions.union(DSDDecoder.supportedPathExtensions).union(dolbyExtensions)
            .union(FFmpegDecoder.extensions)
    }

    /// Dolby Digital / Dolby Digital Plus elementary streams. macOS decodes them (licensed); the MP3
    /// decoder would otherwise claim `.ac3` by its extension.
    static let dolbyExtensions: Set<String> = ["ac3", "ec3", "eac3"]

    static func probe(_ url: URL) throws -> ProbedSource {
        let ext = url.pathExtension.lowercased()
        if FFmpegDecoder.dsdExtensions.contains(ext) {
            // DSD at any rate (DSF and DSDIFF): converted to PCM by FFmpeg, or sent as DoP from the raw stream.
            let decoder = FFmpegDecoder(url: url)
            try decoder.open()
            guard decoder.isDSD else { throw SourceOpenerError.unsupported(url) }
            let format = SourceFormat(encoding: .dsd, codec: ext == "dsf" ? "DSF" : "DSDIFF", sampleRate: decoder.dsdRate,
                                      bitDepth: 1, channels: Int(decoder.processingFormat.channelCount))
            return ProbedSource(url: url, format: format, decoderName: "DSD (FFmpeg)", pcm: decoder, dsd: nil)
        }
        if DSDDecoder.handlesPaths(withExtension: ext) {
            let decoder = try DSDDecoder(url: url)
            try decoder.open()
            let asbd = decoder.processingFormat.streamDescription.pointee
            let format = SourceFormat(encoding: .dsd, codec: ext == "dff" ? "DSDIFF" : "DSF",
                                      sampleRate: asbd.mSampleRate, bitDepth: 1,
                                      channels: Int(asbd.mChannelsPerFrame))
            return ProbedSource(url: url, format: format, decoderName: "Native DSD reader", pcm: nil, dsd: decoder)
        }
        if FFmpegDecoder.extensions.contains(ext) {
            // DTS / DTS-HD MA / Dolby TrueHD: FFmpeg.
            let decoder = FFmpegDecoder(url: url)
            try decoder.open()
            let d = decoder.describe
            let format = SourceFormat(encoding: d.lossless ? .pcm : .lossy, codec: d.codec, sampleRate: d.sampleRate,
                                      bitDepth: d.bits, channels: d.channels)
            // FFmpeg decodes the channel bed of Atmos-in-TrueHD and DTS:X; say so rather than imply the objects.
            let name: String = switch d.codec {
            case "Dolby Atmos (TrueHD)": "FFmpeg TrueHD · \(ChannelLayouts.name(channels: d.channels)) bed, objects not rendered"
            case "DTS:X": "FFmpeg DTS-HD · \(ChannelLayouts.name(channels: d.channels)) bed, objects not rendered"
            default: "FFmpeg \(d.codec)"
            }
            return ProbedSource(url: url, format: format, decoderName: name, pcm: decoder, dsd: nil)
        }
        if dolbyExtensions.contains(ext), let mode = DolbyModes.mode(of: url), DolbyModes.needsFFmpeg(mode) {
            // A Dolby Digital mode macOS's decoder scrambles (2/1, 3/0+LFE, 3/1+LFE): FFmpeg decodes it.
            let decoder = FFmpegDecoder(url: url)
            try decoder.open()
            let d = decoder.describe
            let format = SourceFormat(encoding: .lossy, codec: d.codec, sampleRate: d.sampleRate, bitDepth: nil, channels: d.channels)
            return ProbedSource(url: url, format: format, decoderName: "FFmpeg \(d.codec) · \(DolbyModes.name(mode)), which macOS decodes wrongly",
                                pcm: decoder, dsd: nil)
        }
        guard AudioDecoder.handlesPaths(withExtension: ext) || !ext.isEmpty else { throw SourceOpenerError.unsupported(url) }
        let raw = dolbyExtensions.contains(ext) ? try AudioDecoder(url: url, decoderName: .coreAudio) : try AudioDecoder(url: url)
        // Every call into the codec libraries goes through a guard: a damaged file is an error, not a crash.
        let decoder = GuardedDecoder(raw)
        if String(describing: type(of: raw)).contains("MPEG") {
            // mpg123's CPU-feature detection in mpg123_parnew isn't thread-safe: concurrent opens
            // crash in wrap_getcpuflags (seen with parallel library scans). Serialize opening only.
            try mpegOpenLock.withLock { try decoder.open() }
        } else {
            try decoder.open()
        }
        // A DTS CD / DTS-WAV: 16-bit stereo "PCM" that is really a DTS bitstream (noise if played as PCM).
        if DTSDecoder.carriesDTS(decoder) {
            let dts = DTSDecoder(carrier: decoder)
            try dts.open()
            let f = dts.processingFormat
            let format = SourceFormat(encoding: .lossy, codec: "DTS", sampleRate: f.sampleRate, bitDepth: nil,
                                      channels: Int(f.channelCount))
            return ProbedSource(url: url, format: format, decoderName: "FFmpeg DTS (DCA)", pcm: dts, dsd: nil)
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
        var codec = codecName(ext: ext, formatID: source.mFormatID)
        if source.mFormatID == kAudioFormatEnhancedAC3, DolbyAtmos.hasObjects(url) { codec = DolbyAtmos.codecName }
        let format = SourceFormat(encoding: lossless ? .pcm : .lossy,
                                  codec: codec,
                                  sampleRate: processing.mSampleRate, bitDepth: bits,
                                  channels: Int(processing.mChannelsPerFrame))
        return ProbedSource(url: url, format: format, decoderName: decoderName(for: raw), pcm: decoder, dsd: nil)
    }

    /// Wraps the probed decoder for the plan (DoP / DSD→PCM) and applies a CUE region.
    static func decoder(for probed: ProbedSource, plan: OutputPlan, item: PlayableItem) throws -> PCMDecoding {
        var decoder: PCMDecoding
        if plan.mode == .bitstream {
            // A receiver decodes: DTS CDs go out as stored; Dolby frames are wrapped in IEC 61937 bursts.
            if let dts = probed.pcm as? DTSDecoder {
                decoder = dts.carrier
                try decoder.seek(to: 0)
            } else {
                decoder = try BitstreamDecoder.open(url: probed.url)
            }
        } else if probed.format.encoding == .dsd, probed.pcm is FFmpegDecoder {
            // DSD at any rate: DoP from the raw stream, or FFmpeg's DSD→PCM conversion (at the DSD rate / 8).
            decoder = plan.mode == .dop ? try RawDoPDecoder(url: probed.url) : probed.pcm!
        } else if let dsd = probed.dsd {
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
            // A CUE track can't run past the audio actually there: the last track's length comes from
            // rounded durations and may overshoot the file by a few frames, which the region decoder refuses.
            let available = decoder.length > 0 ? max(0, decoder.length - start) : Int64.max
            let length = min(item.regionFrameLength ?? available, available)
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
        case kAudioFormatAC3: return "Dolby Digital"
        case kAudioFormatEnhancedAC3: return "Dolby Digital Plus"
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
    /// Formats with no tag container of their own (read from the decoder and the file name).
    public static var untaggedExtensions: Set<String> { SourceOpener.dolbyExtensions.union(FFmpegDecoder.extensions) }

    /// Whether this file can go to a receiver untouched: Dolby streams, and DTS CDs (the stored bitstream).
    public static func canBitstream(_ url: URL, codec: String) -> Bool {
        guard let kind = BitstreamFormat(codec: codec) else { return false }
        return kind != .dts || !FFmpegDecoder.extensions.contains(url.pathExtension.lowercased())
    }

    /// Container tags for files the tag reader doesn't know (Matroska …): title, artist, album, date, track.
    public static func containerTags(_ url: URL) -> [String: String] {
        guard FFmpegDecoder.extensions.contains(url.pathExtension.lowercased()) else { return [:] }
        let d = FFmpegDecoder(url: url)
        guard (try? d.open()) != nil else { return [:] }
        var out: [String: String] = [:]
        for key in ["title", "artist", "album_artist", "album", "date", "track", "disc", "genre", "composer"] {
            if let v = d.tag(key), !v.isEmpty { out[key] = v }
        }
        return out
    }

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

extension SourceInspector {
    /// Describes the decoder's channel layout (diagnostics).
    public static func probeLayout(_ url: URL) throws -> String {
        let probed = try SourceOpener.probe(url)
        guard let pcm = probed.pcm else { return "n/a (not PCM)" }
        guard let layout = pcm.processingFormat.channelLayout else { return "none (count only)" }
        let tag = layout.layoutTag
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
            return "descriptions \(layout.shortNames)"
        }
        return String(format: "tag 0x%08X (%d ch)", tag, Int(tag & 0xFFFF))
    }
}
