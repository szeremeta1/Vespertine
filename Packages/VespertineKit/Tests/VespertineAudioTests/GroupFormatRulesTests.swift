//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
@testable import VespertineAudio

private func caps(_ rates: [Double], channels: Int = 4, dop: Bool = true) -> DeviceCapabilities {
    let formats = [24, 32].map { PhysicalFormat(minRate: rates.min()!, maxRate: rates.max()!, bitDepth: $0, isInteger: true, isMixable: true, channels: channels) }
    return DeviceCapabilities(sampleRates: rates, physicalFormats: formats, outputChannels: channels, supportsDoP: dop)
}

private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

private func pcm(_ rate: Double, bits: Int = 24, channels: Int = 4, codec: String = "FLAC") -> SourceFormat {
    SourceFormat(encoding: .pcm, codec: codec, sampleRate: rate, bitDepth: bits, channels: channels)
}

@Suite("Speaker group format rules")
struct GroupFormatRulesTests {
    @Test("DSD becomes PCM on a group even when the combined device claims DoP, and DoP is never planned")
    func dsdIsPCM() {
        let dsd = SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: 2_822_400, bitDepth: 1, channels: 4)
        // The plain planner would send DoP here: this is the case the rule exists for.
        #expect(FormatPlanner.plan(source: dsd, device: caps(rates)).mode == .dop)
        let plan = GroupFormatRules.plan(source: dsd, device: caps(rates))
        #expect(plan.mode == .pcm)
        #expect(plan.dsdConvertedToPCM)
        #expect(plan.decodedSampleRate == 352_800)
        #expect(plan.deviceSampleRate == 352_800)
        #expect(!plan.isPassthrough)
        #expect(plan.reason.contains("speaker group"))
    }

    @Test("A Dolby or DTS bitstream is decoded to PCM on a group, never sent as IEC 61937")
    func bitstreamIsDecoded() {
        let ac3 = SourceFormat(encoding: .pcm, codec: "Dolby Digital", sampleRate: 48_000, bitDepth: nil, channels: 6)
        let device = caps([44_100, 48_000, 96_000, 192_000], channels: 8)
        #expect(FormatPlanner.plan(source: ac3, device: device, bitstream: true).mode == .bitstream)
        let plan = GroupFormatRules.plan(source: ac3, device: device)
        #expect(plan.mode == .pcm)
        #expect(plan.channels == 6)
    }

    @Test("No Spatial Audio, upmix, integer samples or 16-bit match on a group")
    func nothingThatNeedsOneDevice() {
        let plan = GroupFormatRules.plan(source: pcm(96_000, bits: 16, channels: 2), device: caps(rates), spatial: .headTracked, spatializeStereo: true)
        #expect(plan.spatial == .off && plan.spatialBed == nil)
        #expect(plan.deviceChannelCount == nil)
        #expect(!plan.integerSamples)
        #expect(plan.sixteenBit == nil)
        #expect(plan.mode == .pcm)
    }

    @Test("PCM at a rate every member shares plays at that rate and does not resample")
    func commonRate() {
        let plan = GroupFormatRules.plan(source: pcm(96_000), device: caps(rates))
        #expect(plan.deviceSampleRate == 96_000)
        #expect(!plan.resamples)
        #expect(plan.channels == 4)
    }

    @Test("The rule set says what is off, for the settings text and the badge")
    func constants() {
        #expect(!GroupFormatRules.allowsDoP)
        #expect(!GroupFormatRules.allowsBitstream)
        #expect(!GroupFormatRules.allowsIntegerMode)
        #expect(!GroupFormatRules.allowsSixteenBitMatch)
        #expect(!GroupFormatRules.allowsSpatial)
    }

    @Test("Whatever the planner says, a non-PCM plan is turned into PCM (defence in depth)")
    func coercion() {
        var bad = OutputPlan(mode: .dop, deviceSampleRate: 176_400, decodedSampleRate: 176_400, physicalBitDepth: 24, channels: 2,
                             dsdConvertedToPCM: false, reason: "DoP")
        bad.integerSamples = true
        bad.spatial = .fixed
        let safe = GroupFormatRules.enforced(bad)
        #expect(safe.mode == .pcm && !safe.integerSamples && safe.spatial == .off)
    }
}
