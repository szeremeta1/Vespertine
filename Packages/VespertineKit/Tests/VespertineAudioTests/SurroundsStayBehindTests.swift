//
// Vespertine: speaker groups: a 7.1 song on a group with one pair of surround speakers. The song has two pairs (sides and
// backs) and the group one, so one pair has no speaker of its own. It joins the other pair on the group's surround speakers, at
// −3 dB, as a single device's speaker setup folds it (`BedRouter`): no part of a surround channel plays on a front speaker.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("7.1 on a group with one surround pair: the surrounds stay behind")
struct SurroundsStayBehindTests {
    // L R C LFE Ls Rs Rls Rrs (MPEG 7.1: the side pair is Ls/Rs, the back pair Rls/Rrs).
    private let surround71: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
                                                    kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
                                                    kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight]

    /// Two two-channel DACs: a front pair and one surround pair of the given names, drawn where given.
    private func fourSpeakers(_ left: SpeakerRole, _ right: SpeakerRole, at surround: Point2D) -> SpeakerGroup {
        let a = "AppleUSBAudioEngine:Fosi:ZD3:1", b = "AppleUSBAudioEngine:FiiO:K11:2"
        return SpeakerGroup(name: "Bar 118",
                            members: [.init(deviceUID: a, name: "Fosi ZD3", channelCount: 2), .init(deviceUID: b, name: "FiiO K11", channelCount: 2)],
                            clockLeaderUID: b,
                            speakers: [.init(role: .frontLeft, deviceUID: a, channel: 0, position: Point2D(x: -1, y: 2)),
                                       .init(role: .frontRight, deviceUID: a, channel: 1, position: Point2D(x: 1, y: 2)),
                                       .init(role: left, deviceUID: b, channel: 0, position: Point2D(x: -abs(surround.x), y: surround.y)),
                                       .init(role: right, deviceUID: b, channel: 1, position: Point2D(x: abs(surround.x), y: surround.y))])
    }

    private func gain(_ router: PositionRouter, of source: Int, on output: Int) -> Float {
        router.matrixRow(output).filter { $0.source == source }.reduce(0) { $0 + $1.gain }
    }

    // Outputs: 0 front left, 1 front right, 2 surround left, 3 surround right. Sources: 4 Lss, 5 Rss, 6 Lrs, 7 Rrs.

    @Test("With no side speakers, a side surround plays on the back speaker of its side at −3 dB and on no front speaker; the back surrounds keep their speakers at 1.0")
    func sidesOnTheBackPair() throws {
        let router = try #require(PositionRouter(source: surround71, group: fourSpeakers(.backLeft, .backRight, at: Point2D(x: 1, y: -2))))
        for front in 0...1 { for surround in 4...7 { #expect(gain(router, of: surround, on: front) == 0) } }
        #expect(gain(router, of: 4, on: 2) == PositionRouter.foldGain && gain(router, of: 5, on: 3) == PositionRouter.foldGain)
        #expect(gain(router, of: 4, on: 3) == 0 && gain(router, of: 5, on: 2) == 0)
        #expect(gain(router, of: 6, on: 2) == 1 && gain(router, of: 7, on: 3) == 1)
        #expect(router.routes[4].map(\.kind) == [.folded] && router.routes[5].map(\.kind) == [.folded])
    }

    @Test("The same wherever the back pair is drawn: beside the seat, or well behind it")
    func whereverTheBackPairStands() throws {
        for place in [Point2D(x: 2, y: 0), Point2D(x: 2, y: -0.5), Point2D(x: 0.5, y: -3)] {
            let router = try #require(PositionRouter(source: surround71, group: fourSpeakers(.backLeft, .backRight, at: place)))
            #expect(gain(router, of: 4, on: 0) == 0 && gain(router, of: 5, on: 1) == 0)
            #expect(gain(router, of: 4, on: 2) == PositionRouter.foldGain && gain(router, of: 5, on: 3) == PositionRouter.foldGain)
        }
    }

    @Test("The mirror: with no back speakers, a back surround plays on the side speaker of its side at −3 dB and on no front speaker")
    func backsOnTheSidePair() throws {
        for place in [Point2D(x: 2, y: 0), Point2D(x: 2, y: 0.5), Point2D(x: 1, y: -2)] {
            let router = try #require(PositionRouter(source: surround71, group: fourSpeakers(.sideLeft, .sideRight, at: place)))
            for front in 0...1 { for surround in 4...7 { #expect(gain(router, of: surround, on: front) == 0) } }
            #expect(gain(router, of: 6, on: 2) == PositionRouter.foldGain && gain(router, of: 7, on: 3) == PositionRouter.foldGain)
            #expect(gain(router, of: 4, on: 2) == 1 && gain(router, of: 5, on: 3) == 1)
        }
    }

    @Test("A group with both pairs is as before: every surround on its own speaker at 1.0")
    func bothPairs() throws {
        let a = "a", b = "b", c = "c"
        let group = SpeakerGroup(name: "Six",
                                 members: [a, b, c].map { .init(deviceUID: $0, name: $0, channelCount: 2) }, clockLeaderUID: a,
                                 speakers: [.init(role: .frontLeft, deviceUID: a, channel: 0, position: Point2D(x: -1, y: 2)),
                                            .init(role: .frontRight, deviceUID: a, channel: 1, position: Point2D(x: 1, y: 2)),
                                            .init(role: .sideLeft, deviceUID: b, channel: 0, position: Point2D(x: -2, y: 0)),
                                            .init(role: .sideRight, deviceUID: b, channel: 1, position: Point2D(x: 2, y: 0)),
                                            .init(role: .backLeft, deviceUID: c, channel: 0, position: Point2D(x: -1, y: -2)),
                                            .init(role: .backRight, deviceUID: c, channel: 1, position: Point2D(x: 1, y: -2))])
        let router = try #require(PositionRouter(source: surround71, group: group))
        for (source, output) in [(4, 2), (5, 3), (6, 4), (7, 5)] { #expect(router.matrixRow(output) == [.init(source: source, gain: 1)]) }
    }

    @Test("A 5.1 song is as before: its one surround pair takes the group's one surround pair at 1.0")
    func fiveOne() throws {
        let router = try #require(PositionRouter(source: Array(surround71.prefix(6)), group: fourSpeakers(.backLeft, .backRight, at: Point2D(x: 1, y: -2))))
        #expect(router.matrixRow(2) == [.init(source: 4, gain: 1)] && router.matrixRow(3) == [.init(source: 5, gain: 1)])
    }
}
