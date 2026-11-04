//
// Vespertine — one song being decoded for the output: decoder → AVAudioConverter (format, and SRC only when needed)
// → Spatial Audio bed routing → ReplayGain, a chunk at a time. The engine writes each chunk to the ring; while a
// crossfade runs, two of these (the outgoing and the incoming song) feed one ring (TransitionMixer.swift).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Accelerate
import AVFAudio
import CoreAudio
import Foundation
import SFBAudioEngine

final class Decoding {
    let item: PlayableItem
    /// Read live from a network share (not a local cached copy): may stall and need rebuffering.
    var streaming = false
    /// Streaming, and can't move to the local copy (lossy, DSD converted to PCM, or the copy didn't match).
    var staysOnShare = false
    /// Both are replaced when playback moves from the share to a finished local copy.
    var probed: ProbedSource
    var decoder: PCMDecoding
    let converter: AVAudioConverter
    let input: AVAudioPCMBuffer
    let output: AVAudioPCMBuffer
    let path: SignalPath
    let gain: Float
    /// Spatial Audio on the source's own speakers: the converter keeps the file's channel order and this
    /// places each channel on the bed (`routed` is what reaches the ring).
    let router: BedRouter?
    let routed: AVAudioPCMBuffer?
    var inputExhausted = false
    var finished = false
    var framesProduced: UInt64 = 0
    var error: Error?

    init(item: PlayableItem, probed: ProbedSource, decoder: PCMDecoding, path: SignalPath, chunk: AVAudioFrameCount,
         layout: AVAudioChannelLayout? = nil) throws {
        self.item = item
        self.probed = probed
        self.decoder = decoder
        self.path = path
        let own = decoder.processingFormat.channelLayout
        var router: BedRouter?
        let channels = Int(decoder.processingFormat.channelCount)
        if path.plan.spatialBed != nil, let bed = layout?.channelLabels,
           let speakers = ChannelLayouts.speakerLabels(own) ?? ChannelLayouts.standardLabels(channels: channels) {
            router = BedRouter(source: speakers, bed: bed)
        }
        self.router = router
        // Integer mode: straight to 32-bit integers (the device takes them as they are).
        let float = router.flatMap { AudioFormats.float32(sampleRate: path.plan.deviceSampleRate, channels: $0.sourceChannels, interleaved: true, layout: own) }
            ?? AudioFormats.float32(sampleRate: path.plan.deviceSampleRate, channels: path.plan.channels, interleaved: true, layout: layout)
        let integer = float.flatMap { f in
            AVAudioFormat(commonFormat: .pcmFormatInt32, sampleRate: f.sampleRate, interleaved: true, channelLayout: f.channelLayout
                          ?? AVAudioChannelLayout(layoutTag: f.channelCount == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo)!)
        }
        guard let outFormat = path.applied.integerMode ? integer : float,
              let converter = OutputSession.converter(from: decoder.processingFormat, to: outFormat, plan: path.plan) else {
            throw SourceOpenerError.unsupported(item.url)
        }
        self.converter = converter
        let inCapacity = AVAudioFrameCount(Double(chunk) * decoder.processingFormat.sampleRate / path.plan.deviceSampleRate) + 1024
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: inCapacity),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunk) else {
            throw SourceOpenerError.unsupported(item.url)
        }
        input = inBuffer
        output = outBuffer
        routed = router.flatMap { r in
            AudioFormats.float32(sampleRate: path.plan.deviceSampleRate, channels: r.bedChannels, interleaved: true, layout: layout)
                .flatMap { AVAudioPCMBuffer(pcmFormat: $0, frameCapacity: chunk) }
        }
        if let db = item.replayGainDB, db != 0, path.plan.mode == .pcm {
            gain = Float(pow(10, db / 20))
        } else {
            gain = 1
        }
    }

    var durationSeconds: Double {
        let rate = decoder.processingFormat.sampleRate
        return rate > 0 ? Double(decoder.length) / rate : 0
    }

    // MARK: Transitions (none of this is used while the master switch is off)

    /// The source frame decoding started from (a seek, or a crossfade's trimmed head): `framesProduced` counts from here.
    var startSourceFrame: Int64 = 0
    /// Gain ramps on this song's frames before the ring: a dip's fade out at its end, and its fade in at its start.
    var rampOut: FrameRamp?
    var rampIn: FrameRamp?

    /// Frames this decoding produces in all, at the device rate: the rest of the song from `startSourceFrame`. nil
    /// when the decoder doesn't know its length.
    var expectedFrames: Int64? {
        let length = decoder.length, rate = decoder.processingFormat.sampleRate
        guard length > 0, rate > 0 else { return nil }
        return Int64((Double(max(0, length - startSourceFrame)) * path.plan.deviceSampleRate / rate).rounded())
    }

    /// One converted chunk: what `fill` hands the ring.
    struct Chunk {
        var frames: AVAudioFrameCount
        /// Interleaved samples at the device rate and channel count (Int32 bit patterns in integer mode).
        var data: UnsafeMutablePointer<Float>?
        /// The decoder is done (end of the song, or an error).
        var ended: Bool
        /// The read-ahead decoder is waiting on a share and nothing new came.
        var waiting: Bool
        var error: Error?
    }

    /// Decodes and converts up to one chunk, routes it onto the Spatial Audio bed and applies ReplayGain: the samples
    /// exactly as the ring gets them. `framesProduced` counts them.
    func convertChunk() -> Chunk {
        output.frameLength = 0
        var conversionError: NSError?
        var waiting = false
        let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
            if self.inputExhausted {
                inputStatus.pointee = .endOfStream
                return nil
            }
            self.input.frameLength = 0
            do {
                try self.decoder.decode(into: self.input, length: min(requested, self.input.frameCapacity))
            } catch is ReadAheadDecoder.Starved {
                // The share hasn't delivered the next audio yet: convert what's here, and try again shortly.
                waiting = true
                inputStatus.pointee = .noDataNow
                return nil
            } catch {
                self.error = error
                self.inputExhausted = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            if self.input.frameLength == 0 {
                self.inputExhausted = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return self.input
        }

        let frames = output.frameLength
        var raw = output.floatChannelData?[0]
            ?? output.int32ChannelData.map { UnsafeMutableRawPointer($0[0]).assumingMemoryBound(to: Float.self) }
        if let router, let routed, let source = raw, let bed = routed.floatChannelData?[0] {
            router.route(source, into: bed, frames: Int(frames))
            raw = bed
        }
        if frames > 0, let data = raw {
            framesProduced += UInt64(frames)
            if gain != 1, !path.applied.integerMode {
                var g = gain
                vDSP_vsmul(data, 1, &g, data, 1, vDSP_Length(frames) * vDSP_Length(path.plan.channels))
            }
        }
        let ended = status == .error || status == .endOfStream || (inputExhausted && frames == 0)
        return Chunk(frames: frames, data: frames > 0 ? raw : nil, ended: ended, waiting: waiting,
                     error: ended ? (conversionError ?? error) : nil)
    }
}
