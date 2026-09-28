import AVFAudio
import Foundation
import Testing
@testable import NocturneAudio

@Suite("Audio audit regressions") struct AuditAudioTests {
    @Test func downmixIsNotBitPerfect() {
        let source = SourceFormat(encoding: .pcm, codec: "WAV", sampleRate: 48000, bitDepth: 16, channels: 6)
        let device = DeviceCapabilities(sampleRates: [48000], physicalFormats: [], outputChannels: 2, supportsDoP: false)
        let plan = FormatPlanner.plan(source: source, device: device)
        let path = SignalPath(source: source, decoderName: "Test", plan: plan,
            applied: AppliedFormat(sampleRate: 48000, physicalBitDepth: 24, physicalIsInteger: true, virtualChannels: 2, exclusive: true, bufferFrames: 512),
            deviceName: "Test", deviceUID: "Test", deviceProfile: DeviceProfile(kind: .usbDAC, tag: "USB", canBeBitPerfect: true, symbol: "speaker"), volume: .fixed)
        #expect(!path.isBitPerfect)
    }
    @Test func multichannelDSDCannotDownmixDoP() {
        let source = SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: 2822400, bitDepth: 1, channels: 6)
        let device = DeviceCapabilities(sampleRates: [176400,352800], physicalFormats: [], outputChannels: 2, supportsDoP: true)
        #expect(FormatPlanner.plan(source: source, device: device).mode == .pcm)
    }
    @Test func emptyTapIsSafe() {
        let engine = PlaybackEngine()
        var samples: [Float] = []
        #expect(engine.copyTap(into: &samples) == nil)
        engine.seek(to: .infinity)
        engine.seek(to: .nan)
    }
    @Test func engineCanBeReleased() async throws {
        weak var released: PlaybackEngine?
        do { let engine = PlaybackEngine(); released = engine }
        for _ in 0..<50 {
            if released == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(released == nil)
    }
    @Test func spectrumHandlesLowRatesAndInvalidArguments() {
        let analyzer = SpectrumAnalyzer(size: 1024)
        let samples = [Float](repeating: 0, count: 1024)
        #expect(analyzer.bands(samples, sampleRate: 10, count: 30).count == 30)
        #expect(analyzer.bands(samples, sampleRate: 0, count: 30).isEmpty)
        #expect(analyzer.bands(samples, sampleRate: 48000, count: -1).isEmpty)
        #expect(FileAnalyzer.estimateBandwidth([Double](repeating: -200, count: 4096), binHz: 0.1) == 0)
    }
    @Test func floatSampleFileDoesNotCrashAnalyzer() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nocturne-float-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 4800))
            buffer.frameLength = 4800
            for c in 0..<2 { for i in 0..<4800 { buffer.floatChannelData![c][i] = .nan } }
            try f.write(from: buffer)
        }
        do {
            let result = try FileAnalyzer.analyze(url: url)
            #expect(result.verdict == .notApplicable)
        } catch { /* Invalid sample data may also be rejected by the decoder. */ }
    }
    @Test func analysisIsBoundedAndSilenceHasNoBandwidth() throws {
        let url = try writeWAV("silence", rate: 48000, bits: 24, seconds: 1) { _, _ in 0 }
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try FileAnalyzer.analyze(url: url, maxSeconds: 0.01)
        #expect(result.secondsAnalyzed <= 0.01)
        #expect(result.bandwidthHz == 0)
        #expect(throws: (any Error).self) { try FileAnalyzer.analyze(url: url, maxSeconds: .nan) }
    }
}
