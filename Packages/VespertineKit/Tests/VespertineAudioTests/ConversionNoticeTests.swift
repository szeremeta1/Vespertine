//
// Vespertine — what the UI is told was done to the music: DSD converted to PCM, channels mixed down.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Testing
@testable import VespertineAudio

@Suite("Conversion notice")
struct ConversionNoticeTests {
    typealias S = DSDSpatialTests

    @Test("The UI is told a 5.1 DSD track was converted to PCM, even while Spatial Audio is on, and that nothing was downmixed")
    func convertedNoticeWithSpatial() {
        let p = DSDSpatialTests.path(S.surround, FormatPlanner.plan(source: S.surround, device: S.airPodsMax, spatial: .headTracked))
        let conversion = p.conversion
        #expect(conversion?.dsdToPCM == true)
        #expect(conversion?.downmix == nil)
        #expect(!p.isBitPerfect)
    }

    @Test("With Spatial Audio off, a 5.1 DSD track on headphones is reported as converted and downmixed to stereo")
    func convertedAndDownmixed() {
        let p = DSDSpatialTests.path(S.surround, FormatPlanner.plan(source: S.surround, device: S.airPodsMax, spatial: .off))
        #expect(p.conversion?.dsdToPCM == true)
        #expect(p.conversion?.downmix == SignalPath.Downmix(from: "5.1", to: "Stereo"))
    }

    @Test("Nothing to report for 5.1 PCM on Spatial Audio; a 5.1 PCM downmix is still reported")
    func pcmSources() {
        let pcm = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 48_000, bitDepth: 24, channels: 6, channelLabels: S.surround.channelLabels)
        #expect(DSDSpatialTests.path(pcm, FormatPlanner.plan(source: pcm, device: S.airPodsMax, spatial: .fixed)).conversion == nil)
        let downmixed = DSDSpatialTests.path(pcm, FormatPlanner.plan(source: pcm, device: S.airPodsMax, spatial: .off)).conversion
        #expect(downmixed?.dsdToPCM == false && downmixed?.downmix == SignalPath.Downmix(from: "5.1", to: "Stereo"))
    }

    @Test("The badges add what the status line leaves out: Converted from DSD beside SPATIAL or a downmix, nothing twice")
    func badges() {
        let spatial = DSDSpatialTests.path(S.surround, FormatPlanner.plan(source: S.surround, device: S.airPodsMax, spatial: .headTracked))
        #expect(spatial.statusLine == "SPATIAL · HEAD TRACKED" && spatial.conversionBadges == ["Converted from DSD"])
        let downmixed = DSDSpatialTests.path(S.surround, FormatPlanner.plan(source: S.surround, device: S.airPodsMax, spatial: .off))
        #expect(downmixed.statusLine == "Downmixed to stereo" && downmixed.conversionBadges == ["Converted from DSD"])
        var stereo = S.surround
        stereo.channels = 2
        stereo.channelLabels = nil
        let converted = DSDSpatialTests.path(stereo, FormatPlanner.plan(source: stereo, device: S.airPodsMax, spatial: .headTracked))
        #expect(converted.statusLine == "Converted from DSD" && converted.conversionBadges.isEmpty)
    }
}
