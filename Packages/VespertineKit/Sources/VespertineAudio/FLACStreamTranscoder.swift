//
// Vespertine: lossless FLAC for "Play on this phone": whatever the Mac can decode (DSD, APE, WavPack, a CUE track, DTS, a disc
// image…) written as FLAC for the phone to play, with every channel kept and the speaker of each named.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Mac's own decoders do the work (the same `SourceOpener` the player uses). DSD goes to PCM at the decoder's rate and is then
// brought to the rate asked for with Core Audio's mastering-grade converter. PCM at the rate and depth asked for is written
// through untouched: the samples that come out are the samples that went in. Channels stay in the decoder's order, and `labels`
// says which speaker each is.
//

import Accelerate
import AVFAudio
import Foundation
import SFBAudioEngine

public enum FLACStreamTranscoder {
    public struct Result: Sendable, Equatable {
        public var sampleRate: Double
        public var bitDepth: Int
        public var channels: Int
        /// The speaker of each channel (Core Audio `AudioChannelLabel` values), in the order the channels are written.
        public var labels: [UInt32]
        /// Sample frames written.
        public var frames: Int64
    }

    public enum Failure: LocalizedError, Equatable {
        case unsupported(String)
        case cancelled
        case encoder(String)

        public var errorDescription: String? {
            switch self {
            case .unsupported(let why): String(localized: "Can’t convert this for the phone: \(why).", comment: "Stream to phone: the reason is a short phrase.")
            case .cancelled: String(localized: "The conversion was cancelled.", comment: "Stream to phone.")
            case .encoder(let why): String(localized: "The FLAC encoder stopped: \(why)", comment: "Stream to phone: the reason is the encoder's own message.")
            }
        }
    }

    /// Writes `item` to `destination` as FLAC at `sampleRate` and `bitDepth` (16 or 24), keeping every channel (1…8). `destination`
    /// must not exist; it is removed again if the conversion fails or is cancelled. `progress` receives 0…1.
    @discardableResult
    public static func transcode(_ item: PlayableItem, sampleRate target: Double, bitDepth: Int, to destination: URL,
                                 progress: ((Double) -> Void)? = nil, isCancelled: (() -> Bool)? = nil) throws -> Result {
        guard bitDepth == 16 || bitDepth == 24 else { throw Failure.unsupported("\(bitDepth)-bit") }
        guard target >= 8_000, target <= 655_000 else { throw Failure.unsupported("a rate of \(Int(target)) Hz") }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw Failure.unsupported("\(destination.lastPathComponent) already exists") }

        let probed = try SourceOpener.probe(item.url, area: item.sacdArea, dvd: item.dvd, audioStream: item.audioStream)
        let format = probed.format
        guard format.channels >= 1, format.channels <= 8 else { throw Failure.unsupported("\(format.channels) channels") }
        let isDSD = format.encoding == .dsd
        let decodedRate = isDSD ? FormatPlanner.dsdToPCMRate(format.sampleRate) : format.sampleRate
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: decodedRate, decodedSampleRate: decodedRate, physicalBitDepth: 24,
                              channels: format.channels, dsdConvertedToPCM: isDSD, reason: "")
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: item)
        let inFormat = decoder.processingFormat
        let channels = Int(inFormat.channelCount)
        let labels: [AudioChannelLabel] = ChannelLayouts.speakerLabels(inFormat.channelLayout)
            ?? ChannelLayouts.layout(channels: channels)?.channelLabels ?? (0..<channels).map { AudioChannelLabel(kAudioChannelLabel_Discrete_0) + AudioChannelLabel($0) }

        // The float32 audio at the target rate, in the decoder's own channel order.
        guard let floatFormat = AudioFormats.float32(sampleRate: target, channels: channels, interleaved: false, layout: inFormat.channelLayout) else {
            throw Failure.unsupported("\(channels) channels")
        }
        let direct = inFormat.commonFormat == .pcmFormatFloat32 && !inFormat.isInterleaved && abs(inFormat.sampleRate - target) < 0.5
        let converter: AVAudioConverter?
        if direct {
            converter = nil
        } else {
            guard let made = AVAudioConverter(from: inFormat, to: floatFormat) else { throw Failure.unsupported("no converter for \(channels) channels") }
            if abs(inFormat.sampleRate - target) > 0.5 {
                made.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
                made.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            }
            converter = made
        }
        // Dither only where the samples are re-quantized to 16 bits: a rate change, or a source of more than 16 bits (or float).
        let requantized = abs(inFormat.sampleRate - target) > 0.5 || isDSD || (format.bitDepth ?? 32) > bitDepth
        let dither = bitDepth == 16 && requantized

        // The encoder's own integer format for this depth (a 24-bit sample sits in the top of a 32-bit word).
        var asbd = AudioStreamBasicDescription(mSampleRate: target, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh,
                                               mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
                                               mChannelsPerFrame: UInt32(channels), mBitsPerChannel: UInt32(bitDepth), mReserved: 0)
        guard let sourceFormat = AVAudioFormat(streamDescription: &asbd, channelLayout: channels > 2 ? ChannelLayouts.layout(channels: channels) : nil)
                ?? AVAudioFormat(streamDescription: &asbd) else { throw Failure.unsupported("\(bitDepth)-bit, \(channels) channels") }

        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: destination) } }
        let encoder: AudioEncoder
        do {
            encoder = try AudioEncoder(url: destination, encoderName: .FLAC)
            try encoder.setSourceFormat(sourceFormat)
            // Somebody is waiting to hear this: a lighter FLAC setting encodes noticeably quicker for a file a few percent
            // bigger. Lossless either way; the samples are the same.
            encoder.settings = [.flacCompressionLevel: 2]
            encoder.estimatedFramesToEncode = Int64((Double(decoder.length) * target / inFormat.sampleRate).rounded())
            try encoder.openReturningError()
        } catch {
            throw Failure.encoder(error.localizedDescription)
        }
        let chunk: AVAudioFrameCount = 16_384
        guard let encoding = AVAudioPCMBuffer(pcmFormat: encoder.processingFormat, frameCapacity: chunk),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk),
              let floats = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: chunk) else { throw Failure.unsupported("buffers") }

        let scale = Float(1 << (bitDepth - 1)), top = scale - 1, shift = Int32(32 - bitDepth)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func noise() -> Float {   // TPDF dither of ±1 LSB at the target depth
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let a = Float(seed >> 40) / Float(1 << 24), b = Float((seed >> 8) & 0xFF_FFFF) / Float(1 << 24)
            return a - b
        }
        var written: Int64 = 0
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: Int(chunk))
        defer { scratch.deallocate() }
        func encode(_ buffer: AVAudioPCMBuffer) throws {
            let n = Int(buffer.frameLength)
            guard n > 0, n <= Int(chunk), let planes = buffer.floatChannelData, let raw = encoding.audioBufferList.pointee.mBuffers.mData else { return }
            let out = raw.bindMemory(to: Int32.self, capacity: n * channels)
            if dither {
                for frame in 0..<n {
                    for channel in 0..<channels {
                        let x = planes[channel][frame] * scale + noise()
                        out[frame * channels + channel] = Int32(max(-scale, min(top, x.rounded()))) << shift
                    }
                }
            } else {
                // Without dither each sample is scaled, limited and rounded on its own: done a whole channel at a time, which
                // is several times quicker than one sample at a time and gives the same integers for integer sources.
                var gain = scale, low = -scale, high = top
                for channel in 0..<channels {
                    vDSP_vsmul(planes[channel], 1, &gain, scratch, 1, vDSP_Length(n))
                    vDSP_vclip(scratch, 1, &low, &high, scratch, 1, vDSP_Length(n))
                    vDSP_vfixr32(scratch, 1, out + channel, vDSP_Stride(channels), vDSP_Length(n))
                }
                if shift > 0 { for index in 0..<(n * channels) { out[index] <<= shift } }
            }
            encoding.frameLength = AVAudioFrameCount(n)
            do { try encoder.encode(from: encoding, length: AVAudioFrameCount(n)) } catch { throw Failure.encoder(error.localizedDescription) }
            written += Int64(n)
        }

        let total = max(1, Double(decoder.length))
        var decoded = 0.0
        func decodeChunk(_ into: AVAudioPCMBuffer, _ wanted: AVAudioFrameCount) throws {
            into.frameLength = 0
            do { try decoder.decode(into: into, length: min(wanted, into.frameCapacity)) } catch { throw Failure.unsupported(error.localizedDescription) }
            decoded += Double(into.frameLength)
            progress?(min(1, decoded / total))
        }
        if let converter {
            var finishedInput = false
            while !finishedInput {
                if isCancelled?() == true { throw Failure.cancelled }
                floats.frameLength = 0
                var failure: Error?
                var convertError: NSError?
                let status = converter.convert(to: floats, error: &convertError) { requested, inputStatus in
                    do { try decodeChunk(input, requested) } catch { failure = error; inputStatus.pointee = .endOfStream; return nil }
                    if input.frameLength == 0 { inputStatus.pointee = .endOfStream; return nil }
                    inputStatus.pointee = .haveData
                    return input
                }
                if let failure { throw failure }
                if let convertError { throw Failure.unsupported(convertError.localizedDescription) }
                try encode(floats)
                finishedInput = status == .endOfStream || status == .error || floats.frameLength == 0
            }
        } else {
            while true {
                if isCancelled?() == true { throw Failure.cancelled }
                try decodeChunk(input, chunk)
                if input.frameLength == 0 { break }
                try encode(input)
            }
        }
        // `finish()` writes the last, partial block and the header's totals; `close()` alone drops them (the tail of the song).
        do { try encoder.finish(); try encoder.close() } catch { throw Failure.encoder(error.localizedDescription) }
        finished = true
        progress?(1)
        return Result(sampleRate: target, bitDepth: bitDepth, channels: channels, labels: labels, frames: written)
    }

    /// The speaker of each channel of `item` as the player reads it (Core Audio `AudioChannelLabel` values), for a multichannel
    /// original sent as it is. nil when the file can't be opened.
    public static func channelLabels(of item: PlayableItem) -> [UInt32]? {
        guard let probed = try? SourceOpener.probe(item.url, area: item.sacdArea, dvd: item.dvd, audioStream: item.audioStream) else { return nil }
        return probed.format.channelLabels ?? ChannelLayouts.layout(channels: probed.format.channels)?.channelLabels
    }
}
