//
// Vespertine: DSD at a DoP carrier rate a listed DAC is known not to play is converted to PCM for it, not sent
// natively into silence.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("DSD rates a DAC doesn't play natively")
struct DoPUnplayedCarrierTests {
    static func dsd(_ rate: Double) -> SourceFormat {
        SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: rate, bitDepth: 1, channels: 2)
    }
    static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    static let formats = [PhysicalFormat(minRate: 44_100, maxRate: 384_000, bitDepth: 32, isInteger: true, isMixable: true, channels: 2)]
    /// A DAC with DoP on that offers every carrier as a PCM rate.
    static func dac(unplayed: [Double]?) -> DeviceCapabilities {
        DeviceCapabilities(sampleRates: rates, physicalFormats: formats, outputChannels: 2, supportsDoP: true, dopUnplayedCarriers: unplayed)
    }

    @Test("At a carrier the DAC stays silent at, DSD is converted to PCM and the signal path says why",
          arguments: [(3_072_000.0, "192"), (6_144_000.0, "384")])
    func converted(dsdRate: Double, carrier: String) {
        let plan = FormatPlanner.plan(source: Self.dsd(dsdRate), device: Self.dac(unplayed: [192_000, 384_000]))
        #expect(plan.mode == .pcm && plan.dsdConvertedToPCM)
        #expect(plan.reason.contains("doesn't play DSD natively at \(carrier) kHz"), "\(plan.reason)")
        // Nothing to offer: DoP is on already, and switching it wouldn't make this rate play.
        #expect(!plan.dopAvailable)
    }

    @Test("The carriers it does play still go natively", arguments: [(2_822_400.0, 176_400.0), (5_644_800.0, 352_800.0)])
    func native(dsdRate: Double, carrier: Double) {
        let plan = FormatPlanner.plan(source: Self.dsd(dsdRate), device: Self.dac(unplayed: [192_000, 384_000]))
        #expect(plan.mode == .dop && plan.deviceSampleRate == carrier)
    }

    @Test("A DAC with nothing known against it gets every carrier it offers natively",
          arguments: [2_822_400.0, 3_072_000.0, 5_644_800.0, 6_144_000.0])
    func unrestricted(dsdRate: Double) {
        #expect(FormatPlanner.plan(source: Self.dsd(dsdRate), device: Self.dac(unplayed: nil)).mode == .dop)
        #expect(Self.dac(unplayed: nil).playsDoP(at: dsdRate / 16))
    }

    @Test("With DoP off nothing is played natively, whatever the list says")
    func dopOff() {
        var device = Self.dac(unplayed: nil)
        device.supportsDoP = false
        #expect(!device.playsDoP(at: 176_400))
    }

    @Test("The bundled list: a FiiO K11 doesn't play the 192 and 384 kHz carriers; a Fosi Audio ZD3 has none listed")
    func bundledList() {
        let list = DoPDACList.bundled
        let k11 = list.knownDAC(for: DoPDeviceIdentity(uid: "AppleUSBAudioEngine:FIIO:FiiO K11:0000000:2"))
        #expect(k11?.noDoPCarriers == [192_000, 384_000])
        let zd3 = list.knownDAC(for: DoPDeviceIdentity(uid: "AppleUSBAudioEngine:XMOS:Fosi Audio ZD3:0000000:1"))
        #expect(zd3 != nil && zd3?.noDoPCarriers == nil)
    }
}
