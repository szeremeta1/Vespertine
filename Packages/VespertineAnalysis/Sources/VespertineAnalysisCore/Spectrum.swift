//
// Vespertine — magnitude spectra for the live display and for file analysis.
// Uses Accelerate's FFT on Apple platforms and a portable radix-2 FFT elsewhere (Linux servers);
// both produce the same normalised dBFS values (tested against each other).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Log-spaced magnitude bands from a mono time-domain block.
public final class SpectrumAnalyzer: @unchecked Sendable {
    public let size: Int
    private let window: [Float]
    private let portable: PortableFFT?
    #if canImport(Accelerate)
    private let fft: vDSP.FFT<DSPSplitComplex>?
    private var real: [Float]
    private var imag: [Float]
    #endif

    /// `forcePortable` uses the portable FFT even where Accelerate exists (for parity tests).
    public init(size: Int = 4096, forcePortable: Bool = false) {
        precondition(size.nonzeroBitCount == 1 && size >= 4)
        self.size = size
        // Hann, "denormalized" (peak 1): w[n] = 0.5·(1 − cos(2πn/N)), the same as vDSP's.
        window = (0..<size).map { Float(0.5 * (1 - cos(2 * Double.pi * Double($0) / Double(size)))) }
        #if canImport(Accelerate)
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
        if forcePortable {
            fft = nil
            portable = PortableFFT(size: size)
        } else {
            fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(size))), radix: .radix2, ofType: DSPSplitComplex.self)!
            portable = nil
        }
        #else
        portable = PortableFFT(size: size)
        #endif
    }

    /// Magnitudes in dBFS for each FFT bin (size/2 values).
    public func magnitudes(_ samples: [Float]) -> [Float] {
        precondition(samples.count >= size)
        let tail = samples.suffix(size)
        var windowed = [Float](repeating: 0, count: size)
        for (i, s) in tail.enumerated() { windowed[i] = s * window[i] }
        let half = size / 2
        var mags: [Float]
        if let portable {
            mags = portable.packedMagnitudes(windowed)
        } else {
            #if canImport(Accelerate)
            mags = [Float](repeating: 0, count: half)
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    fft!.forward(input: split, output: &split)
                    vDSP.absolute(split, result: &mags)
                }
            }
            #else
            mags = []
            #endif
        }
        // Normalise: Hann coherent gain 0.5, FFT scaling 2/N → full-scale sine ≈ 0 dBFS.
        let scale = 1.0 / Float(half)
        return mags.map { m in
            let a = m * scale
            return a > 0 ? max(20 * log10(a), -160) : -160
        }
    }

    /// `count` log-spaced bands between `lowHz` and `highHz`, each 0…1 over a 90 dB range.
    public func bands(_ samples: [Float], sampleRate: Double, count: Int, lowHz: Double = 25, highHz: Double = 20_000) -> [Float] {
        guard count > 0, sampleRate.isFinite, sampleRate > 0, lowHz.isFinite, lowHz > 0,
              highHz.isFinite, highHz > 0 else { return [] }
        let db = magnitudes(samples)
        let binHz = sampleRate / Double(size)
        let top = min(highHz, sampleRate / 2)
        return (0..<count).map { i in
            let f0 = lowHz * pow(top / lowHz, Double(i) / Double(count))
            let f1 = lowHz * pow(top / lowHz, Double(i + 1) / Double(count))
            let b0 = min(db.count - 1, max(1, Int(f0 / binHz)))
            let b1 = min(db.count, max(b0 + 1, Int(f1 / binHz)))
            let peak = db[b0..<b1].max() ?? -160
            return Float(max(0, min(1, (Double(peak) + 90) / 90)))
        }
    }
}

/// Iterative radix-2 complex FFT (double precision) of a real block, returning magnitudes packed
/// the way Accelerate's real FFT reports them: bin k is 2·|X[k]|, and bin 0 carries DC and Nyquist
/// together (hypot of both, each doubled).
struct PortableFFT: Sendable {
    let size: Int
    private let cosTable: [Double]
    private let sinTable: [Double]
    private let reversed: [Int]

    init(size: Int) {
        precondition(size.nonzeroBitCount == 1 && size >= 4)
        self.size = size
        cosTable = (0..<size / 2).map { cos(2 * Double.pi * Double($0) / Double(size)) }
        sinTable = (0..<size / 2).map { sin(2 * Double.pi * Double($0) / Double(size)) }
        let bits = size.trailingZeroBitCount
        reversed = (0..<size).map { i in
            var r = 0, v = i
            for _ in 0..<bits { r = (r << 1) | (v & 1); v >>= 1 }
            return r
        }
    }

    func packedMagnitudes(_ input: [Float]) -> [Float] {
        let n = size
        var re = [Double](repeating: 0, count: n), im = [Double](repeating: 0, count: n)
        for i in 0..<n { re[reversed[i]] = Double(input[i]) }
        var len = 2
        while len <= n {
            let half = len / 2, step = n / len
            var start = 0
            while start < n {
                for k in 0..<half {
                    let c = cosTable[k * step], s = -sinTable[k * step]
                    let a = start + k, b = a + half
                    let tr = re[b] * c - im[b] * s, ti = re[b] * s + im[b] * c
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                }
                start += len
            }
            len <<= 1
        }
        var out = [Float](repeating: 0, count: n / 2)
        out[0] = Float((2 * re[0]).magnitude.hypot(2 * re[n / 2]))
        for k in 1..<n / 2 { out[k] = Float(2 * (re[k] * re[k] + im[k] * im[k]).squareRoot()) }
        return out
    }
}

private extension Double {
    func hypot(_ other: Double) -> Double { (self * self + other * other).squareRoot() }
}
