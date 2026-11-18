//
// Vespertine: speaker groups: headroom for a fold. A song with more channels than the group has speakers has channels summed
// onto one speaker (a 5.1 song's centre onto the fronts, a 7.1 song's side surrounds onto the back pair), and when they are
// loud together the sum passes full scale: `PositionRouter.worstCaseGain` says by how much at most (1.71 for 5.1 or 7.1 on four
// speakers). A DAC clips there.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A speaker that gets such a sum has the limiter Fill the room uses (`RenderLimiter`): its samples are exactly the routed ones
// until that speaker would clip, and only then is it turned down, over 1.5 ms of look-ahead, and let back up over 200 ms.
// So a song keeps its level, which a preamp lowered for the worst case (4.6 dB for every 5.1 song) would not, and the limiter
// follows the song it is made for, which the chain's preamp, shared by every song in the ring, cannot.
// A speaker that plays one channel of the file at 1.0 is never touched, whatever its samples are: it is the file's own.
// Runs on the decode thread, before ReplayGain, whose gain it allows for. Output frame n is input frame n.
//

import Foundation

/// What `Decoding` runs between the converter and the ring for a song put onto a speaker group, when that is more than a
/// matrix: the song's frames in, the group's frames out (as wide as the group), every frame once.
protocol GroupRendering: AnyObject {
    var outputChannels: Int { get }
    /// Takes `frames` interleaved frames of the song and appends the group's frames now ready, interleaved, to `output`.
    func process(_ input: UnsafePointer<Float>, frames: Int, into output: inout [Float])
    /// Appends the frames still held: after this, exactly as many frames have come out as went in.
    func finish(into output: inout [Float])
}

extension RoomRenderer: GroupRendering {}

/// A song routed onto a group by `PositionRouter`, with a limiter on the speakers that can pass full scale.
final class GroupFoldLimiter: GroupRendering {
    let router: PositionRouter
    let outputChannels: Int
    private var limiter: RenderLimiter
    private var wide: [Float] = []

    /// Whether `router` can drive a speaker past full scale with a song that stays within it, once `gain` (ReplayGain) is applied.
    static func isNeeded(_ router: PositionRouter, gain: Float = 1) -> Bool {
        let gain = gain.isFinite && gain > 0 ? gain : 1
        return router.usedOutputs.contains { !isUntouched(router, $0) && rowGain(router, $0) * gain > 1 }
    }

    /// nil when no speaker can pass full scale: the router alone does then, and nothing is held back.
    /// `gain` is what is applied to every channel after this (ReplayGain): full scale is where the DAC clips, so a song turned
    /// down later may be driven that much harder here, and one turned up must stay that much lower.
    init?(router: PositionRouter, sampleRate: Double, gain: Float = 1) {
        guard sampleRate.isFinite, sampleRate > 0, Self.isNeeded(router, gain: gain) else { return nil }
        let gain = gain.isFinite && gain > 0 ? gain : 1
        self.router = router
        outputChannels = router.outputChannels
        limiter = RenderLimiter(channels: router.outputChannels, sampleRate: sampleRate, thresholds: (0..<router.outputChannels).map { output in
            Self.isUntouched(router, output) ? .greatestFiniteMagnitude : 1 / gain
        })
    }

    func process(_ input: UnsafePointer<Float>, frames: Int, into output: inout [Float]) {
        guard frames > 0 else { return }
        let count = frames * outputChannels
        if wide.count < count { wide = [Float](repeating: 0, count: count) }
        wide.withUnsafeMutableBufferPointer { w in
            router.route(input, into: w.baseAddress!, frames: frames)
            limiter.process(w.baseAddress!, frames: frames, into: &output)
        }
    }

    func finish(into output: inout [Float]) { limiter.finish(into: &output) }

    /// One channel of the file at exactly 1.0, or nothing at all.
    private static func isUntouched(_ router: PositionRouter, _ output: Int) -> Bool {
        let row = router.matrixRow(output)
        return row.isEmpty || (row.count == 1 && row[0].gain == 1)
    }

    private static func rowGain(_ router: PositionRouter, _ output: Int) -> Float {
        router.matrixRow(output).reduce(Float(0)) { $0 + abs($1.gain) }
    }
}
