//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
@testable import VespertineAudio

private func pcm(_ rate: Double, _ bits: Int = 24, codec: String = "FLAC") -> SourceFormat {
    SourceFormat(encoding: .pcm, codec: codec, sampleRate: rate, bitDepth: bits, channels: 2)
}

private func caps(_ rates: [Double], depths: [Int] = [16, 24, 32], dop: Bool = false) -> DeviceCapabilities {
    let formats = depths.map { PhysicalFormat(minRate: rates.min()!, maxRate: rates.max()!, bitDepth: $0, isInteger: true, isMixable: true, channels: 2) }
    return DeviceCapabilities(sampleRates: rates, physicalFormats: formats, outputChannels: 2, supportsDoP: dop)
}

/// FiiO K11-class USB DAC: 44.1–384 kHz, 16/24/32-bit.
private let k11 = caps([44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000])
/// AirPods Max on USB-C: 24-bit / 48 kHz only.
private let airPodsMax = caps([48_000], depths: [24])
/// UGREEN CM450 (read 2026-10-15): 44.1, 48, 96, 192 and 384 kHz, none of 88.2 / 176.4 / 352.8.
private let cm450 = caps([44_100, 48_000, 96_000, 192_000, 384_000])
/// A 192 kHz-max DAC.
private let dac192 = caps([44_100, 48_000, 88_200, 96_000, 176_400, 192_000])

@Suite("FormatPlanner")
struct FormatPlannerTests {
    @Test("A DAC without the 44.1 family's high rates converts up to the next rate, never down")
    func missingHighFortyFourFamily() {
        for (source, expected) in [(88_200.0, 96_000.0), (176_400, 192_000), (352_800, 384_000)] {
            let plan = FormatPlanner.plan(source: pcm(source), device: cm450)
            #expect(plan.deviceSampleRate == expected)
            #expect(plan.resamples)
        }
        #expect(!FormatPlanner.plan(source: pcm(44_100, 16), device: cm450).resamples)
        let dsd = SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: 2_822_400, bitDepth: 1, channels: 2)
        let plan = FormatPlanner.plan(source: dsd, device: cm450)
        #expect(plan.dsdConvertedToPCM)
        #expect(plan.deviceSampleRate == 384_000)
    }

    @Test("Native rates are matched exactly", arguments: [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000])
    func matchesNative(rate: Double) {
        let plan = FormatPlanner.plan(source: pcm(rate), device: k11)
        #expect(plan.deviceSampleRate == rate)
        #expect(!plan.resamples)
        #expect(plan.physicalBitDepth == 32)
        #expect(plan.mode == .pcm)
    }

    @Test("AirPods Max: 44.1 kHz is converted to 48 kHz, 24-bit")
    func airPods441() {
        let plan = FormatPlanner.plan(source: pcm(44_100, 16, codec: "ALAC"), device: airPodsMax)
        #expect(plan.deviceSampleRate == 48_000)
        #expect(plan.physicalBitDepth == 24)
        #expect(plan.resamples)
    }

    @Test("AirPods Max: 48 kHz plays without conversion")
    func airPods48() {
        let plan = FormatPlanner.plan(source: pcm(48_000), device: airPodsMax)
        #expect(plan.deviceSampleRate == 48_000)
        #expect(!plan.resamples)
    }

    @Test("AirPods Max: 192 kHz goes down to 48 kHz (integer divisor)")
    func airPods192() {
        #expect(FormatPlanner.plan(source: pcm(192_000), device: airPodsMax).deviceSampleRate == 48_000)
    }

    @Test("Unsupported high rates fall to the same family's divisor")
    func downFamily() {
        #expect(FormatPlanner.plan(source: pcm(384_000), device: dac192).deviceSampleRate == 192_000)
        #expect(FormatPlanner.plan(source: pcm(352_800), device: dac192).deviceSampleRate == 176_400)
    }

    @Test("A divisor far below the device's top rate loses to the top rate")
    func divisorKeepsBandwidth() {
        // The KTMicro chip in UGREEN's small USB-C adapter (read 2026-10-15): 44.1, 48 and 96 kHz only.
        let kt = caps([44_100, 48_000, 96_000], depths: [16, 24])
        #expect(FormatPlanner.plan(source: pcm(176_400), device: kt).deviceSampleRate == 96_000)
        #expect(FormatPlanner.plan(source: pcm(352_800), device: kt).deviceSampleRate == 96_000)
        #expect(FormatPlanner.plan(source: pcm(192_000), device: kt).deviceSampleRate == 96_000)
        let dsd = SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: 2_822_400, bitDepth: 1, channels: 2)
        #expect(FormatPlanner.plan(source: dsd, device: kt).deviceSampleRate == 96_000)
        // A 48 kHz-max device still takes the same family's divisor.
        #expect(FormatPlanner.plan(source: pcm(88_200), device: caps([44_100, 48_000])).deviceSampleRate == 44_100)
    }

    @Test("Missing low rates prefer an integer multiple (same family)")
    func upFamily() {
        let noBase = caps([48_000, 88_200, 96_000])
        #expect(FormatPlanner.plan(source: pcm(44_100), device: noBase).deviceSampleRate == 88_200)
    }

    @Test("A rate a few hertz off the source isn't the source: a true multiple wins", arguments: [44_100.0, 48_000])
    func nearRateIsNotTheSource(rate: Double) {
        for offset in [1.0, 2.0, 5.0] {
            let near = caps([rate + offset, rate * 2])
            #expect(FormatPlanner.plan(source: pcm(rate), device: near).deviceSampleRate == rate * 2)
        }
        // The divisor search uses the same test.
        #expect(!SampleRate.isIntegerMultiple(rate, of: rate / 2 - 1))
        #expect(SampleRate.isIntegerMultiple(rate, of: rate / 2))
    }

    @Test("Rate policies")
    func policies() {
        #expect(FormatPlanner.plan(source: pcm(44_100), device: k11, policy: .maximum).deviceSampleRate == 384_000)
        #expect(FormatPlanner.plan(source: pcm(44_100), device: k11, policy: .fixed(96_000)).deviceSampleRate == 96_000)
    }

    @Test("DSD64 → DoP at 176.4 kHz when the DAC is DoP-enabled")
    func dsdDoP() {
        let src = SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: 2_822_400, bitDepth: 1, channels: 2)
        let plan = FormatPlanner.plan(source: src, device: caps(k11.sampleRates, dop: true))
        #expect(plan.mode == .dop)
        #expect(plan.deviceSampleRate == 176_400)
        #expect(!plan.dsdConvertedToPCM)
    }

    /// A DoP-enabled DAC whose formats are `formats` at every rate it lists (44.1 to 384 kHz).
    private func dopDAC(_ formats: [PhysicalFormat]) -> DeviceCapabilities {
        DeviceCapabilities(sampleRates: k11.sampleRates, physicalFormats: formats, outputChannels: 2, supportsDoP: true)
    }
    private func format(_ bits: Int, integer: Bool = true, from: Double = 44_100, to: Double = 384_000, channels: Int = 2) -> PhysicalFormat {
        PhysicalFormat(minRate: from, maxRate: to, bitDepth: bits, isInteger: integer, isMixable: true, channels: channels)
    }

    @Test("DoP only where the DAC takes 24-bit integers at the carrier rate; otherwise DSD is converted to PCM and the plan says why",
          arguments: [
              ("Float32 only", [PhysicalFormat(minRate: 44_100, maxRate: 384_000, bitDepth: 32, isInteger: false, isMixable: true, channels: 2)]),
              ("16-bit integer only", [PhysicalFormat(minRate: 44_100, maxRate: 384_000, bitDepth: 16, isInteger: true, isMixable: true, channels: 2)]),
              ("24-bit only up to 96 kHz", [PhysicalFormat(minRate: 44_100, maxRate: 96_000, bitDepth: 24, isInteger: true, isMixable: true, channels: 2),
                                            PhysicalFormat(minRate: 44_100, maxRate: 384_000, bitDepth: 32, isInteger: false, isMixable: true, channels: 2)]),
              ("24-bit at 176.4 kHz, mono only", [PhysicalFormat(minRate: 44_100, maxRate: 384_000, bitDepth: 24, isInteger: true, isMixable: true, channels: 1),
                                                  PhysicalFormat(minRate: 44_100, maxRate: 384_000, bitDepth: 32, isInteger: false, isMixable: true, channels: 2)]),
          ])
    func dopNeedsIntegerCarrier(name: String, formats: [PhysicalFormat]) {
        let src = SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: 2_822_400, bitDepth: 1, channels: 2)
        let plan = FormatPlanner.plan(source: src, device: dopDAC(formats))
        #expect(plan.mode == .pcm, "\(name)")
        #expect(plan.dsdConvertedToPCM)
        #expect(plan.reason.contains("DoP") && plan.reason.contains("converted to PCM"), "\(plan.reason)")
    }

    @Test("DoP where the DAC takes 24- or 32-bit integers at the carrier rate", arguments: [24, 32])
    func dopWithIntegerCarrier(bits: Int) {
        for (rate, carrier) in [(2_822_400.0, 176_400.0), (5_644_800, 352_800)] {
            let src = SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: rate, bitDepth: 1, channels: 2)
            let plan = FormatPlanner.plan(source: src, device: dopDAC([format(bits), format(32, integer: false)]))
            #expect(plan.mode == .dop && plan.deviceSampleRate == carrier && plan.physicalBitDepth == bits)
        }
    }

    @Test("Multichannel DoP on a DAC whose channels come as several stereo streams, when every stream that carries them takes 24-bit integers")
    func dopAcrossStreams() {
        let stereo24 = format(24, channels: 2), stereoFloat = format(32, integer: false, channels: 2)
        func dac(_ streams: [[PhysicalFormat]]) -> DeviceCapabilities {
            DeviceCapabilities(sampleRates: k11.sampleRates, physicalFormats: Array(Set(streams.flatMap { $0 })),
                               outputChannels: streams.count * 2, supportsDoP: true, streamFormats: streams)
        }
        let src = SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: 2_822_400, bitDepth: 1, channels: 6)
        let four = FormatPlanner.plan(source: src, device: dac([[stereo24], [stereo24], [stereo24], [stereo24]]))
        #expect(four.mode == .dop && four.channels == 6 && four.physicalBitDepth == 24)
        // The channels go to the streams in order: one of the first three without an integer carrier means PCM.
        let floatSecond = FormatPlanner.plan(source: src, device: dac([[stereo24], [stereoFloat], [stereo24], [stereo24]]))
        #expect(floatSecond.mode == .pcm && floatSecond.dsdConvertedToPCM)
        // The fourth stream isn't used by 5.1, so it doesn't matter what it takes.
        #expect(FormatPlanner.plan(source: src, device: dac([[stereo24], [stereo24], [stereo24], [stereoFloat]])).mode == .dop)
        // Too few streams for every channel: PCM.
        #expect(FormatPlanner.plan(source: src, device: dac([[stereo24], [stereo24]])).mode == .pcm)
    }

    @Test("A DAC that lists no formats at all keeps DoP: the output checks the format it gets before playing")
    func dopWithoutListedFormats() {
        let src = SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: 2_822_400, bitDepth: 1, channels: 2)
        #expect(FormatPlanner.plan(source: src, device: dopDAC([])).mode == .dop)
    }

    @Test("DSD64 → PCM 352.8 kHz when DoP is off")
    func dsdToPCM() {
        let src = SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: 2_822_400, bitDepth: 1, channels: 2)
        let plan = FormatPlanner.plan(source: src, device: k11)
        #expect(plan.mode == .pcm)
        #expect(plan.dsdConvertedToPCM)
        #expect(plan.deviceSampleRate == 352_800)
        #expect(!plan.resamples)
    }

    @Test("DSD on AirPods Max ends at 24/48")
    func dsdAirPods() {
        let src = SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: 5_644_800, bitDepth: 1, channels: 2)
        let plan = FormatPlanner.plan(source: src, device: airPodsMax)
        #expect(plan.deviceSampleRate == 48_000)
        #expect(plan.resamples)
    }

    @Test("Gapless compatibility depends only on the device format")
    func compatibility() {
        let a = FormatPlanner.plan(source: pcm(96_000, 24), device: k11)
        let b = FormatPlanner.plan(source: pcm(96_000, 16, codec: "WAV"), device: k11)
        let c = FormatPlanner.plan(source: pcm(44_100), device: k11)
        #expect(a.isDeviceCompatible(with: b))
        #expect(!a.isDeviceCompatible(with: c))
    }

    @Test("AirPods' 24 kHz mono hands-free mode is never used for stereo")
    func ignoresMonoOnlyRates() {
        let airPodsReal = DeviceCapabilities(
            sampleRates: [24_000, 48_000],
            physicalFormats: [
                PhysicalFormat(minRate: 24_000, maxRate: 24_000, bitDepth: 32, isInteger: false, isMixable: true, channels: 1),
                PhysicalFormat(minRate: 48_000, maxRate: 48_000, bitDepth: 32, isInteger: false, isMixable: true, channels: 2),
            ],
            outputChannels: 2, supportsDoP: false)
        #expect(FormatPlanner.plan(source: pcm(22_050, 16), device: airPodsReal).deviceSampleRate == 48_000)
        #expect(FormatPlanner.plan(source: pcm(44_100, 16), device: airPodsReal).deviceSampleRate == 48_000)
    }

    @Test("Rate formatting")
    func formatting() {
        #expect(SampleRate.format(44_100) == "44.1")
        #expect(SampleRate.format(192_000) == "192")
        #expect(SampleRate.format(352_800) == "352.8")
    }
}

@Suite("Bitstream planning")
struct BitstreamPlanningTests {
    private func lossy(_ codec: String, _ rate: Double, channels: Int = 6) -> SourceFormat {
        SourceFormat(encoding: .lossy, codec: codec, sampleRate: rate, bitDepth: nil, channels: channels)
    }
    /// An HDMI output to a receiver: 32–192 kHz, 16/24-bit, 8 channels.
    private let hdmi = DeviceCapabilities(sampleRates: [32_000, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000],
                                          physicalFormats: [16, 24].map { PhysicalFormat(minRate: 32_000, maxRate: 192_000, bitDepth: $0, isInteger: true, isMixable: true, channels: 8) },
                                          outputChannels: 8, supportsDoP: false)
    /// S/PDIF (optical): up to 96 kHz, stereo.
    private let spdif = DeviceCapabilities(sampleRates: [44_100, 48_000, 96_000],
                                           physicalFormats: [PhysicalFormat(minRate: 44_100, maxRate: 96_000, bitDepth: 24, isInteger: true, isMixable: true, channels: 2)],
                                           outputChannels: 2, supportsDoP: false)

    @Test("Dolby and DTS go out untouched to a receiver, at the carrier rate", arguments: [
        ("Dolby Digital", 48_000.0, 48_000.0), ("Dolby Digital Plus", 48_000, 192_000), ("Dolby Atmos", 48_000, 192_000), ("DTS", 44_100, 44_100),
    ])
    func toReceiver(codec: String, rate: Double, carrier: Double) {
        let plan = FormatPlanner.plan(source: lossy(codec, rate), device: hdmi, spatial: .headTracked, bitstream: true)
        #expect(plan.mode == .bitstream)
        #expect(plan.deviceSampleRate == carrier && plan.channels == 2 && plan.spatial == .off && plan.isPassthrough)
    }

    @Test("Dolby Digital Plus needs 192 kHz: over S/PDIF it's decoded instead")
    func eac3NeedsHDMI() {
        #expect(FormatPlanner.plan(source: lossy("Dolby Digital Plus", 48_000), device: spdif, bitstream: true).mode == .pcm)
        #expect(FormatPlanner.plan(source: lossy("Dolby Digital", 48_000), device: spdif, bitstream: true).mode == .bitstream)
    }

    @Test("Without the receiver setting, or for other formats, nothing changes")
    func onlyWhenAsked() {
        #expect(FormatPlanner.plan(source: lossy("Dolby Digital", 48_000), device: hdmi).mode == .pcm)
        #expect(FormatPlanner.plan(source: lossy("AAC", 48_000, channels: 2), device: hdmi, bitstream: true).mode == .pcm)
    }
}
