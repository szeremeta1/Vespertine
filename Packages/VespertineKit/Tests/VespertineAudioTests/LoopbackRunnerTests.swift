//
// Vespertine — the loopback self-test's files, plan, guard and forced settings (no device needed), and one real run
// through "Vespertine Loopback" when hardware tests are on.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import Testing
import VespertineAnalysisCore
@testable import VespertineAudio

private func device(_ name: String, transport: Transport, rates: [Double] = [44_100, 48_000, 96_000],
                    formats: [PhysicalFormat]? = nil) -> OutputDevice {
    let f = formats ?? [PhysicalFormat(minRate: rates.min()!, maxRate: rates.max()!, bitDepth: 32, isInteger: false, isMixable: true, channels: 2)]
    return OutputDevice(id: 0, uid: name, name: name, manufacturer: "", modelUID: nil, transport: transport, nominalSampleRate: rates[0],
                        capabilities: DeviceCapabilities(sampleRates: rates, physicalFormats: f, outputChannels: 2, supportsDoP: false),
                        hasHardwareVolume: false, isDefault: false)
}

@Suite("Loopback self-test")
struct LoopbackRunnerTests {
    /// Decodes a file the way the engine does in integer mode: its decoder, then a converter to Int32.
    private func decodeToInt32(_ url: URL) throws -> [Int32] {
        let probed = try SourceOpener.probe(url)
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: probed.format.sampleRate, decodedSampleRate: probed.format.sampleRate,
                              physicalBitDepth: 32, channels: 2, dsdConvertedToPCM: false, reason: "")
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: url))
        let out = AVAudioFormat(commonFormat: .pcmFormatInt32, sampleRate: probed.format.sampleRate, channels: 2, interleaved: true)!
        let converter = try #require(AVAudioConverter(from: decoder.processingFormat, to: out))
        converter.dither = false
        let input = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096)!
        let output = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: 4096)!
        var result: [Int32] = []
        while true {
            try decoder.decode(into: input, length: 4096)
            if input.frameLength == 0 { break }
            try converter.convert(to: output, from: input)
            result += UnsafeBufferPointer(start: output.int32ChannelData![0], count: Int(output.frameLength) * 2)
        }
        return result
    }

    @Test("The test files decode to exactly the signal's samples", arguments: [16, 24, 32])
    func filesAreExact(bits: Int) throws {
        let signal = LoopbackSignal(.init(sampleRate: 48_000, bits: bits, payloadSeconds: 0.1))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loopback-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try LoopbackWAV.write(signal.samples, range: 0..<signal.frames, bits: bits, sampleRate: 48_000, to: url)
        let probed = try SourceOpener.probe(url)
        #expect(probed.format.bitDepth == bits && probed.format.sampleRate == 48_000 && probed.format.channels == 2)
        let decoded = try decodeToInt32(url)
        #expect(decoded.count == signal.frames * 2)
        var wrong = 0
        for f in 0..<signal.frames {
            for c in 0..<2 where decoded[f * 2 + c] != signal.samples[c][f] << Int32(32 - bits) { wrong += 1 }
        }
        #expect(wrong == 0)
    }

    @Test("The gapless pair's two files are the signal split in the payload")
    func gaplessFiles() throws {
        let signal = LoopbackSignal(.init(sampleRate: 44_100, bits: 24, payloadSeconds: 0.1))
        let a = FileManager.default.temporaryDirectory.appendingPathComponent("loopback-a-\(UUID()).wav")
        let b = FileManager.default.temporaryDirectory.appendingPathComponent("loopback-b-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        try LoopbackWAV.write(signal.samples, range: 0..<signal.splitFrame, bits: 24, sampleRate: 44_100, to: a)
        try LoopbackWAV.write(signal.samples, range: signal.splitFrame..<signal.frames, bits: 24, sampleRate: 44_100, to: b)
        let joined = try decodeToInt32(a) + decodeToInt32(b)
        let whole = (0..<signal.frames).flatMap { f in (0..<2).map { signal.samples[$0][f] << 8 } }
        #expect(joined == whole)
    }

    @Test("Quick: two rates, 24- and 16-bit and a gapless pair. Full: every common rate the device has, and both pairs")
    func plan() {
        let rates: [Double] = [8_000, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000, 768_000]
        let quick = LoopbackPlan.cases(rates: rates, mode: .quick)
        #expect(quick.map(\.name) == ["24-bit at 44.1 kHz", "24-bit at 96 kHz", "16-bit padded at 44.1 kHz", "Gapless pair, 24-bit at 44.1 kHz"])
        let full = LoopbackPlan.cases(rates: rates, mode: .full)
        #expect(full.count == 8 * 4 + 2)
        #expect(Set(full.map(\.sampleRate)) == Set(LoopbackPlan.commonRates))
        #expect(full.contains { $0.bits == 16 && $0.matchSixteenBit } && full.contains { $0.bits == 16 && !$0.matchSixteenBit })
        #expect(full.contains { $0.bits == 32 && $0.integerMode })
        #expect(full.filter { $0.kind != .single }.map(\.kind) == [.gapless, .sixteenThenTwentyFour])
        #expect(Set(full.map(\.id)).count == full.count)
        // A 48 kHz-only device still gets a quick test.
        #expect(LoopbackPlan.cases(rates: [48_000], mode: .quick).map(\.sampleRate) == [48_000, 48_000, 48_000])
        #expect(LoopbackPlan.cases(rates: [], mode: .full).isEmpty)
    }

    @Test("Full-scale noise only ever goes to a virtual device")
    func guardRefusesRealOutputs() {
        for transport in [Transport.usb, .builtIn, .bluetooth, .hdmi, .airPlay, .thunderbolt, .aggregate] {
            let d = device("DAC", transport: transport)
            #expect(LoopbackGuard.refusal(d) != nil, "\(transport)")
            #expect(throws: LoopbackError.self) { try LoopbackRunner(output: d) }
        }
        #expect(LoopbackGuard.refusal(device("Vespertine Loopback", transport: .virtual)) == nil)
        let devices = [device("BlackHole 2ch", transport: .virtual), device("Vespertine Loopback", transport: .virtual),
                       device("Vespertine Loopback", transport: .usb)]
        #expect(LoopbackGuard.dedicatedDevice(in: devices)?.transport == .virtual)
        #expect(LoopbackGuard.dedicatedDevice(in: [device("BlackHole 2ch", transport: .virtual)]) == nil)
    }

    @Test("Every case turns off whatever could change the samples, and says so")
    func forcedSettings() throws {
        let runner = try LoopbackRunner(output: device("Vespertine Loopback", transport: .virtual))
        let s = runner.engineSettings(for: LoopbackCase(sampleRate: 96_000, bits: 16, matchSixteenBit: true))
        #expect(s.exclusive && s.deviceUID == "Vespertine Loopback" && s.digitalVolumeDB == nil && s.equalizers.isEmpty)
        #expect(s.spatialModes["Vespertine Loopback"] == .off && s.bitstreamDeviceUIDs.isEmpty && s.dopDeviceUIDs.isEmpty)
        #expect(s.ratePolicies["Vespertine Loopback"] == .matchSource && s.matchSixteenBit && !s.integerMode)
        let described = LoopbackRunner.describe(s)
        for key in ["Digital volume", "Equalizer", "ReplayGain", "Spatial Audio", "Bitstream"] { #expect(described[key] == "off") }
        #expect(described["Match 16-bit sources"] == "on")
    }

    @Test("32-bit integer mode is skipped, and says why, on a device without a 32-bit integer format")
    func integerSkipped() throws {
        let runner = try LoopbackRunner(output: device("Vespertine Loopback", transport: .virtual))
        let r = runner.runCase(LoopbackCase(sampleRate: 48_000, bits: 32, integerMode: true), mode: .quick)
        #expect(r.status == .skipped && r.summary.contains("no 32-bit integer format"))
    }

    @Test("Reports survive JSON, and the overall status is the worst case that ran")
    func reportJSON() throws {
        let ok = LoopbackCaseResult(testCase: LoopbackCase(sampleRate: 44_100, bits: 24), status: .bitExact, summary: "bit-exact")
        var skipped = ok; skipped.status = .skipped
        var bad = ok; bad.status = .failed
        var setup = ok; setup.status = .setupProblem
        func report(_ cases: [LoopbackCaseResult]) -> LoopbackReport {
            LoopbackReport(outputDevice: "Vespertine Loopback", outputUID: "uid", inputDevice: "Vespertine Loopback", macOS: "26.0.0",
                           appVersion: "0.12.0", date: Date(timeIntervalSince1970: 1_800_000_000), mode: .quick, cases: cases)
        }
        #expect(report([ok, skipped]).status == .bitExact)
        #expect(report([ok, bad, skipped]).status == .failed)
        #expect(report([bad, setup]).status == .setupProblem)
        #expect(report([skipped]).status == .skipped)
        let r = report([ok, bad])
        #expect(try JSONDecoder().decode(LoopbackReport.self, from: JSONEncoder().encode(r)) == r)
    }

    /// Plays the quick test through the dedicated loopback device. Silent: the device is virtual.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_HARDWARE_TESTS"] == "1"))
    func quickRunIsBitExact() async throws {
        guard await LoopbackPermission.ensure(),
              let output = LoopbackGuard.dedicatedDevice(in: OutputDevices.list()) else { return }
        let runner = try LoopbackRunner(output: output)
        let report = try runner.run(LoopbackPlan.cases(rates: output.capabilities.sampleRates, mode: .quick), mode: .quick, appVersion: "test")
        for c in report.cases { print("\(c.testCase.name): \(c.summary) [\(c.deviceFormat ?? "-")]") }
        #expect(report.status == .bitExact)
    }
}
