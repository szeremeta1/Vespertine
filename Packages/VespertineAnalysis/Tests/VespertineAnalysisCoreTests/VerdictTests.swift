//
// Vespertine — verdicts, on the measurements the thresholds were calibrated on and on generated audio, so they
// are checked on Linux too (the app's ForensicsTests need AVFoundation).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAnalysisCore

@Suite("Verdicts")
struct VerdictTests {
    static func m(cliff: Double?, drop: Double, cons: Double, content: Double = 0, tracking: Double? = nil,
                  shelf: (hz: Double, step: Double, end: Double, slope: Double, above: Double, cons: Double)? = nil) -> SpectralForensics {
        SpectralForensics(cliffHz: cliff, cliffDropDB: drop, cliffConsistency: cons, belowDB: -80, aboveDB: -120, floorDB: -140,
                          extensionHz: 0, extensionSlope: 0, holeRatio: 0, contentHz: content, framesAnalyzed: 400,
                          shelfHz: shelf?.hz, shelfStepDB: shelf?.step ?? 0, shelfEndHz: shelf?.end ?? 0,
                          shelfSlope: shelf?.slope ?? 0, shelfAboveFloorDB: shelf?.above ?? 0, shelfConsistency: shelf?.cons ?? 0,
                          shelfTracking: tracking)
    }

    /// The same measurements as VespertineKit's ForensicsTests (from real files, see docs/ANALYSIS.md).
    static let calibration: [(name: String, rate: Double, f: SpectralForensics, expected: FileAnalysis.Verdict)] = [
        ("CD master, steep 21.1 kHz filter", 44_100, m(cliff: 21_100, drop: 38.6, cons: 0.99), .genuine),
        ("CD master, steep 21.3 kHz filter", 44_100, m(cliff: 21_300, drop: 32.8, cons: 1.00), .genuine),
        ("CD master, 20.5 kHz filter", 44_100, m(cliff: 20_500, drop: 17.3, cons: 0.97), .genuine),
        ("Hi-res master, converter edge near Nyquist", 96_000, m(cliff: 44_800, drop: 19.7, cons: 0.92), .genuine),
        ("Analog-era 24/96 with natural roll-off", 96_000, m(cliff: nil, drop: 5.0, cons: 0, content: 24_200), .genuine),
        ("Lo-fi 44.1 kHz production, gentle roll-off", 44_100, m(cliff: nil, drop: 4.6, cons: 0, content: 18_000), .genuine),
        ("Fan release labelled \"Enhanced 24bit 48kHz\"", 48_000,
         m(cliff: 16_300, drop: 37.7, cons: 0.97, shelf: (16_300, 37.7, 21_000, -2.34, 16.7, 0.98)), .bandwidthExtended),
        ("Mashup rebuilt from streams", 48_000,
         m(cliff: 20_300, drop: 47.1, cons: 0.98, shelf: (15_800, 14.3, 20_300, -0.83, 72.8, 0.87)), .bandwidthExtended),
        ("MP3 128 in a 16/44.1 FLAC", 44_100,
         m(cliff: 16_200, drop: 15.4, cons: 0.51, shelf: (16_200, 15.4, 18_900, -4.0, 20, 0.56)), .possibleLossyOrigin),
        ("MP3 320 in a 24/48 FLAC", 48_000, m(cliff: 19_900, drop: 28.0, cons: 1.00), .possibleLossyOrigin),
        ("Opus in a 24/48 FLAC", 48_000, m(cliff: 20_300, drop: 40.7, cons: 1.00), .possibleLossyOrigin),
        ("Radio promo: MP3, then upsampled to 192 kHz", 192_000,
         m(cliff: 22_100, drop: 28.6, cons: 1.00, shelf: (16_200, 24.3, 22_100, -3.5, 20, 0.78)), .possibleLossyOrigin),
        ("48 kHz session sold as 24/96", 96_000, m(cliff: 24_000, drop: 50.3, cons: 1.00), .upsampled),
        ("CD master sold as 24/96", 96_000, m(cliff: 21_100, drop: 24.7, cons: 0.91), .upsampled),
    ]

    @Test("Calibrated verdicts", arguments: calibration.indices)
    func calibrated(index: Int) {
        let c = Self.calibration[index]
        let j = FileAnalyzer.judge(forensics: c.f, claimedBits: 24, effectiveBits: 24, sampleRate: c.rate)
        #expect(j.verdict == c.expected, "\(c.name): got \(j.verdict)")
        // Only an exact finding (zero padding) earns high confidence; a spectrum alone never does.
        #expect(j.confidence < 0.8, "\(c.name): confidence \(j.confidence)")
    }

    @Test("Stored version 2 results are judged anew from their measurements, without the file")
    func rejudgedFromStoredMeasurements() {
        // As version 2 stored them: an old, certain verdict and wording, and no shelf tracking.
        func stored(_ f: SpectralForensics, rate: Double, verdict: FileAnalysis.Verdict, effective: Int?, claimed: Int? = 24) -> FileAnalysis {
            FileAnalysis(claimedBitDepth: claimed, effectiveBitDepth: effective, sampleRate: rate, bandwidthHz: 20_000, peakDBFS: -0.3,
                         clippedSamples: 0, verdict: verdict, summary: "Made from an MP3, AAC or Opus file.", spectrum: [],
                         secondsAnalyzed: 300, forensics: f, version: 2, confidence: 1)
        }
        // A genuine 32 kHz master v2 called lossy: now genuine, and current.
        let low = FileAnalyzer.rejudged(stored(Self.m(cliff: 15_200, drop: 30, cons: 1, content: 15_000), rate: 32_000,
                                               verdict: .possibleLossyOrigin, effective: 24))
        #expect(low.version == FileAnalysis.currentVersion && low.verdict == .genuine)
        // An MP3-sourced file stays flagged, as a question at no more than the spectral cap, with the hedged wording.
        let lossy = FileAnalyzer.rejudged(stored(Self.m(cliff: 19_900, drop: 28, cons: 1, content: 19_800), rate: 48_000,
                                                 verdict: .possibleLossyOrigin, effective: 24))
        #expect(lossy.verdict == .possibleLossyOrigin && lossy.confidence <= FileAnalyzer.spectralConfidenceCap)
        #expect(lossy.summary.contains("mastering"))
        // A 32-bit file's word length was never really checked: not reported as checked any more.
        let wide = FileAnalyzer.rejudged(stored(Self.m(cliff: 21_100, drop: 38.6, cons: 0.99, content: 21_000), rate: 44_100,
                                                verdict: .genuine, effective: 32, claimed: 32))
        #expect(wide.verdict == .genuine && wide.effectiveBitDepth == nil && wide.summary.contains("not checked"))
        // Version 1 kept no measurements: left alone, for a fresh analysis.
        var v1 = stored(Self.calibration[0].f, rate: 44_100, verdict: .genuine, effective: 24)
        v1.version = 1; v1.forensics = nil
        #expect(FileAnalyzer.rejudged(v1) == v1)
    }

    @Test("Zero padding is exact and wins over spectral findings")
    func padding() {
        let v = FileAnalyzer.judge(forensics: Self.m(cliff: 16_000, drop: 40, cons: 1), claimedBits: 24, effectiveBits: 16, sampleRate: 48_000)
        #expect(v.verdict == .paddedBitDepth && v.confidence == 1)
    }

    @Test("A shelf that doesn't follow the music isn't called synthetic")
    func stationaryShelf() {
        // Tape hiss over an FM-limited (15 kHz) recording: a steep step, then flat noise up to the CD filter.
        let f = Self.m(cliff: 15_500, drop: 30.7, cons: 1, tracking: 0.04, shelf: (15_500, 30.7, 20_900, -0.15, 30, 1))
        let j = FileAnalyzer.judge(forensics: f, claimedBits: 16, effectiveBits: 16, sampleRate: 44_100)
        #expect(j.verdict == .possibleLossyOrigin)
        #expect(j.summary.contains("tape hiss") && j.summary.contains("FM"))
        let generated = FileAnalyzer.judge(forensics: Self.m(cliff: 15_500, drop: 30.7, cons: 1, tracking: 0.96,
                                                             shelf: (15_500, 30.7, 20_900, -0.15, 30, 1)),
                                           claimedBits: 16, effectiveBits: 16, sampleRate: 44_100)
        #expect(generated.verdict == .bandwidthExtended)
    }

    @Test("At 44.1 kHz a wall in the CD filter zone doesn't vouch for a weak step")
    func cdZoneWall() {
        // A gentle 16 kHz roll-off (10–15 dB step) under a steep 20.4 kHz anti-alias filter.
        let f = Self.m(cliff: 20_400, drop: 35.6, cons: 1, tracking: 0.88, shelf: (16_700, 13.1, 20_400, -2.08, 20, 1))
        #expect(FileAnalyzer.judge(forensics: f, claimedBits: 16, effectiveBits: 16, sampleRate: 44_100).verdict == .possibleLossyOrigin)
    }

    @Test("A 32 kHz or 22.05 kHz file's own anti-alias filter isn't a codec wall")
    func lowRates() {
        let f32 = FileAnalyzer.judge(forensics: Self.m(cliff: 15_200, drop: 54, cons: 1, content: 15_300), claimedBits: 16,
                                     effectiveBits: 16, sampleRate: 32_000)
        #expect(f32.verdict == .genuine && f32.summary.contains("own anti-alias filter"))
        let f22 = FileAnalyzer.judge(forensics: Self.m(cliff: 10_300, drop: 59, cons: 1, content: 10_400), claimedBits: 16,
                                     effectiveBits: 16, sampleRate: 22_050)
        #expect(f22.verdict == .genuine)
        // A codec wall well inside the band still counts.
        let mp3 = FileAnalyzer.judge(forensics: Self.m(cliff: 11_000, drop: 40, cons: 1, content: 11_100), claimedBits: 16,
                                     effectiveBits: 16, sampleRate: 32_000)
        #expect(mp3.verdict == .possibleLossyOrigin)
    }

    @Test("Spectral verdicts describe the evidence and name innocent explanations")
    func wording() {
        let lossy = FileAnalyzer.judge(forensics: Self.m(cliff: 16_000, drop: 40, cons: 1), claimedBits: 16, effectiveBits: 16, sampleRate: 44_100)
        #expect(lossy.summary.hasPrefix("Steep cutoff at ~16.0 kHz in 100% of the music (40 dB drop)"))
        #expect(lossy.summary.contains("mastering"))
        // When the wall is the shelf's step, the numbers quoted are the step's, not a higher cliff's.
        let promo = FileAnalyzer.judge(forensics: Self.calibration[11].f, claimedBits: 24, effectiveBits: 24, sampleRate: 192_000)
        #expect(promo.summary.hasPrefix("Steep cutoff at ~16.2 kHz in 78% of the music (24 dB drop)"), "\(promo.summary)")
        let up = FileAnalyzer.judge(forensics: Self.calibration[13].f, claimedBits: 24, effectiveBits: 24, sampleRate: 96_000)
        #expect(up.summary.contains("DSD") && !up.summary.contains("nothing recorded"))
    }

    @Test("Genuine never claims an unchecked word length")
    func unchecked() {
        let float = FileAnalyzer.judge(forensics: Self.m(cliff: nil, drop: 2, cons: 0, content: 20_000), claimedBits: 32,
                                       effectiveBits: nil, sampleRate: 44_100)
        #expect(float.verdict == .genuine && float.summary.hasPrefix("Word length not checked") && float.confidence < 0.6)
        let full = FileAnalyzer.judge(forensics: Self.m(cliff: nil, drop: 2, cons: 0, content: 20_000), claimedBits: 24,
                                      effectiveBits: 24, sampleRate: 44_100)
        #expect(full.summary.hasPrefix("No zero padding: all 24 bits are in use.") && full.confidence < 0.8)
    }

    // MARK: - End to end, through the accumulator

    static func run(_ samples: [Float], rate: Double, bits: Int?) throws -> FileAnalysis {
        let acc = AnalysisAccumulator(sampleRate: rate, channels: 1, claimedBitDepth: bits, forcePortableFFT: true)
        try samples.withUnsafeBufferPointer { try acc.add(interleaved: $0, frames: samples.count) }
        return acc.finish()
    }

    static func quantize(_ x: [Float], bits: Int) -> [Float] {
        let q = Float(1 << (bits - 1))
        return x.map { min(q - 1, max(-q, ($0 * q).rounded())) / q }
    }

    @Test("Generated highs that follow the music are synthetic; steady hiss over the same cutoff is not")
    func endToEndShelf() throws {
        let rate = 48_000.0
        let tilt: (Double) -> Double = { -3 * $0 / 1000 }
        // One level per hop for every bin: the shelf rises and falls with the music, as SBR's does.
        let generated = TestNoise.shaped(rate: rate, seconds: 8, seed: 1) { f in
            f < 15_800 ? tilt(f) : f < 20_300 ? tilt(15_800) - 18 : nil
        }
        let a = try Self.run(Self.quantize(TestNoise.normalized(generated), bits: 24), rate: rate, bits: 24)
        #expect(a.verdict == .bandwidthExtended, "\(a.summary)")
        #expect((a.forensics?.shelfTracking ?? 0) > 0.8)
        // The same music cut at 15.8 kHz, plus noise at a steady level above it.
        let music = TestNoise.shaped(rate: rate, seconds: 8, seed: 2) { f in f < 15_800 ? tilt(f) : nil }
        let hiss = TestNoise.shaped(rate: rate, seconds: 8, seed: 3, steady: true) { f in
            f >= 15_800 && f < 20_300 ? tilt(15_800) - 22 : nil
        }
        let b = try Self.run(Self.quantize(TestNoise.normalized(zip(music, hiss).map { $0 + $1 }), bits: 24), rate: rate, bits: 24)
        #expect(b.verdict == .possibleLossyOrigin, "\(b.summary)")
        #expect((b.forensics?.shelfTracking ?? 1) < 0.5)
    }

    @Test("Positive full scale counts as clipped in 16-bit files")
    func clipping() throws {
        let top: Float = 32_767 / 32_768
        let x: [Float] = (0..<48_000).map { i -> Float in
            if i % 100 == 0 { return top }
            if i % 100 == 50 { return -1 }
            return 0.1 * sin(Float(i) * 0.05)
        }
        let a = try Self.run(x, rate: 48_000, bits: 16)
        #expect(a.clippedSamples == 960)
    }

    @Test("An unknown word length is not judged as padded")
    func unknownDepth() throws {
        let x = Self.quantize(TestNoise.normalized(TestNoise.shaped(rate: 44_100, seconds: 4, seed: 4) { -3 * $0 / 1000 }), bits: 16)
        let a = try Self.run(x, rate: 44_100, bits: nil)
        #expect(a.verdict != .paddedBitDepth && a.effectiveBitDepth == nil)
        #expect(try Self.run(x, rate: 44_100, bits: 24).verdict == .paddedBitDepth)
    }

    @Test("Too little audio is inconclusive, but zero padding is still reported")
    func thinEvidence() throws {
        let x = TestNoise.normalized(TestNoise.shaped(rate: 44_100, seconds: 0.5, seed: 5) { -3 * $0 / 1000 })
        let short = try Self.run(Self.quantize(x, bits: 24), rate: 44_100, bits: 24)
        #expect(short.verdict == .notApplicable && short.summary.contains("inconclusive"))
        #expect(try Self.run(Self.quantize(x, bits: 16), rate: 44_100, bits: 24).verdict == .paddedBitDepth)
        // Channels that cancel when mixed to mono: nothing to measure.
        let y = Self.quantize(TestNoise.normalized(TestNoise.shaped(rate: 44_100, seconds: 4, seed: 6) { -3 * $0 / 1000 }), bits: 24)
        let acc = AnalysisAccumulator(sampleRate: 44_100, channels: 2, claimedBitDepth: 24, forcePortableFFT: true)
        let stereo = y.flatMap { [$0, -$0] }
        try stereo.withUnsafeBufferPointer { try acc.add(interleaved: $0, frames: y.count) }
        #expect(acc.finish().verdict == .notApplicable)
    }
}

/// Music-like shaped noise: random-phase spectra with gain `gainDB(f)` (nil = nothing), overlap-added, with one random
/// level per hop for every bin (like VespertineKit's TestSignals), or a steady level.
enum TestNoise {
    static func shaped(rate: Double, seconds: Double, seed: UInt64, steady: Bool = false, gainDB: (Double) -> Double?) -> [Double] {
        let n = 4096, hop = n / 2, total = Int(rate * seconds)
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        let gains = (0...n / 2).map { k in k == 0 ? 0 : gainDB(Double(k) * rate / Double(n)).map { pow(10, $0 / 20) } ?? 0 }
        let window = (0..<n).map { 0.5 * (1 - cos(2 * Double.pi * Double($0) / Double(n))) }
        var out = [Double](repeating: 0, count: total + n)
        var start = 0
        while start + n <= out.count {
            let level = steady ? 1 : pow(10, -8 * random() / 20)
            var re = [Double](repeating: 0, count: n), im = [Double](repeating: 0, count: n)
            for k in 1..<n / 2 {
                let phase = 2 * Double.pi * random()
                re[k] = gains[k] * level * cos(phase); im[k] = gains[k] * level * sin(phase)
                re[n - k] = re[k]; im[n - k] = -im[k]
            }
            let frame = inverseFFT(re, im)
            for i in 0..<n { out[start + i] += frame[i] * window[i] }
            start += hop
        }
        return Array(out.prefix(total))
    }

    /// Scaled to a 0.9 peak.
    static func normalized(_ x: [Double]) -> [Float] {
        let peak = max(x.map(abs).max() ?? 1, .leastNormalMagnitude)
        return x.map { Float($0 / peak * 0.9) }
    }

    /// Real part of the inverse DFT (radix-2, unscaled).
    static func inverseFFT(_ inRe: [Double], _ inIm: [Double]) -> [Double] {
        let n = inRe.count, bits = n.trailingZeroBitCount
        var re = [Double](repeating: 0, count: n), im = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var r = 0, v = i
            for _ in 0..<bits { r = (r << 1) | (v & 1); v >>= 1 }
            re[r] = inRe[i]; im[r] = inIm[i]
        }
        var len = 2
        while len <= n {
            let half = len / 2
            for start in stride(from: 0, to: n, by: len) {
                for k in 0..<half {
                    let angle = 2 * Double.pi * Double(k) / Double(len)
                    let c = cos(angle), s = sin(angle)
                    let a = start + k, b = a + half
                    let tr = re[b] * c - im[b] * s, ti = re[b] * s + im[b] * c
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                }
            }
            len <<= 1
        }
        return re
    }
}
