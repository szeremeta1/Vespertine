//
// Vespertine: multichannel through the real engine and Core Audio to a 16-channel virtual device (BlackHole 16ch), recorded
// back from its input: every channel on its own output, bit for bit, at the file's rate; and Spatial Audio rendered on the
// I/O thread to the first pair only.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Opt-in: VESPERTINE_MULTICHANNEL_LOOPBACK=1 swift test --filter MultichannelLoopback (needs a virtual device of 8 or more
// channels, "BlackHole 16ch" unless VESPERTINE_MULTICHANNEL_DEVICE names another, and audio input access for the test
// process). Nothing is audible: the device is virtual. A device another process is using is left alone.
//

import AVFAudio
import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio
import VespertineTestSupport

@Suite("Multichannel loopback", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_MULTICHANNEL_LOOPBACK"] == "1"))
struct MultichannelLoopbackTests {
    static let deviceName = ProcessInfo.processInfo.environment["VESPERTINE_MULTICHANNEL_DEVICE"] ?? "BlackHole 16ch"

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let channels: Int
        let mask: UInt32
        let rate: Double
        let carries: [Int]
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "5.1 at 96 kHz", channels: 6, mask: 0x3F, rate: 96_000, carries: Array(0..<6)),
        Case(name: "7.1 (WAV) at 48 kHz", channels: 8, mask: 0x63F, rate: 48_000, carries: [0, 1, 2, 3, 6, 7, 4, 5]),
        Case(name: "quad at 44.1 kHz", channels: 4, mask: 0x33, rate: 44_100, carries: Array(0..<4)),
        Case(name: "5.1 with no speaker mask at 192 kHz", channels: 6, mask: 0, rate: 192_000, carries: Array(0..<6)),
        Case(name: "7.1.4 at 48 kHz", channels: 12, mask: 0x63F | 0x1000 | 0x4000 | 0x8000 | 0x2_0000, rate: 48_000, carries: Array(0..<12)),
        Case(name: "12 ch with no speaker mask at 48 kHz", channels: 12, mask: 0, rate: 48_000, carries: Array(0..<12)),
    ]

    /// The device, untouched by anyone else, and its rate to put back afterwards.
    static func device() throws -> (OutputDevice, Double) {
        let output = try #require(DeviceQuery.outputDevices(dopEnabledUIDs: []).first { $0.name == deviceName && $0.transport == .virtual },
                                  "no virtual device named \(deviceName)")
        try #require(output.capabilities.outputChannels >= 8, "\(deviceName) has \(output.capabilities.outputChannels) channels")
        try #require(!LoopbackGuard.inUseByOthers(output.id), "\(deviceName) is in use by another process; left alone")
        try #require(AVAudioApplication.shared.recordPermission != .denied, "audio input access denied")
        let rate = try HAL.get(output.id, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))
        return (output, rate)
    }

    static func settings(_ output: OutputDevice, spatial: SpatialMode, policy: RatePolicy = .matchSource, spatializeStereo: Bool = false) -> EngineSettings {
        var settings = EngineSettings()
        settings.exclusive = false
        settings.deviceUID = output.uid
        settings.deviceName = output.name
        settings.ratePolicies = [output.uid: policy]
        settings.spatialModes = [output.uid: spatial]
        if spatializeStereo { settings.spatializeStereoUIDs = [output.uid] }
        return settings
    }

    /// Plays `url` on `output` and returns the recording (one array per input channel), the device rate seen while
    /// playing, and the signal path.
    static func play(_ url: URL, on output: OutputDevice, rate: Double, spatial: SpatialMode = .off, seconds: Double, item: PlayableItem? = nil,
                     policy: RatePolicy = .matchSource, spatializeStereo: Bool = false)
        throws -> (recorded: [[Float]], rates: Set<Double>, path: SignalPath?, discontinuities: Int) {
        try DeviceControl.setNominalRate(rate, on: output.id)
        let recorder = try LoopbackRecorder(device: output.id, rate: rate, maxChannels: 16)
        try recorder.start()
        defer { recorder.restore() }
        let engine = PlaybackEngine()
        engine.update(settings: settings(output, spatial: spatial, policy: policy, spatializeStereo: spatializeStereo))
        Thread.sleep(forTimeInterval: 0.2)
        recorder.drain()
        engine.play(item ?? PlayableItem(url: url))
        let started = Date()
        var played = false, rates: Set<Double> = [], path: SignalPath?
        while Date().timeIntervalSince(started) < seconds + 8 {
            Thread.sleep(forTimeInterval: 0.01)
            recorder.drain()
            let snap = engine.snapshot
            if snap.state == .playing {
                played = true
                path = path ?? snap.signalPath
                rates.insert((try? HAL.get(output.id, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0)
            }
            if played, snap.state == .stopped { break }
        }
        let tail = Date().addingTimeInterval(0.3)
        while Date() < tail { Thread.sleep(forTimeInterval: 0.02); recorder.drain() }
        engine.stopAndWait()
        recorder.stop()
        #expect(played, "never played")
        return (recorder.samples, rates, path, recorder.discontinuityCount)
    }

    @Test("Every channel reaches its own output of the device, bit for bit, in order, at the file's rate", arguments: cases)
    func channelForChannel(_ c: Case) throws {
        let (output, originalRate) = try Self.device()
        defer { try? DeviceControl.setNominalRate(originalRate, on: output.id) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcloop-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let seconds = 2.0
        let frames = Int(c.rate * seconds)
        try ChannelID.writeWAV(to: url, channels: c.channels, frames: frames, rate: c.rate, mask: c.mask)
        let run = try Self.play(url, on: output, rate: c.rate, seconds: seconds)
        let channels = run.recorded.count
        try #require(channels >= 8)
        #expect(run.rates == [c.rate], "device rate while playing: \(run.rates.sorted())")
        if let path = run.path {
            #expect(path.plan.spatial == .off && path.plan.channels == c.channels && path.plan.deviceChannels == c.channels, "\(path.plan)")
            #expect(abs(path.applied.sampleRate - c.rate) < 0.5)
        }
        #expect(run.discontinuities == 0)

        // Past the start's fade in: from source frame `anchor` on, every sample is the file's own.
        let anchor = Int(c.rate * 0.5)
        let source = try #require(c.carries.firstIndex(of: 0), "no output carries channel 0")
        let left = run.recorded[source]
        let start = try #require(left.indices.first { i in ChannelID.decode(left[i]).map { $0.channel == 0 && $0.frame == anchor } ?? false },
                                 "\(c.name): source frame \(anchor) never reached output \(source + 1) (recorded \(left.count) frames, peak \(left.map(abs).max() ?? 0))")
        let window = frames - anchor - Int(c.rate * 0.05)
        try #require(start + window <= left.count, "recording ends early")
        var interleaved = [Float](repeating: 0, count: window * channels)
        for ch in 0..<channels { for f in 0..<window { interleaved[f * channels + ch] = run.recorded[ch][start + f] } }
        let carried = ChannelID.identify(interleaved, stride: channels, frames: window, firstFrame: anchor)
        let want: [Int?] = c.carries + Array(repeating: -1, count: channels - c.channels)
        #expect(carried == want, "\(c.name): outputs carried \(carried.map { $0.map(String.init) ?? "✗" })")
    }

    @Test("5.1 with Spatial Audio on a multichannel device: rendered on the I/O thread to the first pair only, each speaker on its side",
          arguments: [SpatialMode.fixed, .headTracked])
    func spatial(_ mode: SpatialMode) throws {
        let (output, originalRate) = try Self.device()
        defer { try? DeviceControl.setNominalRate(originalRate, on: output.id) }
        let names = ["FL", "FR", "FC", "LFE", "BL", "BR"]
        let tones = SpatialProbe.frequencies(names)
        let rate = 48_000.0, seconds = 2.0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcspatial-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try ChannelID.writeWAV(to: url, channels: 6, frames: Int(rate * seconds), rate: rate, mask: 0x3F) { c, f in
            Int32((0.1 * sin(2 * .pi * tones[c] * Double(f) / rate) * 8_388_607).rounded())
        }
        let run = try Self.play(url, on: output, rate: rate, spatial: mode, seconds: seconds)
        if let path = run.path {
            #expect(path.plan.spatial == mode && path.plan.channels == 6 && path.plan.deviceChannels == 2, "\(path.plan)")
            #expect(path.plan.spatialBed == kAudioChannelLayoutTag_MPEG_5_1_A)
        }
        #expect(run.rates == [rate])
        let recorded = run.recorded
        let l = recorded[0], r = recorded[1]
        let first = try #require(l.indices.first { abs(l[$0]) > 1e-4 || abs(r[$0]) > 1e-4 }, "nothing reached the first pair")
        let from = first + Int(rate * 0.5), count = Int(rate * 0.8)
        try #require(from + count <= l.count)
        // Nothing but the binaural pair: every other output exactly silent.
        for ch in 2..<recorded.count {
            #expect(recorded[ch].allSatisfy { $0 == 0 }, "output \(ch + 1) isn't silent")
        }
        for (c, name) in names.enumerated() {
            let lv = SpatialProbe.level(l, stride: 1, offset: 0, frequency: tones[c], rate: rate, from: from, count: count)
            let rv = SpatialProbe.level(r, stride: 1, offset: 0, frequency: tones[c], rate: rate, from: from, count: count)
            let ild = 20 * log10(max(lv, 1e-9) / max(rv, 1e-9))
            #expect(max(lv, rv) > 0.1 * 0.03, "\(name) not heard after Spatial Audio")
            let position = SpatialProbe.expected(name, in: names).sorted().first ?? ""
            switch SpatialProbe.side(position) {
            case .left: #expect(ild > 2, "\(name) not on the left (ILD \(ild) dB)")
            case .right: #expect(ild < -2, "\(name) not on the right (ILD \(ild) dB)")
            case .middle: #expect(abs(ild) < 2.5, "\(name) off-centre (ILD \(ild) dB)")
            }
            print("spatial \(mode.rawValue) \(name): L \(String(format: "%.4f", lv)) R \(String(format: "%.4f", rv)) ILD \(String(format: "%+.1f", ild)) dB")
        }
    }

    @Test("5.1 DSF and SACD ISO: converted to PCM, every channel on its own output, the rest silent", arguments: ["dsf", "iso"])
    func dsd(ext: String) throws {
        let (output, originalRate) = try Self.device()
        defer { try? DeviceControl.setNominalRate(originalRate, on: output.id) }
        let url = try MultichannelDSDDeviceTests.write(ext)
        defer { try? FileManager.default.removeItem(at: url) }
        let item = ext == "iso" ? PlayableItem(url: url, sacdArea: .multichannel) : PlayableItem(url: url)
        // DSD64 becomes 352.8 kHz PCM, sent at a fixed 88.2 kHz here: the recorder can't keep up with 16 channels at 352.8 kHz
        // in a debug build (the planner's own choice of rate for DSD is covered offline, MultichannelDSDDeviceTests).
        let rate = 88_200.0
        let run = try Self.play(url, on: output, rate: rate, seconds: 1.3, item: item, policy: .fixed(rate))
        #expect(run.rates == [rate], "device rate while playing: \(run.rates.sorted())")
        if let path = run.path { #expect(path.plan.dsdConvertedToPCM && path.plan.channels == 6 && path.plan.spatial == .off, "\(path.plan)") }
        let channels = run.recorded.count
        let first = try #require(run.recorded[0].indices.first { abs(run.recorded[0][$0]) > 1e-4 }, "nothing recorded")
        let frames = run.recorded[0].count
        var interleaved = [Float](repeating: 0, count: frames * channels)
        for ch in 0..<channels { for f in 0..<frames { interleaved[f * channels + ch] = run.recorded[ch][f] } }
        let carried = ToneID.identify(interleaved, stride: channels, tones: SpatialProbe.frequencies(MultichannelDSDDeviceTests.names), rate: rate,
                                      from: first + Int(rate * 0.3), count: Int(rate * 0.6))
        #expect(carried == Array(0..<6) + Array(repeating: -1, count: channels - 6), "\(ext) at \(rate) Hz: \(carried)")
        print("dsd \(ext): \(rate) Hz, outputs carried \(carried)")
    }

    @Test("Spatialize stereo on the device: a stereo file upmixed to outputs 1–6 (the middle on C), the rest silent; off, untouched",
          arguments: [true, false])
    func spatializeStereo(_ on: Bool) throws {
        let (output, originalRate) = try Self.device()
        defer { try? DeviceControl.setNominalRate(originalRate, on: output.id) }
        let rate = 48_000.0
        let url = try StereoSpatializeTests.write(rate: rate, seconds: 1.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let run = try Self.play(url, on: output, rate: rate, seconds: 1.5, spatializeStereo: on)
        #expect(run.rates == [rate])
        if let path = run.path { #expect(path.plan.upmix == on && path.plan.channels == (on ? 6 : 2), "\(path.plan)") }
        let rec = run.recorded
        let first = try #require(rec[0].indices.first { abs(rec[0][$0]) > 1e-4 || abs(rec[2][$0]) > 1e-4 }, "nothing recorded")
        let from = first + Int(rate * 0.4), count = Int(rate * 0.6)
        try #require(from + count <= rec[0].count)
        func level(_ ch: Int, _ hz: Double) -> Double { SpatialProbe.level(rec[ch], stride: 1, offset: 0, frequency: hz, rate: rate, from: from, count: count) }
        let silentFrom = on ? 6 : 2
        for ch in silentFrom..<rec.count { #expect(rec[ch].allSatisfy { $0 == 0 }, "output \(ch + 1) isn't silent") }
        if on {
            #expect(abs(level(2, 1_000) / (0.1 * 2.0.squareRoot()) - 1) < 0.03, "C: \(level(2, 1_000))")
            #expect(level(0, 1_000) < 0.001 && level(1, 1_000) < 0.001)
            #expect(abs(level(0, 600) / 0.1 - 1) < 0.03, "L: \(level(0, 600))")
            print("spatialize on: C 1 kHz \(level(2, 1_000)), L 600 Hz \(level(0, 600)), L 1 kHz \(level(0, 1_000)), Ls \(level(4, 1_000))")
        } else {
            #expect(abs(level(0, 1_000) / 0.1 - 1) < 0.01 && abs(level(1, 1_000) / 0.1 - 1) < 0.01)
        }
    }
}
