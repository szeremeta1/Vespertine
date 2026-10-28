//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
@testable import VespertineAudio

private let zd3 = "AppleUSBAudioEngine:XMOS:Fosi Audio ZD3:2142200:1"
private let k11 = "AppleUSBAudioEngine:FIIO:FiiO K11:2130000:2"
private let other = "AppleUSBAudioEngine:ACME:Some DAC:1000:1"

private func caps(_ rates: [Double], dop: Bool) -> DeviceCapabilities {
    let formats = [24, 32].map { PhysicalFormat(minRate: rates.min()!, maxRate: rates.max()!, bitDepth: $0, isInteger: true, isMixable: false, channels: 2) }
    return DeviceCapabilities(sampleRates: rates, physicalFormats: formats, outputChannels: 2, supportsDoP: dop)
}

private func dsd(_ rate: Double) -> SourceFormat {
    SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: rate, bitDepth: 1, channels: 2)
}

/// Fosi ZD3 as read from Core Audio on 2026-10-28: 44.1 kHz to 768 kHz, 24 and 32 bit.
private let zd3Rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000, 705_600, 768_000]

@Suite("DoPDefaults")
struct DoPDefaultsTests {
    @Test("Known DACs have DoP on with no saved choice; others stay off")
    func knownDefaultsOn() {
        #expect(DoPDefaults.isEnabled(uid: zd3, on: [], off: []))
        #expect(DoPDefaults.isEnabled(uid: k11, on: [], off: []))
        #expect(!DoPDefaults.isEnabled(uid: other, on: [], off: []))
    }

    @Test("The unit serial and USB port in the UID don't matter")
    func serialIndependent() {
        #expect(DoPDefaults.isKnownDoP(uid: "AppleUSBAudioEngine:XMOS:Fosi Audio ZD3:9999999:3"))
        #expect(!DoPDefaults.isKnownDoP(uid: "AppleUSBAudioEngine:XMOS:Fosi Audio ZD2:2142200:1"))
    }

    @Test("An explicit off wins over the default, and an explicit on works for any device")
    func explicitChoices() {
        #expect(!DoPDefaults.isEnabled(uid: zd3, on: [], off: [zd3]))
        #expect(!DoPDefaults.isEnabled(uid: zd3, on: [zd3], off: [zd3]))
        #expect(DoPDefaults.isEnabled(uid: other, on: [other], off: []))
    }

    @Test("resolve gives the engine the on set plus connected known DACs, minus explicit offs")
    func resolveSet() {
        #expect(DoPDefaults.resolve(on: [], off: [], connected: [zd3, other]) == [zd3])
        #expect(DoPDefaults.resolve(on: [other], off: [zd3], connected: [zd3, other]) == [other])
        #expect(DoPDefaults.resolve(on: [k11], off: [], connected: []) == [k11])
    }

    @Test("ZD3 plans DSD64/128/256 as DoP at 176.4/352.8/705.6 kHz and converts DSD512")
    func zd3Planning() {
        let device = caps(zd3Rates, dop: true)
        for (source, carrier) in [(2_822_400.0, 176_400.0), (5_644_800, 352_800), (11_289_600, 705_600)] {
            let plan = FormatPlanner.plan(source: dsd(source), device: device)
            #expect(plan.mode == .dop)
            #expect(plan.deviceSampleRate == carrier)
            #expect(!plan.dsdConvertedToPCM)
        }
        let big = FormatPlanner.plan(source: dsd(22_579_200), device: device)
        #expect(big.mode == .pcm && big.dsdConvertedToPCM)
    }

    @Test("With DoP off the ZD3 gets PCM, the conversion the user saw")
    func zd3DoPOff() {
        let plan = FormatPlanner.plan(source: dsd(2_822_400), device: caps(zd3Rates, dop: false))
        #expect(plan.mode == .pcm && plan.dsdConvertedToPCM)
    }
}
