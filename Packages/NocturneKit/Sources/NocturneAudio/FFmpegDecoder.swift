//
// Nocturne — DTS / DTS-HD Master Audio and Dolby TrueHD files (.dts, .dtshd, .thd, .mlp, .mka),
// decoded with FFmpeg: formats macOS can't decode.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import CNocturneDTS
import Foundation
import SFBAudioEngine

final class FFmpegDecoder: NSObject, PCMDecoding {
    static let extensions: Set<String> = ["dts", "dtshd", "thd", "mlp", "mka"]

    let url: URL
    private var handle: OpaquePointer?
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
        var hasObjects: Bool         // DTS:X or Atmos objects (Nocturne plays the channel bed)
    }

    var describe: Description {
        guard let handle else { return Description(codec: "", lossless: false, bits: nil, channels: 0, sampleRate: 0, hasObjects: false) }
        let codec = String(cString: nff_codec(handle)), profile = String(cString: nff_profile(handle))
        let bits = Int(nff_bits(handle))
        var d = Description(codec: "DTS", lossless: false, bits: nil, channels: Int(nff_channels(handle)),
                            sampleRate: Double(nff_sample_rate(handle)), hasObjects: false)
        if codec == "truehd" || codec == "mlp" {
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
