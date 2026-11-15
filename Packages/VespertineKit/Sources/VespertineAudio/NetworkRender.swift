//
// Vespertine: a song rendered for a network renderer's processed stream, with no device: the engine's own pieces in the
// engine's order (FormatPlanner at the source rate → SourceOpener's decoder → Decoding.convertChunk, ReplayGain included →
// the ring → nrt_context_render_interleaved with room correction, the equalizer, digital volume and TPDF dither at 24 bits),
// as GoldenRender runs them in the tests. What comes out is the 24-bit stream the FLAC encoder gets.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import CVespertineRT
import Foundation

public final class NetworkRender: @unchecked Sendable {
    /// What the stream is planned for.
    public enum Target: Sendable, Hashable {
        /// A renderer's processed FLAC: the source's rate (DSD as PCM), 24 bits, the source's channels.
        case sourceRate24
        /// AirPlay: 44.1 kHz, 16 bits, at most two channels (resampled, downmixed and DSD→PCM by the engine's own converter).
        case airPlay
    }

    /// What comes out: PCM at the plan's rate (the source's own for PCM, 44.1 kHz for AirPlay), at the target's word length,
    /// the source's channels (at most two for AirPlay).
    public let format: SourceFormat
    /// The plan the engine's planner made for the target (resampling, DSD→PCM, channels).
    public let plan: OutputPlan
    /// The source as probed.
    public var source: SourceFormat { probed.format }
    public var decoderName: String { probed.decoderName }
    /// The chain itself adds TPDF dither at the target's word length (gain, equalizer or room correction change the samples).
    public let chainDithers: Bool
    private let probed: ProbedSource
    private let decoding: Decoding
    private let ring: OpaquePointer
    private let context: OpaquePointer
    private let channels: Int
    private var scratch: [Float] = []
    public private(set) var finished = false
    public private(set) var error: Error?

    static let chunkFrames: AVAudioFrameCount = 4096

    /// The rates a renderer stream may run at (DSD becomes PCM at the planner's rate within them).
    static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    public init(item: PlayableItem, url: URL, equalizer: EQPreset?, roomCorrection: RoomCorrectionPlayback?, digitalVolumeDB: Double?,
                startSeconds: TimeInterval = 0, target: Target = .sourceRate24) throws {
        let probed = try SourceOpener.probe(url, area: item.sacdArea, dvd: item.dvd, audioStream: item.audioStream)
        let source = probed.format
        let bits = target == .airPlay ? 16 : 24
        let channels = target == .airPlay ? min(2, max(1, source.channels)) : max(1, source.channels)
        let rates = target == .airPlay ? [44_100.0] : Self.rates
        let device = DeviceCapabilities(sampleRates: rates,
                                        physicalFormats: [PhysicalFormat(minRate: rates.min()!, maxRate: rates.max()!, bitDepth: bits, isInteger: true, isMixable: true,
                                                                         channels: target == .airPlay ? 2 : channels)],
                                        outputChannels: target == .airPlay ? 2 : channels, supportsDoP: false)
        var plan = FormatPlanner.plan(source: source, device: device, policy: .matchSource)
        plan.integerSamples = false
        guard plan.mode == .pcm, let ring = nrt_ring_create(OutputSession.ringFrames(rate: plan.deviceSampleRate, channels: plan.channels, seconds: 4), UInt32(plan.channels)) else {
            throw SourceOpenerError.unsupported(url)
        }
        guard let context = nrt_context_create(ring, 8192) else {
            nrt_ring_destroy(ring)
            throw SourceOpenerError.unsupported(url)
        }
        self.ring = ring
        self.context = context
        self.probed = probed
        self.channels = plan.channels
        self.plan = plan
        let rate = plan.deviceSampleRate
        format = SourceFormat(encoding: .pcm, codec: target == .airPlay ? "ALAC" : "FLAC", sampleRate: rate, bitDepth: bits, channels: plan.channels)
        do {
            let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: item)
            if startSeconds > 0 {
                let frame = AVAudioFramePosition(startSeconds * plan.decodedSampleRate)
                if frame < decoder.length { try decoder.seek(to: frame) }
            }
            let applied = AppliedFormat(sampleRate: rate, physicalBitDepth: bits, physicalIsInteger: true, virtualChannels: plan.channels,
                                        exclusive: false, bufferFrames: 512)
            let path = SignalPath(source: source, decoderName: probed.decoderName, plan: plan, applied: applied, deviceName: "", deviceUID: "",
                                  deviceProfile: .networkRenderer(protocolName: ""), volume: .fixed, replayGainDB: item.replayGainDB)
            decoding = try Decoding(item: item, probed: probed, decoder: decoder, path: path, chunk: Self.chunkFrames,
                                    layout: OutputSession.routeLayout(plan: plan, speakers: nil))
        } catch {
            nrt_context_destroy(context)
            nrt_ring_destroy(ring)
            throw error
        }
        // PlaybackEngine.applyGain, with the stream's word length (24 bits, 16 for AirPlay).
        let db = digitalVolumeDB ?? 0
        nrt_context_set_gain(context, db == 0 ? 1.0 : pow(10, db / 20), UInt32(bits))
        let eq = equalizer.flatMap { $0.isFlat ? nil : $0 }
        let sections = eq?.sections(sampleRate: rate) ?? []
        sections.withUnsafeBufferPointer { nrt_context_set_eq(context, $0.baseAddress, UInt32($0.count), eq?.preampGain ?? 1) }
        let room = roomCorrection.flatMap { $0.isFlat || !$0.applies(channels: plan.channels) ? nil : $0 }
        RoomCorrectionPlayback.install(room, on: context, sampleRate: rate, channelCount: plan.channels)
        RoomCorrectionPlayback.installFilters(room?.impulseTaps(sampleRate: rate, channelCount: plan.channels), on: context)
        chainDithers = db != 0 || !sections.isEmpty || room != nil
    }

    deinit {
        nrt_context_destroy(context)
        nrt_ring_destroy(ring)
    }

    /// Up to `maxFrames` interleaved frames, each sample a 24-bit value (−8388608…8388607) in an Int32; empty at the end.
    public func next(maxFrames: Int = 4096) -> [Int32] {
        let rendered = nextFloats(maxFrames: maxFrames)
        var out = [Int32](repeating: 0, count: rendered.count)
        for i in rendered.indices {
            let v = (Double(rendered[i]) * 8_388_608).rounded()
            out[i] = Int32(min(max(v, -8_388_608), 8_388_607))
        }
        return out
    }

    /// Up to `maxFrames` interleaved frames as the chain renders them (Float, full scale ±1); empty at the end. The caller
    /// quantises them to the target's word length.
    public func nextFloats(maxFrames: Int = 4096) -> [Float] {
        while Int(nrt_ring_readable(ring)) < maxFrames, !decoding.finished {
            guard Int(nrt_ring_writable(ring)) >= Int(Self.chunkFrames) else { break }
            let chunk = decoding.convertChunk()
            if chunk.frames > 0, let data = chunk.data { _ = nrt_ring_write(ring, data, chunk.frames) }
            if chunk.ended {
                decoding.finished = true
                if let e = chunk.error { error = e }
            }
        }
        let n = min(Int(nrt_ring_readable(ring)), maxFrames)
        guard n > 0 else { finished = true; return [] }
        if scratch.count < n * channels { scratch = [Float](repeating: 0, count: n * channels) }
        scratch.withUnsafeMutableBufferPointer { nrt_context_render_interleaved(context, $0.baseAddress!, UInt32(n), UInt32(channels)) }
        return Array(scratch.prefix(n * channels))
    }
}
