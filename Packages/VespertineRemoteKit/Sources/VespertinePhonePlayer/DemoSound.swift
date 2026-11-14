//
// Vespertine: sound for the demo. The built-in demo has a made-up library and no Mac, so its songs are a few soft notes the
// app makes itself: different for each song, the same every time, nobody's recording. It is served through the same stream
// channel a Mac's songs come through, so the demo plays with the real player.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
#if canImport(Network) && canImport(AVFAudio)
import VespertineRemoteClient
#endif
import VespertineRemoteProtocol

public enum DemoSound {
    public static let sampleRate = 44_100
    /// How long a demo song sounds.
    public static let defaultSeconds: Double = 45

    /// A 16-bit stereo WAVE file of `seconds` of sound for `song`.
    public static func wave(song: Int64, seconds: Double) -> Data {
        let frames = max(1, Int(seconds * Double(sampleRate)))
        var random = Generator(seed: UInt64(bitPattern: song) &* 0x9E37_79B9_7F4A_7C15 &+ 1)
        // A pentatonic scale on one of a few roots, played as slow overlapping notes.
        let roots: [Double] = [196.00, 220.00, 246.94, 261.63, 293.66]
        let root = roots[Int(random.next() % UInt64(roots.count))]
        let steps: [Double] = [0, 2, 4, 7, 9, 12, 14, 16]
        let beat = 0.42 + Double(random.next() % 30) / 100
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        var time = 0.0
        while time < seconds {
            let step = steps[Int(random.next() % UInt64(steps.count))]
            let frequency = root * pow(2, step / 12)
            let pan = Double(random.next() % 100) / 100
            let length = beat * Double(2 + random.next() % 4)
            let start = Int(time * Double(sampleRate))
            let count = min(Int(length * Double(sampleRate)), frames - start)
            if count > 0 {
                for i in 0..<count {
                    let t = Double(i) / Double(sampleRate)
                    // A soft attack and a long decay; a little of the octave above for warmth.
                    let envelope = min(1, t / 0.03) * exp(-2.2 * t / length) * min(1, Double(count - i) / (0.02 * Double(sampleRate)))
                    let value = 0.11 * envelope * (sin(2 * .pi * frequency * t) + 0.3 * sin(4 * .pi * frequency * t))
                    left[start + i] += Float(value * (1 - 0.6 * pan))
                    right[start + i] += Float(value * (0.4 + 0.6 * pan))
                }
            }
            time += beat
        }
        // In from silence, out to silence.
        let fade = min(frames / 2, sampleRate / 4)
        for i in 0..<fade {
            let gain = Float(i) / Float(fade)
            left[i] *= gain; right[i] *= gain
            left[frames - 1 - i] *= gain; right[frames - 1 - i] *= gain
        }

        var data = Data(capacity: 44 + frames * 4)
        func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put32(UInt32(36 + frames * 4)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put32(16); put16(1); put16(2); put32(UInt32(sampleRate)); put32(UInt32(sampleRate * 4)); put16(4); put16(16)
        data.append(contentsOf: Array("data".utf8)); put32(UInt32(frames * 4))
        var samples = [Int16](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            samples[2 * i] = Int16(max(-1, min(1, left[i])) * 32_767).littleEndian
            samples[2 * i + 1] = Int16(max(-1, min(1, right[i])) * 32_767).littleEndian
        }
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// SplitMix64: the same notes for a song on every device.
    private struct Generator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

#if canImport(Network) && canImport(AVFAudio)
extension DemoSound {
    /// The demo's stream channel: every song opens, and is its made sound.
    public static func client(seconds: Double = defaultSeconds) -> PhoneStreamClient {
        let streams = Streams(seconds: seconds)
        return PhoneStreamClient(open: { song, _ in .streamOpened(streams.open(song)) },
                                 read: { stream, offset, length in try streams.read(stream, offset, length) },
                                 close: { stream in streams.close(stream) },
                                 isConnected: { true })
    }

    private final class Streams: @unchecked Sendable {
        private let lock = NSLock()
        private let seconds: Double
        private var open: [Int: Data] = [:]
        private var next = 0

        init(seconds: Double) { self.seconds = seconds }

        func open(_ song: Int64) -> StreamDescriptor {
            let data = DemoSound.wave(song: song, seconds: seconds)
            return lock.withLock {
                next += 1
                open[next] = data
                return StreamDescriptor(stream: next, kind: .original, byteSize: Int64(data.count),
                                        format: StreamFormat(codec: "WAV", container: "wav", sampleRate: Double(DemoSound.sampleRate), bitDepth: 16,
                                                             channels: 2, channelLabels: nil, lossless: true),
                                        frames: Int64((data.count - 44) / 4), tag: "demo-\(song)-\(Int(seconds))", chunkSize: RemoteProtocol.defaultChunkSize)
            }
        }

        func read(_ stream: Int, _ offset: Int64, _ length: Int) throws -> StreamFrame {
            guard let data = lock.withLock({ open[stream] }), offset >= 0, offset <= Int64(data.count) else { throw RemoteLinkError.closed }
            let end = min(Int(offset) + max(0, length), data.count)
            return StreamFrame(request: 0, stream: stream, offset: offset, endOfStream: end >= data.count, payload: data.subdata(in: Int(offset)..<end))
        }

        func close(_ stream: Int) { lock.withLock { open[stream] = nil } }
    }
}
#endif
