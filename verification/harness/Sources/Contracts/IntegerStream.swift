//
// Vespertine verification: contracts/integer-stream.md in Swift. Says nothing the document doesn't.
// SPDX-License-Identifier: GPL-3.0-or-later
//

/// The last stage before an audio device that takes 32-bit integer samples directly. Words are exchanged as bit
/// patterns; any pattern can occur (including ones that would be NaN, infinity or denormal as Float32).
/// Frames are interleaved, one word per channel, in channel order.
public protocol IntegerStage: AnyObject {
    /// Interleaved whole frames. Returns how many frames were accepted; at least `capacityFrames` are accepted
    /// into an empty stage, and 0 when full.
    func write(words: [UInt32]) -> Int
    /// Always exactly `frameCount × channels` words, `frameCount` from 1 to 4096. A frame is played (consumed)
    /// when `render` returns it.
    func render(frameCount: Int) -> [UInt32]
    /// While muted the device must still be fed.
    func setMuted(_ muted: Bool)
}

public protocol IntegerOutput: Sendable {
    func makeStage(channels: Int, capacityFrames: Int) -> any IntegerStage
}
