//
// Vespertine: keeps what an audio engine puts out. A tap on the engine's main mixer hands over every buffer on its way
// to the output, after everything Vespertine does to a song (decoding, the join between songs, ReplayGain) and after the
// mixer has brought it to the output's rate. What iOS and the hardware do after that isn't in it. Used by the phone bench.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(AVFAudio)
import AVFAudio
import Foundation

public final class OutputCapture: @unchecked Sendable {
    /// What was kept since the last `restart()`.
    public struct Take: Sendable {
        /// Up to two channels.
        public var channels: [[Float]]
        public var rate: Double
        /// Seconds into the take where the tap skipped audio (it said so itself, by its clock): a silence there is the
        /// capture's, not the player's.
        public var breaks: [Double]

        public var seconds: Double { rate > 0 ? Double(channels.first?.count ?? 0) / rate : 0 }
    }

    private let lock = NSLock()
    private var channels: [[Float]] = []
    private var rate = 0.0
    private var breaks: [Double] = []
    /// The sample time the next buffer should carry, when the tap gives one.
    private var expected: Int64?
    /// No more than this is kept (seconds): a capture that was forgotten must not fill the phone's memory.
    private let limit: Double

    public init(limit: Double = 180) { self.limit = limit }

    /// Starts keeping what `node` puts out on its first bus.
    public func install(on node: AVAudioNode) {
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 4096, format: nil) { [self] buffer, time in
            append(buffer, sampleTime: time.isSampleTimeValid ? time.sampleTime : nil)
        }
    }

    public func remove(from node: AVAudioNode) { node.removeTap(onBus: 0) }

    /// Forgets what was kept: the next take starts with the next buffer.
    public func restart() {
        lock.withLock {
            channels = []
            breaks = []
            expected = nil
        }
    }

    /// Seconds kept so far.
    public var seconds: Double { lock.withLock { rate > 0 ? Double(channels.first?.count ?? 0) / rate : 0 } }

    public func take() -> Take { lock.withLock { Take(channels: channels, rate: rate, breaks: breaks) } }

    /// One buffer of the output. `sampleTime`: where the engine says it sits on its clock, when it says.
    public func append(_ buffer: AVAudioPCMBuffer, sampleTime: Int64?) {
        guard let planes = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let count = min(2, Int(buffer.format.channelCount))
        guard frames > 0, count > 0 else { return }
        lock.withLock {
            if channels.count != count || rate != buffer.format.sampleRate {
                channels = [[Float]](repeating: [], count: count)
                rate = buffer.format.sampleRate
                breaks = []
                expected = nil
            }
            guard Double(channels[0].count) < limit * rate else { return }
            if let sampleTime {
                if let expected, expected != sampleTime { breaks.append(Double(channels[0].count) / rate) }
                expected = sampleTime + Int64(frames)
            }
            for channel in 0..<count {
                channels[channel].append(contentsOf: UnsafeBufferPointer(start: planes[channel], count: frames))
            }
        }
    }
}
#endif
