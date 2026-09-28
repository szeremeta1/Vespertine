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
        case notApplicable      // lossy / DSD source
    }

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
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                      channels: AVAudioChannelCount(channels), interleaved: false)!
        guard let converter = AVAudioConverter(from: decoderPCM.processingFormat, to: outFormat) else {
            throw SourceOpenerError.unsupported(url)
        }
        let chunk: AVAudioFrameCount = 16_384
        let input = AVAudioPCMBuffer(pcmFormat: decoderPCM.processingFormat, frameCapacity: chunk)!
        let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunk)!

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
            // Mono mix for spectrum, sampled across the file.
            framesSinceFFT += n
            if framesSinceFFT >= fftStride, n >= fftSize {
                framesSinceFFT = 0
                for i in 0..<fftSize {
                    var sum: Float = 0
                    for c in 0..<channels { sum += data[c][i] }
                    mono[i] = sum / Float(channels)
                }
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

        var verdict = FileAnalysis.Verdict.genuine
        var summary = "Uses the full \(claimed)-bit word length; content reaches \(Int(bandwidth / 1000)) kHz."
        if let effective, effective > 0, effective < claimed - 1 {
            verdict = .paddedBitDepth
            summary = "\(claimed)-bit file, but only \(effective) bits carry audio (zero-padded)."
        } else if format.sampleRate >= 88_200, bandwidth > 0, bandwidth < 24_500 {
            verdict = .upsampled
            summary = "Content stops at ~\(String(format: "%.1f", bandwidth / 1000)) kHz, which suggests an upsampled 44.1/48 kHz master."
        } else if format.sampleRate <= 48_000, bandwidth > 0, bandwidth < 19_500 {
            verdict = .possibleLossyOrigin
            summary = "Sharp cutoff at ~\(String(format: "%.1f", bandwidth / 1000)) kHz; may have been made from a lossy file."
        }

        return FileAnalysis(claimedBitDepth: format.bitDepth, effectiveBitDepth: effective, sampleRate: format.sampleRate,
                            bandwidthHz: bandwidth, peakDBFS: peak > 0 ? 20 * log10(Double(peak)) : -.infinity,
                            clippedSamples: clipped, verdict: verdict, summary: summary, spectrum: spectrum,
                            secondsAnalyzed: framesDone / format.sampleRate)
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
