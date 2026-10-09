//
// Vespertine verification: contracts/dop-stream.md in Swift. Says nothing the document doesn't.
// SPDX-License-Identifier: GPL-3.0-or-later
//

/// The last stage before the audio device while DoP plays. Every word holds one DoP sample left-justified: the
/// 24-bit DoP sample in bits 31…8 (marker byte in 31…24, DSD bits in 23…8), bits 7…0 zero. Frames are
/// interleaved, one word per channel, in channel order.
public protocol DoPStage: AnyObject {
    /// Interleaved whole frames (the word count is a multiple of `channels`). Returns how many frames were
    /// accepted; at least `capacityFrames` are accepted into an empty stage, and 0 when full.
    func write(frames: [UInt32]) -> Int
    /// Always exactly `frameCount × channels` words, `frameCount` from 1 to 4096. A frame is played (consumed)
    /// when `render` returns it.
    func render(frameCount: Int) -> [UInt32]
    /// While muted the device must still be fed.
    func setMuted(_ muted: Bool)
    /// The stage's software gain control, linear (1.0 is unity). May be called at any time.
    func setGain(_ gain: Double)
    /// Turns a fixed equalizer setting that changes PCM on or off. May be called at any time.
    func setEqualizer(_ on: Bool)
}

public protocol DoPStageMaker: Sendable {
    func makeStage(channels: Int, capacityFrames: Int) -> any DoPStage
}
