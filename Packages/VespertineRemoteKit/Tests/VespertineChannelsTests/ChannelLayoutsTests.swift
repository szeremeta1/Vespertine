//
// Vespertine: the speaker layouts the Mac and the iPhone share: the bed a set of speakers is rendered on, and where each
// channel goes on it. (The Mac's own suite checks every bed against Apple's spatial mixer.)
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(AudioToolbox) && canImport(AVFAudio)
import AudioToolbox
import AVFAudio
import Testing
import VespertineChannels

private let L = kAudioChannelLabel_Left, R = kAudioChannelLabel_Right, C = kAudioChannelLabel_Center, LFE = kAudioChannelLabel_LFEScreen
private let Ls = kAudioChannelLabel_LeftSurround, Rs = kAudioChannelLabel_RightSurround
private let Lsd = kAudioChannelLabel_LeftSurroundDirect, Rsd = kAudioChannelLabel_RightSurroundDirect
private let Lrs = kAudioChannelLabel_RearSurroundLeft, Rrs = kAudioChannelLabel_RearSurroundRight

@Suite struct ChannelLayoutsTests {
    @Test func fivePointOneIsItsOwnBed() throws {
        let bed = try #require(ChannelLayouts.spatialBed(for: [L, R, C, LFE, Ls, Rs]))
        #expect(bed.tag == kAudioChannelLayoutTag_MPEG_5_1_A && bed.channels == 6)
        #expect(ChannelLayouts.spatialBed(for: [L, R]) == nil)
    }

    @Test func aWaveSevenPointOneLandsOnASevenPointOneBedWithNothingLost() throws {
        // WAVE and FLAC order: the back pair is called Ls/Rs, the side pair Lsd/Rsd.
        let source = try #require(ChannelLayouts.wavOrderLabels(channels: 8))
        #expect(source == [L, R, C, LFE, Ls, Rs, Lsd, Rsd])
        let bed = try #require(ChannelLayouts.spatialBed(for: source))
        #expect(bed.channels == 8)
        let labels = try #require(AVAudioChannelLayout(layoutTag: bed.tag)).channelLabels
        let router = try #require(BedRouter(source: source, bed: labels))
        #expect(router.dropped == 0 && router.approximated == 0)
        // The file's back pair goes to the bed's rear speakers, its side pair to the bed's sides.
        #expect(router.routes[4].map(\.bed) == [try #require(labels.firstIndex(of: Lrs))])
        #expect(router.routes[6].map(\.bed) == [try #require(labels.firstIndex(of: Ls))])
    }

    @Test func channelsAreRoutedPlaneByPlane() throws {
        // A 5.1 whose channels come in another order than the bed's, in separate buffers (as AVAudioPCMBuffer holds them).
        let source = [C, L, R, Ls, Rs, LFE]
        let bed = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)).channelLabels
        let router = try #require(BedRouter(source: source, bed: bed))
        let frames = 4
        let input = source.indices.map { s -> UnsafeMutablePointer<Float> in
            let plane = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            plane.initialize(repeating: Float(s + 1), count: frames)
            return plane
        }
        let output = bed.indices.map { _ -> UnsafeMutablePointer<Float> in
            let plane = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            plane.initialize(repeating: 9, count: frames)
            return plane
        }
        defer { (input + output).forEach { $0.deallocate() } }
        router.route(planes: input.map { UnsafePointer($0) }, into: output, frames: frames)
        for (b, label) in bed.enumerated() {
            let s = try #require(source.firstIndex(of: label))
            #expect(Array(UnsafeBufferPointer(start: output[b], count: frames)) == [Float](repeating: Float(s + 1), count: frames), "bed speaker \(b)")
        }
    }

    @Test func aCentreWithNoSpeakerOfItsOwnIsSharedBetweenLeftAndRight() throws {
        let router = try #require(BedRouter(source: [C], bed: [L, R]))
        #expect(router.routes[0].map(\.bed) == [0, 1])
        #expect(abs(router.routes[0][0].gain - Float(0.5.squareRoot())) < 1e-6)
        #expect(router.approximated == 1 && router.dropped == 0)
    }
}

#endif
