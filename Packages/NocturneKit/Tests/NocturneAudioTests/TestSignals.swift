//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Accelerate
import AVFAudio
import Foundation

enum TestSignals {
    /// Music-like test audio: noise shaped to a spectral envelope by FFT overlap-add (exact cutoffs,
    /// no block-edge splatter), with the level changing frame to frame like real dynamics.
    /// `gainDB(f)` returns the level at frequency f, or nil for nothing at all.
    static func writeShapedNoise(_ url: URL, rate: Double, seconds: Double, gainDB: (Double) -> Double?) throws {
        let n = 4096, hop = n / 2
        let total = Int(rate * seconds)
        var out = [Float](repeating: 0, count: total + n)
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        let fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(n))), radix: .radix2, ofType: DSPSplitComplex.self)!
        var rng = SystemRandomNumberGenerator()
        let gains: [Float] = (0..<n / 2).map { k in gainDB(Double(k) * rate / Double(n)).map { Float(pow(10, $0 / 20)) } ?? 0 }
        var start = 0
        while start + n <= out.count {
            let level = Float(pow(10, Double.random(in: -8...0, using: &rng) / 20))
            var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
            for k in 1..<n / 2 {
                let phase = Float.random(in: 0...(2 * .pi), using: &rng)
                re[k] = gains[k] * level * cos(phase); im[k] = gains[k] * level * sin(phase)
            }
            var frame = [Float](repeating: 0, count: n)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    fft.inverse(input: split, output: &split)
                    frame.withUnsafeMutableBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(n / 2)) }
                    }
                }
            }
            for i in 0..<n { out[start + i] += frame[i] * window[i] }
            start += hop
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false]
        // The writer finalizes the header when it goes away, so it lives only in this scope.
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        let peak = max(1e-9, out.prefix(total).map(abs).max() ?? 1)
        for ch in 0..<2 {
            let p = buffer.floatChannelData![ch]
            for i in 0..<total { p[i] = out[i] / peak * 0.5 }
        }
        try file.write(from: buffer)
    }
}
