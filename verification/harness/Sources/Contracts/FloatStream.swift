//
// Vespertine verification: contracts/float-stream.md in Swift. Says nothing the document doesn't.
// SPDX-License-Identifier: GPL-3.0-or-later
//

/// The last stage before the audio device for ordinary PCM in 32-bit float, at unity gain with no equalizer.
/// Samples are exchanged as values, full scale ±1.0, interleaved one per channel in channel order.
public protocol FloatStage: AnyObject {
    /// Interleaved whole frames. Returns how many frames were accepted; at least `capacityFrames` are accepted
    /// into an empty stage, and 0 when full. Inputs are finite values from −1.0 to +1.0.
    func write(samples: [Float]) -> Int
    /// Always exactly `frameCount × channels` samples, `frameCount` from 1 to 4096. A frame is played (consumed)
    /// when `render` returns it.
    func render(frameCount: Int) -> [Float]
    /// While muted the device must still be fed.
    func setMuted(_ muted: Bool)
}

public protocol FloatOutput: Sendable {
    /// Converts each signed 24-bit sample (−8 388 608 … 8 388 607) in order, one result per input; full scale is
    /// 2^23, so each result is meant to equal k ÷ 2^23. Any number of samples per call.
    func int24ToFloat(samples: [Int32]) -> [Float]
    func makeStage(channels: Int, capacityFrames: Int) -> any FloatStage
}
