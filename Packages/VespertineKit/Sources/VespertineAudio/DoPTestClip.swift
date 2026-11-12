//
// Vespertine: the short DSD64 clip the DoP test plays: a soft three-note chord that fades in from silence.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A few seconds of DSD64, made in code (nothing to ship, nothing to license) so its level is exactly what the constants
/// say. Heard through a DAC that decodes DoP it is a soft chord. Heard through one that doesn't, it is the 24-bit PCM
/// the DoP frames look like: an inaudible 88 kHz marker plus the DSD bits in the 16 low bits, never above
/// `DoPTestConstants.maxMisreadAudibleDBFS` in the audible band (a test renders that and checks it).
public struct DoPTestClip: Sendable {
    public let channels = 2
    public let dsdRate = 2_822_400
    /// One plane per channel, 8 DSD bits per byte, the oldest bit in the MSB (what `DoP.pack` takes).
    public let planes: [[UInt8]]
    /// The same bits as a DSF file (oldest bit in the LSB, 4096-byte blocks per channel), for the engine to open.
    public let dsfData: Data

    /// The master level over time as a fraction of DSD full scale: 0 at the start, a smooth rise over the fade-in, the
    /// ceiling until the fade-out, 0 again at the end. Never above `maxToneAmplitude`.
    public static func envelope(at t: Double) -> Double {
        let total = DoPTestConstants.clipSeconds
        guard t > 0, t < total else { return 0 }
        func smooth(_ x: Double) -> Double { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }
        let rise = smooth(t / DoPTestConstants.fadeInSeconds)
        let fall = smooth((total - t) / DoPTestConstants.fadeOutSeconds)
        return DoPTestConstants.maxToneAmplitude * min(rise, fall)
    }

    /// The chord's notes: C5, E5, G5, each coming in a second after the one before (an arpeggio, so it is music and
    /// not a tone), then all three held.
    private static let notes: [(hz: Double, start: Double)] = [(523.25, 0), (659.25, 1.0), (783.99, 2.0)]

    /// The signal fed to the modulator at `t`, within ±`envelope(at: t)`.
    static func signal(at t: Double) -> Double {
        let env = envelope(at: t)
        guard env > 0 else { return 0 }
        var sum = 0.0
        for note in notes where t >= note.start {
            let entry = min((t - note.start) / 0.3, 1)                // 0.3 s to come in, so a note starts without a click
            sum += entry * sin(2 * Double.pi * note.hz * t)
        }
        return env * sum / Double(notes.count)
    }

    public static func make() -> DoPTestClip {
        let rate = 2_822_400
        let samples = Int(DoPTestConstants.clipSeconds * Double(rate))
        let bytes = (samples + 7) / 8
        var msb = [UInt8](repeating: 0, count: bytes + (bytes & 1))
        var lsb = [UInt8](repeating: 0, count: msb.count)
        // The signal changes at 44.1 kHz (every 64 DSD samples) and is interpolated between, which is plenty for a chord
        // below 1 kHz and keeps the sine calls to a few hundred thousand.
        let step = 64
        var v1 = 0.0, v2 = 0.0, y = 0.0
        var x0 = signal(at: 0), x1 = signal(at: Double(step) / Double(rate))
        for i in 0..<samples {
            let k = i % step
            if k == 0, i > 0 { x0 = x1; x1 = signal(at: Double(i + step) / Double(rate)) }
            let x = x0 + (x1 - x0) * Double(k) / Double(step)
            v1 += x - y                                              // a second-order sigma-delta modulator
            v2 += v1 - y
            y = v2 >= 0 ? 1 : -1
            if y > 0 {
                msb[i >> 3] |= UInt8(0x80 >> (i & 7))
                lsb[i >> 3] |= UInt8(1 << (i & 7))
            }
        }
        // DoP carries 16 bits a frame, so each plane is a whole number of 16-bit pairs; the extra byte is DSD silence.
        if bytes & 1 == 1 { msb[bytes] = DoP.silence; lsb[bytes] = 0x96 }
        return DoPTestClip(planes: [msb, msb], dsf: Self.dsf(lsb, samples: samples, rate: rate))
    }

    private init(planes: [[UInt8]], dsf: Data) {
        self.planes = planes
        dsfData = dsf
    }

    private static func dsf(_ channel: [UInt8], samples: Int, rate: Int) -> Data {
        let blockSize = 4096
        let blocks = (channel.count + blockSize - 1) / blockSize
        var padded = channel
        padded += [UInt8](repeating: 0x96, count: blocks * blockSize - channel.count)      // 0x96 is 0x69 in LSB-first order
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let dataBytes = UInt64(blocks * blockSize * 2)
        data.append(contentsOf: Array("DSD ".utf8)); u64(28); u64(28 + 52 + 12 + dataBytes); u64(0)
        data.append(contentsOf: Array("fmt ".utf8)); u64(52); u32(1); u32(0); u32(2); u32(2); u32(UInt32(rate)); u32(1)
        u64(UInt64(samples)); u32(UInt32(blockSize)); u32(0)
        data.append(contentsOf: Array("data".utf8)); u64(12 + dataBytes)
        for b in 0..<blocks {
            let block = padded[b * blockSize ..< (b + 1) * blockSize]
            data.append(contentsOf: block); data.append(contentsOf: block)
        }
        return data
    }
}
