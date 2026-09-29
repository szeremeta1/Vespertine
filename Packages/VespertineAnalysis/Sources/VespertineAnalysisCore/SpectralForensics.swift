//
// Vespertine — spectral forensics: tells genuine high-resolution audio from lossy, upsampled and
// "enhanced" copies (high frequencies synthesized by SBR-style bandwidth extension or AI upscalers).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lossy encoders low-pass the signal with a steep, frame-to-frame "brick wall" (MP3/AAC/Opus,
// typically 11–20 kHz) and zero individual bins below it at quiet moments ("holes"). Bandwidth
// extension (HE-AAC SBR, xHE-AAC, AI "enhancers", "remasters" made from streams) regenerates the
// band above that wall from the band below: the result is a level step at the old cutoff, then a
// flat, uniform shelf, often ending in a second wall. Natural recordings roll off gradually, and
// their only steep edge is the converter's anti-alias filter just below Nyquist.
//

import Foundation

public struct SpectralForensics: Sendable, Hashable, Codable {
    public init(cliffHz: Double?, cliffDropDB: Double, cliffConsistency: Double, belowDB: Double, aboveDB: Double, floorDB: Double,
                extensionHz: Double, extensionSlope: Double, holeRatio: Double, contentHz: Double, framesAnalyzed: Int,
                shelfHz: Double? = nil, shelfStepDB: Double = 0, shelfEndHz: Double = 0, shelfSlope: Double = 0,
                shelfAboveFloorDB: Double = 0, shelfConsistency: Double = 0) {
        self.cliffHz = cliffHz; self.cliffDropDB = cliffDropDB; self.cliffConsistency = cliffConsistency
        self.belowDB = belowDB; self.aboveDB = aboveDB; self.floorDB = floorDB
        self.extensionHz = extensionHz; self.extensionSlope = extensionSlope; self.holeRatio = holeRatio
        self.contentHz = contentHz; self.framesAnalyzed = framesAnalyzed
        self.shelfHz = shelfHz; self.shelfStepDB = shelfStepDB; self.shelfEndHz = shelfEndHz; self.shelfSlope = shelfSlope
        self.shelfAboveFloorDB = shelfAboveFloorDB; self.shelfConsistency = shelfConsistency
    }

    /// Frequency of the steepest spectral cliff, if one was found.
    public var cliffHz: Double?
    /// Level difference across the cliff (±400 Hz), dB.
    public var cliffDropDB: Double
    /// Fraction of active frames that show the cliff.
    public var cliffConsistency: Double
    /// Average level just below / just above the cliff, and the quietest region (floor), dB.
    public var belowDB: Double
    public var aboveDB: Double
    public var floorDB: Double
    /// Content above the cliff that is clearly above the floor, and how far it extends (Hz).
    public var extensionHz: Double
    /// Slope of that content, dB per kHz (natural high frequencies fall off; synthetic shelves are flat).
    public var extensionSlope: Double
    /// Fraction of near-empty bins just below the cliff (codec quantization "holes").
    public var holeRatio: Double
    /// Highest frequency with meaningful content (after any extension).
    public var contentHz: Double
    public var framesAnalyzed: Int
    /// A lower step with a flat shelf of content above it (the original cutoff of an extended file).
    public var shelfHz: Double? = nil
    public var shelfStepDB: Double = 0
    public var shelfEndHz: Double = 0
    public var shelfSlope: Double = 0
    public var shelfAboveFloorDB: Double = 0
    public var shelfConsistency: Double = 0
}

/// Accumulates per-frame spectra while a file is decoded, then measures it.
final class ForensicsAccumulator {
    let sampleRate: Double
    let fftSize: Int
    let bandHz: Double = 100
    let bandCount: Int
    private let analyzer: SpectrumAnalyzer
    private(set) var frames: [[Float]] = []      // band levels per analysed frame, dB
    private(set) var holes: [[Float]] = []       // hole fraction per 1 kHz region per frame (-1 = no content)
    private let binHz: Double

    init(sampleRate: Double, forcePortableFFT: Bool = false) {
        self.sampleRate = sampleRate
        // ~85 ms frames: 4096 at 44.1/48 kHz, 8192 at 88.2/96, 16384 at 176.4/192.
        var size = 4096
        while Double(size) / sampleRate < 0.07 { size *= 2 }
        fftSize = size
        analyzer = SpectrumAnalyzer(size: size, forcePortable: forcePortableFFT)
        binHz = sampleRate / Double(size)
        bandCount = Int((sampleRate / 2) / bandHz)
    }

    func add(_ mono: [Float]) {
        let db = analyzer.magnitudes(mono) // fftSize/2 bins, dBFS
        var bands = [Float](repeating: -160, count: bandCount)
        for b in 0..<bandCount {
            let lo = Int(Double(b) * bandHz / binHz), hi = min(db.count, max(lo + 1, Int(Double(b + 1) * bandHz / binHz)))
            guard lo < hi else { continue }
            var power: Double = 0
            for i in lo..<hi { power += pow(10, Double(db[i]) / 10) }
            bands[b] = Float(10 * log10(max(power / Double(hi - lo), 1e-16)))
        }
        frames.append(bands)

        // Holes: bins far below their 1 kHz region's median, where the region carries content.
        let regions = Int(sampleRate / 2 / 1000)
        var frameHoles = [Float](repeating: -1, count: regions)
        for r in 0..<regions {
            let lo = Int(Double(r) * 1000 / binHz), hi = min(db.count, Int(Double(r + 1) * 1000 / binHz))
            guard hi - lo > 8 else { continue }
            let slice = Array(db[lo..<hi]).sorted()
            let median = slice[slice.count / 2]
            guard median > -115 else { continue }
            let empty = slice.prefix { $0 < median - 30 }.count
            frameHoles[r] = Float(empty) / Float(slice.count)
        }
        holes.append(frameHoles)
    }

    func result() -> SpectralForensics {
        let nyquist = sampleRate / 2
        // Active frames: real content in the 1–4 kHz band.
        let lo1k = Int(1000 / bandHz), hi4k = min(bandCount, Int(4000 / bandHz))
        let active = frames.indices.filter { i in
            let mid = frames[i][lo1k..<hi4k]
            return mid.reduce(0, +) / Float(mid.count) > -75
        }
        let use = active.count >= 8 ? active : Array(frames.indices)
        guard !use.isEmpty, bandCount > 40 else {
            return SpectralForensics(cliffHz: nil, cliffDropDB: 0, cliffConsistency: 0, belowDB: -160, aboveDB: -160, floorDB: -160,
                                     extensionHz: 0, extensionSlope: 0, holeRatio: 0, contentHz: 0, framesAnalyzed: frames.count)
        }
        // Long-term spectrum: log-average of the active frames.
        var s = [Double](repeating: 0, count: bandCount)
        for i in use { for b in 0..<bandCount { s[b] += Double(frames[i][b]) } }
        for b in 0..<bandCount { s[b] /= Double(use.count) }

        func mean(_ a: Int, _ b: Int) -> Double {
            let lo = max(0, a), hi = min(bandCount, b)
            guard hi > lo else { return -160 }
            return s[lo..<hi].reduce(0, +) / Double(hi - lo)
        }
        // Floor: the quietest 1 kHz stretch above 1 kHz.
        var floor = 0.0
        do {
            var best = Double.infinity
            var b = Int(1000 / bandHz)
            while b + 10 <= bandCount { best = min(best, mean(b, b + 10)); b += 5 }
            floor = best.isFinite ? best : -160
        }

        // Steepest cliff between 9 kHz and just below Nyquist.
        var cliffBand = -1, drop = 0.0
        let start = Int(9000 / bandHz), stop = bandCount - 6
        if start < stop {
            for b in start..<stop {
                let d = mean(b - 6, b - 2) - mean(b + 2, b + 6)
                if d > drop { drop = d; cliffBand = b }
            }
        }
        let cliffHz = cliffBand >= 0 && drop >= 8 ? Double(cliffBand) * bandHz : nil
        var below = -160.0, above = -160.0, extensionHz = 0.0, slope = 0.0, consistency = 0.0, holeRatio = 0.0
        if let cliffHz {
            let c = cliffBand
            below = mean(c - 20, c - 3)
            above = mean(c + 3, min(bandCount, c + 20))
            // Content that continues above the cliff (allowing short dips).
            var end = c + 2, gap = 0
            var b = c + 2
            while b < bandCount {
                if s[b] > floor + 10 { end = b; gap = 0 } else { gap += 1; if gap > 5 { break } }
                b += 1
            }
            extensionHz = max(0, Double(end - c) * bandHz)
            if end - c > 8 {
                // Least-squares slope of the extension, dB per kHz.
                let xs = (c + 3...end - 2).map { Double($0) * bandHz / 1000 }
                let ys = (c + 3...end - 2).map { s[$0] }
                let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
                var num = 0.0, den = 0.0
                for (x, y) in zip(xs, ys) { num += (x - mx) * (y - my); den += (x - mx) * (x - mx) }
                slope = den > 0 ? num / den : 0
            }
            // Per-frame: does the cliff show up in each active frame with content below it?
            var seen = 0, with = 0
            for i in use {
                let f = frames[i]
                func fm(_ a: Int, _ b: Int) -> Double {
                    let lo = max(0, a), hi = min(bandCount, b)
                    return hi > lo ? Double(f[lo..<hi].reduce(0, +)) / Double(hi - lo) : -160
                }
                let bl = fm(c - 6, c - 2)
                guard bl > floor + 15 else { continue }
                seen += 1
                if bl - fm(c + 2, c + 6) >= 12 { with += 1 }
            }
            consistency = seen > 0 ? Double(with) / Double(seen) : 0
            // Holes in the 3 kHz just below the cliff.
            let r1 = Int(cliffHz / 1000) - 1, r0 = max(0, r1 - 3)
            var sum = 0.0, n = 0
            for h in holes { for r in r0..<max(r0, r1) where r < h.count && h[r] >= 0 { sum += Double(h[r]); n += 1 } }
            holeRatio = n > 0 ? sum / Double(n) : 0
        }
        // Every step: local maxima of the ±400 Hz level difference.
        var steps: [(band: Int, drop: Double)] = []
        if start < stop {
            let d = (0..<bandCount).map { b -> Double in b >= start && b < stop ? mean(b - 6, b - 2) - mean(b + 2, b + 6) : 0 }
            for b in start..<stop where d[b] >= 8 {
                let lo = max(start, b - 5), hi = min(stop - 1, b + 5)
                if d[b] == d[lo...hi].max() { steps.append((b, d[b])) }
            }
        }
        // Consistency of a step across active frames with content below it.
        func stepConsistency(_ c: Int) -> Double {
            var seen = 0, with = 0
            for i in use {
                let f = frames[i]
                func fm(_ a: Int, _ b: Int) -> Double {
                    let lo = max(0, a), hi = min(bandCount, b)
                    return hi > lo ? Double(f[lo..<hi].reduce(0, +)) / Double(hi - lo) : -160
                }
                let bl = fm(c - 6, c - 2)
                guard bl > floor + 15 else { continue }
                seen += 1
                if bl - fm(c + 2, c + 6) >= 8 { with += 1 }
            }
            return seen > 0 ? Double(with) / Double(seen) : 0
        }
        // Shelf: a step up to 24.5 kHz with flat content above it that stays well above the floor for
        // at least 1.5 kHz (up to the next wall or Nyquist).
        var shelf: (hz: Double, step: Double, end: Double, slope: Double, above: Double, consistency: Double)?
        for step in steps where Double(step.band) * bandHz <= 24_500 {
            let c = step.band
            var end = c + 2, gap = 0, b = c + 3
            while b < bandCount {
                if s[b] > floor + 12 { end = b; gap = 0 } else { gap += 1; if gap > 3 { break } }
                // Stop at the next significant step (the wall that ends the shelf).
                if let next = steps.first(where: { $0.band > c + 5 && $0.band <= b && $0.drop >= 12 }) { end = min(end, next.band); break }
                b += 1
            }
            guard end - c >= 15 else { continue }
            let a = c + 3, z = end - 3
            guard z - a >= 8 else { continue }
            let xs = (a...z).map { Double($0) * bandHz / 1000 }, ys = (a...z).map { s[$0] }
            let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
            var num = 0.0, den = 0.0
            for (x, y) in zip(xs, ys) { num += (x - mx) * (y - my); den += (x - mx) * (x - mx) }
            let candidate = (hz: Double(c) * bandHz, step: step.drop, end: Double(end) * bandHz,
                             slope: den > 0 ? num / den : 0, above: my - floor, consistency: stepConsistency(c))
            if shelf == nil || candidate.step > shelf!.step { shelf = candidate }
        }

        // Highest frequency with meaningful content.
        var content = 0.0
        for b in stride(from: bandCount - 1, through: 0, by: -1) where s[b] > floor + 10 {
            content = min(nyquist, Double(b + 1) * bandHz); break
        }
        return SpectralForensics(cliffHz: cliffHz, cliffDropDB: drop, cliffConsistency: consistency, belowDB: below, aboveDB: above,
                                 floorDB: floor, extensionHz: extensionHz, extensionSlope: slope, holeRatio: holeRatio,
                                 contentHz: content, framesAnalyzed: frames.count,
                                 shelfHz: shelf?.hz, shelfStepDB: shelf?.step ?? 0, shelfEndHz: shelf?.end ?? 0,
                                 shelfSlope: shelf?.slope ?? 0, shelfAboveFloorDB: shelf?.above ?? 0, shelfConsistency: shelf?.consistency ?? 0)
    }
}
