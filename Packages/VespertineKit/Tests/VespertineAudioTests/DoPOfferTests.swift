//
// Vespertine: when the signal path offers to switch DoP on for DSD it is converting to PCM.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
@testable import VespertineAudio

@Suite("DoP offer for DSD converted to PCM")
struct DoPOfferTests {
    static let dsd64 = SourceFormat(encoding: .dsd, codec: "DSDIFF", sampleRate: 2_822_400, bitDepth: 1, channels: 2)
    static let dsd512 = SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: 22_579_200, bitDepth: 1, channels: 2)
    static let int24 = [PhysicalFormat(minRate: 44_100, maxRate: 384_000, bitDepth: 24, isInteger: true, isMixable: true, channels: 2)]

    static func dac(dop: Bool, formats: [PhysicalFormat] = int24, rates: [Double] = [44_100, 88_200, 176_400, 352_800]) -> DeviceCapabilities {
        DeviceCapabilities(sampleRates: rates, physicalFormats: formats, outputChannels: 2, supportsDoP: dop)
    }

    @Test("DoP off on a DAC with the 24-bit carrier: converted to PCM, and DoP is offered")
    func offeredWhenOnlyDoPIsOff() {
        let plan = FormatPlanner.plan(source: Self.dsd64, device: Self.dac(dop: false))
        #expect(plan.mode == .pcm && plan.dsdConvertedToPCM && plan.dopAvailable)
        // Switching it on gives native DoP, which the offer promises.
        #expect(FormatPlanner.plan(source: Self.dsd64, device: Self.dac(dop: true)).mode == .dop)
    }

    @Test("No offer once DoP plays, or where switching it on wouldn't give DoP")
    func notOffered() {
        #expect(!FormatPlanner.plan(source: Self.dsd64, device: Self.dac(dop: true)).dopAvailable)
        // No carrier rate (DSD512 needs 1411.2 kHz), or only float or 16-bit formats at it.
        #expect(!FormatPlanner.plan(source: Self.dsd512, device: Self.dac(dop: false)).dopAvailable)
        let float32 = [PhysicalFormat(minRate: 44_100, maxRate: 384_000, bitDepth: 32, isInteger: false, isMixable: true, channels: 2)]
        #expect(!FormatPlanner.plan(source: Self.dsd64, device: Self.dac(dop: false, formats: float32)).dopAvailable)
        let int16 = [PhysicalFormat(minRate: 44_100, maxRate: 384_000, bitDepth: 16, isInteger: true, isMixable: true, channels: 2)]
        #expect(!FormatPlanner.plan(source: Self.dsd64, device: Self.dac(dop: false, formats: int16)).dopAvailable)
        // Converted for another reason that DoP wouldn't change.
        #expect(!FormatPlanner.plan(source: Self.dsd64, device: Self.dac(dop: false), dsdToPCMForRoom: true).dopAvailable)
        #expect(!FormatPlanner.plan(source: Self.dsd64, device: Self.dac(dop: false), dsdToPCMForTransitions: true).dopAvailable)
        #expect(!FormatPlanner.plan(source: Self.dsd64, device: Self.dac(dop: false), spatial: .fixed, spatializeStereo: true).dopAvailable)
        // PCM sources never carry the offer.
        let flac = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 88_200, bitDepth: 24, channels: 2)
        #expect(!FormatPlanner.plan(source: flac, device: Self.dac(dop: false)).dopAvailable)
    }
}
