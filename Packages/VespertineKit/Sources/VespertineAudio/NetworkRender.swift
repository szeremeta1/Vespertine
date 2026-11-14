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
    /// What comes out: PCM at the plan's rate (the source's own for PCM), 24-bit, the source's channels.
    public let format: SourceFormat
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
                startSeconds: TimeInterval = 0) throws {
        let probed = try SourceOpener.probe(url, area: item.sacdArea, dvd: item.dvd, audioStream: item.audioStream)
        let source = probed.format
        let channels = max(1, source.channels)
        let device = DeviceCapabilities(sampleRates: Self.rates,
                                        physicalFormats: [PhysicalFormat(minRate: 44_100, maxRate: 384_000, bitDepth: 24, isInteger: true, isMixable: true, channels: channels)],
                                        outputChannels: channels, supportsDoP: false)
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
        let rate = plan.deviceSampleRate
        format = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: rate, bitDepth: 24, channels: plan.channels)
        do {
            let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: item)
            if startSeconds > 0 {
                let frame = AVAudioFramePosition(startSeconds * plan.decodedSampleRate)
                if frame < decoder.length { try decoder.seek(to: frame) }
            }
            let applied = AppliedFormat(sampleRate: rate, physicalBitDepth: 24, physicalIsInteger: true, virtualChannels: plan.channels,
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
        // PlaybackEngine.applyGain, with the stream's 24 bits as the word length.
        let db = digitalVolumeDB ?? 0
        nrt_context_set_gain(context, db == 0 ? 1.0 : pow(10, db / 20), 24)
        let eq = equalizer.flatMap { $0.isFlat ? nil : $0 }
        let sections = eq?.sections(sampleRate: rate) ?? []
        sections.withUnsafeBufferPointer { nrt_context_set_eq(context, $0.baseAddress, UInt32($0.count), eq?.preampGain ?? 1) }
        let room = roomCorrection.flatMap { $0.isFlat || !$0.applies(channels: plan.channels) ? nil : $0 }
        RoomCorrectionPlayback.install(room, on: context, sampleRate: rate, channelCount: plan.channels)
        RoomCorrectionPlayback.installFilters(room?.impulseTaps(sampleRate: rate, channelCount: plan.channels), on: context)
    }

    deinit {
        nrt_context_destroy(context)
        nrt_ring_destroy(ring)
    }

    /// Up to `maxFrames` interleaved frames, each sample a 24-bit value (−8388608…8388607) in an Int32; empty at the end.
    public func next(maxFrames: Int = 4096) -> [Int32] {
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
        var out = [Int32](repeating: 0, count: n * channels)
        for i in 0..<(n * channels) {
            let v = (Double(scratch[i]) * 8_388_608).rounded()
            out[i] = Int32(min(max(v, -8_388_608), 8_388_607))
        }
        return out
    }
}
