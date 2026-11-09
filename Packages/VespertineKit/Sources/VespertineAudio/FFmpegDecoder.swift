//
// Vespertine — DTS / DTS-HD Master Audio and Dolby TrueHD files (.dts, .dtshd, .thd, .mlp), TAK, the audio of
// Matroska and WebM files (.mka, .mkv, .webm) whatever codec it is in, and the Dolby Digital modes macOS decodes
// wrongly (DolbyModes), decoded with FFmpeg.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import CVespertineDTS
import Foundation
import SFBAudioEngine

final class FFmpegDecoder: NSObject, PCMDecoding, ConcealingDecoder {
    static let extensions: Set<String> = ["dts", "dtshd", "thd", "mlp", "mka", "mkv", "webm", "tak"]

    let url: URL
    /// The container stream to read (an index in the file), or nil for the best audio stream.
    let stream: Int?
    private var handle: OpaquePointer?
    private var cacheEntry: NetworkPlaybackCache.Entry?
    var rawHandle: OpaquePointer? { handle }
    private(set) var isOpen = false
    private var format: AVAudioFormat?

    init(url: URL, stream: Int? = nil) { self.url = url; self.stream = stream }
    deinit { if let handle { nff_close(handle) } }

    /// What the file holds, for the library and the signal path.
    struct Description {
        var codec: String            // "DTS-HD Master Audio", "DTS:X", "Dolby TrueHD", "Dolby Atmos (TrueHD)", "DTS"
        var lossless: Bool
        var bits: Int?
        var channels: Int
        var sampleRate: Double
        var hasObjects: Bool         // DTS:X or Atmos objects (Vespertine plays the channel bed)
    }

    var describe: Description {
        guard let handle else { return Description(codec: "", lossless: false, bits: nil, channels: 0, sampleRate: 0, hasObjects: false) }
        var d = Self.describe(codec: String(cString: nff_codec(handle)), profile: String(cString: nff_profile(handle)),
                              bits: Int(nff_bits(handle)))
        d.channels = Int(nff_channels(handle))
        d.sampleRate = Double(nff_sample_rate(handle))
        return d
    }

    /// What FFmpeg's codec name and profile say the stream is. `channels` and `sampleRate` are left for the caller.
    static func describe(codec: String, profile: String, bits: Int) -> Description {
        var d = Description(codec: "DTS", lossless: false, bits: nil, channels: 0, sampleRate: 0, hasObjects: false)
        switch codec {
        case "ac3": d.codec = "Dolby Digital"
        case "eac3": d.codec = "Dolby Digital Plus"
        case "truehd", "mlp":
            d.lossless = true
            d.hasObjects = profile.localizedCaseInsensitiveContains("atmos")
            d.codec = d.hasObjects ? "Dolby Atmos (TrueHD)" : (codec == "mlp" ? "MLP Lossless" : "Dolby TrueHD")
        case "dca", "dts":
            if profile.contains("DTS:X") || profile.contains("DTS-X") {
                d.lossless = profile.contains("MA")
                d.hasObjects = true
                d.codec = "DTS:X"
            } else if profile.contains("MA") {
                d.lossless = true
                d.codec = "DTS-HD Master Audio"
            } else if profile.contains("HRA") || profile.contains("HR") {
                d.codec = "DTS-HD High Resolution"
            } else if profile.contains("Express") {
                d.codec = "DTS Express"
            }
        case "tak": (d.codec, d.lossless) = ("TAK", true)
        case "flac": (d.codec, d.lossless) = ("FLAC", true)
        case "alac": (d.codec, d.lossless) = ("ALAC", true)
        case "wavpack": (d.codec, d.lossless) = ("WavPack", true)
        case "ape": (d.codec, d.lossless) = ("APE", true)
        case "tta": (d.codec, d.lossless) = ("TTA", true)
        case "aac": d.codec = profile.hasPrefix("xHE-AAC") ? "xHE-AAC" : "AAC"
        case "mp3", "mp3float": d.codec = "MP3"
        case "vorbis": d.codec = "Vorbis"
        case "opus": d.codec = "Opus"
        case let pcm where pcm.hasPrefix("pcm_"): (d.codec, d.lossless) = ("PCM", true)
        default: d.codec = codec.uppercased()
        }
        if d.lossless { d.bits = bits > 0 ? bits : 24 }
        return d
    }

    /// Every audio stream of the file, in file order; [] when it can't be opened. Streams FFmpeg can't decode here are
    /// left out.
    static func audioStreams(in url: URL) -> [ContainerAudioStream] {
        let decoder = FFmpegDecoder(url: url)
        guard (try? decoder.open()) != nil, let handle = decoder.handle else { return [] }
        let capacity = 64
        var infos = [NFFStreamInfo](repeating: NFFStreamInfo(), count: capacity)
        let count = min(Int(nff_audio_streams(handle, &infos, Int32(capacity))), capacity)
        return infos.prefix(count).filter { $0.decodable != 0 }.map { info in
            func text<T>(_ field: T) -> String {
                withUnsafeBytes(of: field) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            }
            let d = describe(codec: text(info.codec), profile: text(info.profile), bits: Int(info.bits))
            let title = text(info.title), language = text(info.language)
            return ContainerAudioStream(index: Int(info.index), codec: d.codec, channels: Int(info.channels), sampleRate: Double(info.sampleRate),
                               bits: d.bits, title: title.isEmpty ? nil : title, language: language.isEmpty ? nil : language,
                               isDefault: info.isDefault != 0, lossless: d.lossless)
        }
    }

    /// Tags from the container (Matroska tags, …).
    func tag(_ key: String) -> String? {
        guard let handle, let v = nff_tag(handle, key) else { return nil }
        return String(cString: v)
    }

    var inputSource: InputSource { (try? InputSource(for: url)) ?? InputSource(data: Data()) }
    var sourceFormat: AVAudioFormat { processingFormat }
    var processingFormat: AVAudioFormat { format ?? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)! }
    var decodingIsLossless: Bool { describe.lossless }
    var properties: [AudioDecodingPropertiesKey: Any] { [:] }
    var supportsSeeking: Bool { true }
    var position: AVAudioFramePosition { handle.map { nff_position($0) } ?? 0 }
    /// Damaged frames FFmpeg's decoder skipped: the audio around them plays, but not as the file was made.
    var concealedFrames: Int { handle.map { Int(nff_concealed($0)) } ?? 0 }
    var length: AVAudioFramePosition { handle.map { nff_length($0) } ?? 0 }

    func open() throws {
        guard !isOpen else { return }
        var error = [CChar](repeating: 0, count: 256)
        cacheEntry = NetworkPlaybackCache.lookup(url)
        let opened: OpaquePointer?
        if let entry = cacheEntry, !entry.isComplete {
            opened = nff_open_cached_stream(url.path, Int32(stream ?? -1), Unmanaged.passUnretained(entry).toOpaque(), entry.size, { opaque, offset, buffer, count in
                let entry = Unmanaged<NetworkPlaybackCache.Entry>.fromOpaque(opaque).takeUnretainedValue()
                do {
                    let data = try entry.read(at: offset, count: Int(count))
                    data.copyBytes(to: buffer, count: data.count)
                    return Int32(data.count)
                } catch { return -1 }
            }, &error, Int32(error.count))
        } else {
            opened = nff_open_stream(url.path, Int32(stream ?? -1), &error, Int32(error.count))
        }
        guard let h = opened else {
            throw DTSError.unsupported(String(cString: error))
        }
        handle = h
        format = DTSDecoder.format(rate: Double(nff_sample_rate(h)), channels: Int(nff_channels(h)), mask: nff_channel_mask(h))
        isOpen = true
    }

    /// Names the channels from the file's own header, where FFmpeg's reader gets them wrong (DSF, DSDIFF).
    func relabel(_ layout: AVAudioChannelLayout) {
        guard let format, layout.channelCount == format.channelCount else { return }
        self.format = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channelLayout: layout)
    }

    func close() throws {
        if let handle { nff_close(handle) }
        handle = nil
        isOpen = false
    }

    func decode(into buffer: AVAudioBuffer) throws {
        guard let pcm = buffer as? AVAudioPCMBuffer else { throw DTSError.decoding }
        try decode(into: pcm, length: pcm.frameCapacity)
    }

    func decode(into buffer: AVAudioPCMBuffer, length: AVAudioFrameCount) throws {
        buffer.frameLength = 0
        guard let handle, let planes = buffer.floatChannelData else { throw DTSError.decoding }
        let want = Int32(min(length, buffer.frameCapacity))
        var pointers = (0..<Int(nff_channels(handle))).map { planes[$0] }
        let n = pointers.withUnsafeMutableBufferPointer { nff_read(handle, $0.baseAddress!, want) }
        if n < 0 { throw DTSError.decoding }
        buffer.frameLength = AVAudioFrameCount(n)
    }

    func seek(to frame: AVAudioFramePosition) throws {
        guard let handle, nff_seek(handle, frame) else { throw DTSError.decoding }
    }
}

extension FFmpegDecoder {
    /// DSF / DSDIFF: DSD at any rate (DSD64 to DSD1024), converted to PCM by FFmpeg (at the DSD rate / 8).
    static let dsdExtensions: Set<String> = ["dsf", "dff", "dsdiff"]

    var isDSD: Bool { handle.map { nff_is_dsd($0) } ?? false }
    /// The DSD bit rate (FFmpeg reports bytes per second per channel).
    var dsdRate: Double { handle.map { Double(nff_sample_rate($0)) * 8 } ?? 0 }
}

/// Raw DSD for DoP: one plane per channel, most significant bit first in time. Positions are bytes per channel.
protocol RawDSDSource: AnyObject {
    var channelCount: Int { get }
    var dsdRate: Double { get }
    /// Bytes per channel.
    var dsdLength: Int64 { get }
    var isOpen: Bool { get }
    var inputSource: InputSource { get }
    /// Reads up to `bytes` bytes per channel into `planes`. Returns how many, 0 at the end.
    func readDSD(into planes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>>, bytes: Int) throws -> Int
    func seekDSD(to position: Int64) throws
    func close() throws
    /// Frames replaced by silence because they were damaged (0 for sources that never conceal).
    var concealedFrames: Int { get }
}

extension RawDSDSource {
    var concealedFrames: Int { 0 }
}

/// A decoder that can play damaged stretches of its file as silence, and counts how many frames it has.
protocol ConcealingDecoder: AnyObject {
    var concealedFrames: Int { get }
}

/// DSF and DSDIFF files, read raw through FFmpeg's demuxers.
extension FFmpegDecoder: RawDSDSource {
    var channelCount: Int { rawHandle.map { Int(nff_channels($0)) } ?? 0 }
    var dsdLength: Int64 { length }

    func readDSD(into planes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>>, bytes: Int) throws -> Int {
        guard let h = rawHandle else { throw DTSError.decoding }
        let got = nff_read_dsd(h, planes, Int32(bytes))
        guard got >= 0 else { throw DTSError.decoding }
        return Int(got)
    }

    func seekDSD(to position: Int64) throws {
        guard let h = rawHandle, nff_seek_dsd(h, position) else { throw DTSError.decoding }
    }
}

/// DSD over PCM from the raw 1-bit stream (any DSD rate): 16 DSD bits per channel per frame, behind the
/// alternating 0x05 / 0xFA marker, as 24-bit samples (carried exactly in Float32). Positions are DoP frames.
/// An odd last byte per channel at the end of the track is padded with DSD silence (`DoP.silence`) into a last
/// whole frame rather than dropped.
final class RawDoPDecoder: NSObject, PCMDecoding, ConcealingDecoder {
    private let source: RawDSDSource
    private var frame: AVAudioFramePosition = 0
    /// 1 swaps which frames carry 0x05 and which 0xFA (see `nextMarker`).
    private var markerOffset: AVAudioFramePosition = 0
    private let format: AVAudioFormat
    /// The raw DSD read in, one plane of `planeBytes` per channel, owned here (the source writes through pointers into it).
    private var planes: UnsafeMutablePointer<UInt8>?
    private var planeBytes = 0

    /// The next frame's marker: 0 for 0x05, 1 for 0xFA. Set when this track continues another one in the same
    /// output buffer, so the markers keep alternating across the join: two 0x05 in a row make a DAC drop out of DSD.
    var nextMarker: AVAudioFramePosition {
        get { (frame + markerOffset) & 1 }
        set { markerOffset = (newValue - frame) & 1 }
    }

    /// A DSF or DSDIFF file; `channelLayout` names its channels (by default, the standard layout for their count).
    convenience init(url: URL, channelLayout: AVAudioChannelLayout? = nil) throws {
        let source = FFmpegDecoder(url: url)
        try source.open()
        guard source.isDSD else { throw DTSError.unsupported(String(localized: "not DSD", comment: "Why a file can't be played, in “This file can't be played (…).”")) }
        try self.init(source: source, channelLayout: channelLayout)
    }

    init(source: RawDSDSource, channelLayout: AVAudioChannelLayout? = nil) throws {
        self.source = source
        let channels = source.channelCount, carrier = source.dsdRate / 16
        let layout = channelLayout ?? (channels <= 2 ? nil : ChannelLayouts.layout(channels: channels))
        let f: AVAudioFormat? = if let layout { AVAudioFormat(standardFormatWithSampleRate: carrier, channelLayout: layout) }
                                else { AVAudioFormat(standardFormatWithSampleRate: carrier, channels: AVAudioChannelCount(channels)) }
        guard let f else { throw DTSError.unsupported(String(localized: "DoP format", comment: "Why a file can't be played, in “This file can't be played (…).”")) }
        format = f
    }

    deinit { planes?.deallocate() }

    var inputSource: InputSource { source.inputSource }
    var sourceFormat: AVAudioFormat { format }
    var processingFormat: AVAudioFormat { format }
    var decodingIsLossless: Bool { true }
    var properties: [AudioDecodingPropertiesKey: Any] { [:] }
    var isOpen: Bool { source.isOpen }
    var supportsSeeking: Bool { true }
    var position: AVAudioFramePosition { frame }
    var length: AVAudioFramePosition { (source.dsdLength + 1) / 2 }
    var concealedFrames: Int { source.concealedFrames }
    func open() throws {}
    func close() throws { try source.close() }
    func decode(into buffer: AVAudioBuffer) throws {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        try decode(into: pcm, length: pcm.frameCapacity)
    }

    func decode(into buffer: AVAudioPCMBuffer, length: AVAudioFrameCount) throws {
        buffer.frameLength = 0
        guard let out = buffer.floatChannelData else { throw DTSError.decoding }
        let channels = Int(format.channelCount), want = Int(min(length, buffer.frameCapacity))
        if planes == nil || planeBytes < want * 2 {
            planes?.deallocate()
            planeBytes = max(want * 2, 2)
            planes = .allocate(capacity: planeBytes * channels)
        }
        guard let planes else { throw DTSError.decoding }
        guard want > 0 else { return }
        // Whole frames only: a read that ends on half a frame reads on, and the end of the track on half a frame is
        // padded with DSD silence.
        var bytes = 0, end = false
        while bytes < want * 2 {
            var pointers: [UnsafeMutablePointer<UInt8>] = (0..<channels).map { planes + $0 * planeBytes + bytes }
            let got = try pointers.withUnsafeMutableBufferPointer { try source.readDSD(into: $0.baseAddress!, bytes: want * 2 - bytes) }
            bytes += got
            if got == 0 { end = true; break }
            if bytes % 2 == 0 { break }
        }
        if bytes % 2 == 1, end {
            for c in 0..<channels { planes[c * planeBytes + bytes] = DoP.silence }
            bytes += 1
        }
        let frames = bytes / 2
        for c in 0..<channels {
            let src = planes + c * planeBytes
            for i in 0..<frames {
                let word = DoP.word(marker: Int(frame + markerOffset) + i, src[2 * i], src[2 * i + 1])
                out[c][i] = Float(Int32(bitPattern: word << 8)) / 2_147_483_648
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        frame += AVAudioFramePosition(frames)
    }

    func seek(to target: AVAudioFramePosition) throws {
        try source.seekDSD(to: max(0, target) * 2)
        frame = max(0, target)
    }
}

/// One audio stream of a container (Matroska, WebM), as a stream picker lists it.
public struct ContainerAudioStream: Sendable, Hashable {
    /// The stream's index in the file: what `PlayableItem.audioStream` takes.
    public var index: Int
    public var codec: String
    public var channels: Int
    public var sampleRate: Double
    public var bits: Int?
    public var title: String?
    public var language: String?
    public var isDefault: Bool
    public var lossless: Bool

    public init(index: Int, codec: String, channels: Int, sampleRate: Double, bits: Int?, title: String?, language: String?,
                isDefault: Bool, lossless: Bool) {
        self.index = index; self.codec = codec; self.channels = channels; self.sampleRate = sampleRate; self.bits = bits
        self.title = title; self.language = language; self.isDefault = isDefault; self.lossless = lossless
    }
}

/// A library track that is one audio stream of a container with several: its location is "<path>#audio-<index>".
public struct AudioStreamRef: Sendable, Hashable {
    public let index: Int
    public init(index: Int) { self.index = index }
    public init?(location: String) {
        guard let hash = location.lastIndex(of: "#"), location[location.index(after: hash)...].hasPrefix("audio-"),
              let index = Int(location[location.index(hash, offsetBy: 7)...]), index >= 0 else { return nil }
        self.index = index
    }
    public static func location(path: String, index: Int) -> String { "\(path)#audio-\(index)" }
}

extension SourceInspector {
    /// The audio streams of a Matroska or WebM file (and any other FFmpeg container), when it has more than one to choose from.
    public static func audioStreams(in url: URL) -> [ContainerAudioStream] { FFmpegDecoder.audioStreams(in: url) }
}
