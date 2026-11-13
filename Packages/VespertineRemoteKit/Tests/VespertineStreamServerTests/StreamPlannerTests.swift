//
// Vespertine: what the Mac sends for a song: its own file when the phone can decode it, else a lossless FLAC, and the
// rate and channels that FLAC keeps.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteProtocol
@testable import VespertineStreamServer

private func facts(_ ext: String, codec: String? = nil, rate: Double = 44_100, depth: Int? = 16, channels: Int = 2, dsd: Bool = false,
                   lossless: Bool = true, region: Bool = false, macDecoder: Bool = false, size: Int64 = 30_000_000) -> StreamSourceFacts {
    StreamSourceFacts(id: 1, url: URL(fileURLWithPath: "/Music/a.\(ext)"), fileExtension: ext, codec: codec ?? ext.uppercased(),
                      isDSD: dsd, isLossless: lossless, sampleRate: rate, bitDepth: depth, channels: channels, duration: 240,
                      fileSize: size, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), isRegion: region,
                      needsMacDecoder: macDecoder, replayGain: nil)
}

@Suite struct OriginalOrConverted {
    @Test(arguments: ["flac", "m4a", "wav", "aiff", "aif", "caf", "mp3"])
    func formatsThePhoneDecodesAreSentAsTheyAre(ext: String) {
        let plan = StreamPlanner.plan(facts(ext), maxSampleRate: nil)
        #expect(plan.kind == .original && plan.transcode == nil && plan.macOnlyReason == nil)
        #expect(plan.delivered?.container == (ext == "aif" ? "aiff" : ext))
    }

    @Test func aStereoHiResFileIsNotTouchedEvenAboveThePhonesRate() {
        // A stereo 24/192 file is cheap enough, and "lossless as recorded" is the point: the phone resamples if its route needs to.
        let plan = StreamPlanner.plan(facts("flac", rate: 192_000, depth: 24), maxSampleRate: 48_000)
        #expect(plan.kind == .original)
    }

    @Test func aMultichannelFileAboveThePhonesRateIsConvertedDownOnTheMac() {
        // 7.1 at 24/192 is 36 Mbit/s raw; AirPods render at 48 kHz anyway.
        let plan = StreamPlanner.plan(facts("flac", rate: 192_000, depth: 24, channels: 8), maxSampleRate: 48_000)
        #expect(plan.kind == .flac)
        #expect(plan.transcode?.sampleRate == 48_000 && plan.transcode?.channels == 8 && plan.transcode?.bitDepth == 24)
    }

    @Test func aMultichannelFileWithinThePhonesRateIsNotConverted() {
        #expect(StreamPlanner.plan(facts("flac", rate: 48_000, depth: 24, channels: 6), maxSampleRate: 48_000).kind == .original)
        #expect(StreamPlanner.plan(facts("flac", rate: 192_000, depth: 24, channels: 6), maxSampleRate: nil).kind == .original)
    }

    @Test(arguments: ["dsf", "dff", "ape", "wv", "tta", "ogg", "opus", "wma", "mpc", "ofr", "shn", "mka"])
    func formatsThePhoneCannotDecodeBecomeFLAC(ext: String) {
        let plan = StreamPlanner.plan(facts(ext), maxSampleRate: nil)
        #expect(plan.kind == .flac)
        #expect(plan.delivered?.container == "flac" && plan.delivered?.codec == "FLAC")
    }

    @Test func cueTracksAndDiscImagesAreConvertedBecauseTheFileIsTheWholeAlbum() {
        #expect(StreamPlanner.plan(facts("flac", region: true), maxSampleRate: nil).kind == .flac)
        #expect(StreamPlanner.plan(facts("iso", macDecoder: true), maxSampleRate: nil).kind == .flac)
    }

    @Test func dtsInsideAFlacOrWavIsDecodedOnTheMac() {
        #expect(StreamPlanner.plan(facts("wav", codec: "DTS", channels: 6), maxSampleRate: nil).kind == .flac)
    }

    @Test func aFlacOfMoreThan24BitsIsConvertedSoEveryPhoneOpensIt() {
        let plan = StreamPlanner.plan(facts("flac", depth: 32), maxSampleRate: nil)
        #expect(plan.kind == .flac && plan.transcode?.bitDepth == 24)
    }
}

@Suite struct ConversionTargets {
    @Test func dsd64BecomesPCMAt176Point4() {
        let plan = StreamPlanner.plan(facts("dsf", rate: 2_822_400, depth: 1, channels: 2, dsd: true), maxSampleRate: nil)
        #expect(plan.transcode?.sampleRate == 176_400 && plan.transcode?.bitDepth == 24)
    }

    @Test func dsd128IsKeptToTheDefaultCeilingOf192() {
        let plan = StreamPlanner.plan(facts("dsf", rate: 5_644_800, depth: 1, dsd: true), maxSampleRate: nil)
        #expect(plan.transcode?.sampleRate == 176_400, "same rate family, the highest at or under 192 kHz")
    }

    @Test func aPhoneThatCanUseOnly48kGetsDsdAt44Point1() {
        let plan = StreamPlanner.plan(facts("dsf", rate: 2_822_400, depth: 1, dsd: true), maxSampleRate: 48_000)
        #expect(plan.transcode?.sampleRate == 44_100, "the lowest of the family: the phone's last resample is the only one")
    }

    @Test func dsd5Point1ForAirPodsIsSmall() {
        let plan = StreamPlanner.plan(facts("dff", rate: 2_822_400, depth: 1, channels: 6, dsd: true), maxSampleRate: 48_000)
        #expect(plan.kind == .flac && plan.transcode?.channels == 6 && plan.transcode?.sampleRate == 44_100)
    }

    @Test func aHigherCeilingIsHonouredForDsd() {
        let plan = StreamPlanner.plan(facts("dsf", rate: 5_644_800, depth: 1, dsd: true), maxSampleRate: 384_000)
        #expect(plan.transcode?.sampleRate == 352_800)
    }

    @Test func the48kFamilyStaysInItsFamily() {
        let plan = StreamPlanner.plan(facts("ape", rate: 96_000, depth: 24, channels: 6), maxSampleRate: 48_000)
        #expect(plan.transcode?.sampleRate == 48_000)
        #expect(StreamPlanner.plan(facts("ape", rate: 88_200, depth: 24, channels: 6), maxSampleRate: 48_000).transcode?.sampleRate == 44_100)
    }

    @Test func aSixteenBitSourceIsNotInflated() {
        #expect(StreamPlanner.plan(facts("ape", depth: 16), maxSampleRate: nil).transcode?.bitDepth == 16)
        #expect(StreamPlanner.plan(facts("ape", depth: 24), maxSampleRate: nil).transcode?.bitDepth == 24)
    }

    @Test func aConversionNeverRaisesTheRate() {
        #expect(StreamPlanner.plan(facts("ape", rate: 44_100), maxSampleRate: 192_000).transcode?.sampleRate == 44_100)
    }

    @Test func multichannelIsPreservedNotFolded() {
        for channels in [3, 4, 5, 6, 7, 8] {
            let plan = StreamPlanner.plan(facts("ape", depth: 24, channels: channels), maxSampleRate: nil)
            #expect(plan.transcode?.channels == channels, "\(channels) channels")
        }
    }
}

@Suite struct MacOnly {
    @Test func moreThanEightChannelsPlaysOnTheMacOnly() {
        let plan = StreamPlanner.plan(facts("wav", depth: 24, channels: 12), maxSampleRate: nil)
        #expect(plan.kind == nil && plan.delivered == nil)
        #expect(plan.macOnlyReason?.contains("8") == true)
    }

    @Test func aFileNobodyCanDecodeSaysSo() {
        let plan = StreamPlanner.plan(facts("xyz", codec: "Unknown", macDecoder: false), maxSampleRate: nil)
        #expect(plan.kind == nil && plan.macOnlyReason != nil)
    }

    @Test func infoReportsWhatPlanDecided() {
        let info = StreamPlanner.info(for: facts("flac", rate: 96_000, depth: 24, channels: 6), maxSampleRate: nil)
        #expect(info.streamable && info.kind == .original && info.byteSize == 30_000_000 && info.totalFrames == 240 * 96_000)
        #expect(info.source.channels == 6 && info.delivered?.sampleRate == 96_000 && info.delivered?.lossless == true)
        let mac = StreamPlanner.info(for: facts("wav", channels: 16), maxSampleRate: nil)
        #expect(!mac.streamable && mac.kind == nil && mac.macOnlyReason != nil && mac.byteSize == nil)
    }
}
