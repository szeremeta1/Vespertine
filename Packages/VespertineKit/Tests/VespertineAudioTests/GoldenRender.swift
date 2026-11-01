//
// Vespertine — golden PCM: what today's engine hands the device, byte for byte, rendered offline with no device.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Runs a queue through the engine's own pieces in the engine's order (PlaybackEngine.begin, Decoding.init, fill,
// advance): FormatPlanner → SourceOpener's decoder → OutputSession.converter (4096-frame chunks) → ReplayGain →
// nrt_ring_write → nrt_context_render_interleaved, the function the I/O proc calls, in 512-frame device buffers.
// A gapless join continues into the same ring; a plan the device can't take without reconfiguring starts a new
// session, as the engine's drain + replaceSession does. The settings and decisions the engine keeps private
// (integer mode, "Match 16-bit sources", DoP marker alignment, the gain stage) are mirrored here line for line;
// each names the engine code it copies. Spatial Audio, room correction, the equalizer and Atmos are left out.
//

import Accelerate
import AVFAudio
import CoreAudio
import CryptoKit
import CVespertineRT
import Foundation
import SFBAudioEngine
@testable import VespertineAudio

enum GoldenRender {
    /// An output device as the planner sees it, and what OutputSession would read back from it.
    struct Device {
        var name: String
        var capabilities: DeviceCapabilities
        /// Channels of the device's output stream (the I/O proc's buffer).
        var streamChannels: Int
        /// An AV receiver that decodes Dolby and DTS (`EngineSettings.bitstreamDeviceUIDs`).
        var bitstream = false
        var bufferFrames = 512
    }

    struct Settings {
        var integerMode = false
        var matchSixteenBit = false
        var digitalVolumeDB: Double?
        var exclusive = true
    }

    /// One configured device format: what the I/O proc wrote, as the device's words.
    struct SessionOutput {
        var plan: OutputPlan
        var integerMode: Bool
        var streamChannels: Int
        var words: [UInt32] = []
        var frames: Int { words.count / max(1, streamChannels) }

        var header: String {
            "session mode=\(plan.mode.rawValue) rate=\(Int(plan.deviceSampleRate)) channels=\(plan.channels) out=\(streamChannels) "
                + "depth=\(plan.physicalBitDepth) integer=\(integerMode) frames=\(frames)\n"
        }
    }

    struct Output {
        var sessions: [SessionOutput]

        /// The bytes the hash covers: each session's header line, then its words, little-endian.
        var canonicalBytes: Data {
            var data = Data()
            for s in sessions {
                data.append(contentsOf: Array(s.header.utf8))
                s.words.withUnsafeBufferPointer { buffer in
                    for w in buffer { withUnsafeBytes(of: w.littleEndian) { data.append(contentsOf: $0) } }
                }
            }
            return data
        }

        var sha256: String { SHA256.hash(data: canonicalBytes).map { String(format: "%02x", $0) }.joined() }
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    static let chunkFrames: AVAudioFrameCount = 4096        // PlaybackEngine.chunkFrames

    // MARK: The engine's private decisions, mirrored

    /// PlaybackEngine.wantsIntegerMode (digital volume, ReplayGain, EQ and room correction are the only processing).
    static func wantsIntegerMode(_ plan: OutputPlan, probed: ProbedSource, item: PlayableItem, device: Device, settings: Settings) -> Bool {
        let source = probed.format
        return settings.integerMode && settings.exclusive && plan.mode == .pcm && !plan.resamples && plan.spatial == .off
            && plan.channels == source.channels && source.encoding == .pcm && probed.exactAsIntegers
            && settings.digitalVolumeDB == nil && (item.replayGainDB ?? 0) == 0
            && device.capabilities.physicalFormats.contains { $0.isInteger && !$0.isMixable && $0.bitDepth == 32 }
    }

    /// PlaybackEngine.mayMatchSixteenBit.
    static func mayMatchSixteenBit(item: PlayableItem, settings: Settings) -> Bool {
        settings.matchSixteenBit && settings.exclusive && settings.digitalVolumeDB == nil && (item.replayGainDB ?? 0) == 0
    }

    /// PlaybackEngine.begin / advance: the plan for `probed` on `device`.
    static func plan(_ probed: ProbedSource, item: PlayableItem, device: Device, settings: Settings) -> OutputPlan {
        let bitstream = device.bitstream && SourceInspector.canBitstream(probed.url, codec: probed.format.codec)
        var plan = FormatPlanner.plan(source: probed.format, device: device.capabilities, policy: .matchSource,
                                      spatial: .off, bitstream: bitstream, dsdToPCMForRoom: false)
        plan.integerSamples = wantsIntegerMode(plan, probed: probed, item: item, device: device, settings: settings)
        plan = FormatPlanner.matchSixteenBit(plan, source: probed.format, device: device.capabilities,
                                             eligible: mayMatchSixteenBit(item: item, settings: settings))
        return plan
    }

    /// PlaybackEngine.alignDoPMarkers (no read-ahead decoder here: nothing streams from a share).
    static func alignDoPMarkers(_ decoder: PCMDecoding, at ringFrame: UInt64) {
        (decoder as? RawDoPDecoder)?.nextMarker = AVAudioFramePosition(ringFrame & 1)
    }

    // MARK: Session (OutputSession.init + PlaybackEngine.applyGain, with no device)

    final class Session {
        let ring: OpaquePointer
        let context: OpaquePointer
        let plan: OutputPlan
        let integerMode: Bool
        let layout: AVAudioChannelLayout?
        let device: Device
        var output: SessionOutput

        init(plan: OutputPlan, device: Device, settings: Settings) throws {
            guard plan.spatial == .off else { throw Failure(description: "Spatial Audio isn't rendered offline") }
            guard let ring = nrt_ring_create(OutputSession.ringFrames(rate: plan.deviceSampleRate, channels: plan.channels), UInt32(plan.channels)) else {
                throw Failure(description: "ring")
            }
            guard let context = nrt_context_create(ring, UInt32(max(device.bufferFrames * 2, 4096))) else {
                nrt_ring_destroy(ring)
                throw Failure(description: "context")
            }
            self.ring = ring
            self.context = context
            self.plan = plan
            self.device = device
            // The device is held (exclusive) and takes the integer format when asked: OutputSession.swift:123.
            integerMode = plan.integerSamples && (settings.exclusive || plan.isPassthrough) && plan.mode == .pcm
            nrt_context_set_passthrough(context, plan.isPassthrough)
            nrt_context_set_dop(context, plan.mode == .dop)
            nrt_context_set_integer(context, integerMode)
            layout = OutputSession.routeLayout(plan: plan, speakers: nil)
            // applyGain: digital volume on PCM only, dither at the device's word length.
            let db = plan.isPassthrough ? 0 : (settings.digitalVolumeDB ?? 0)
            nrt_context_set_gain(context, db == 0 ? 1.0 : pow(10, db / 20), UInt32(plan.physicalBitDepth))
            output = SessionOutput(plan: plan, integerMode: integerMode, streamChannels: device.streamChannels)
        }

        deinit {
            nrt_context_destroy(context)
            nrt_ring_destroy(ring)
        }

        var totalWritten: UInt64 { nrt_ring_total_written(ring) }

        /// The I/O proc's calls, one device buffer at a time (the last one only as long as what's left).
        func render(upTo frames: Int? = nil) {
            let channels = device.streamChannels
            var readable = Int(nrt_ring_readable(ring))
            if let frames { readable = min(readable, frames) }
            var scratch = [Float](repeating: 0, count: device.bufferFrames * channels)
            while readable > 0 {
                let n = min(readable, device.bufferFrames)
                scratch.withUnsafeMutableBufferPointer { nrt_context_render_interleaved(context, $0.baseAddress!, UInt32(n), UInt32(channels)) }
                scratch.withUnsafeBufferPointer { buffer in
                    buffer.baseAddress!.withMemoryRebound(to: UInt32.self, capacity: n * channels) {
                        output.words.append(contentsOf: UnsafeBufferPointer(start: $0, count: n * channels))
                    }
                }
                readable -= n
            }
        }
    }

    // MARK: Decoding (PlaybackEngine.Decoding.init and fill)

    final class Decoding {
        let item: PlayableItem
        let decoder: PCMDecoding
        let converter: AVAudioConverter
        let input: AVAudioPCMBuffer
        let output: AVAudioPCMBuffer
        let gain: Float
        let integerMode: Bool
        let channels: Int
        var inputExhausted = false
        var finished = false
        var framesProduced: UInt64 = 0
        var error: Error?

        init(item: PlayableItem, decoder: PCMDecoding, session: Session) throws {
            self.item = item
            self.decoder = decoder
            let plan = session.plan
            integerMode = session.integerMode
            channels = plan.channels
            let float = AudioFormats.float32(sampleRate: plan.deviceSampleRate, channels: plan.channels, interleaved: true, layout: session.layout)
            let integer = float.flatMap { f in
                AVAudioFormat(commonFormat: .pcmFormatInt32, sampleRate: f.sampleRate, interleaved: true, channelLayout: f.channelLayout
                              ?? AVAudioChannelLayout(layoutTag: f.channelCount == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo)!)
            }
            guard let outFormat = integerMode ? integer : float,
                  let converter = OutputSession.converter(from: decoder.processingFormat, to: outFormat, plan: plan) else {
                throw SourceOpenerError.unsupported(item.url)
            }
            self.converter = converter
            let inCapacity = AVAudioFrameCount(Double(chunkFrames) * decoder.processingFormat.sampleRate / plan.deviceSampleRate) + 1024
            guard let inBuffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: inCapacity),
                  let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunkFrames) else {
                throw SourceOpenerError.unsupported(item.url)
            }
            input = inBuffer
            output = outBuffer
            if let db = item.replayGainDB, db != 0, plan.mode == .pcm {
                gain = Float(pow(10, db / 20))
            } else {
                gain = 1
            }
        }

        /// One chunk into the ring (PlaybackEngine.fill).
        func fill(_ session: Session) {
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                if self.inputExhausted {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                self.input.frameLength = 0
                do {
                    try self.decoder.decode(into: self.input, length: min(requested, self.input.frameCapacity))
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
            let raw = output.floatChannelData?[0]
                ?? output.int32ChannelData.map { UnsafeMutableRawPointer($0[0]).assumingMemoryBound(to: Float.self) }
            if frames > 0, let data = raw {
                framesProduced += UInt64(frames)
                if gain != 1, !integerMode {
                    var g = gain
                    vDSP_vsmul(data, 1, &g, data, 1, vDSP_Length(frames) * vDSP_Length(channels))
                }
                _ = nrt_ring_write(session.ring, data, frames)
            }
            if status == .error || status == .endOfStream || (inputExhausted && frames == 0) {
                finished = true
                if let e = conversionError { error = error ?? e }
            }
        }
    }

    // MARK: A queue

    /// Plays `items` in order, gaplessly where the plans allow, and returns what reached the device.
    static func render(_ items: [PlayableItem], device: Device, settings: Settings = Settings()) throws -> Output {
        var sessions: [SessionOutput] = []
        var session: Session?
        for item in items {
            let probed = try SourceOpener.probe(item.url, area: item.sacdArea, dvd: item.dvd)
            let plan = plan(probed, item: item, device: device, settings: settings)
            if let current = session, !current.plan.isDeviceCompatible(with: plan) {
                // Not device-compatible: the ring plays out, then the device is reconfigured (advance → checkTransitions).
                current.render()
                sessions.append(current.output)
                session = nil
            }
            if session == nil { session = try Session(plan: plan, device: device, settings: settings) }
            guard let session else { break }
            let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: item)
            alignDoPMarkers(decoder, at: session.totalWritten)
            let decoding = try Decoding(item: item, decoder: decoder, session: session)
            while !decoding.finished {
                // fill() waits for room for a whole chunk; the device plays meanwhile.
                while Int(nrt_ring_writable(session.ring)) < Int(chunkFrames) { session.render(upTo: device.bufferFrames) }
                decoding.fill(session)
            }
            if let error = decoding.error { throw Failure(description: "\(item.url.lastPathComponent): \(error)") }
            if decoding.framesProduced == 0 { throw Failure(description: "\(item.url.lastPathComponent): nothing decoded") }
        }
        if let session {
            session.render()
            sessions.append(session.output)
        }
        return Output(sessions: sessions)
    }
}
