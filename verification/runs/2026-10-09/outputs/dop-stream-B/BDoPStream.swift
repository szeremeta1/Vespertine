//
// Implementation (role B) of the DoP output stream contract.
//

import Contracts

public enum BDoPStream {
    public static let subject: (any DoPStageMaker)? = BDoPStageMaker()
}

struct BDoPStageMaker: DoPStageMaker {
    func makeStage(channels: Int, capacityFrames: Int) -> any DoPStage {
        BDoPStageImpl(channels: channels, capacityFrames: capacityFrames)
    }
}

/// A FIFO of written music frames in front of the device.
///
/// Output rules:
/// - Unmuted with music queued: the next music frame goes out unchanged, unless its marker equals the marker of
///   the frame output just before; then exactly one silence frame (with the other marker) goes out first.
/// - Muted, or nothing queued: a silence frame goes out, its marker the opposite of the previous frame's.
/// Gain and equalizer never touch DoP output.
final class BDoPStageImpl: DoPStage {
    private static let markerLow: UInt8 = 0x05
    private static let markerHigh: UInt8 = 0xFA
    /// DSD silence byte: four bits set, four clear.
    private static let silenceByte: UInt32 = 0x69
    /// Upper bound on words produced for a ruled-out `frameCount` above 4096, so absurd requests cannot exhaust memory.
    private static let maxWordsForRuledOutRequest = 1 << 20

    private let channels: Int
    private let capacityFrames: Int

    /// Queued, not yet played words; the unplayed part starts at `head`.
    private var queue: [UInt32] = []
    private var head = 0
    /// Marker byte of the last frame returned by `render`; nil before anything has been output.
    private var lastMarker: UInt8?
    private var muted = false

    init(channels: Int, capacityFrames: Int) {
        self.channels = max(0, channels)
        self.capacityFrames = max(0, capacityFrames)
    }

    private var queuedFrames: Int {
        channels > 0 ? (queue.count - head) / channels : 0
    }

    func write(frames: [UInt32]) -> Int {
        guard channels > 0 else { return 0 }
        let offered = frames.count / channels  // whole frames only; a trailing partial frame is ignored
        let room = max(0, capacityFrames - queuedFrames)
        let accepted = min(offered, room)
        guard accepted > 0 else { return 0 }
        compactIfUseful()
        queue.append(contentsOf: frames[frames.startIndex..<(frames.startIndex + accepted * channels)])
        return accepted
    }

    func render(frameCount: Int) -> [UInt32] {
        guard channels > 0, frameCount > 0 else { return [] }
        var frames = frameCount
        if frames > 4096 {
            // Outside the contract's range: honour it, but within a sane bound.
            frames = min(frames, max(4096, Self.maxWordsForRuledOutRequest / channels))
        }
        let (words, overflow) = frames.multipliedReportingOverflow(by: channels)
        guard !overflow else { return [] }

        var out: [UInt32] = []
        out.reserveCapacity(words)
        for _ in 0..<frames {
            if !muted, head < queue.count {
                let marker = UInt8(truncatingIfNeeded: queue[head] >> 24)
                if let last = lastMarker, last == marker {
                    // The music would repeat the previous frame's marker: one silence frame in between.
                    appendSilenceFrame(to: &out)
                } else {
                    out.append(contentsOf: queue[head..<(head + channels)])
                    head += channels
                    lastMarker = marker
                }
            } else {
                appendSilenceFrame(to: &out)
            }
        }
        if head >= queue.count {
            queue.removeAll(keepingCapacity: true)
            head = 0
        }
        return out
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
    }

    func setGain(_ gain: Double) {
        // DoP is always passthrough: gain does not apply.
    }

    func setEqualizer(_ on: Bool) {
        // DoP is always passthrough: the equalizer does not apply.
    }

    private func appendSilenceFrame(to out: inout [UInt32]) {
        let marker = lastMarker == Self.markerLow ? Self.markerHigh : Self.markerLow
        let word = UInt32(marker) << 24 | Self.silenceByte << 16 | Self.silenceByte << 8
        for _ in 0..<channels {
            out.append(word)
        }
        lastMarker = marker
    }

    /// Drops already played words from the front once they make up at least half the storage.
    private func compactIfUseful() {
        guard head > 0, head * 2 >= queue.count else { return }
        queue.removeSubrange(0..<head)
        head = 0
    }
}
