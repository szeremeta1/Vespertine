//
// Role B implementation of the float output stream contract (unity gain, no equalizer),
// plus the 24-bit integer to Float32 mapping.
//

import Contracts

public enum BFloat {
    public static let subject: (any FloatOutput)? = BFloatOutput()
}

/// Factory for float stages and the 24-bit conversion.
struct BFloatOutput: FloatOutput {
    /// Full scale for signed 24-bit samples: 2^23.
    private static let fullScale: Float = 8_388_608

    /// k ÷ 2^23 for each k, in order. Exact for every 24-bit k: any |k| ≤ 2^24 converts to Float32 without
    /// rounding, and dividing by a power of two only changes the exponent (no result is subnormal).
    func int24ToFloat(samples: [Int32]) -> [Float] {
        let count = samples.count
        if count == 0 { return [] }
        return [Float](unsafeUninitializedCapacity: count) { out, initialized in
            samples.withUnsafeBufferPointer { input in
                for i in 0..<count {
                    out[i] = Float(input[i]) / BFloatOutput.fullScale
                }
            }
            initialized = count
        }
    }

    func makeStage(channels: Int, capacityFrames: Int) -> any FloatStage {
        BFloatStage(channels: channels, capacityFrames: capacityFrames)
    }
}

/// A FIFO of interleaved frames, copied through unchanged (unity gain, no equalizer).
///
/// Storage grows only with what is actually written, so a very large `capacityFrames` costs nothing up front.
final class BFloatStage: FloatStage {
    /// Samples per frame. A stage with fewer than one channel accepts nothing and renders nothing.
    private let channels: Int
    /// The most frames held at once (never negative).
    private let capacityFrames: Int
    /// Written samples; the unplayed ones are `storage[readIndex...]`, always whole frames.
    private var storage: [Float] = []
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

    func write(samples: [Float]) -> Int {
        guard channels > 0 else { return 0 }
        let offered = samples.count / channels  // whole frames only; a trailing partial frame is not taken
        let room = capacityFrames - queuedFrames
        let accepted = min(offered, room)
        guard accepted > 0 else { return 0 }
        compactIfWorthwhile()
        storage.append(contentsOf: samples[0..<(accepted * channels)])
        return accepted
    }

    func render(frameCount: Int) -> [Float] {
        guard channels > 0, frameCount >= 1, frameCount <= 4096 else { return [] }
        let (total, overflow) = frameCount.multipliedReportingOverflow(by: channels)
        guard !overflow else { return [] }

        let played = muted ? 0 : min(frameCount, queuedFrames)
        if played == 0 {
            return [Float](repeating: 0, count: total)
        }

        var out = [Float]()
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

    /// Drops played samples from the front once they make up at least half the storage (amortised O(1)).
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
