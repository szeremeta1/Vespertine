//
// Vespertine: a file folded onto a speaker setup with as many speakers as it has channels (5.1.2 on 7.1, LCRS on quad, 5.1 on
// 6.0) has channels mixed into their neighbours: the signal path says so, and BIT-PERFECT is not shown for it.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Speaker folds in the signal path")
struct SpeakerFoldPathTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let mask: UInt32
        let channels: Int
        let speakers: [AudioChannelLabel]
        /// The status line expected; nil: no fold, bit-perfect.
        let folded: String?
        var testDescription: String { name }
    }

    static let (L, R, C, LFE, Ls, Rs, Lrs, Rrs, Cs) = (kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                                                     kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround,
                                                     kAudioChannelLabel_RightSurround, kAudioChannelLabel_RearSurroundLeft,
                                                     kAudioChannelLabel_RearSurroundRight, kAudioChannelLabel_CenterSurround)
    static let w = WaveMask.self

    static let cases: [Case] = [
        Case(name: "5.1.2 on 7.1 speakers", mask: w.FL | w.FR | w.FC | w.LFE | w.SL | w.SR | w.TFL | w.TFR, channels: 8,
             speakers: [L, R, C, LFE, Ls, Rs, Lrs, Rrs], folded: "5.1.2 → 7.1"),
        Case(name: "LCRS on quad speakers", mask: w.FL | w.FR | w.FC | w.BC, channels: 4,
             speakers: [L, R, Ls, Rs], folded: "4.0 → QUAD"),
        Case(name: "5.1 on 6.0 speakers", mask: 0x3F, channels: 6, speakers: [L, R, C, Ls, Rs, Cs], folded: "5.1 → 6.0"),
        Case(name: "7.1 on 7.1 speakers (placed, not folded)", mask: 0x63F, channels: 8, speakers: [L, R, C, LFE, Ls, Rs, Lrs, Rrs], folded: nil),
    ]

    @Test("A fold onto as many speakers as channels turns BIT-PERFECT off and names the fold", arguments: cases)
    func foldIsNamed(_ c: Case) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fold-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try ChannelID.writeWAV(to: url, channels: c.channels, frames: 4800, rate: 48_000, mask: c.mask)
        let speakers = try #require(ChannelLayouts.layout(labels: c.speakers))
        let device = DeviceCapabilities(sampleRates: GoldenDevices.rates, physicalFormats: [
            PhysicalFormat(minRate: 44_100, maxRate: 192_000, bitDepth: 24, isInteger: true, isMixable: true, channels: 8)],
            outputChannels: 8, supportsDoP: false, speakerLayoutChannels: c.speakers.count)
        let probed = try SourceOpener.probe(url)
        var plan = FormatPlanner.plan(source: probed.format, device: device)
        plan.integerSamples = false
        #expect(plan.channels == c.channels, "the plan keeps every channel: \(plan.channels)")
        let layout = try #require(OutputSession.routeLayout(plan: plan, speakers: speakers))
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: url))
        let path = SignalPath(source: probed.format, decoderName: "test", plan: plan,
                              applied: AppliedFormat(sampleRate: 48_000, physicalBitDepth: 24, physicalIsInteger: true, virtualChannels: 8,
                                                     exclusive: true, bufferFrames: 512),
                              deviceName: "Receiver", deviceUID: "test",
                              deviceProfile: DeviceProfile(kind: .usbDAC, tag: "", canBeBitPerfect: true, symbol: "x"), volume: .fixed)
        let decoding = try Decoding(item: PlayableItem(url: url), probed: probed, decoder: decoder, path: path, chunk: 4096, layout: layout)
        if let folded = c.folded {
            #expect(!decoding.path.isBitPerfect, "\(c.name): shown as bit-perfect")
            #expect(decoding.path.statusLine == folded, "\(c.name): \(decoding.path.statusLine)")
            #expect(decoding.path.conversion?.downmix != nil, "\(c.name): no downmix notice")
        } else {
            #expect(decoding.path.isBitPerfect, "\(c.name): \(decoding.path.statusLine)")
        }
    }
}
