//
// Vespertine — live spectrum and offline file analysis (true bit depth, band-limit detection).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import SFBAudioEngine

// The analysis itself (spectra, forensics, verdicts) lives in VespertineAnalysisCore so the same code
// also runs on a Linux file server (`vespertine-analyze`). This file decodes with SFBAudioEngine.
@_exported import VespertineAnalysisCore

extension FileAnalyzer {
    /// Decodes up to `maxSeconds` of the file at its native rate and inspects the samples.
    /// `shouldContinue` is polled between chunks; returning false stops with `AnalysisError.cancelled`.
    public static func analyze(url: URL, maxSeconds: Double = 600,
                               shouldContinue: (() -> Bool)? = nil) throws -> FileAnalysis {
        try analyzeWithProfile(url: url, maxSeconds: maxSeconds, shouldContinue: shouldContinue).analysis
    }

    /// `analyze`, plus the song's transition profile from the same decoded samples (nil for sources the analysis
    /// doesn't read: lossy, DSD). A song longer than `maxSeconds` gets a profile of its start only; the player
    /// measures its end when it's about to play it.
    public static func analyzeWithProfile(url: URL, maxSeconds: Double = 600,
                                          shouldContinue: (() -> Bool)? = nil) throws -> (analysis: FileAnalysis, profile: TransitionProfile?) {
        guard maxSeconds.isFinite, maxSeconds > 0 else { throw SourceOpenerError.unsupported(url) }
        let probed = try SourceOpener.probe(url)
        let format = probed.format
        guard format.encoding == .pcm, let decoderPCM = try? SourceOpener.decoder(
            for: probed,
            plan: OutputPlan(mode: .pcm, deviceSampleRate: format.sampleRate, decodedSampleRate: format.sampleRate,
                             physicalBitDepth: 32, channels: format.channels, dsdConvertedToPCM: false, reason: ""),
            item: PlayableItem(url: url)) else {
            // Stored in English, like the server's; `FileAnalysis.localizedSummary` translates these two for display.
            return (.notApplicable(claimedBitDepth: format.bitDepth, sampleRate: format.sampleRate,
                                   summary: format.encoding == .dsd ? "DSD source: bit depth analysis doesn't apply." : "Lossy source: analysis doesn't apply."), nil)
        }

        let channels = max(1, format.channels)
        let chunk: AVAudioFrameCount = 16_384
        guard let outFormat = AudioFormats.float32(sampleRate: format.sampleRate, channels: channels, interleaved: false),
              let converter = AVAudioConverter(from: decoderPCM.processingFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: decoderPCM.processingFormat, frameCapacity: chunk),
              let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunk) else {
            throw SourceOpenerError.unsupported(url)
        }
        // Channel for channel. Left alone, the converter matches channels by speaker label, and a 5.1
        // file's L/R/C/LFE/Ls/Rs match none of the plain numbered outputs, so every channel read silent.
        converter.channelMap = (0..<channels).map { NSNumber(value: $0) }

        let accumulator = AnalysisAccumulator(sampleRate: format.sampleRate, channels: channels,
                                              claimedBitDepth: format.bitDepth, maxSeconds: maxSeconds)
        let profile = TransitionAnalyzer(sampleRate: format.sampleRate, channels: channels)
        var exhausted = false
        while !exhausted && accumulator.wantsMore {
            if let shouldContinue, !shouldContinue() { throw AnalysisError.cancelled }
            output.frameLength = 0
            var error: NSError?
            var decodeError: Error?
            let status = converter.convert(to: output, error: &error) { requested, inputStatus in
                input.frameLength = 0
                do { try decoderPCM.decode(into: input, length: min(requested, input.frameCapacity)) } catch {
                    decodeError = error
                    inputStatus.pointee = .endOfStream; return nil
                }
                if input.frameLength == 0 { inputStatus.pointee = .endOfStream; return nil }
                inputStatus.pointee = .haveData
                return input
            }
            if let decodeError { throw decodeError }
            if let error { throw error }
            if status == .error { throw SourceOpenerError.unsupported(url) }
            let n = Int(output.frameLength)
            if n == 0 || status != .haveData { exhausted = true }
            guard n > 0, let data = output.floatChannelData else { continue }
            do {
                let planes = (0..<channels).map { UnsafePointer(data[$0]) }
                try accumulator.add(planar: planes, frames: n)
                profile.add(planar: planes, frames: n)
            } catch AnalysisError.invalidSample {
                throw SourceOpenerError.unsupported(url)
            }
        }
        let total = decoderPCM.length > 0 ? Int64(decoderPCM.length) : (exhausted ? profile.framesAdded : nil)
        return (accumulator.finish(), profile.finish(totalFrames: total))
    }
}

/// Float32 formats for any channel count. AVAudioFormat's plain initializer returns nil above two
/// channels (5.1, 7.1, …) unless a channel layout is given, so a multichannel file must never be
/// able to crash analysis or playback.
public enum AudioFormats {
    public static func float32(sampleRate: Double, channels: Int, interleaved: Bool, layout: AVAudioChannelLayout? = nil) -> AVAudioFormat? {
        guard sampleRate.isFinite, sampleRate > 0, channels > 0, channels <= 64 else { return nil }
        if let layout, Int(layout.channelCount) == channels {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: interleaved, channelLayout: layout)
        }
        if channels <= 2 {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                 channels: AVAudioChannelCount(channels), interleaved: interleaved)
        }
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)) else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: interleaved, channelLayout: layout)
    }
}
