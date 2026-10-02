//
// Vespertine — file analysis: accumulates decoded samples (from any decoder) and judges the result.
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
        case notApplicable      // lossy / DSD source, or nothing to judge (silence, too short, nothing measurable)
    }

    /// Bumped when the analysis learns something new, so older results can be refreshed.
    /// 3: shelves must follow the music to count as synthetic, hedged wording, capped spectral confidence.
    public static let currentVersion = 3

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
    private let clipLevel: Float
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
        // Positive full scale is one step below 1 (32767/32768 in a 16-bit file), so count from there.
        clipLevel = Float(min(0.99999, 1 - 1 / scale))
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
                    if a >= clipLevel { clipped += 1 }
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
        // Effective bit depth: trailing zero bits shared by every sample. Only against a known word length:
        // judged against an assumed one, a 16-bit file would read as padded.
        var effective: Int? = nil
        if claimedBitDepth != nil, claimed <= 24 {
            effective = orBits != 0 ? min(claimed, 24) - Int(orBits.trailingZeroBitCount) : 0
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
        // Too little to judge the spectrum on: a very short file, or nothing that stands out from the floor (very quiet,
        // or channels that cancel when mixed to mono). Zero padding is exact and still reported; nothing else is.
        let minimumFrames = 6
        if judged.verdict != .paddedBitDepth, measured.framesAnalyzed < minimumFrames || measured.contentHz == 0 {
            let reason = measured.framesAnalyzed < minimumFrames
                ? "Too short for the spectral checks (they need a couple of seconds of audio), so the result is inconclusive."
                : "Nothing in the spectrum stands out from the noise floor (very quiet, or the channels cancel when mixed to mono), so the spectral checks are inconclusive."
            let bits: String
            if let effective, effective > 0 {
                bits = effective >= claimed ? " No zero padding: all \(claimed) bits are in use." : " No zero padding: \(effective) of \(claimed) bits are in use."
            } else {
                bits = " Word length not checked."
            }
            return FileAnalysis(claimedBitDepth: claimedBitDepth, effectiveBitDepth: effective, sampleRate: sampleRate,
                                bandwidthHz: 0, peakDBFS: 20 * log10(Double(peak)), clippedSamples: clipped, verdict: .notApplicable,
                                summary: reason + bits, spectrum: spectrum, secondsAnalyzed: seconds, forensics: measured,
                                version: FileAnalysis.currentVersion, confidence: 0)
        }
        // The display bandwidth follows the forensic measurement (robust to faint sparse junk above a cutoff).
        return FileAnalysis(claimedBitDepth: claimedBitDepth, effectiveBitDepth: effective, sampleRate: sampleRate,
                            bandwidthHz: judged.bandwidth ?? bandwidth, peakDBFS: 20 * log10(Double(peak)),
                            clippedSamples: clipped, verdict: judged.verdict, summary: judged.summary, spectrum: spectrum,
                            secondsAnalyzed: seconds, forensics: measured,
                            version: FileAnalysis.currentVersion, confidence: judged.confidence)
    }
}

public enum FileAnalyzer {
    /// The most a spectral verdict's confidence can reach. The steep low-pass that marks a codec is also left by
    /// steep mastering and anti-alias filters, FM sources and band-limited historical masters, so a spectrum
    /// alone never earns the "high confidence" of an exact finding such as zero padding.
    public static let spectralConfidenceCap = 0.75
    /// A shelf counts as generated only when its level follows the music below the step this closely.
    public static let shelfTrackingThreshold = 0.5

    /// Verdict from the measurements. Thresholds are calibrated on genuine CD and hi-res masters
    /// against the same audio passed through MP3 (128/320/V0), AAC (128/256), Opus (96/160),
    /// HE-AAC (SBR), 44.1 kHz upsampling and 16-bit padding (see docs/ANALYSIS.md). Genuine CD
    /// masters show anti-alias walls at 20.4–21.3 kHz (steep ones, up to ~39 dB, at 21.1 kHz and
    /// above), so only walls below 20.7 kHz count against a CD-rate file.
    public static func judge(forensics f: SpectralForensics, claimedBits: Int, effectiveBits: Int?, sampleRate: Double)
        -> (verdict: FileAnalysis.Verdict, summary: String, confidence: Double, bandwidth: Double?) {
        func khz(_ hz: Double) -> String { String(format: "%.1f", hz / 1000) }
        func percent(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
        if let effectiveBits, effectiveBits > 0, effectiveBits < claimedBits - 1 {
            return (.paddedBitDepth, "\(claimedBits)-bit file, but only \(effectiveBits) bits carry audio (zero-padded).", 1, nil)
        }
        // Below 44.1 kHz a file's own anti-alias filter falls in the codec zone: the top tenth of its band is that
        // filter, not a codec wall (a genuine 32 kHz master cuts off near 15 kHz).
        func ownFilter(_ hz: Double) -> Bool { sampleRate < 44_100 && hz >= 0.9 * sampleRate / 2 }
        // Codec wall: a steep, frame-to-frame low-pass below the anti-alias zone. A lower step counts
        // too when a steeper wall sits above it (a lossy file later upsampled or extended).
        var wall: (hz: Double, drop: Double, consistency: Double)?
        var wallConfidence = 0.0
        var cdZoneWall = false
        let hiRes = sampleRate >= 88_200
        if let hz = f.cliffHz, hz < 19_600, !ownFilter(hz), f.cliffDropDB >= 15, f.cliffConsistency >= 0.5 {
            wall = (hz, f.cliffDropDB, f.cliffConsistency)
            wallConfidence = min(spectralConfidenceCap, 0.5 + (f.cliffDropDB - 15) / 40 + (f.cliffConsistency - 0.5) / 2)
        } else if let hz = f.shelfHz, hz < 19_600, !ownFilter(hz), f.shelfStepDB >= 15, f.shelfConsistency >= 0.6 {
            wall = (hz, f.shelfStepDB, f.shelfConsistency)
            wallConfidence = min(spectralConfidenceCap, 0.5 + (f.shelfStepDB - 15) / 40 + (f.shelfConsistency - 0.6) / 2)
        } else if !hiRes, let hz = f.cliffHz, hz >= 19_600, hz < 20_700, f.cliffDropDB >= 22, f.cliffConsistency >= 0.85 {
            // Lossy encoders' 20 kHz-class low-passes sit at 19.9–20.6 kHz (MP3 320 ≈ 20.0, Opus 20.3,
            // HE-AAC 20.4–20.6); steep genuine CD mastering filters measured at 21.1 kHz and up.
            // In hi-res files this zone means "made from a 44.1/48 kHz file" (reported as upsampled below).
            // A genuine CD's own filter can sit here too (calibration: 20.4–21.3 kHz), so this is never more than possible.
            wall = (hz, f.cliffDropDB, f.cliffConsistency)
            wallConfidence = min(0.55, 0.5 + (f.cliffDropDB - 22) / 40 + (f.cliffConsistency - 0.85))
            cdZoneWall = true
        }
        // Synthetic high frequencies: a flat shelf of real content above a lower step, whose level rises and falls
        // with the music (generated highs follow it; hiss or surface noise added after a band-limited source doesn't).
        // Measurements from before tracking was measured (nil) are judged as they were.
        let follows = f.shelfTracking.map { $0 >= shelfTrackingThreshold } ?? true
        // At 44.1 kHz a 19.6–20.7 kHz wall may be the file's own steep anti-alias filter, so it doesn't vouch for a weak step.
        let wallVouches = wall != nil && !(cdZoneWall && sampleRate < 46_000)
        if let shelf = f.shelfHz, shelf <= 20_500, !ownFilter(shelf), f.shelfStepDB >= 10, f.shelfSlope >= -2.5, f.shelfAboveFloorDB >= 10,
           f.shelfConsistency >= 0.8, f.shelfEndHz - shelf >= 1_500, follows,
           wallVouches || (shelf < 19_600 && f.shelfStepDB >= 15) {
            // A hard wall closing the shelf (where the generator stopped) is strong corroboration.
            let closedByWall = f.cliffHz.map { $0 > shelf + 1_000 && f.cliffDropDB >= 22 && f.cliffConsistency >= 0.85 } ?? false
            let conf = min(spectralConfidenceCap,
                           0.55 + (f.shelfConsistency - 0.8) + min(0.3, (f.shelfStepDB - 10) / 60) + (closedByWall ? 0.15 : 0))
            let moving = f.shelfTracking == nil ? "" : " that rises and falls with the music"
            return (.bandwidthExtended,
                    "Steep step at ~\(khz(shelf)) kHz in \(percent(f.shelfConsistency)) of the music (\(Int(f.shelfStepDB.rounded())) dB), then a flat shelf of content up to ~\(khz(f.shelfEndHz)) kHz\(moving). High frequencies synthesized over a lossy source (HE-AAC SBR, AI \u{201C}enhancement\u{201D}) look like this; so can an exciter or noise reduction used on a band-limited recording.",
                    conf, shelf)
        }
        if let wall {
            var text = "Steep cutoff at ~\(khz(wall.hz)) kHz in \(percent(wall.consistency)) of the music (\(Int(wall.drop.rounded())) dB drop). MP3, AAC and Opus encodes look like this, but so do steep mastering or anti-alias filters, FM broadcast sources and band-limited historical masters."
            if let tracking = f.shelfTracking, tracking < shelfTrackingThreshold, let shelf = f.shelfHz, abs(shelf - wall.hz) <= 1_000,
               f.shelfEndHz - shelf >= 1_500, f.shelfAboveFloorDB >= 10 {
                text += " Above it, steady noise-like content that doesn't follow the music, as analog tape hiss or vinyl surface noise added after the cutoff would be."
            }
            return (.possibleLossyOrigin, text, wallConfidence, wall.hz)
        }
        if hiRes, let hz = f.cliffHz, hz >= 19_600, hz <= 24_500, f.cliffDropDB >= 18, f.cliffConsistency >= 0.9 {
            return (.upsampled,
                    "Steep cutoff at ~\(khz(hz)) kHz in \(percent(f.cliffConsistency)) of the music (\(Int(f.cliffDropDB.rounded())) dB drop), far below this \(rateText(sampleRate)) kHz file's \(rateText(sampleRate / 2)) kHz limit. A 44.1 or 48 kHz master (or a lossy file) upsampled to \(rateText(sampleRate)) kHz looks like this; so does a steep low-pass applied in mastering or in a DSD-to-PCM conversion.",
                    min(spectralConfidenceCap, 0.6 + (f.cliffDropDB - 18) / 40), hz)
        }
        let reach = f.contentHz
        var note: String
        if let effectiveBits, effectiveBits > 0 {
            note = effectiveBits >= claimedBits ? "No zero padding: all \(claimedBits) bits are in use."
                                                 : "No zero padding: \(effectiveBits) of \(claimedBits) bits are in use."
        } else {
            note = claimedBits > 24 ? "Word length not checked (padding is only tested up to 24 bits)." : "Word length not checked."
        }
        note += " No codec-like cutoff, synthetic-looking shelf or upsampling wall found."
        if let hz = f.cliffHz, ownFilter(hz), f.cliffDropDB >= 15 {
            note += " The steep cutoff at ~\(khz(hz)) kHz is this \(rateText(sampleRate)) kHz file's own anti-alias filter."
        }
        if sampleRate >= 88_200, reach > 0, reach < 26_000 {
            note += " Little recorded above ~\(khz(reach)) kHz, which is normal for analog-era masters."
        }
        // No flag isn't proof: some high-bitrate lossy files pass, and an unchecked word length proves nothing.
        return (.genuine, note, effectiveBits.map { $0 > 0 } == true ? 0.7 : 0.5, reach > 0 ? reach : nil)
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
