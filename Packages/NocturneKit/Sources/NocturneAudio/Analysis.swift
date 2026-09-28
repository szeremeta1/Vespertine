//
// Nocturne — live spectrum and offline file analysis (true bit depth, band-limit detection).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Accelerate
import AVFAudio
import Foundation
import SFBAudioEngine

// MARK: - Live spectrum

/// Log-spaced magnitude bands from a mono time-domain block.
public final class SpectrumAnalyzer: @unchecked Sendable {
    public let size: Int
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private var real: [Float]
    private var imag: [Float]

    public init(size: Int = 4096) {
        precondition(size.nonzeroBitCount == 1)
        self.size = size
        fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(size))), radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
    }

    /// Magnitudes in dBFS for each FFT bin (size/2 values).
    public func magnitudes(_ samples: [Float]) -> [Float] {
        precondition(samples.count >= size)
        let windowed = vDSP.multiply(Array(samples.suffix(size)), window)
        let half = size / 2
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.absolute(split, result: &mags)
            }
        }
        // Normalise: Hann coherent gain 0.5, FFT scaling 2/N → full-scale sine ≈ 0 dBFS.
        vDSP.multiply(1.0 / Float(size / 2), mags, result: &mags)
        return vDSP.amplitudeToDecibels(mags, zeroReference: 1).map { max($0, -160) }
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

// MARK: - File analysis

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
}

public enum FileAnalyzer {
    /// Decodes up to `maxSeconds` of the file at its native rate and inspects the samples.
    public static func analyze(url: URL, maxSeconds: Double = 600) throws -> FileAnalysis {
        guard maxSeconds.isFinite, maxSeconds > 0 else { throw SourceOpenerError.unsupported(url) }
        let probed = try SourceOpener.probe(url)
        let format = probed.format
        guard format.encoding == .pcm, let decoderPCM = try? SourceOpener.decoder(
            for: probed,
            plan: OutputPlan(mode: .pcm, deviceSampleRate: format.sampleRate, decodedSampleRate: format.sampleRate,
                             physicalBitDepth: 32, channels: format.channels, dsdConvertedToPCM: false, reason: ""),
            item: PlayableItem(url: url)) else {
            return FileAnalysis(claimedBitDepth: format.bitDepth, effectiveBitDepth: nil, sampleRate: format.sampleRate,
                                bandwidthHz: 0, peakDBFS: 0, clippedSamples: 0, verdict: .notApplicable,
                                summary: format.encoding == .dsd ? "DSD source: bit depth analysis doesn't apply." : "Lossy source: analysis doesn't apply.",
                                spectrum: [])
        }

        let channels = max(1, format.channels)
        let chunk: AVAudioFrameCount = 16_384
        guard let outFormat = AudioFormats.float32(sampleRate: format.sampleRate, channels: channels, interleaved: false),
              let converter = AVAudioConverter(from: decoderPCM.processingFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: decoderPCM.processingFormat, frameCapacity: chunk),
              let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunk) else {
            throw SourceOpenerError.unsupported(url)
        }

        let fftSize = 8192
        let analyzer = SpectrumAnalyzer(size: fftSize)
        var spectrumSum = [Double](repeating: 0, count: fftSize / 2)
        var spectrumFrames = 0
        var mono = [Float](repeating: 0, count: fftSize)

        let claimed = format.bitDepth ?? 24
        let scale = Float(1 << (max(1, min(claimed, 24)) - 1))
        var orBits: Int32 = 0
        var peak: Float = 0
        var clipped = 0
        var framesDone: Double = 0
        let limit = maxSeconds * format.sampleRate
        var exhausted = false
        var framesSinceFFT = 0
        let fftStride = Int(format.sampleRate / 4) // four spectra per second
        let forensics = ForensicsAccumulator(sampleRate: format.sampleRate)
        var forensicMono = [Float](repeating: 0, count: forensics.fftSize)
        let historyLimit = 2 * max(fftSize, forensics.fftSize)
        var history: [Float] = []
        history.reserveCapacity(historyLimit + Int(chunk))

        while !exhausted && framesDone < limit {
            output.frameLength = 0
            var error: NSError?
            var decodeError: Error?
            let status = converter.convert(to: output, error: &error) { requested, inputStatus in
                input.frameLength = 0
                do { try decoderPCM.decode(into: input, length: min(requested, input.frameCapacity)) } catch {
                    decodeError = error
                    inputStatus.pointee = .endOfStream; return nil
                }
                if input.frameLength == 0 { inputStatus.pointee = .endOfStream; return nil }
                inputStatus.pointee = .haveData
                return input
            }
            if let decodeError { throw decodeError }
            if let error { throw error }
            if status == .error { throw SourceOpenerError.unsupported(url) }
            let n = min(Int(output.frameLength), max(0, Int(min(Double(chunk), limit - framesDone))))
            if n == 0 || status == .endOfStream || status == .error { exhausted = n == 0 || status != .haveData }
            guard n > 0, let data = output.floatChannelData else { continue }
            for c in 0..<channels {
                let p = data[c]
                for i in 0..<n {
                    let s = p[i]
                    guard s.isFinite else { throw SourceOpenerError.unsupported(url) }
                    let a = abs(s)
                    if a > peak { peak = a }
                    if a >= 0.99999 { clipped += 1 }
                    let integer = Double(s) * Double(scale)
                    orBits |= Int32(max(Double(Int32.min), min(Double(Int32.max), integer.rounded())))
                }
            }
            // Mono mix into a rolling history, so frames never depend on how the decoder chunks audio.
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<channels { sum += data[c][i] }
                history.append(sum / Float(channels))
            }
            if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
            framesSinceFFT += n
            if framesSinceFFT >= fftStride, history.count >= max(fftSize, forensics.fftSize) {
                framesSinceFFT = 0
                forensicMono = Array(history.suffix(forensics.fftSize))
                forensics.add(forensicMono)
                mono = Array(history.suffix(fftSize))
                let mags = analyzer.magnitudes(mono)
                for i in 0..<mags.count { spectrumSum[i] += pow(10, Double(mags[i]) / 10) }
                spectrumFrames += 1
            }
            framesDone += Double(n)
        }

        // Effective bit depth: trailing zero bits shared by every sample.
        var effective: Int? = nil
        if claimed <= 24, orBits != 0 {
            effective = min(claimed, 24) - Int(orBits.trailingZeroBitCount)
        } else if claimed <= 24 {
            effective = 0
        }

        // Long-term spectrum and bandwidth.
        let binHz = format.sampleRate / Double(fftSize)
        let avgDB: [Double] = spectrumSum.map { spectrumFrames > 0 ? 10 * log10(max($0 / Double(spectrumFrames), 1e-20)) : -200 }
        let bandwidth = estimateBandwidth(avgDB, binHz: binHz)
        let nyquist = format.sampleRate / 2
        let spectrum = (0..<256).map { i -> Float in
            let f = 20 * pow(nyquist / 20, Double(i) / 255)
            let bin = min(avgDB.count - 1, max(0, Int(f / binHz)))
            return Float(avgDB[bin])
        }

        let measured = forensics.result()
        let judged = Self.judge(forensics: measured, claimedBits: claimed, effectiveBits: effective, sampleRate: format.sampleRate)
        let verdict = judged.verdict, summary = judged.summary
        // The display bandwidth follows the forensic measurement (robust to faint sparse junk above a cutoff).
        let shownBandwidth = judged.bandwidth ?? bandwidth

        return FileAnalysis(claimedBitDepth: format.bitDepth, effectiveBitDepth: effective, sampleRate: format.sampleRate,
                            bandwidthHz: shownBandwidth, peakDBFS: peak > 0 ? 20 * log10(Double(peak)) : -.infinity,
                            clippedSamples: clipped, verdict: verdict, summary: summary, spectrum: spectrum,
                            secondsAnalyzed: framesDone / format.sampleRate, forensics: measured,
                            version: FileAnalysis.currentVersion, confidence: judged.confidence)
    }

    /// Verdict from the measurements. Thresholds are calibrated on genuine CD and hi-res masters
    /// against the same audio passed through MP3 (128/320/V0), AAC (128/256), Opus (96/160),
    /// HE-AAC (SBR), 44.1 kHz upsampling and 16-bit padding (see docs/ANALYSIS.md). Genuine CD
    /// masters show anti-alias walls at 20.4–21.3 kHz (steep ones, up to ~39 dB, at 21.1 kHz and
    /// above), so only walls below 20.7 kHz count against a CD-rate file.
    static func judge(forensics f: SpectralForensics, claimedBits: Int, effectiveBits: Int?, sampleRate: Double)
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
                    "Hard cutoff at ~\(khz(hz)) kHz with nothing recorded above it: a 44.1/48 kHz master upsampled to \(SampleRate.format(sampleRate)) kHz.",
                    min(1, 0.6 + (f.cliffDropDB - 18) / 40), hz)
        }
        let reach = f.contentHz
        var note = "Uses the full \(claimedBits)-bit word length; no codec cutoff, synthetic shelf or upsampling wall."
        if sampleRate >= 88_200, reach > 0, reach < 26_000 {
            note += " Little recorded above ~\(khz(reach)) kHz, which is normal for analog-era masters."
        }
        return (.genuine, note, 0.8, reach > 0 ? reach : nil)
    }

    /// Highest frequency whose smoothed level is clearly above the top-band noise floor.
    static func estimateBandwidth(_ db: [Double], binHz: Double) -> Double {
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

/// Float32 formats for any channel count. AVAudioFormat's plain initializer returns nil above two
/// channels (5.1, 7.1, …) unless a channel layout is given, so a multichannel file must never be
/// able to crash analysis or playback.
public enum AudioFormats {
    public static func float32(sampleRate: Double, channels: Int, interleaved: Bool, layout: AVAudioChannelLayout? = nil) -> AVAudioFormat? {
        guard sampleRate.isFinite, sampleRate > 0, channels > 0, channels <= 64 else { return nil }
        if let layout, Int(layout.channelCount) == channels {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: interleaved, channelLayout: layout)
        }
        if channels <= 2 {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                 channels: AVAudioChannelCount(channels), interleaved: interleaved)
        }
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)) else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: interleaved, channelLayout: layout)
    }
}
