//
// Vespertine — golden PCM: what today's engine hands the device, byte for byte, rendered offline with no device.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Runs a queue through the engine's own pieces in the engine's order (PlaybackEngine.begin, fill, advance):
// FormatPlanner → SourceOpener's decoder → the engine's Decoding (OutputSession.converter in 4096-frame chunks, then
// ReplayGain: `Decoding.convertChunk`, exactly what fill() writes) → nrt_ring_write → nrt_context_render_interleaved,
// the function the I/O proc calls, in 512-frame device buffers.
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

    // MARK: Decoding (the engine's own: EngineDecoding.swift)

    /// The signal path the engine would make for `probed` (PlaybackEngine.makePath): `Decoding` reads its plan and
    /// whether the session is in integer mode.
    static func path(_ probed: ProbedSource, item: PlayableItem, session: Session, settings: Settings, plan: OutputPlan? = nil) -> SignalPath {
        let plan = plan ?? session.plan
        let applied = AppliedFormat(sampleRate: plan.deviceSampleRate, physicalBitDepth: plan.physicalBitDepth, physicalIsInteger: true,
                                    virtualChannels: session.device.streamChannels, exclusive: settings.exclusive,
                                    bufferFrames: session.device.bufferFrames, integerMode: session.integerMode)
        return SignalPath(source: probed.format, decoderName: probed.decoderName, plan: plan, applied: applied,
                          deviceName: session.device.name, deviceUID: session.device.name,
                          deviceProfile: DeviceProfile(kind: .usbDAC, tag: "", canBeBitPerfect: true, symbol: "x"), volume: .fixed,
                          replayGainDB: plan.mode == .pcm ? item.replayGainDB : nil)
    }

    /// PlaybackEngine.Decoding for `item` on `session`.
    static func decoding(_ item: PlayableItem, probed: ProbedSource, decoder: PCMDecoding, session: Session, settings: Settings,
                         plan: OutputPlan? = nil) throws -> Decoding {
        try Decoding(item: item, probed: probed, decoder: decoder, path: path(probed, item: item, session: session, settings: settings, plan: plan),
                     chunk: chunkFrames, layout: session.layout)
    }

    /// PlaybackEngine.fill with transitions off: one chunk into the ring.
    static func fill(_ decoding: Decoding, _ session: Session) {
        let chunk = decoding.convertChunk()
        if chunk.frames > 0, let data = chunk.data { _ = nrt_ring_write(session.ring, data, chunk.frames) }
        if chunk.ended {
            decoding.finished = true
            if let e = chunk.error { decoding.error = decoding.error ?? e }
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
            let decoding = try decoding(item, probed: probed, decoder: decoder, session: session, settings: settings)
            while !decoding.finished {
                // fill() waits for room for a whole chunk; the device plays meanwhile.
                while Int(nrt_ring_writable(session.ring)) < Int(chunkFrames) { session.render(upTo: device.bufferFrames) }
                fill(decoding, session)
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

    // MARK: Transitions on

    /// A transition, in ring frames of its session: where its samples are changed.
    struct Mixed: Equatable, CustomStringConvertible {
        enum Kind: String { case overlap, dipOut, dipIn }
        var session: Int
        var ringFrame: UInt64
        var length: Int
        var kind: Kind
        var description: String { "\(kind.rawValue) session \(session) at \(ringFrame) for \(length)" }
    }

    struct TransitionOutput {
        var output: Output
        var mixes: [Mixed]
        var decisions: [TransitionDecision]
    }

    /// Plays `items` with transitions on, as the engine does (PlaybackEngine.fillWithTransitions, planBoundaryIfDue,
    /// planBoundary, finishCrossfade, handOver, advance's dip and checkTransitions' fade in), on the engine's own pieces:
    /// TransitionPlanner, Crossfade.prepare (silence scan and placement), Crossfade, FrameRamp and Decoding. `dither`:
    /// the mixer dithers at the device's depth, as the engine does on an integer DAC with nothing after the ring.
    static func render(_ items: [PlayableItem], device: Device, settings: Settings = Settings(), transitions: TransitionSettings,
                       dither: Bool) throws -> TransitionOutput {
        var sessions: [SessionOutput] = [], mixes: [Mixed] = [], decisions: [TransitionDecision] = []
        var session: Session?
        var index = 0
        var deck: Decoding?
        var deckRing: UInt64 = 0          // ring frame of the deck's frame 0
        var crossfade: Crossfade?
        var planned = false
        var fadeIn: (seconds: Double, curve: TransitionCurve)?
        while index < items.count {
            if deck == nil {
                // begin / advance / checkTransitions: open the next song, on a new session if its plan needs one.
                let item = items[index]
                let probed = try SourceOpener.probe(item.url, area: item.sacdArea, dvd: item.dvd)
                let plan = plan(probed, item: item, device: device, settings: settings)
                if let current = session, !current.plan.isDeviceCompatible(with: plan) {
                    current.render()
                    sessions.append(current.output)
                    session = nil
                }
                var ramp: FrameRamp?
                if session == nil {
                    session = try Session(plan: plan, device: device, settings: settings)
                    if let f = fadeIn { ramp = FrameRamp.fadeIn(seconds: f.seconds, curve: f.curve, rate: plan.deviceSampleRate) }
                }
                fadeIn = nil
                let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: item)
                alignDoPMarkers(decoder, at: session!.totalWritten)
                let d = try decoding(item, probed: probed, decoder: decoder, session: session!, settings: settings, plan: plan)
                d.rampIn = ramp
                if let ramp { mixes.append(Mixed(session: sessions.count, ringFrame: session!.totalWritten, length: ramp.length, kind: .dipIn)) }
                deck = d
                deckRing = session!.totalWritten
                planned = false
            }
            guard let a = deck, let s = session else { break }
            if a.finished {
                if let cf = crossfade, cf.started {
                    // finishCrossfade
                    while !cf.done {
                        while Int(nrt_ring_writable(s.ring)) < Int(chunkFrames) * 2 { s.render(upTo: device.bufferFrames) }
                        cf.finishAlone(maxFrames: Int(chunkFrames)) { _ = nrt_ring_write(s.ring, $0, UInt32($1)) }
                    }
                    cf.flushIncoming { _ = nrt_ring_write(s.ring, $0, UInt32($1)) }
                    deck = cf.incoming
                    crossfade = nil
                    index += 1
                    planned = false
                    continue
                }
                crossfade = nil
                if let error = a.error { throw Failure(description: "\(a.item.url.lastPathComponent): \(error)") }
                deck = nil
                index += 1
                continue
            }
            // planBoundaryIfDue / planBoundary
            if !planned, let total = a.expectedFrames,
               total - Int64(a.framesProduced) <= TransitionTiming.planningLead(crossfadeSeconds: transitions.crossfadeSeconds, rate: a.path.plan.deviceSampleRate) {
                planned = true
                if index + 1 < items.count {
                    let next = items[index + 1]
                    let probed = try SourceOpener.probe(next.url, area: next.sacdArea, dvd: next.dvd)
                    let planB = plan(probed, item: next, device: device, settings: settings)
                    var planA = a.path.plan
                    planA.integerSamples = a.path.applied.integerMode || planA.integerSamples
                    let decision = TransitionPlanner.decide(transitions, from: a.item, format: .plan(planA), to: next, format: .plan(planB),
                                                            compatible: s.plan.isDeviceCompatible(with: planB))
                    decisions.append(decision)
                    switch decision {
                    case .overlap(let seconds, let curve):
                        crossfade = try Crossfade.prepare(outgoing: a, total: total, next: next, probed: probed, plan: planB,
                                                          path: path(probed, item: next, session: s, settings: settings, plan: planB),
                                                          seconds: seconds, curve: curve, trimSilence: transitions.trimSilence,
                                                          ditherBits: dither ? planB.physicalBitDepth : 0, chunk: chunkFrames, layout: s.layout,
                                                          reopenOutgoing: {
                                                              try SourceOpener.decoder(for: SourceOpener.probe(a.item.url, area: a.item.sacdArea, dvd: a.item.dvd),
                                                                                       plan: a.path.plan, item: a.item)
                                                          })
                    case .dip(let seconds, let curve):
                        if let ramp = FrameRamp.fadeOut(seconds: seconds, curve: curve, total: total, produced: a.framesProduced, rate: a.path.plan.deviceSampleRate) {
                            a.rampOut = ramp
                            mixes.append(Mixed(session: sessions.count, ringFrame: deckRing + ramp.start, length: ramp.length, kind: .dipOut))
                        }
                        fadeIn = (seconds, curve)
                    case .gapless, .cut:
                        break
                    }
                }
            }
            // fillWithTransitions
            while Int(nrt_ring_writable(s.ring)) < Int(chunkFrames) * (crossfade != nil ? 2 : 1) { s.render(upTo: device.bufferFrames) }
            let first = a.framesProduced
            let chunk = a.convertChunk()
            let channels = a.path.plan.channels
            if chunk.frames > 0, let data = chunk.data {
                a.rampIn?.apply(data, frames: Int(chunk.frames), first: first, channels: channels)
                a.rampOut?.apply(data, frames: Int(chunk.frames), first: first, channels: channels)
                if let cf = crossfade {
                    let before = s.totalWritten
                    if let offset = cf.feed(data, frames: Int(chunk.frames), first: first, write: { _ = nrt_ring_write(s.ring, $0, UInt32($1)) }) {
                        mixes.append(Mixed(session: sessions.count, ringFrame: before + UInt64(offset), length: cf.length, kind: .overlap))
                    }
                } else {
                    _ = nrt_ring_write(s.ring, data, chunk.frames)
                }
            }
            if chunk.ended {
                a.finished = true
                if let e = chunk.error { a.error = a.error ?? e }
            }
            if let cf = crossfade, cf.done {
                // handOver
                cf.flushIncoming { _ = nrt_ring_write(s.ring, $0, UInt32($1)) }
                deck = cf.incoming
                deckRing = mixes.last { $0.kind == .overlap }?.ringFrame ?? deckRing
                crossfade = nil
                index += 1
                planned = false
            }
        }
        if let session {
            session.render()
            sessions.append(session.output)
        }
        return TransitionOutput(output: Output(sessions: sessions), mixes: mixes, decisions: decisions)
    }
}
