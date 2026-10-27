//
// Vespertine — 5.1 DSD on headphones: converted to PCM for AirPods, every channel kept for Spatial Audio, and the
// conversion (and any downmix) reported for the UI.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import Testing
@testable import VespertineAudio
import VespertineTestSupport

@Suite("5.1 DSD on Spatial Audio")
struct DSDSpatialTests {
    /// AirPods Max: 24-bit / 48 kHz stereo only, no DoP.
    static let airPodsMax = DeviceCapabilities(
        sampleRates: [48_000], physicalFormats: [PhysicalFormat(minRate: 48_000, maxRate: 48_000, bitDepth: 24, isInteger: true, isMixable: true, channels: 2)],
        outputChannels: 2, supportsDoP: false)
    static let surround = SourceFormat(encoding: .dsd, codec: "DSF", sampleRate: 2_822_400, bitDepth: 1, channels: 6,
                                       channelLabels: [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                                                       kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround])
    /// Left/right placement after the spatial mixer is machine-specific: asserted on a real Mac (VESPERTINE_HARDWARE_TESTS=1), not on the CI runner.
    static let sides = ProcessInfo.processInfo.environment["VESPERTINE_HARDWARE_TESTS"] == "1"
    static let fiveOne: [String] = ["L", "R", "C", "LFE", "Ls", "Rs"]

    private func tmp(_ name: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("dsd51-\(UUID())-\(name)") }

    static func path(_ source: SourceFormat, _ plan: OutputPlan) -> SignalPath {
        SignalPath(source: source, decoderName: "test", plan: plan,
                   applied: AppliedFormat(sampleRate: plan.deviceSampleRate, physicalBitDepth: 24, physicalIsInteger: true,
                                          virtualChannels: plan.deviceChannels, exclusive: false, bufferFrames: 512),
                   deviceName: "AirPods Max", deviceUID: "test",
                   deviceProfile: DeviceProfile(kind: .airPodsMaxUSB, tag: "USB", canBeBitPerfect: true, symbol: "x"), volume: .fixed)
    }

    /// A 5.1 DSD64 file, one tone per channel at -20 dBFS, in the channel order of `format`.
    private func write(_ ext: String, channels: [String]) throws -> URL {
        let url = tmp("51.\(ext)")
        let planes = DSDFiles.modulate(rate: 2_822_400, seconds: 1.3, tones: SpatialProbe.frequencies(channels))
        if ext == "dsf" { try DSDFiles.writeDSF(planes, rate: 2_822_400, channelType: 7, to: url) }
        else { try DSDFiles.writeDFF(planes, rate: 2_822_400, channelIDs: ["SLFT", "SRGT", "C   ", "LFE ", "LS  ", "RS  "], to: url) }
        return url
    }

    @Test("5.1 DSD64 on AirPods Max: converted to PCM and rendered with Spatial Audio on its own 5.1 bed",
          arguments: [true, false])
    func planned(labeled: Bool) {
        // Unlabeled: an SACD area, whose six channels are taken in the standard order.
        var source = Self.surround
        if !labeled { source.channelLabels = nil; source.codec = "SACD" }
        let plan = FormatPlanner.plan(source: source, device: Self.airPodsMax, spatial: .headTracked)
        #expect(plan.mode == .pcm && plan.dsdConvertedToPCM)
        #expect(plan.decodedSampleRate == 352_800 && plan.deviceSampleRate == 48_000)
        #expect(plan.spatial == .headTracked)
        #expect(plan.channels == 6 && plan.deviceChannels == 2)
        #expect(plan.spatialBed == kAudioChannelLayoutTag_MPEG_5_1_A)
    }

    @Test("A 5.1 DSF and DSDIFF keep all six channels and their speakers through the DSD→PCM conversion", arguments: ["dsf", "dff"])
    func layoutSurvivesConversion(ext: String) throws {
        let url = try write(ext, channels: ["FL", "FR", "FC", "LFE", "BL", "BR"])
        defer { try? FileManager.default.removeItem(at: url) }
        let probed = try SourceOpener.probe(url)
        #expect(probed.format.encoding == .dsd && probed.format.channels == 6)
        #expect(probed.format.channelLabels.map { $0.map(ChannelLayouts.shortName) } == Self.fiveOne)
        let plan = FormatPlanner.plan(source: probed.format, device: Self.airPodsMax, spatial: .headTracked)
        #expect(plan.spatial == .headTracked && plan.spatialBed == kAudioChannelLayoutTag_MPEG_5_1_A)
        let decoder = try SourceOpener.decoder(for: probed, plan: plan, item: PlayableItem(url: url))
        #expect(decoder.processingFormat.channelCount == 6)
        #expect(decoder.processingFormat.sampleRate == 352_800)
        #expect(decoder.processingFormat.channelLayout?.shortNames == Self.fiveOne)
    }

    @Test("Every channel of a 5.1 DSD file reaches its own place on the bed and its side after Spatial Audio, at 48 kHz",
          arguments: ["dsf", "dff", "iso"])
    func spatialEndToEnd(ext: String) throws {
        let channels = ["FL", "FR", "FC", "LFE", "SL", "SR"]
        let url: URL
        if ext == "iso" {
            url = tmp("51.iso")
            let frames = 98      // 1.3 s
            let planes = DSDFiles.modulate(rate: SACDFixture.rate, seconds: Double(frames) / 75, tones: SpatialProbe.frequencies(channels))
            try SACDFixture.write(to: url, stereo: nil,
                                  multichannel: .init(channels: 6, dst: false, planes: planes, tracks: [.init(title: "One", frames: frames)]))
        } else {
            url = try write(ext, channels: channels)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try SpatialProbe.check(url, channels: channels, device: Self.airPodsMax, sides: Self.sides)
        #expect(result.bed == Self.fiveOne)
        #expect(result.problems.isEmpty, "\(ext): \(result.problems)")
    }

    @Test("A DSDIFF whose channel IDs say nothing (discrete) is planned on the standard 5.1 bed the engine routes it to")
    func discreteChannelIDsPlanned() {
        var source = Self.surround
        source.codec = "DSDIFF"
        source.channelLabels = (0..<6).map { kAudioChannelLabel_Discrete_0 + UInt32($0) }
        let plan = FormatPlanner.plan(source: source, device: Self.airPodsMax, spatial: .headTracked)
        #expect(plan.spatial == .headTracked)
        #expect(plan.channels == 6 && plan.spatialBed == kAudioChannelLayoutTag_MPEG_5_1_A)
    }

    @Test("Every channel of a DST DSDIFF with discrete channel IDs is heard after Spatial Audio, in the standard 5.1 order")
    func discreteChannelIDsEndToEnd() throws {
        let channels = ["FL", "FR", "FC", "LFE", "SL", "SR"]
        let url = tmp("51-discrete.dff")
        defer { try? FileManager.default.removeItem(at: url) }
        let planes = DSDFiles.modulate(rate: SACDFixture.rate, seconds: 98.0 / 75, tones: SpatialProbe.frequencies(channels))
        try DSDIFFFixture.writeDST(planes, indexed: true, storedOnly: true, channelIDs: ["C000", "C001", "C002", "C003", "C004", "C005"], to: url)
        let result = try SpatialProbe.check(url, channels: channels, device: Self.airPodsMax, sides: Self.sides)
        #expect(result.bed == Self.fiveOne)
        #expect(result.problems.isEmpty, "\(result.problems)")
    }
}
