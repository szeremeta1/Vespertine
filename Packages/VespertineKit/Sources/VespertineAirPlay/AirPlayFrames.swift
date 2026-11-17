//
// Vespertine: a song as AirPlay frames: 16-bit stereo at 44.1 kHz, from the engine's own chain (NetworkRender with the
// AirPlay target: the planner, the mastering resampler, the downmix, DSD→PCM, ReplayGain, room correction, the equalizer and
// digital volume). A 16-bit / 44.1 kHz source with nothing applied comes out as its own samples (mono copied to both
// channels); anything else is reduced to 16 bits with TPDF dither, by the chain where it processes the samples, here
// otherwise. What was done is said by `steps`.
//
// For a receiver that takes more, the same in another `AirPlayFormat` (24 bits, 48 kHz): a source at the format's rate
// and no deeper than it, with nothing applied, comes out as its own samples there too.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio
import VespertineUPnP

public typealias AirPlayStep = SignalPath.RendererStage.Processing

public enum AirPlayConversion {
    /// What turns `source` into stereo ALAC in `format` (16/44.1 unless said) with `settings` applied; empty: the
    /// samples are sent as they are.
    public static func steps(source: SourceFormat, settings: RendererSettings, replayGainDB: Double?, format: AirPlayFormat = .cd) -> [AirPlayStep] {
        var steps: [AirPlayStep] = []
        if settings.activeRoomCorrection != nil { steps.append(.roomCorrection) }
        if settings.activeEqualizer != nil { steps.append(.equalizer) }
        if settings.activeVolumeDB != nil { steps.append(.volume) }
        if let rg = replayGainDB, rg != 0 { steps.append(.replayGain) }
        if source.encoding == .dsd { steps.append(.dsdToPCM) }
        if abs(source.sampleRate - Double(format.sampleRate)) > 0.5 { steps.append(.resampled) }
        if source.channels > 2 { steps.append(.downmix) }
        let exactWords = source.encoding == .pcm && (source.bitDepth.map { (1...format.bitDepth).contains($0) } ?? false)
        if !steps.isEmpty || !exactWords { steps.append(.dithered) }
        return steps.sorted { AirPlayStep.allCases.firstIndex(of: $0)! < AirPlayStep.allCases.firstIndex(of: $1)! }
    }
}

public final class AirPlayFrames: @unchecked Sendable {
    public let source: SourceFormat
    /// What the frames are in.
    public let format: AirPlayFormat
    public let steps: [AirPlayStep]
    public let decoderName: String
    private let render: NetworkRender
    /// Dither added here (the chain didn't already dither at the format's depth).
    private let dithers: Bool
    private var rng = Xorshift(seed: UInt64.random(in: 1...UInt64.max))
    /// Untouched songs only: samples that weren't exact 16-bit values (should stay 0; counted so a test can say so).
    public private(set) var inexactSamples = 0
    public private(set) var finished = false
    public var error: Error? { render.error }

    public init(item: PlayableItem, url: URL, settings: RendererSettings, startSeconds: TimeInterval = 0, format: AirPlayFormat = .cd) throws {
        // A format AirPlay has no name for is never sent: 16-bit at 44.1 kHz instead.
        let format = format.streamFormat == nil ? AirPlayFormat.cd : format
        self.format = format
        render = try NetworkRender(item: item, url: url, equalizer: settings.activeEqualizer, roomCorrection: settings.activeRoomCorrection,
                                   digitalVolumeDB: settings.activeVolumeDB, startSeconds: startSeconds,
                                   target: format == .cd ? .airPlay : .airPlayStream(sampleRate: format.sampleRate, bitDepth: format.bitDepth))
        source = render.source
        var steps = AirPlayConversion.steps(source: source, settings: settings, replayGainDB: item.replayGainDB, format: format)
        // The planner's own account wins where it differs (a DSD file planned at another rate is still resampled to the format's).
        if render.plan.resamples, !steps.contains(.resampled) { steps.append(.resampled) }
        if render.plan.channels < source.channels, !steps.contains(.downmix) { steps.append(.downmix) }
        if !steps.isEmpty, !steps.contains(.dithered) { steps.append(.dithered) }
        self.steps = steps.sorted { AirPlayStep.allCases.firstIndex(of: $0)! < AirPlayStep.allCases.firstIndex(of: $1)! }
        dithers = !steps.isEmpty && !render.chainDithers
        decoderName = render.decoderName
    }

    /// Up to `maxFrames` interleaved stereo frames (two Int16 each); empty at the end of the song. For 16-bit formats:
    /// a 24-bit one's samples don't fit, and `nextSamples` gives them.
    public func next(maxFrames: Int = 4096) -> [Int16] {
        nextSamples(maxFrames: maxFrames).map { Int16(truncatingIfNeeded: $0) }
    }

    /// Up to `maxFrames` interleaved stereo frames, each sample a value of the format's depth (16-bit: -32 768 to
    /// 32 767; 24-bit: -8 388 608 to 8 388 607); empty at the end of the song.
    public func nextSamples(maxFrames: Int = 4096) -> [Int32] {
        let floats = render.nextFloats(maxFrames: maxFrames)
        guard !floats.isEmpty else { finished = true; return [] }
        let channels = render.format.channels
        let frames = floats.count / channels
        let full = Double(Int64(1) << Int64(format.bitDepth - 1))
        var out = [Int32](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            for c in 0..<2 {
                let x = Double(floats[f * channels + min(c, channels - 1)]) * full
                let v: Double
                if dithers {
                    v = (x + rng.tpdf()).rounded()
                } else {
                    v = x.rounded()
                    if steps.isEmpty, v != x { inexactSamples += 1 }
                }
                out[f * 2 + c] = Int32(min(max(v, -full), full - 1))
            }
        }
        return out
    }
}

/// A small fast generator for dither (xorshift64*).
struct Xorshift {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    /// Triangular in (−1, 1) LSB: the sum of two uniform ±½.
    mutating func tpdf() -> Double { unit() + unit() - 1 }
}
