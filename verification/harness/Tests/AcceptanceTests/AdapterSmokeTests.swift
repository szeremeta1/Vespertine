//
// Vespertine verification: the adapters run at all. Not evidence for any requirement (no requirement IDs here):
// only that a Vespertine result in the scoreboard comes from Vespertine's code running, not from a broken adapter.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Contracts
import SpecKit
import Testing
import VespertineAdapters

@Suite("Adapters run") struct AdapterSmokeTests {
    @Test("The real-time stages render the frame counts asked for")
    func stages() {
        let dop = Vespertine.dopStage.makeStage(channels: 2, capacityFrames: 64)
        #expect(dop.render(frameCount: 7).count == 14)
        let int = Vespertine.integerOutput.makeStage(channels: 2, capacityFrames: 64)
        #expect(int.write(words: [1, 2, 3, 4]) == 2)
        #expect(int.render(frameCount: 3).count == 6)
        let float = Vespertine.floatOutput.makeStage(channels: 1, capacityFrames: 64)
        #expect(float.write(samples: [0.5]) == 1)
        #expect(float.render(frameCount: 1).count == 1)
    }

    @Test("The DST decoder decodes a fixture frame to the right length")
    func dst() throws {
        let fixture = try #require(DSTFixtures.all.first)
        let out = Vespertine.dstDecoder.makeDecoder(channels: fixture.channels).decode(frame: fixture.frame)
        #expect(out?.count == fixture.expected.count)
    }

    #if os(macOS)
    @Test("The macOS adapters return results")
    func mac() throws {
        let packer = try #require(Vespertine.dopPacker)
        #expect(try packer.dopPack(dsd: [[0x69, 0x69], [0x69, 0x69]], firstMarker: 0x05).map(\.count) == [1, 1])
        #expect(Vespertine.floatOutput.int24ToFloat(samples: [0, 1, -1]).count == 3)
        let planner = try #require(Vespertine.ratePlanner)
        #expect(planner.dopCarrierRate(dsdRate: 2_822_400) > 0)
        let verdict = try #require(Vespertine.verdict)
        let input = VerdictInput(
            source: .init(encoding: .pcm, codec: "FLAC", sampleRate: 44_100, bitDepth: 16, channels: 2),
            plan: .init(mode: .pcm, requestedRate: 44_100, requestedBitDepth: 24, channels: 2, resampling: false,
                        dsdConvertedToPCM: false, spatial: .off, integerMode: false),
            readback: .init(nominalRate: 44_100, physicalBitDepth: 24, physicalIsInteger: true, deviceChannels: 2, hogOwnerPID: -1, ownPID: 100),
            deviceClass: .usbDAC,
            processing: .init(volume: .hardware, replayGainDB: nil, equalizerActive: false, otherAppsPlaying: false, concealedFrames: 0))
        #expect(!verdict.verdict(input).isEmpty)
    }
    #endif
}
