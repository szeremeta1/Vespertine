//
// Vespertine verification: Vespertine itself, behind each contract. See each adapter for exactly which code it
// drives. Adapters only translate; anything an adapter has to decide on Vespertine's behalf is said in its comment.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Contracts

public enum Vespertine {
    public static let dopStage: any DoPStageMaker = RenderDoPStageMaker()
    public static let integerOutput: any IntegerOutput = RenderIntegerOutput()
    public static let dstDecoder: any DSTDecoderMaker = NDSTDecoderMaker()
#if os(macOS)
    public static let dopPacker: (any DoPPacker)? = RawDoPPacker()
    public static let floatOutput: any FloatOutput = DecoderFloatOutput()
    public static let ratePlanner: (any RatePlanner)? = PlannerAdapter()
    public static let verdict: (any BadgeVerdict)? = SignalPathVerdict()
    /// Requirement IDs that can't be checked against Vespertine on this platform.
    public static let unavailable: [String: String] = [:]
#else
    public static let dopPacker: (any DoPPacker)? = nil
    public static let floatOutput: any FloatOutput = LinuxFloatOutput()
    public static let ratePlanner: (any RatePlanner)? = nil
    public static let verdict: (any BadgeVerdict)? = nil
    public static let unavailable: [String: String] = [
        "FLT-004": "24-bit decoding goes through SFBAudioEngine and AVAudioConverter (macOS only)",
    ]
#endif
}

#if !os(macOS)
/// On Linux only the float stage (vespertine_rt.c) can run; the decoding step is macOS-only (see `unavailable`).
struct LinuxFloatOutput: FloatOutput {
    func int24ToFloat(samples: [Int32]) -> [Float] { [] }
    func makeStage(channels: Int, capacityFrames: Int) -> any FloatStage {
        RenderContext(channels: channels, capacityFrames: capacityFrames).map(RenderFloatStage.init) ?? RefusedStage(channels: channels)
    }
}
#endif
