//
// Vespertine — DTS / DTS-HD Master Audio and Dolby TrueHD files (.dts, .dtshd, .thd, .mlp, .mka), and the
// Dolby Digital modes macOS decodes wrongly (DolbyModes), decoded with FFmpeg.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import CVespertineDTS
import Foundation
import SFBAudioEngine

final class FFmpegDecoder: NSObject, PCMDecoding {
    static let extensions: Set<String> = ["dts", "dtshd", "thd", "mlp", "mka"]

    let url: URL
    private var handle: OpaquePointer?
    var rawHandle: OpaquePointer? { handle }
    private(set) var isOpen = false
    private var format: AVAudioFormat?

    init(url: URL) { self.url = url }
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
        let codec = String(cString: nff_codec(handle)), profile = String(cString: nff_profile(handle))
        let bits = Int(nff_bits(handle))
        var d = Description(codec: "DTS", lossless: false, bits: nil, channels: Int(nff_channels(handle)),
                            sampleRate: Double(nff_sample_rate(handle)), hasObjects: false)
        if codec == "ac3" || codec == "eac3" {
            d.codec = codec == "ac3" ? "Dolby Digital" : "Dolby Digital Plus"
        } else if codec == "truehd" || codec == "mlp" {
            d.lossless = true
            d.hasObjects = profile.localizedCaseInsensitiveContains("atmos")
            d.codec = d.hasObjects ? "Dolby Atmos (TrueHD)" : (codec == "mlp" ? "MLP Lossless" : "Dolby TrueHD")
        } else if profile.contains("DTS:X") || profile.contains("DTS-X") {
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
        if d.lossless { d.bits = bits > 0 ? bits : 24 }
        return d
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
    var length: AVAudioFramePosition { handle.map { nff_length($0) } ?? 0 }

    func open() throws {
        guard !isOpen else { return }
        var error = [CChar](repeating: 0, count: 256)
        guard let h = nff_open(url.path, &error, Int32(error.count)) else {
            throw DTSError.unsupported(String(cString: error))
        }
        handle = h
        format = DTSDecoder.format(rate: Double(nff_sample_rate(h)), channels: Int(nff_channels(h)), mask: nff_channel_mask(h))
        isOpen = true
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

/// DSD over PCM from the raw 1-bit stream (any DSD rate): 16 DSD bits per channel per frame, behind the
/// alternating 0x05 / 0xFA marker, as 24-bit samples (carried exactly in Float32). Positions are DoP frames.
final class RawDoPDecoder: NSObject, PCMDecoding {
    private let source: FFmpegDecoder
    private var handle: OpaquePointer? { source.rawHandle }
    private var frame: AVAudioFramePosition = 0
    /// 1 swaps which frames carry 0x05 and which 0xFA (see `nextMarker`).
    private var markerOffset: AVAudioFramePosition = 0
    private let format: AVAudioFormat
    /// The raw DSD read in, one plane of `planeBytes` per channel, owned here (FFmpeg writes through pointers into it).
    private var planes: UnsafeMutablePointer<UInt8>?
    private var planeBytes = 0

    /// The next frame's marker: 0 for 0x05, 1 for 0xFA. Set when this track continues another one in the same
    /// output buffer, so the markers keep alternating across the join: two 0x05 in a row make a DAC drop out of DSD.
    var nextMarker: AVAudioFramePosition {
        get { (frame + markerOffset) & 1 }
        set { markerOffset = (newValue - frame) & 1 }
    }

    init(url: URL) throws {
        source = FFmpegDecoder(url: url)
        try source.open()
        guard source.isDSD, let h = source.rawHandle else { throw DTSError.unsupported("not DSD") }
        let channels = Int(nff_channels(h)), carrier = source.dsdRate / 16
        let layout = channels <= 2 ? nil : ChannelLayouts.layout(channels: channels)
        let f: AVAudioFormat? = if let layout { AVAudioFormat(standardFormatWithSampleRate: carrier, channelLayout: layout) }
                                else { AVAudioFormat(standardFormatWithSampleRate: carrier, channels: AVAudioChannelCount(channels)) }
        guard let f else { throw DTSError.unsupported("DoP format") }
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
    var length: AVAudioFramePosition { source.length / 2 }
    func open() throws {}
    func close() throws { try source.close() }
    func decode(into buffer: AVAudioBuffer) throws {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        try decode(into: pcm, length: pcm.frameCapacity)
    }

    func decode(into buffer: AVAudioPCMBuffer, length: AVAudioFrameCount) throws {
        buffer.frameLength = 0
        guard let h = handle, let out = buffer.floatChannelData else { throw DTSError.decoding }
        let channels = Int(format.channelCount), want = Int(min(length, buffer.frameCapacity))
        if planes == nil || planeBytes < want * 2 {
            planes?.deallocate()
            planeBytes = max(want * 2, 2)
            planes = .allocate(capacity: planeBytes * channels)
        }
        guard let planes else { throw DTSError.decoding }
        var pointers: [UnsafeMutablePointer<UInt8>] = (0..<channels).map { planes + $0 * planeBytes }
        let got = pointers.withUnsafeMutableBufferPointer { nff_read_dsd(h, $0.baseAddress!, Int32(want * 2)) }
        guard got >= 0 else { throw DTSError.decoding }
        let frames = Int(got) / 2
        for c in 0..<channels {
            let src = planes + c * planeBytes
            for i in 0..<frames {
                let marker: UInt32 = (frame + markerOffset + AVAudioFramePosition(i)) & 1 == 0 ? 0x05 : 0xFA
                let word = marker << 16 | UInt32(src[2 * i]) << 8 | UInt32(src[2 * i + 1])
                out[c][i] = Float(Int32(bitPattern: word << 8)) / 2_147_483_648
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        frame += AVAudioFramePosition(frames)
    }

    func seek(to target: AVAudioFramePosition) throws {
        guard let h = handle, nff_seek_dsd(h, max(0, target) * 2) else { throw DTSError.decoding }
        frame = max(0, target)
    }
}
