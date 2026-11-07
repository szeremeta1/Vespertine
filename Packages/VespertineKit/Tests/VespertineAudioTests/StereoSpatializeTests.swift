//
// Vespertine — Spatialize stereo through the engine's own pieces: when the planner upmixes (and only then), and what the
// decoding hands the ring on each kind of output, then Apple's spatial mixer for headphones.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Spatialize stereo through the engine")
struct StereoSpatializeTests {
    static let airPods = DeviceCapabilities(sampleRates: [48_000], physicalFormats: [
        PhysicalFormat(minRate: 48_000, maxRate: 48_000, bitDepth: 24, isInteger: true, isMixable: true, channels: 2)], outputChannels: 2, supportsDoP: false)
    static func device(outputs: Int, speakers: Int? = nil, dop: Bool = false) -> DeviceCapabilities {
        DeviceCapabilities(sampleRates: GoldenDevices.rates, physicalFormats: [
            PhysicalFormat(minRate: 44_100, maxRate: 192_000, bitDepth: 24, isInteger: true, isMixable: true, channels: outputs)],
            outputChannels: outputs, supportsDoP: dop, speakerLayoutChannels: speakers)
    }
    static let stereo = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 96_000, bitDepth: 24, channels: 2)
    static let mono = SourceFormat(encoding: .pcm, codec: "MP3", sampleRate: 44_100, bitDepth: nil, channels: 1)
    static let dsd = SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: 2_822_400, bitDepth: 1, channels: 2)

    @Test("Off (the default), every plan is the usual one")
    func offIsUnchanged() {
        let devices = [Self.airPods, Self.device(outputs: 2), Self.device(outputs: 8), Self.device(outputs: 16), Self.device(outputs: 8, speakers: 8),
                       Self.device(outputs: 8, dop: true)]
        for source in [Self.stereo, Self.mono, Self.dsd] {
            for device in devices {
                for spatial in SpatialMode.allCases {
                    let usual = FormatPlanner.plan(source: source, device: device, spatial: spatial)
                    let off = FormatPlanner.plan(source: source, device: device, spatial: spatial, spatializeStereo: false)
                    #expect(off == usual && !off.upmix)
                }
            }
        }
    }

    @Test("On: AirPods get 5.1 on the Spatial Audio bed, head tracked as set; the device still gets two channels")
    func headphones() {
        let plan = FormatPlanner.plan(source: Self.stereo, device: Self.airPods, spatial: .headTracked, spatializeStereo: true)
        #expect(plan.upmix && plan.spatial == .headTracked && plan.channels == 6 && plan.deviceChannels == 2)
        #expect(plan.spatialBed == kAudioChannelLayoutTag_MPEG_5_1_A)
        #expect(plan.deviceSampleRate == 48_000 && plan.mode == .pcm)
        #expect(plan.reason.hasPrefix("Stereo upmixed to 5.1 and rendered with Spatial Audio (head tracked)"), "\(plan.reason)")
        let mono = FormatPlanner.plan(source: Self.mono, device: Self.airPods, spatial: .fixed, spatializeStereo: true)
        #expect(mono.upmix && mono.channels == 6 && mono.reason.hasPrefix("Mono upmixed"))
    }

    @Test("On: a multichannel output gets 5.1 on outputs 1–6; a speaker setup gets it by speaker; a stereo DAC is unchanged")
    func speakers() {
        let sixteen = FormatPlanner.plan(source: Self.stereo, device: Self.device(outputs: 16), spatializeStereo: true)
        #expect(sixteen.upmix && sixteen.channels == 6 && sixteen.deviceChannels == 6 && sixteen.spatial == .off)
        #expect(sixteen.routeLabels == StereoUpmixer.outputLabels && sixteen.deviceSampleRate == 96_000)
        let room = FormatPlanner.plan(source: Self.stereo, device: Self.device(outputs: 8, speakers: 8), spatializeStereo: true)
        #expect(room.upmix && room.channels == 8 && room.routeLabels == nil)
        let dac = FormatPlanner.plan(source: Self.stereo, device: Self.device(outputs: 2), spatializeStereo: true)
        #expect(!dac.upmix && dac == FormatPlanner.plan(source: Self.stereo, device: Self.device(outputs: 2)))
        let four = FormatPlanner.plan(source: Self.stereo, device: Self.device(outputs: 4), spatializeStereo: true)
        #expect(!four.upmix, "4 outputs and no speaker setup: nowhere to put 5.1")
        let surround = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 48_000, bitDepth: 24, channels: 6)
        #expect(!FormatPlanner.plan(source: surround, device: Self.device(outputs: 16), spatializeStereo: true).upmix)
    }

    @Test("The switch applies only where 5.1 has somewhere to go, which is when a plan upmixes; a stereo DAC with Spatial Audio off has none")
    func appliesWhereTheEngineUpmixes() {
        let devices = [Self.airPods, Self.device(outputs: 2), Self.device(outputs: 4), Self.device(outputs: 8), Self.device(outputs: 16),
                       Self.device(outputs: 8, speakers: 8), Self.device(outputs: 2, speakers: 2)]
        for device in devices {
            for spatial in SpatialMode.allCases {
                let upmixes = FormatPlanner.plan(source: Self.stereo, device: device, spatial: spatial, spatializeStereo: true).upmix
                #expect(FormatPlanner.canSpatializeStereo(on: device, spatial: spatial) == upmixes,
                        "\(device.outputChannels) outputs, speakers \(device.speakerLayoutChannels ?? 0), \(spatial)")
            }
        }
        #expect(!FormatPlanner.canSpatializeStereo(on: Self.airPods, spatial: .off))
        #expect(FormatPlanner.canSpatializeStereo(on: Self.airPods, spatial: .fixed))
        #expect(FormatPlanner.canSpatializeStereo(on: Self.device(outputs: 16), spatial: .off), "multichannel outputs don't need Spatial Audio")
    }

    @Test("On: DSD is converted to PCM to be upmixed, even on a DoP DAC, and says so")
    func dsdToPCM() {
        let plan = FormatPlanner.plan(source: Self.dsd, device: Self.device(outputs: 8, dop: true), spatializeStereo: true)
        #expect(plan.upmix && plan.mode == .pcm && plan.dsdConvertedToPCM && plan.channels == 6)
        #expect(plan.reason.contains("converted to PCM so it can be upmixed"), "\(plan.reason)")
        #expect(FormatPlanner.plan(source: Self.dsd, device: Self.device(outputs: 8, dop: true)).mode == .dop)
    }

    /// Stereo: a 1 kHz tone in the middle and a 600 Hz tone on the left only, -20 dBFS each.
    static func write(rate: Double, seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spz-\(UUID()).wav")
        try ChannelID.writeWAV(to: url, channels: 2, frames: Int(rate * seconds), rate: rate, mask: WaveMask.FL | WaveMask.FR) { c, f in
            let t = Double(f) / rate
            let v = 0.1 * sin(2 * .pi * 1_000 * t) + (c == 0 ? 0.1 * sin(2 * .pi * 600 * t) : 0)
            return Int32((v * 8_388_607).rounded())
        }
        return url
    }

    /// What `Decoding` hands the ring for `url` planned on `device` (the session's layout as OutputSession makes it).
    static func decode(_ url: URL, device: DeviceCapabilities, spatial: SpatialMode = .off, speakers: AVAudioChannelLayout? = nil) throws
        -> (samples: [Float], plan: OutputPlan, layout: AVAudioChannelLayout?) {
        let probed = try SourceOpener.probe(url)
        var plan = FormatPlanner.plan(source: probed.format, device: device, spatial: spatial, spatializeStereo: true)
        plan.integerSamples = false
        let layout = OutputSession.routeLayout(plan: plan, speakers: speakers)
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: url))
        let path = SignalPath(source: probed.format, decoderName: "test", plan: plan,
                              applied: AppliedFormat(sampleRate: plan.deviceSampleRate, physicalBitDepth: 24, physicalIsInteger: true,
                                                     virtualChannels: device.outputChannels, exclusive: true, bufferFrames: 512),
                              deviceName: "test", deviceUID: "test",
                              deviceProfile: DeviceProfile(kind: .usbDAC, tag: "", canBeBitPerfect: true, symbol: "x"), volume: .fixed)
        #expect(!path.isBitPerfect)
        let decoding = try Decoding(item: PlayableItem(url: url), probed: probed, decoder: decoder, path: path, chunk: 4096, layout: layout)
        var out: [Float] = []
        while true {
            let chunk = decoding.convertChunk()
            if let data = chunk.data { out += UnsafeBufferPointer(start: data, count: Int(chunk.frames) * plan.channels) }
            if chunk.ended { break }
        }
        return (out, plan, layout)
    }

    @Test("A stereo file on a 16-channel output: the middle on C, the left-only tone on L, nothing on R's own; length exact")
    func onSixOutputs() throws {
        let rate = 96_000.0, seconds = 1.5
        let url = try Self.write(rate: rate, seconds: seconds)
        defer { try? FileManager.default.removeItem(at: url) }
        let (out, plan, _) = try Self.decode(url, device: Self.device(outputs: 16))
        #expect(plan.channels == 6)
        #expect(out.count / 6 == Int(rate * seconds), "\(out.count / 6) frames for \(Int(rate * seconds))")
        let from = Int(rate * 0.4), count = Int(rate * 0.6)
        func level(_ ch: Int, _ hz: Double) -> Double { SpatialProbe.level(out, stride: 6, offset: ch, frequency: hz, rate: rate, from: from, count: count) }
        #expect(abs(level(2, 1_000) / (0.1 * 2.0.squareRoot()) - 1) < 0.03, "C carries the middle at equal power: \(level(2, 1_000))")
        #expect(level(0, 1_000) < 0.001 && level(1, 1_000) < 0.001, "the middle left the fronts: L \(level(0, 1_000)) R \(level(1, 1_000))")
        #expect(abs(level(0, 600) / 0.1 - 1) < 0.03, "L keeps the left-only tone: \(level(0, 600))")
        #expect(level(2, 600) < 0.001 && level(1, 600) < 0.001 && level(4, 600) < 0.001, "the left-only tone stays left")
        #expect(out.enumerated().allSatisfy { $0.offset % 6 != 3 || $0.element == 0 }, "LFE silent by default")
    }

    @Test("On a receiver with 7.1 speakers in HDMI order (L R LFE C …): the centre on C's own output, the back pair silent")
    func onHDMIReceiver() throws {
        let rate = 48_000.0
        let url = try Self.write(rate: rate, seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let hdmi = try #require(ChannelLayouts.layout(labels: [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_LFEScreen,
                                                               kAudioChannelLabel_Center, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
                                                               kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight]))
        let (out, plan, layout) = try Self.decode(url, device: Self.device(outputs: 8, speakers: 8), speakers: hdmi)
        #expect(plan.channels == 8 && layout?.shortNames == ["L", "R", "LFE", "C", "Ls", "Rs", "Lrs", "Rrs"])
        let from = 19_200, count = 24_000
        func level(_ ch: Int, _ hz: Double) -> Double { SpatialProbe.level(out, stride: 8, offset: ch, frequency: hz, rate: rate, from: from, count: count) }
        #expect(abs(level(3, 1_000) / (0.1 * 2.0.squareRoot()) - 1) < 0.03, "C (output 4): \(level(3, 1_000))")
        #expect(level(2, 1_000) < 0.001, "nothing on the LFE")
        for ch in [6, 7] { #expect((0..<(out.count / 8)).allSatisfy { out[$0 * 8 + ch] == 0 }, "output \(ch + 1) isn't silent") }
    }

    @Test("On AirPods: the 5.1 upmix through Apple's spatial mixer, the middle in the middle and the left-only tone on the left")
    func onHeadphones() throws {
        let rate = 48_000.0
        let url = try Self.write(rate: rate, seconds: 1.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let (bed, plan, layout) = try Self.decode(url, device: Self.airPods, spatial: .headTracked)
        #expect(plan.channels == 6 && plan.deviceChannels == 2)
        let renderer = try SpatialRenderer(inputLayout: try #require(layout), channels: 6, sampleRate: rate, maxFrames: 4096, mode: .headTracked)
        let out = renderer.render(interleaved: bed, frames: bed.count / 6)
        let from = 19_200, count = 38_400
        func level(_ ch: Int, _ hz: Double) -> Double { SpatialProbe.level(out, stride: 2, offset: ch, frequency: hz, rate: rate, from: from, count: count) }
        let centre = 20 * log10(level(0, 1_000) / level(1, 1_000)), left = 20 * log10(level(0, 600) / level(1, 600))
        print("spatialized stereo on headphones: middle ILD \(String(format: "%+.1f", centre)) dB, left-only ILD \(String(format: "%+.1f", left)) dB")
        #expect(level(0, 1_000) > 0.01 && level(0, 600) > 0.01, "heard")
        if ProcessInfo.processInfo.environment["VESPERTINE_HARDWARE_TESTS"] == "1" {
            #expect(abs(centre) < 1.5, "the middle off-centre: \(centre) dB")
            #expect(left > 2, "the left-only tone not on the left: \(left) dB")
        }
    }
}
