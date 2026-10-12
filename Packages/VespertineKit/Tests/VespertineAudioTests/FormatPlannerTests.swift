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
/// A 192 kHz-max DAC.
private let dac192 = caps([44_100, 48_000, 88_200, 96_000, 176_400, 192_000])

@Suite("FormatPlanner")
struct FormatPlannerTests {
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
