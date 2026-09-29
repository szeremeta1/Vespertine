//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Accelerate
import AVFAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Spectral forensics")
struct ForensicsTests {
    /// Measurements taken from real files (see docs/ANALYSIS.md). The verdicts are the calibration:
    /// genuine CD and hi-res masters must stay genuine, confirmed fakes must be caught.
    static let cases: [(name: String, rate: Double, f: SpectralForensics, expected: FileAnalysis.Verdict)] = [
        // Genuine masters with steep mastering filters (the false-positive traps).
        ("CD master, steep 21.1 kHz filter", 44_100, m(cliff: 21_100, drop: 38.6, cons: 0.99), .genuine),
        ("CD master, steep 21.3 kHz filter", 44_100, m(cliff: 21_300, drop: 32.8, cons: 1.00), .genuine),
        ("CD master, 20.5 kHz filter", 44_100, m(cliff: 20_500, drop: 17.3, cons: 0.97), .genuine),
        ("Hi-res master, converter edge near Nyquist", 96_000, m(cliff: 44_800, drop: 19.7, cons: 0.92), .genuine),
        ("Analog-era 24/96 with natural roll-off", 96_000, m(cliff: nil, drop: 5.0, cons: 0, content: 24_200), .genuine),
        ("Lo-fi 44.1 kHz production, gentle roll-off", 44_100, m(cliff: nil, drop: 4.6, cons: 0, content: 18_000), .genuine),
        // Fakes.
        ("Fan release labelled \"Enhanced 24bit 48kHz\" (lossy + generated highs)", 48_000,
         m(cliff: 16_300, drop: 37.7, cons: 0.97, shelf: (16_300, 37.7, 21_000, -2.34, 16.7, 0.98)), .bandwidthExtended),
        ("Mashup rebuilt from streams: step, flat shelf, second wall", 48_000,
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

    @Test("Calibrated verdicts on measurements from real files", arguments: cases.indices)
    func calibrated(index: Int) {
        let c = Self.cases[index]
        let v = FileAnalyzer.judge(forensics: c.f, claimedBits: 24, effectiveBits: 24, sampleRate: c.rate).verdict
        #expect(v == c.expected, "\(c.name): got \(v)")
    }

    @Test("Multichannel (5.1) files are analyzed channel for channel, not read as silence")
    func multichannel() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-51-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)!
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0,
                                                                   AVNumberOfChannelsKey: 6, AVLinearPCMBitDepthKey: 24,
                                                                   AVLinearPCMIsFloatKey: false, AVChannelLayoutKey: Data(bytes: layout.layout, count: MemoryLayout<AudioChannelLayout>.size)],
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
            buffer.frameLength = 96_000
            // The loudest signal is in the left surround only, so the peak proves every channel is read.
            for c in 0..<6 { for i in 0..<96_000 { buffer.floatChannelData![c][i] = (c == 4 ? 0.5 : 0.1) * sin(Float(i) * Float(c + 1) * 0.01) } }
            try file.write(from: buffer)
        }
        let result = try FileAnalyzer.analyze(url: url)
        #expect(result.sampleRate == 48_000)
        // Before 0.5.3 the converter matched channels by speaker label and read a labelled 5.1 file as silence.
        #expect(abs(result.peakDBFS - (-6.02)) < 0.2, "peak \(result.peakDBFS)")
        #expect(result.effectiveBitDepth == 24)
        #expect(result.verdict != .notApplicable)
        #expect(AudioFormats.float32(sampleRate: 96_000, channels: 8, interleaved: true)?.channelCount == 8)
    }

    @Test("Zero padding is exact and wins over spectral findings")
    func padding() {
        let v = FileAnalyzer.judge(forensics: Self.m(cliff: 16_000, drop: 40, cons: 1), claimedBits: 24, effectiveBits: 16, sampleRate: 48_000)
        #expect(v.verdict == .paddedBitDepth && v.confidence == 1)
    }

    @Test("End to end: full-band audio is genuine, a 16 kHz brick wall is lossy, a flat shelf is synthetic")
    func endToEnd() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-forensics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func render(_ name: String, band: @escaping (Double) -> Double?) throws -> FileAnalysis {
            let url = dir.appendingPathComponent(name)
            try TestSignals.writeShapedNoise(url, rate: 48_000, seconds: 8, gainDB: band)
            let result = try FileAnalyzer.analyze(url: url)
            #expect((result.forensics?.framesAnalyzed ?? 0) > 20, "\(name) was not analyzed")
            return result
        }
        let tilt: (Double) -> Double = { -3 * $0 / 1000 }
        let genuine = try render("genuine.wav") { tilt($0) }
        let lossy = try render("lossy.wav") { $0 < 16_000 ? tilt($0) : nil }
        let extended = try render("extended.wav") { f in
            if f < 15_800 { return tilt(f) }
            if f < 20_300 { return tilt(15_800) - 18 }   // flat generated shelf
            return nil
        }
        #expect(genuine.verdict == .genuine, "genuine: \(genuine.summary)")
        #expect(lossy.verdict == .possibleLossyOrigin, "lossy: \(lossy.summary) \(String(describing: lossy.forensics))")
        #expect(extended.verdict == .bandwidthExtended, "extended: \(extended.summary) \(String(describing: extended.forensics))")
    }

    static func m(cliff: Double?, drop: Double, cons: Double, content: Double = 0,
                  shelf: (hz: Double, step: Double, end: Double, slope: Double, above: Double, cons: Double)? = nil) -> SpectralForensics {
        SpectralForensics(cliffHz: cliff, cliffDropDB: drop, cliffConsistency: cons, belowDB: -80, aboveDB: -120, floorDB: -140,
                          extensionHz: 0, extensionSlope: 0, holeRatio: 0, contentHz: content, framesAnalyzed: 400,
                          shelfHz: shelf?.hz, shelfStepDB: shelf?.step ?? 0, shelfEndHz: shelf?.end ?? 0,
                          shelfSlope: shelf?.slope ?? 0, shelfAboveFloorDB: shelf?.above ?? 0, shelfConsistency: shelf?.cons ?? 0)
    }
}
