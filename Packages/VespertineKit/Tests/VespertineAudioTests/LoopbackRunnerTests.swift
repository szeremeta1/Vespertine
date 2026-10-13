//
// Vespertine — the loopback self-test's files, plan, guard and forced settings (no device needed), and one real run
// through "Vespertine Loopback" when hardware tests are on.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import Testing
@testable import VespertineAnalysisCore
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

    private func sampleReport(app: String = "0.12.0", macOS: String = "26.0.0", date: Double = 1_800_000_000) -> LoopbackReport {
        let ok = LoopbackCaseResult(testCase: LoopbackCase(sampleRate: 96_000, bits: 24), status: .bitExact, summary: "bit-exact",
                                    settings: ["Equalizer": "off", "Digital volume": "off"], deviceFormat: "Float32 · 96 kHz")
        let channel = LoopbackChannelResult(channel: 1, capturedChannel: 1, lock: 1, nextPeak: 0.03, latencyFrames: 512, driftFrames: 0,
                                            comparedFrames: 100_000, mismatchedFrames: 40, firstMismatch: 2_048, maxErrorLSB: 1)
        let finding = LoopbackFinding(kind: .dither, channel: 1, frame: 2_048, count: 40, value: 1, summary: "dither on the right channel | ±1 LSB",
                                      isSetupProblem: false)
        var bad = LoopbackCaseResult(testCase: LoopbackCase(sampleRate: 44_100, bits: 16), status: .failed, summary: "dither on the right channel",
                                     settings: ok.settings, sixteenBitNote: "No 16-bit mode at 44.1 kHz; sent as 32-bit (same samples, zero-padded)")
        bad.analyses = [LoopbackResult(spec: .init(sampleRate: 44_100, bits: 16), channels: [channel], findings: [finding])]
        let skipped = LoopbackCaseResult(testCase: LoopbackCase(sampleRate: 44_100, bits: 32, integerMode: true), status: .skipped,
                                         summary: "no 32-bit integer format")
        return LoopbackReport(outputDevice: "Vespertine Loopback", outputUID: "uid", inputDevice: "Vespertine Loopback", macOS: macOS,
                              appVersion: app, date: Date(timeIntervalSince1970: date), mode: .quick, cases: [ok, bad, skipped])
    }

    @Test("The Markdown report says it's a software check, lists every case and the settings, and details the failures")
    func markdown() {
        let md = sampleReport().markdown
        #expect(md.hasPrefix("## Loopback (software check)\n\n" + LoopbackReport.scope))
        #expect(md.contains("- Result: **Failed**") && md.contains("Vespertine 0.12.0, macOS 26.0.0"))
        #expect(md.contains("| 24-bit at 96 kHz | Bit-exact | Float32 · 96 kHz | bit-exact |"))
        #expect(md.contains("| 16-bit padded at 44.1 kHz | Failed | – | dither on the right channel; No 16-bit mode"))
        #expect(md.contains("| 32-bit integer mode at 44.1 kHz | Skipped |"))
        #expect(md.contains("- Digital volume: off\n- Equalizer: off\n"))
        #expect(md.contains("**16-bit padded at 44.1 kHz**") && !md.contains("**24-bit at 96 kHz**"))
        #expect(md.contains("- Right (captured on 2), 40 of 100000 frames differ, first at frame 2048, up to 1 LSB"))
        #expect(!md.lowercased().contains("dac is bit-perfect"))
    }

    @Test("Saved results are keyed by device, format, settings, macOS and app version; a newer run replaces its key")
    func savedResults() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loopback-results-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LoopbackResultStore(url: url)
        #expect(store.load().isEmpty)
        try store.save(sampleReport())
        #expect(store.load().count == 2)                       // the skipped case isn't kept
        try store.save(sampleReport(date: 1_800_000_100))       // same keys: replaced
        try store.save(sampleReport(app: "0.13.0"))             // another version: kept beside
        let saved = store.load()
        #expect(saved.count == 4)
        #expect(Set(saved.map(\.key)).count == 4)
        let key = try #require(saved.first { $0.key.appVersion == "0.12.0" && $0.key.format == "24-bit at 96 kHz" }).key
        #expect(key.deviceUID == "uid" && key.macOS == "26.0.0" && key.settings == "Digital volume=off\nEqualizer=off")
        let hit = LoopbackResultStore.latest(in: saved, sampleRate: 96_000, bits: 24, macOS: "26.0.0", appVersion: "0.12.0")
        #expect(hit?.result.status == .bitExact && hit?.date == Date(timeIntervalSince1970: 1_800_000_100))
        #expect(LoopbackResultStore.latest(in: saved, sampleRate: 96_000, bits: 24, macOS: "26.1.0", appVersion: "0.12.0") == nil)
        #expect(LoopbackResultStore.latest(in: saved, sampleRate: 44_100, bits: 16, macOS: "26.0.0", appVersion: "0.12.0")?.result.status == .failed)
        #expect(LoopbackResultStore.latest(in: saved, sampleRate: 44_100, bits: 16, matchSixteenBit: true, macOS: "26.0.0", appVersion: "0.12.0") == nil)
    }

    @Test("The signal path shows a saved result only for its own format, on this version, with nothing changing the samples")
    func savedResultForSignalPath() throws {
        let ok = LoopbackCaseResult(testCase: LoopbackCase(sampleRate: 96_000, bits: 24), status: .bitExact, summary: "bit-exact")
        let saved = [LoopbackSavedResult(key: LoopbackResultKey(deviceUID: "loop", format: ok.id, settings: [:], macOS: "26.0.0", appVersion: "0.12.0"),
                                         deviceName: "Vespertine Loopback", date: .now, mode: .quick, result: ok)]
        func path(rate: Double, bits: Int, volume: SignalPath.VolumeStage = .fixed) -> SignalPath {
            let source = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: rate, bitDepth: bits, channels: 2)
            let plan = FormatPlanner.plan(source: source, device: DeviceCapabilities(sampleRates: [rate], physicalFormats: [],
                                                                                     outputChannels: 2, supportsDoP: false))
            return SignalPath(source: source, decoderName: "test", plan: plan,
                              applied: AppliedFormat(sampleRate: rate, physicalBitDepth: 24, physicalIsInteger: true, virtualChannels: 2,
                                                     exclusive: true, bufferFrames: 512),
                              deviceName: "DAC", deviceUID: "dac",
                              deviceProfile: DeviceProfile(kind: .usbDAC, tag: "USB", canBeBitPerfect: true, symbol: "x"), volume: volume)
        }
        func lookup(_ p: SignalPath, macOS: String = "26.0.0") -> LoopbackSavedResult? {
            LoopbackResultStore.latest(in: saved, for: p, macOS: macOS, appVersion: "0.12.0")
        }
        #expect(lookup(path(rate: 96_000, bits: 24))?.result.status == .bitExact)
        #expect(lookup(path(rate: 96_000, bits: 24), macOS: "26.1.0") == nil)
        #expect(lookup(path(rate: 44_100, bits: 24)) == nil)
        #expect(lookup(path(rate: 96_000, bits: 16)) == nil)
        #expect(lookup(path(rate: 96_000, bits: 24, volume: .digital(dB: -6))) == nil)
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
