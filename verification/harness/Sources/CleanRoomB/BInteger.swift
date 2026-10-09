//
// Role B implementation of the integer-mode output stream contract.
//

import Contracts

public enum BInteger {
    public static let subject: (any IntegerOutput)? = BIntegerOutput()
}

/// Factory for integer stages.
struct BIntegerOutput: IntegerOutput {
    func makeStage(channels: Int, capacityFrames: Int) -> any IntegerStage {
        BIntegerStage(channels: channels, capacityFrames: capacityFrames)
    }
}

/// A FIFO of interleaved frames of 32-bit words, copied through bit for bit. Words are never interpreted.
///
/// Storage grows only with what is actually written, so a very large `capacityFrames` costs nothing up front.
final class BIntegerStage: IntegerStage {
    /// Words per frame. A stage with fewer than one channel accepts nothing and renders nothing.
    private let channels: Int
    /// The most frames held at once (never negative).
    private let capacityFrames: Int
    /// Written words; the unplayed ones are `storage[readIndex...]`, always whole frames.
    private var storage: [UInt32] = []
    private var readIndex = 0
    private var muted = false

    init(channels: Int, capacityFrames: Int) {
        self.channels = channels
        self.capacityFrames = max(capacityFrames, 0)
    }

    /// Frames written and not yet played.
    private var queuedFrames: Int {
        channels > 0 ? (storage.count - readIndex) / channels : 0
    }

    func write(words: [UInt32]) -> Int {
        guard channels > 0 else { return 0 }
        let offered = words.count / channels  // whole frames only; a trailing partial frame is not taken
        let room = capacityFrames - queuedFrames
        let accepted = min(offered, room)
        guard accepted > 0 else { return 0 }
        compactIfWorthwhile()
        storage.append(contentsOf: words[0..<(accepted * channels)])
        return accepted
    }

    func render(frameCount: Int) -> [UInt32] {
        guard channels > 0, frameCount >= 1, frameCount <= 4096 else { return [] }
        let (total, overflow) = frameCount.multipliedReportingOverflow(by: channels)
        guard !overflow else { return [] }

        let played = muted ? 0 : min(frameCount, queuedFrames)
        if played == 0 {
            return [UInt32](repeating: 0, count: total)
        }

        var out = [UInt32]()
        out.reserveCapacity(total)
        let end = readIndex + played * channels
        out.append(contentsOf: storage[readIndex..<end])
        readIndex = end
        if out.count < total {
            // Nothing written remains: the rest of this buffer is silence.
            out.append(contentsOf: repeatElement(0, count: total - out.count))
        }
        compactIfWorthwhile()
        return out
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
    }

    /// Drops played words from the front once they make up at least half the storage (amortised O(1)).
    private func compactIfWorthwhile() {
        if readIndex == 0 { return }
        if readIndex == storage.count {
            storage.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex >= storage.count / 2 {
            storage.removeSubrange(0..<readIndex)
            readIndex = 0
        }
    }
}
