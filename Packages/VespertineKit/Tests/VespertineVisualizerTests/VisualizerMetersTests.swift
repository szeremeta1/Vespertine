//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineVisualizer

@Suite("Visualizer meters")
struct VisualizerMetersTests {
    static let rate = 48_000.0
    static let reference = -18.0   // dBFS (sine RMS) for 0 VU and PPM 4

    /// A 1 kHz sine whose RMS is `db` dBFS.
    static func tone(_ db: Double, frames: Int, from start: Int = 0) -> [Float] {
        let peak = pow(10, db / 20) * 2.0.squareRoot()
        return (0..<frames).map { Float(peak * sin(2 * .pi * 1000 * Double(start + $0) / rate)) }
    }

    /// Runs `meters` over `signal` in 1 ms blocks, recording the VU needle and the PPM after each.
    static func run(_ meters: inout VisualizerMeters, _ signal: [Float]) -> (vu: [Double], ppm: [Double]) {
        var vu: [Double] = [], ppm: [Double] = []
        let block = Int(rate / 1000)
        var i = 0
        while i < signal.count {
            let chunk = Array(signal[i..<min(i + block, signal.count)])
            chunk.withUnsafeBufferPointer { b in meters.process(left: b, right: b, sampleRate: rate, referenceDBFS: reference) }
            vu.append(meters.vu.x)
            ppm.append(meters.ppm(referenceDBFS: reference).x)
            i += block
        }
        return (vu, ppm)
    }

    static func silence(_ meters: inout VisualizerMeters, ms: Int) -> [Double] {
        var ppm: [Double] = []
        for _ in 0..<ms {
            meters.process(left: UnsafeBufferPointer(start: nil, count: 0), right: UnsafeBufferPointer(start: nil, count: 0),
                           silentFrames: Int(rate / 1000), sampleRate: rate, referenceDBFS: reference)
            ppm.append(meters.ppm(referenceDBFS: reference).x)
        }
        return ppm
    }

    @Test("VU: a tone at the reference reads 0 VU, 10 dB under reads -10 VU (on a scale linear in voltage)")
    func vuCalibration() {
        for (db, expected) in [(0.0, VisualizerMeters.zeroVU), (-10, VisualizerMeters.zeroVU * pow(10, -0.5))] {
            var m = VisualizerMeters()
            let (vu, _) = Self.run(&m, Self.tone(Self.reference + db, frames: Int(Self.rate)))
            let settled = vu.suffix(200).reduce(0, +) / 200
            #expect(abs(20 * log10(settled / expected)) < 0.1, "\(db) dB read \(settled)")
        }
        #expect(abs(VisualizerMeters.vuTravel(decibels: 0) - VisualizerMeters.zeroVU) < 1e-12)
        #expect(abs(VisualizerMeters.vuTravel(decibels: 3) - 1) < 1e-3)
    }

    @Test("VU ballistics (IEC 60268-17): 99 % of the reading in 300 ms ± 10 %, overshoot 1 to 1.5 %")
    func vuBallistics() {
        var m = VisualizerMeters()
        let (vu, _) = Self.run(&m, Self.tone(Self.reference, frames: Int(Self.rate * 1.5)))
        let steady = vu.suffix(300).reduce(0, +) / 300
        let reached = vu.firstIndex { $0 >= 0.99 * steady }.map { Double($0 + 1) } ?? .infinity   // ms
        #expect(reached >= 270 && reached <= 330, "99 % after \(reached) ms")
        let overshoot = (vu.max() ?? 0) / steady - 1
        #expect(overshoot >= 0.008 && overshoot <= 0.016, "overshoot \(overshoot * 100) %")
    }

    @Test("VU: the needle falls back when the music stops, and pegs against its stop, not beyond")
    func vuFallsAndPegs() {
        var m = VisualizerMeters()
        _ = Self.run(&m, Self.tone(Self.reference + 20, frames: Int(Self.rate)))
        #expect(m.vu.x <= VisualizerMeters.vuTravel.upperBound && m.vu.x > 1)
        _ = Self.silence(&m, ms: 1000)
        #expect(m.vu.x < 0.01 && m.vu.x >= 0)
    }

    @Test("PPM (IEC 60268-10 Type IIa): a steady tone at the reference reads PPM 4; a 10 ms burst reads 2 dB under it")
    func ppmIntegration() {
        var steadyMeter = VisualizerMeters()
        let steady = Self.run(&steadyMeter, Self.tone(Self.reference, frames: Int(Self.rate))).ppm.last ?? -40
        #expect(abs(steady) < 0.1, "steady tone read \(steady) dB")
        var burst = VisualizerMeters()
        let ten = Self.run(&burst, Self.tone(Self.reference, frames: Int(Self.rate * 0.010))).ppm.max() ?? -40
        #expect(abs(ten - steady - -2) < 0.5, "10 ms burst read \(ten - steady) dB")
        var shorter = VisualizerMeters()
        let five = Self.run(&shorter, Self.tone(Self.reference, frames: Int(Self.rate * 0.005))).ppm.max() ?? -40
        #expect(five < ten - 1)
    }

    @Test("PPM: falls 24 dB in 2.8 s")
    func ppmFall() {
        var m = VisualizerMeters()
        _ = Self.run(&m, Self.tone(Self.reference + 8, frames: Int(Self.rate / 2)))
        let start = m.ppm(referenceDBFS: Self.reference).x
        let fall = Self.silence(&m, ms: 2800)
        #expect(abs((start - (fall.last ?? 0)) - 24) < 0.5, "fell \(start - (fall.last ?? 0)) dB")
    }

    @Test("PPM scale: marks 1 to 7 are 4 dB apart, PPM 4 at the reference; below 1 the needle drops to rest")
    func ppmScale() {
        for m in 1...7 {
            #expect(abs(VisualizerMeters.ppmTravel(decibels: Double(m - 4) * 4) - VisualizerMeters.ppmMark(Double(m))) < 1e-12)
        }
        #expect(VisualizerMeters.ppmTravel(decibels: -24) == 0)
        #expect(VisualizerMeters.ppmTravel(decibels: 30) <= VisualizerMeters.vuTravel.upperBound)
    }

    @Test("The analyzer's meters: fixed references are kept; automatic follows the music, so quiet and loud masters read alike")
    func analyzerReference() {
        func settle(_ db: Double, reference: Float?) -> VisualizerFrame {
            var c = VisualizerAnalyzer.Configuration()
            c.meterReferenceDB = reference
            let analyzer = VisualizerAnalyzer(configuration: c)
            let n = VisualizerAnalyzer.fftSize(for: Self.rate), hop = Int(Self.rate / 60)
            let x = Self.tone(db, frames: n + hop * 60 * 20)
            var frame = VisualizerFrame.silent(bands: 64, fine: 512)
            for k in 0..<(60 * 20) {
                let window = Array(x[(k * hop)..<(k * hop + n)])
                frame = analyzer.process(left: window, right: window, sampleRate: Self.rate, fresh: true, dt: 1.0 / 60)
            }
            return frame
        }
        let fixed = settle(-18, reference: -18)
        #expect(fixed.meterReferenceDB == -18)
        #expect(abs(Double(fixed.vu.x) - VisualizerMeters.zeroVU) < 0.02)
        #expect(abs(fixed.ppm.x) < 0.3)
        let quiet = settle(-26, reference: nil), loud = settle(-9, reference: nil)
        #expect(abs(quiet.vu.x - loud.vu.x) < 0.03, "quiet \(quiet.vu.x), loud \(loud.vu.x)")
        // 1 dB over the loudness: a steady tone sits just under 0 VU.
        #expect(abs(Double(loud.meterReferenceDB) - -8) < 0.3)
    }

    @Test("Correlation: +1 for mono, -1 out of phase, near 0 for unrelated channels; the scope gets the newest samples")
    func correlation() {
        let rate = 48_000.0, n = VisualizerAnalyzer.fftSize(for: rate)
        func settle(_ l: [Float], _ r: [Float]) -> VisualizerFrame {
            let analyzer = VisualizerAnalyzer()
            var frame = VisualizerFrame.silent(bands: 64, fine: 512)
            for _ in 0..<60 { frame = analyzer.process(left: l, right: r, sampleRate: rate, fresh: true, dt: 1.0 / 60) }
            return frame
        }
        let x = Self.tone(-12, frames: n)
        #expect(settle(x, x).correlation > 0.99)
        #expect(settle(x, x.map { -$0 }).correlation < -0.99)
        var rng = SplitMix64(seed: 7)
        let a = (0..<n).map { _ in Float.random(in: -0.5...0.5, using: &rng) }, b = (0..<n).map { _ in Float.random(in: -0.5...0.5, using: &rng) }
        #expect(abs(settle(a, b).correlation) < 0.1)
        #expect(settle([Float](repeating: 0, count: n), x).correlation == 0)
        let frame = settle(a, b)
        #expect(frame.stereo.count == VisualizerFrame.stereoCount)
        #expect(frame.stereo.last == SIMD2(a[n - 1], b[n - 1]))
        #expect(frame.stereo.first == SIMD2(a[n - VisualizerFrame.stereoCount], b[n - VisualizerFrame.stereoCount]))
        #expect(VisualizerAnalyzer.stereoStride(for: 96_000) == 2 && VisualizerAnalyzer.stereoStride(for: 192_000) == 4)
    }
}
