//
// Nocturne — file analysis: accumulates decoded samples (from any decoder) and judges the result.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public struct FileAnalysis: Sendable, Hashable, Codable {
    public enum Verdict: String, Sendable, Codable {
        case genuine            // nothing suspicious found
        case paddedBitDepth     // e.g. 16-bit content in a 24-bit container
        case upsampled          // band-limited far below Nyquist
        case possibleLossyOrigin
        case bandwidthExtended  // high frequencies synthesized above a lossy cutoff (SBR, AI "enhanced")
        case notApplicable      // lossy / DSD source
    }

    /// Bumped when the analysis learns something new, so older results can be refreshed.
    public static let currentVersion = 2

    public var claimedBitDepth: Int?
    public var effectiveBitDepth: Int?
    public var sampleRate: Double
    /// Highest frequency with meaningful content.
    public var bandwidthHz: Double
    public var peakDBFS: Double
    public var clippedSamples: Int
    public var verdict: Verdict
    public var summary: String
    /// Long-term average spectrum, 256 log-spaced points 20 Hz…Nyquist, dBFS.
    public var spectrum: [Float]
    /// How much audio was actually decoded and inspected.
    public var secondsAnalyzed: Double = 0
    public var forensics: SpectralForensics?
    public var version: Int = 1
    /// How sure the verdict is, 0…1 (1 for exact findings such as zero padding).
    public var confidence: Double = 0

    public init(claimedBitDepth: Int?, effectiveBitDepth: Int?, sampleRate: Double, bandwidthHz: Double, peakDBFS: Double,
                clippedSamples: Int, verdict: Verdict, summary: String, spectrum: [Float], secondsAnalyzed: Double = 0,
                forensics: SpectralForensics? = nil, version: Int = 1, confidence: Double = 0) {
        self.claimedBitDepth = claimedBitDepth
        self.effectiveBitDepth = effectiveBitDepth
        self.sampleRate = sampleRate
        self.bandwidthHz = bandwidthHz
        self.peakDBFS = peakDBFS
        self.clippedSamples = clippedSamples
        self.verdict = verdict
        self.summary = summary
        self.spectrum = spectrum
        self.secondsAnalyzed = secondsAnalyzed
        self.forensics = forensics
        self.version = version
        self.confidence = confidence
    }

    /// Result for sources the analysis doesn't apply to (lossy, DSD).
    public static func notApplicable(claimedBitDepth: Int?, sampleRate: Double, summary: String) -> FileAnalysis {
        FileAnalysis(claimedBitDepth: claimedBitDepth, effectiveBitDepth: nil, sampleRate: sampleRate, bandwidthHz: 0, peakDBFS: 0,
                     clippedSamples: 0, verdict: .notApplicable, summary: summary, spectrum: [])
    }
}

public enum AnalysisError: Error, Sendable {
    /// A decoded sample was NaN or infinite (a broken decoder or file).
    case invalidSample
    case cancelled
}

/// Feeds decoded audio, in chunks of any size, into the measurements. The result doesn't depend
/// on how the decoder chunks the audio: spectra are taken every quarter second of audio.
public final class AnalysisAccumulator {
    public let sampleRate: Double
    public let channels: Int
    public let claimedBitDepth: Int?
    private let claimed: Int
    private let scale: Double
    private let limit: Double

    private let fftSize = 8192
    private let analyzer: SpectrumAnalyzer
    private var spectrumSum: [Double]
    private var spectrumFrames = 0
    private let forensics: ForensicsAccumulator
    private let historyLimit: Int
    private var history: [Float] = []
    private let fftStride: Int
    private var framesSinceFFT = 0

    private var orBits: Int32 = 0
    private var peak: Float = 0
    private var clipped = 0
    public private(set) var framesDone: Double = 0

    /// `claimedBitDepth` is the container's word length (e.g. 24 for a 24-bit FLAC; 32 for float).
    public init(sampleRate: Double, channels: Int, claimedBitDepth: Int?, maxSeconds: Double = 600, forcePortableFFT: Bool = false) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        self.claimedBitDepth = claimedBitDepth
        claimed = claimedBitDepth ?? 24
        scale = Double(1 << (max(1, min(claimed, 24)) - 1))
        limit = max(0, maxSeconds) * sampleRate
        analyzer = SpectrumAnalyzer(size: fftSize, forcePortable: forcePortableFFT)
        spectrumSum = [Double](repeating: 0, count: fftSize / 2)
        forensics = ForensicsAccumulator(sampleRate: sampleRate, forcePortableFFT: forcePortableFFT)
        historyLimit = 2 * max(fftSize, forensics.fftSize)
        history.reserveCapacity(historyLimit + 32_768)
        fftStride = max(1, Int(sampleRate / 4)) // four spectra per second
    }

    /// True until `maxSeconds` of audio have been added.
    public var wantsMore: Bool { framesDone < limit }

    /// Adds `frames` frames of interleaved samples (full scale ±1).
    public func add(interleaved samples: UnsafeBufferPointer<Float>, frames: Int) throws {
        try add(frames: frames) { frame, channel in samples[frame * channels + channel] }
    }

    /// Adds `frames` frames of non-interleaved samples, one pointer per channel (full scale ±1).
    public func add(planar planes: [UnsafePointer<Float>], frames: Int) throws {
        precondition(planes.count >= channels)
        try add(frames: frames) { frame, channel in planes[channel][frame] }
    }

    private func add(frames total: Int, sample: (Int, Int) -> Float) throws {
        let n = min(total, max(0, Int(limit - framesDone)))
        guard n > 0 else { return }
        let needed = max(fftSize, forensics.fftSize)
        var frame = 0
        while frame < n {
            // Up to the next spectrum point, so spectra land at the same audio positions however the input is chunked.
            let segment = min(n - frame, max(1, fftStride - framesSinceFFT))
            for f in frame..<frame + segment {
                var sum: Float = 0
                for c in 0..<channels {
                    let s = sample(f, c)
                    guard s.isFinite else { throw AnalysisError.invalidSample }
                    let a = abs(s)
                    if a > peak { peak = a }
                    if a >= 0.99999 { clipped += 1 }
                    let integer = Double(s) * scale
                    orBits |= Int32(max(Double(Int32.min), min(Double(Int32.max), integer.rounded())))
                    sum += s
                }
                history.append(sum / Float(channels))
            }
            if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
            frame += segment
            framesSinceFFT += segment
            if framesSinceFFT >= fftStride, history.count >= needed {
                framesSinceFFT = 0
                forensics.add(Array(history.suffix(forensics.fftSize)))
                let mags = analyzer.magnitudes(Array(history.suffix(fftSize)))
                for i in 0..<mags.count { spectrumSum[i] += pow(10, Double(mags[i]) / 10) }
                spectrumFrames += 1
            }
        }
        framesDone += Double(n)
    }

    /// Measures everything added so far and judges it.
    public func finish() -> FileAnalysis {
        // Effective bit depth: trailing zero bits shared by every sample.
        var effective: Int? = nil
        if claimed <= 24, orBits != 0 {
            effective = min(claimed, 24) - Int(orBits.trailingZeroBitCount)
        } else if claimed <= 24 {
            effective = 0
        }

        // Long-term spectrum and bandwidth.
        let binHz = sampleRate / Double(fftSize)
        let avgDB: [Double] = spectrumSum.map { spectrumFrames > 0 ? 10 * log10(max($0 / Double(spectrumFrames), 1e-20)) : -200 }
        let bandwidth = FileAnalyzer.estimateBandwidth(avgDB, binHz: binHz)
        let nyquist = sampleRate / 2
        let spectrum = (0..<256).map { i -> Float in
            let f = 20 * pow(nyquist / 20, Double(i) / 255)
            let bin = min(avgDB.count - 1, max(0, Int(f / binHz)))
            return Float(avgDB[bin])
        }

        let measured = forensics.result()
        let seconds = framesDone / sampleRate
        if peak == 0 {
            // Nothing but digital silence decoded: no evidence either way, so never call it genuine.
            return FileAnalysis(claimedBitDepth: claimedBitDepth, effectiveBitDepth: nil, sampleRate: sampleRate,
                                bandwidthHz: 0, peakDBFS: -.infinity, clippedSamples: 0, verdict: .notApplicable,
                                summary: "The file decoded as digital silence, so there's nothing to analyze.", spectrum: spectrum,
                                secondsAnalyzed: seconds, forensics: measured, version: FileAnalysis.currentVersion, confidence: 0)
        }
        let judged = FileAnalyzer.judge(forensics: measured, claimedBits: claimed, effectiveBits: effective, sampleRate: sampleRate)
        // The display bandwidth follows the forensic measurement (robust to faint sparse junk above a cutoff).
        return FileAnalysis(claimedBitDepth: claimedBitDepth, effectiveBitDepth: effective, sampleRate: sampleRate,
                            bandwidthHz: judged.bandwidth ?? bandwidth, peakDBFS: 20 * log10(Double(peak)),
                            clippedSamples: clipped, verdict: judged.verdict, summary: judged.summary, spectrum: spectrum,
                            secondsAnalyzed: seconds, forensics: measured,
                            version: FileAnalysis.currentVersion, confidence: judged.confidence)
    }
}

public enum FileAnalyzer {
    /// Verdict from the measurements. Thresholds are calibrated on genuine CD and hi-res masters
    /// against the same audio passed through MP3 (128/320/V0), AAC (128/256), Opus (96/160),
    /// HE-AAC (SBR), 44.1 kHz upsampling and 16-bit padding (see docs/ANALYSIS.md). Genuine CD
    /// masters show anti-alias walls at 20.4–21.3 kHz (steep ones, up to ~39 dB, at 21.1 kHz and
    /// above), so only walls below 20.7 kHz count against a CD-rate file.
    public static func judge(forensics f: SpectralForensics, claimedBits: Int, effectiveBits: Int?, sampleRate: Double)
        -> (verdict: FileAnalysis.Verdict, summary: String, confidence: Double, bandwidth: Double?) {
        func khz(_ hz: Double) -> String { String(format: "%.1f", hz / 1000) }
        if let effectiveBits, effectiveBits > 0, effectiveBits < claimedBits - 1 {
            return (.paddedBitDepth, "\(claimedBits)-bit file, but only \(effectiveBits) bits carry audio (zero-padded).", 1, nil)
        }
        // Codec wall: a steep, frame-to-frame low-pass below the anti-alias zone. A lower step counts
        // too when a steeper wall sits above it (a lossy file later upsampled or extended).
        var wall: Double?
        var wallConfidence = 0.0
        let hiRes = sampleRate >= 88_200
        if let hz = f.cliffHz, hz < 19_600, f.cliffDropDB >= 15, f.cliffConsistency >= 0.5 {
            wall = hz
            wallConfidence = min(1, 0.5 + (f.cliffDropDB - 15) / 40 + (f.cliffConsistency - 0.5) / 2)
        } else if let hz = f.shelfHz, hz < 19_600, f.shelfStepDB >= 15, f.shelfConsistency >= 0.6 {
            wall = hz
            wallConfidence = min(1, 0.5 + (f.shelfStepDB - 15) / 40 + (f.shelfConsistency - 0.6) / 2)
        } else if !hiRes, let hz = f.cliffHz, hz >= 19_600, hz < 20_700, f.cliffDropDB >= 22, f.cliffConsistency >= 0.85 {
            // Lossy encoders' 20 kHz-class low-passes sit at 19.9–20.6 kHz (MP3 320 ≈ 20.0, Opus 20.3,
            // HE-AAC 20.4–20.6); steep genuine CD mastering filters measured at 21.1 kHz and up.
            // In hi-res files this zone means "made from a 44.1/48 kHz file" (reported as upsampled below).
            wall = hz
            wallConfidence = min(1, 0.5 + (f.cliffDropDB - 22) / 40 + (f.cliffConsistency - 0.85))
        }
        // Synthetic high frequencies: a flat shelf of real content above a lower step.
        if let shelf = f.shelfHz, shelf <= 20_500, f.shelfStepDB >= 10, f.shelfSlope >= -2.5, f.shelfAboveFloorDB >= 10,
           f.shelfConsistency >= 0.8, f.shelfEndHz - shelf >= 1_500,
           wall != nil || (shelf < 19_600 && f.shelfStepDB >= 15) {
            // A hard wall closing the shelf (where the generator stopped) is strong corroboration.
            let closedByWall = f.cliffHz.map { $0 > shelf + 1_000 && f.cliffDropDB >= 22 && f.cliffConsistency >= 0.85 } ?? false
            let conf = min(1, 0.55 + (f.shelfConsistency - 0.8) + min(0.3, (f.shelfStepDB - 10) / 60) + (closedByWall ? 0.15 : 0))
            return (.bandwidthExtended,
                    "Made from a lossy source that stopped at ~\(khz(shelf)) kHz. The content from \(khz(shelf)) to \(khz(f.shelfEndHz)) kHz is a flat, uniform shelf generated afterwards (SBR or AI \u{201C}enhancement\u{201D}), not recorded detail.",
                    conf, shelf)
        }
        if let wall {
            return (.possibleLossyOrigin,
                    "Brick-wall cutoff at ~\(khz(wall)) kHz in \(Int((f.cliffConsistency * 100).rounded()))% of the music (\(Int(f.cliffDropDB.rounded())) dB drop): the signature of an MP3, AAC or Opus encode converted to a lossless file.",
                    wallConfidence, wall)
        }
        if hiRes, let hz = f.cliffHz, hz >= 19_600, hz <= 24_500, f.cliffDropDB >= 18, f.cliffConsistency >= 0.9 {
            return (.upsampled,
                    "Hard cutoff at ~\(khz(hz)) kHz with nothing recorded above it: a 44.1/48 kHz master upsampled to \(rateText(sampleRate)) kHz.",
                    min(1, 0.6 + (f.cliffDropDB - 18) / 40), hz)
        }
        let reach = f.contentHz
        var note = "Uses the full \(claimedBits)-bit word length; no codec cutoff, synthetic shelf or upsampling wall."
        if sampleRate >= 88_200, reach > 0, reach < 26_000 {
            note += " Little recorded above ~\(khz(reach)) kHz, which is normal for analog-era masters."
        }
        return (.genuine, note, 0.8, reach > 0 ? reach : nil)
    }

    /// "44.1", "48", "192", "352.8"
    static func rateText(_ rate: Double) -> String {
        let k = rate / 1000
        if abs(k.rounded() - k) < 0.01 { return String(Int(k.rounded())) }
        return String(format: "%.1f", k)
    }

    /// Highest frequency whose smoothed level is clearly above the top-band noise floor.
    public static func estimateBandwidth(_ db: [Double], binHz: Double) -> Double {
        guard db.count > 64, binHz.isFinite, binHz > 0 else { return 0 }
        let window = max(3, db.count / 256)
        var smoothed = [Double](repeating: -200, count: db.count)
        for i in 0..<db.count {
            let lo = max(0, i - window), hi = min(db.count - 1, i + window)
            smoothed[i] = db[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
        let floorSlice = smoothed.suffix(db.count / 40).sorted()
        let floor = floorSlice[floorSlice.count / 2]
        let threshold = floor + 12
        // Reference level in the midrange: bail out on silence.
        let lo = min(smoothed.count - 1, Int(min(Double(smoothed.count - 1), 1_000 / binHz)))
        let hi = min(smoothed.count, max(lo + 1, Int(min(Double(smoothed.count), 4_000 / binHz)) + 1))
        let mid = smoothed[lo..<hi].max() ?? -200
        guard mid > -180 else { return 0 }
        guard mid > floor + 20 else { return Double(db.count) * binHz }
        for i in stride(from: smoothed.count - 1, through: 1, by: -1) where smoothed[i] > threshold {
            return Double(i) * binHz
        }
        return 0
    }
}
