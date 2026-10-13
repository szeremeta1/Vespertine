//
// Vespertine — "Match 16-bit sources": 16-bit files go to a DAC's own 16-bit mode where it has one.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
@testable import VespertineAudio

private func source(_ rate: Double = 44_100, bits: Int? = 16, channels: Int = 2, encoding: SourceFormat.Encoding = .pcm) -> SourceFormat {
    SourceFormat(encoding: encoding, codec: encoding == .dsd ? "DSF" : "FLAC", sampleRate: rate, bitDepth: bits, channels: channels)
}

/// A USB DAC with 16/24/32-bit integer modes from 44.1 to 384 kHz (and DoP).
private let dac = DeviceCapabilities(
    sampleRates: [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000],
    physicalFormats: [16, 24, 32].map { PhysicalFormat(minRate: 44_100, maxRate: 384_000, bitDepth: $0, isInteger: true, isMixable: true, channels: 2) },
    outputChannels: 2, supportsDoP: true)
/// A DAC whose 16-bit mode stops at 48 kHz.
private let partial16 = DeviceCapabilities(
    sampleRates: [44_100, 48_000, 96_000],
    physicalFormats: [PhysicalFormat(minRate: 44_100, maxRate: 48_000, bitDepth: 16, isInteger: true, isMixable: true, channels: 2),
                      PhysicalFormat(minRate: 44_100, maxRate: 96_000, bitDepth: 24, isInteger: true, isMixable: true, channels: 2)],
    outputChannels: 2, supportsDoP: false)
/// 24-bit only.
private let only24 = DeviceCapabilities(
    sampleRates: [44_100, 48_000, 96_000],
    physicalFormats: [PhysicalFormat(minRate: 44_100, maxRate: 96_000, bitDepth: 24, isInteger: true, isMixable: true, channels: 2)],
    outputChannels: 2, supportsDoP: false)
/// Stereo 16-bit, plus 24-bit 6-channel.
private let surround = DeviceCapabilities(
    sampleRates: [48_000],
    physicalFormats: [PhysicalFormat(minRate: 48_000, maxRate: 48_000, bitDepth: 16, isInteger: true, isMixable: true, channels: 2),
                      PhysicalFormat(minRate: 48_000, maxRate: 48_000, bitDepth: 24, isInteger: true, isMixable: true, channels: 6)],
    outputChannels: 6, supportsDoP: false)

private func matched(_ s: SourceFormat, _ device: DeviceCapabilities, eligible: Bool = true, integer: Bool = false) -> OutputPlan {
    var plan = FormatPlanner.plan(source: s, device: device)
    plan.integerSamples = integer
    return FormatPlanner.matchSixteenBit(plan, source: s, device: device, eligible: eligible)
}

@Suite("Match 16-bit sources")
struct SixteenBitTests {
    @Test("A 16-bit file goes out as 16-bit where the DAC has a 16-bit mode at its rate", arguments: [44_100.0, 48_000, 96_000, 384_000])
    func sentAsSixteen(rate: Double) {
        let plan = matched(source(rate), dac)
        #expect(plan.physicalBitDepth == 16)
        #expect(plan.sixteenBit == .requested)
        #expect(plan.deviceSampleRate == rate && !plan.resamples)
    }

    @Test("Off, or not eligible (shared, built-in, volume, EQ, ReplayGain): the plan is untouched")
    func offChangesNothing() {
        let s = source()
        let plain = FormatPlanner.plan(source: s, device: dac)
        #expect(matched(s, dac, eligible: false) == plain)
        #expect(plain.physicalBitDepth == 32 && plain.sixteenBit == nil)
    }

    @Test("Only 16-bit integer PCM: 24-bit, lossy, float and DSD sources keep the current behaviour")
    func onlySixteenBitPCM() {
        for s in [source(bits: 24), source(bits: nil, encoding: .lossy), source(bits: nil), source(2_822_400, bits: nil, encoding: .dsd)] {
            let plain = FormatPlanner.plan(source: s, device: dac)
            #expect(matched(s, dac) == plain, "\(s.shortDescription)")
        }
        // DoP in particular stays DoP at 24 bits or more.
        let dsd = matched(source(2_822_400, bits: nil, encoding: .dsd), dac)
        #expect(dsd.mode == .dop && dsd.physicalBitDepth >= 24 && dsd.sixteenBit == nil)
    }

    @Test("Resampled, downmixed or Spatial Audio: never matched")
    func onlyAtNativeRateAndChannels() {
        // 44.1 kHz on a 48 kHz-only device is converted, so the samples change anyway.
        let resampled = matched(source(44_100, channels: 2), surround)
        #expect(resampled.resamples && resampled.sixteenBit == nil)
        // 5.1 16-bit to a stereo-only 16-bit format is a downmix.
        let stereoDAC = DeviceCapabilities(sampleRates: [48_000], physicalFormats: [PhysicalFormat(minRate: 48_000, maxRate: 48_000, bitDepth: 16,
                                           isInteger: true, isMixable: true, channels: 2)], outputChannels: 2, supportsDoP: false)
        let downmix = matched(source(48_000, channels: 6), stereoDAC)
        #expect(downmix.channels == 2 && downmix.sixteenBit == nil)
        var spatial = FormatPlanner.plan(source: source(48_000, channels: 6), device: dac, spatial: .fixed)
        spatial = FormatPlanner.matchSixteenBit(spatial, source: source(48_000, channels: 6), device: dac, eligible: true)
        #expect(spatial.sixteenBit == nil)
    }

    @Test("A 16-bit mode needs enough channels: 5.1 isn't sent to a stereo-only 16-bit format")
    func channelsMatter() {
        let plan = matched(source(48_000, channels: 6), surround)
        #expect(plan.channels == 6 && plan.physicalBitDepth == 24 && plan.sixteenBit == .noMode)
    }

    @Test("No 16-bit mode at this rate: sent as before, and the plan says why")
    func noModeAtRate() {
        let at96 = matched(source(96_000), partial16)
        #expect(at96.physicalBitDepth == 24 && at96.sixteenBit == .noMode)
        let at48 = matched(source(48_000), partial16)
        #expect(at48.physicalBitDepth == 16 && at48.sixteenBit == .requested)
        let none = matched(source(44_100), only24)
        #expect(none.physicalBitDepth == 24 && none.sixteenBit == .noMode)
    }

    @Test("Matched 16-bit leaves integer mode off (Float32 carries 16 bits exactly); with no 16-bit mode, integer mode stays")
    func integerMode() {
        #expect(!matched(source(), dac, integer: true).integerSamples)
        #expect(matched(source(), only24, integer: true).integerSamples)
    }

    @Test("16-bit and 24-bit plans need the device changed between them; a 16-bit file with no 16-bit mode doesn't")
    func gaplessJoins() {
        let sixteen = matched(source(), dac)
        let twentyFour = matched(source(bits: 24), dac)
        #expect(!sixteen.isDeviceCompatible(with: twentyFour))
        #expect(matched(source(), only24).isDeviceCompatible(with: matched(source(bits: 24), only24)))
    }

    private func path(_ plan: OutputPlan, depth: Int, rate: Double = 44_100) -> SignalPath {
        SignalPath(source: source(rate), decoderName: "FLAC", plan: plan,
                   applied: AppliedFormat(sampleRate: rate, physicalBitDepth: depth, physicalIsInteger: true, virtualChannels: 2,
                                          exclusive: true, bufferFrames: 512),
                   deviceName: "DAC", deviceUID: "DAC", deviceProfile: DeviceProfile(kind: .usbDAC, tag: "USB", canBeBitPerfect: true, symbol: "x"),
                   volume: .hardware)
    }

    @Test("The signal path reports what the device accepted, not what was asked for")
    func signalPathReadsBack() {
        let asked = matched(source(), dac)
        let took = path(asked, depth: 16)
        #expect(took.sixteenBitNote == "16-bit source sent as 16-bit at 44.1 kHz")
        #expect(took.isBitPerfect && took.deviceFormatShort == "16/44.1")
        let ignored = path(asked, depth: 24)
        #expect(ignored.sixteenBitNote == "Asked for 16-bit at 44.1 kHz; the device stayed at 24-bit (same samples, zero-padded)")
        #expect(ignored.isBitPerfect)
        let none = path(matched(source(96_000), partial16), depth: 24, rate: 96_000)
        #expect(none.sixteenBitNote == "No 16-bit mode at 96 kHz; sent as 24-bit (same samples, zero-padded)")
        #expect(path(FormatPlanner.plan(source: source(), device: dac), depth: 32).sixteenBitNote == nil)
    }
}
