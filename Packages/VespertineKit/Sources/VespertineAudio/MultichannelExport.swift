//
// Vespertine — exports multichannel music for listening elsewhere:
//   • Spatial stereo (binaural): rendered with Apple's spatial renderer, so it sounds spatial on any
//     AirPods or headphones, on any device and in any player (fixed; head tracking needs live rendering).
//   • Multichannel ALAC: every channel, losslessly, with its speaker layout, for Apple devices and players.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import SFBAudioEngine

public enum MultichannelExport {
    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        case spatialStereo, multichannelALAC
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .spatialStereo: "Spatial stereo (binaural)"
            case .multichannelALAC: "Multichannel lossless"
            }
        }
        public var fileSuffix: String {
            switch self {
            case .spatialStereo: " (Spatial)"
            case .multichannelALAC: ""
            }
        }
    }

    public enum ExportError: LocalizedError {
        case notMultichannel, unsupported(String)
        public var errorDescription: String? {
            switch self {
            case .notMultichannel: "Only multichannel files (5.1, 7.1, …) can be exported for Spatial Audio."
            case .unsupported(let why): "Couldn't export: \(why)."
            }
        }
    }

    /// Renders `item` (a whole file or a CUE region) to a 24-bit ALAC .m4a at `destination`.
    /// `progress` receives 0…1. Returns the channel count written.
    @discardableResult
    public static func export(_ item: PlayableItem, kind: Kind, to destination: URL,
                              progress: ((Double) -> Void)? = nil) throws -> Int {
        let probed = try SourceOpener.probe(item.url)
        let format = probed.format
        guard format.encoding == .pcm, format.channels > 2 else { throw ExportError.notMultichannel }
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: format.sampleRate, decodedSampleRate: format.sampleRate,
                              physicalBitDepth: 24, channels: format.channels, dsdConvertedToPCM: false, reason: "")
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: item)
        let rate = decoder.processingFormat.sampleRate
        let channels = Int(decoder.processingFormat.channelCount)

        // Everything is brought into the standard bed layout for this channel count first.
        guard let bed = ChannelLayouts.layout(channels: channels),
              let bedFormat = AudioFormats.float32(sampleRate: rate, channels: channels, interleaved: true, layout: bed),
              let converter = AVAudioConverter(from: decoder.processingFormat, to: bedFormat) else {
            throw ExportError.unsupported("no converter for \(channels) channels")
        }
        let outChannels = kind == .spatialStereo ? 2 : channels
        let outLayout = kind == .spatialStereo ? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo)! : bed
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: rate, AVNumberOfChannelsKey: outChannels,
            AVEncoderBitDepthHintKey: 24,
            AVChannelLayoutKey: Data(bytes: outLayout.layout, count: outLayout.byteSize),
        ]
        try? FileManager.default.removeItem(at: destination)
        let partial = destination.deletingPathExtension().appendingPathExtension("partial.m4a")
        try? FileManager.default.removeItem(at: partial)
        do {
            let file = try AVAudioFile(forWriting: partial, settings: fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunk: AVAudioFrameCount = 16_384
            guard let input = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: chunk),
                  let bedBuffer = AVAudioPCMBuffer(pcmFormat: bedFormat, frameCapacity: chunk),
                  let outFormat = AudioFormats.float32(sampleRate: rate, channels: outChannels, interleaved: false, layout: outLayout),
                  let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunk) else {
                throw ExportError.unsupported("buffers")
            }
            let renderer = kind == .spatialStereo
                ? try SpatialRenderer(inputLayout: bed, channels: channels, sampleRate: rate, maxFrames: chunk, mode: .fixed) : nil
            let total = max(1, Double(decoder.length))
            var done = 0.0
            var finished = false
            while !finished {
                bedBuffer.frameLength = 0
                var decodeError: Error?
                var convertError: NSError?
                let status = converter.convert(to: bedBuffer, error: &convertError) { requested, inputStatus in
                    input.frameLength = 0
                    do { try decoder.decode(into: input, length: min(requested, input.frameCapacity)) } catch {
                        decodeError = error; inputStatus.pointee = .endOfStream; return nil
                    }
                    if input.frameLength == 0 { inputStatus.pointee = .endOfStream; return nil }
                    inputStatus.pointee = .haveData
                    return input
                }
                if let decodeError { throw decodeError }
                if let convertError { throw convertError }
                let n = Int(bedBuffer.frameLength)
                if n > 0, let bedData = bedBuffer.floatChannelData?[0] {
                    let interleaved = Array(UnsafeBufferPointer(start: bedData, count: n * channels))
                    outBuffer.frameLength = AVAudioFrameCount(n)
                    guard let planes = outBuffer.floatChannelData else { throw ExportError.unsupported("output") }
                    if let renderer {
                        let stereo = renderer.render(interleaved: interleaved, frames: n)
                        for f in 0..<n { planes[0][f] = stereo[f * 2]; planes[1][f] = stereo[f * 2 + 1] }
                    } else {
                        for f in 0..<n { for c in 0..<channels { planes[c][f] = interleaved[f * channels + c] } }
                    }
                    try file.write(from: outBuffer)
                    done += Double(n) * decoder.processingFormat.sampleRate / rate
                    progress?(min(1, done / total))
                }
                finished = status == .endOfStream || status == .error || n == 0
            }
        } // the writer finalizes the file when it goes away
        try FileManager.default.moveItem(at: partial, to: destination)
        progress?(1)
        return outChannels
    }
}
