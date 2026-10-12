//
// Vespertine verification: the stream contracts (DoP, float, integer) connected to Vespertine's real-time C,
// vespertine_rt.c, configured as OutputSession configures it (OutputSession.swift:150-152) and driven through
// nrt_context_render_interleaved, the function its I/O proc uses. On Linux the same file is compiled from
// Packages/ through the RTUnderTest target (a symlink, not a copy) with a small Core Audio shim.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Contracts
#if canImport(RTUnderTest)
import RTUnderTest
#else
import CVespertineRT
#endif

/// A ring and render context, as OutputSession creates them.
final class RenderContext {
    let ring: OpaquePointer
    let context: OpaquePointer
    let channels: Int

    /// nil when vespertine_rt.c refuses the shape (no channels, or a ring over 2^30 frames).
    init?(channels: Int, capacityFrames: Int) {
        guard channels > 0, let ring = nrt_ring_create(UInt32(clamping: max(1, capacityFrames)), UInt32(clamping: channels)) else {
            return nil
        }
        // OutputSession asks for max(bufferFrames × 2, 4096); render calls of up to 4096 frames fit in one slice.
        guard let context = nrt_context_create(ring, 4096) else {
            nrt_ring_destroy(ring)
            return nil
        }
        self.ring = ring
        self.context = context
        self.channels = channels
    }

    deinit {
        nrt_context_destroy(context)
        nrt_ring_destroy(ring)
    }

    /// Writes interleaved slots (a float per sample: a value, or a bit pattern in integer mode).
    func write(_ slots: [Float]) -> Int {
        let frames = slots.count / channels
        guard frames > 0 else { return 0 }
        return slots.withUnsafeBufferPointer { Int(nrt_ring_write(ring, $0.baseAddress!, UInt32(clamping: frames))) }
    }

    func render(_ frameCount: Int) -> [Float] {
        let count = max(0, frameCount)
        var out = [Float](repeating: 0, count: count * channels)
        guard count > 0 else { return out }
        out.withUnsafeMutableBufferPointer {
            nrt_context_render_interleaved(context, $0.baseAddress!, UInt32(clamping: count), UInt32(clamping: channels))
        }
        return out
    }

    func setMuted(_ muted: Bool) { nrt_context_set_muted(context, muted) }
}

/// A stage the C refused to create: accepts nothing, renders zeros. Checks then fail on it rather than crash.
final class RefusedStage: DoPStage, FloatStage, IntegerStage {
    let channels: Int
    init(channels: Int) { self.channels = max(0, channels) }
    func write(frames: [UInt32]) -> Int { 0 }
    func write(samples: [Float]) -> Int { 0 }
    func write(words: [UInt32]) -> Int { 0 }
    func render(frameCount: Int) -> [UInt32] { [UInt32](repeating: 0, count: max(0, frameCount) * channels) }
    func render(frameCount: Int) -> [Float] { [Float](repeating: 0, count: max(0, frameCount) * channels) }
    func setMuted(_ muted: Bool) {}
    func setGain(_ gain: Double) {}
    func setEqualizer(_ on: Bool) {}
}

// MARK: - DoP

/// DoP as Vespertine plays it: passthrough and DoP on, integer mode off (OutputSession.swift:98 allows integer mode
/// only for PCM). The ring carries each DoP sample as RawDoPDecoder writes it (FFmpegDecoder.swift:238-239): the
/// left-justified 32-bit word as a signed integer over 2^31, which a Float32 holds exactly.
final class RenderDoPStage: DoPStage {
    let rt: RenderContext

    init(_ rt: RenderContext) {
        self.rt = rt
        nrt_context_set_passthrough(rt.context, true)
        nrt_context_set_dop(rt.context, true)
        nrt_context_set_integer(rt.context, false)
    }

    func write(frames: [UInt32]) -> Int {
        rt.write(frames.map { Float(Int32(bitPattern: $0)) / 2_147_483_648 })
    }

    func render(frameCount: Int) -> [UInt32] {
        rt.render(frameCount).map { UInt32(bitPattern: Int32(clamping: Int64((Double($0) * 2_147_483_648).rounded()))) }
    }

    func setMuted(_ muted: Bool) { rt.setMuted(muted) }

    /// As PlaybackEngine.swift:795 sets volume: linear gain, dither at the physical word length (24 for DoP).
    func setGain(_ gain: Double) { nrt_context_set_gain(rt.context, gain, 24) }

    /// As PlaybackEngine.swift:800 sets an equalizer preset: one fixed, stable section that changes PCM, and a
    /// preamp below unity.
    func setEqualizer(_ on: Bool) {
        if on {
            var section = NRTBiquad(b0: 1.2, b1: -0.3, b2: 0.1, a1: -0.2, a2: 0.05)
            nrt_context_set_eq(rt.context, &section, 1, 0.9)
        } else {
            nrt_context_set_eq(rt.context, nil, 0, 1.0)
        }
    }
}

struct RenderDoPStageMaker: DoPStageMaker {
    func makeStage(channels: Int, capacityFrames: Int) -> any DoPStage {
        RenderContext(channels: channels, capacityFrames: capacityFrames).map(RenderDoPStage.init) ?? RefusedStage(channels: channels)
    }
}

// MARK: - Float PCM at unity gain

/// Ordinary PCM: no passthrough, no DoP, no integer mode, gain 1.0 and no equalizer (the context's initial state).
final class RenderFloatStage: FloatStage {
    let rt: RenderContext

    init(_ rt: RenderContext) {
        self.rt = rt
        nrt_context_set_passthrough(rt.context, false)
        nrt_context_set_dop(rt.context, false)
        nrt_context_set_integer(rt.context, false)
    }

    func write(samples: [Float]) -> Int { rt.write(samples) }
    func render(frameCount: Int) -> [Float] { rt.render(frameCount) }
    func setMuted(_ muted: Bool) { rt.setMuted(muted) }
}

// MARK: - Integer mode

/// Integer mode: the ring's float slots carry 32-bit integer bit patterns (nrt_context_set_integer). Words go in
/// and come out as bit patterns, never as float values.
final class RenderIntegerStage: IntegerStage {
    let rt: RenderContext

    init(_ rt: RenderContext) {
        self.rt = rt
        nrt_context_set_passthrough(rt.context, false)
        nrt_context_set_dop(rt.context, false)
        nrt_context_set_integer(rt.context, true)
    }

    func write(words: [UInt32]) -> Int { rt.write(words.map { Float(bitPattern: $0) }) }
    func render(frameCount: Int) -> [UInt32] { rt.render(frameCount).map(\.bitPattern) }
    func setMuted(_ muted: Bool) { rt.setMuted(muted) }
}

struct RenderIntegerOutput: IntegerOutput {
    func makeStage(channels: Int, capacityFrames: Int) -> any IntegerStage {
        RenderContext(channels: channels, capacityFrames: capacityFrames).map(RenderIntegerStage.init) ?? RefusedStage(channels: channels)
    }
}
