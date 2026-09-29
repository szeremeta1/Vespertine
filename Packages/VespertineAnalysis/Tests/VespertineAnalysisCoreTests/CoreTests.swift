//
// Vespertine — the portable analysis core matches the Accelerate one, and results don't depend on
// how a decoder chunks the audio.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAnalysisCore
#if canImport(Accelerate)
import Accelerate
#endif

@Suite("Portable analysis core")
struct CoreTests {
    static func signal(_ n: Int, seed: UInt64 = 7) -> [Float] {
        var state = seed
        return (0..<n).map { i in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: state) >> 40) / Float(1 << 23) * 0.05
            return 0.4 * sin(Float(i) * 0.031) + 0.2 * sin(Float(i) * 0.73) + noise
        }
    }

    #if canImport(Accelerate)
    @Test("Hann window matches vDSP's denormalized Hann exactly")
    func window() {
        let v = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 4096, isHalfWindow: false)
        let mine = (0..<4096).map { Float(0.5 * (1 - cos(2 * Double.pi * Double($0) / 4096))) }
        #expect(zip(v, mine).allSatisfy { abs($0 - $1) < 1e-6 })
    }

    @Test("Portable FFT magnitudes match Accelerate's", arguments: [1024, 4096, 16384])
    func fftParity(size: Int) {
        let x = Self.signal(size)
        let a = SpectrumAnalyzer(size: size).magnitudes(x)
        let b = SpectrumAnalyzer(size: size, forcePortable: true).magnitudes(x)
        var worst: Float = 0
        for (p, q) in zip(a, b) where p > -120 { worst = max(worst, abs(p - q)) }
        #expect(worst < 0.01, "worst \(worst) dB")
    }
    #endif

    @Test("A full-scale sine reads about 0 dBFS")
    func calibration() {
        let n = 8192
        let x = (0..<n).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 48_000)) }
        let db = SpectrumAnalyzer(size: n, forcePortable: true).magnitudes(x)
        #expect(abs((db.max() ?? -160) - 0) < 1.5)
    }

    @Test("Results don't depend on decoder chunk sizes")
    func chunking() throws {
        let rate = 48_000.0, frames = 48_000 * 6
        let mono = Self.signal(frames, seed: 3)
        let stereo = mono.flatMap { [$0, $0 * 0.5] }
        func run(_ chunk: Int) throws -> FileAnalysis {
            let acc = AnalysisAccumulator(sampleRate: rate, channels: 2, claimedBitDepth: 24, forcePortableFFT: true)
            try stereo.withUnsafeBufferPointer { buf in
                var f = 0
                while f < frames {
                    let n = min(chunk, frames - f)
                    try acc.add(interleaved: UnsafeBufferPointer(rebasing: buf[(f * 2)..<((f + n) * 2)]), frames: n)
                    f += n
                }
            }
            return acc.finish()
        }
        let a = try run(4096), b = try run(16_384), c = try run(1_000)
        #expect(a == b && b == c)
    }

    @Test("Non-finite samples are rejected")
    func nonFinite() {
        let acc = AnalysisAccumulator(sampleRate: 44_100, channels: 1, claimedBitDepth: 16)
        let bad: [Float] = [0, .nan, 0]
        #expect(throws: AnalysisError.self) { try bad.withUnsafeBufferPointer { try acc.add(interleaved: $0, frames: 3) } }
    }
}
