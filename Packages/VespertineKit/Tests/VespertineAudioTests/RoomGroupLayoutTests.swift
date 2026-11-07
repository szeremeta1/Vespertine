//
// Vespertine — room correction on a speaker group: the layouts a group can be measured and aligned as (stereo, quad, 5.1, or any
// set of speakers), the room speakers for the places in a group, the channel map onto the group's outputs, and a profile bound to
// the group so it plays only while the group is wired the way it was made for.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Room layouts on a speaker group")
struct RoomGroupLayoutTests {
    /// One DAC with a channel for each role, in the order given.
    private func group(_ roles: [SpeakerRole], name: String = "Test group") -> SpeakerGroup {
        let speakers = roles.enumerated().map { i, role in
            SpeakerGroup.Speaker(role: role, deviceUID: "a", channel: i, position: Point2D(x: Double(i), y: 2))
        }
        return SpeakerGroup(name: name, members: [.init(deviceUID: "a", name: "A", channelCount: roles.count)], clockLeaderUID: "a", speakers: speakers)
    }

    private func profile(for group: SpeakerGroup, layout: RoomLayout, map: RoomChannelMap, alignment: [RoomSpeaker: RoomSpeakerAlignment]? = nil) -> RoomProfile {
        var p = RoomProfile(id: UUID(), name: "Profile", createdAt: Date(timeIntervalSince1970: 1_793_000_000), sessionID: UUID(), deviceUID: group.outputUID,
                            layout: layout, channelMap: map, micSerial: "", calibrationSHA256: nil, target: .flat,
                            filters: RoomFilterSet(version: 1, channels: [:]))
        p.alignment = alignment
        return p
    }

    // MARK: The layouts

    @Test("The layouts keep their stored names, and quad and custom join them")
    func layoutNames() throws {
        #expect(RoomLayout.stereo.rawValue == "stereo" && RoomLayout.surround51.rawValue == "surround51" && RoomLayout.quad.rawValue == "quad")
        #expect(RoomLayout.allCases == [.stereo, .quad, .surround51])
        #expect(RoomLayout(rawValue: "surround51") == .surround51 && RoomLayout(rawValue: "nonsense") == nil)
        let custom = RoomLayout.custom([.left, .right, .sideLeft, .sideRight, .backLeft, .backRight])
        #expect(RoomLayout(rawValue: custom.rawValue) == custom)
        #expect(RoomLayout(rawValue: "custom:") == nil && RoomLayout(rawValue: "custom:left,left") == nil && RoomLayout(rawValue: "custom:nonsense") == nil)
    }

    @Test("Quad is L R Ls Rs, and a custom layout lists its own speakers")
    func layoutSpeakers() {
        #expect(RoomLayout.quad.speakers == [.left, .right, .leftSurround, .rightSurround])
        #expect(RoomLayout.custom([.left, .topFrontLeft]).speakers == [.left, .topFrontLeft])
        #expect(RoomChannelMap.standard(.quad).entries.map(\.output) == [0, 1, 2, 3])
    }

    @Test("Every place a group can have is a room speaker of its own, and the names are all different")
    func roomSpeakers() {
        let mapped = SpeakerRole.allCases.map { RoomSpeaker(role: $0) }
        #expect(Set(mapped).count == SpeakerRole.allCases.count)
        #expect(RoomSpeaker(role: .frontLeft) == .left && RoomSpeaker(role: .lfe) == .lfe && RoomSpeaker(role: .backRight) == .backRight)
        #expect(Set(RoomSpeaker.allCases.map(\.rawValue)).count == RoomSpeaker.allCases.count)
        #expect(RoomSpeaker.allCases.count == 6 + 13)
    }

    @Test("A layout and a profile with the new speakers survive a save and reload")
    func codable() throws {
        let layout = RoomLayout.custom([.left, .right, .center, .lfe, .sideLeft, .sideRight, .backLeft, .backRight])
        let g = group([.frontLeft, .frontRight])
        var p = profile(for: g, layout: layout, map: RoomChannelMap(entries: layout.speakers.enumerated().map { .init(speaker: $1, output: $0) }, verified: false),
                        alignment: [.backLeft: RoomSpeakerAlignment(delayMs: 1.5, levelDB: -2)])
        p.filters = RoomFilterSet(version: 1, channels: [.sideLeft: [], .backRight: []])
        let back = try RoomCorrectionCoding.decodeProfile(RoomCorrectionCoding.encode(p))
        #expect(back == p)
        #expect(back.layout == layout)
        // A quad profile and a stereo one read as they were.
        let quad = profile(for: g, layout: .quad, map: .standard(.quad))
        #expect(try RoomCorrectionCoding.decodeProfile(RoomCorrectionCoding.encode(quad)).layout == .quad)
    }

    // MARK: The group's layout

    @Test("A stereo group is stereo; the dorm quad (front pair and back pair on two DACs) is a quad with the back pair as the surrounds")
    func stereoAndQuad() throws {
        let stereo = try #require(RoomLayout.layout(for: group([.frontLeft, .frontRight])))
        #expect(stereo.layout == .stereo)
        #expect(stereo.channelMap.entries == [.init(speaker: .left, output: 0), .init(speaker: .right, output: 1)])

        let quad = try #require(RoomLayout.layout(for: GroupFixtures.quad()))
        #expect(quad.layout == .quad)
        #expect(Set(quad.channelMap.entries) == [.init(speaker: .left, output: 0), .init(speaker: .right, output: 1),
                                                 .init(speaker: .leftSurround, output: 2), .init(speaker: .rightSurround, output: 3)])
        #expect(!quad.channelMap.verified)
        #expect(quad.channelMap.validationError == nil)

        let sides = try #require(RoomLayout.layout(for: group([.frontLeft, .frontRight, .sideLeft, .sideRight])))
        #expect(sides.layout == .quad, "a side pair is the surround pair too")
        #expect(sides.channelMap.entries.last == .init(speaker: .rightSurround, output: 3))
    }

    @Test("A 5.1 group is 5.1 whether its surrounds stand at the sides or the back; anything else lists its speakers")
    func surroundAndCustom() throws {
        let five = try #require(RoomLayout.layout(for: group([.frontLeft, .frontRight, .center, .lfe, .backLeft, .backRight])))
        #expect(five.layout == .surround51)
        #expect(five.channelMap.entries.map(\.speaker) == [.left, .right, .center, .lfe, .leftSurround, .rightSurround])

        let seven = try #require(RoomLayout.layout(for: group([.frontLeft, .frontRight, .center, .lfe, .sideLeft, .sideRight, .backLeft, .backRight])))
        #expect(seven.layout == .custom([.left, .right, .center, .lfe, .sideLeft, .sideRight, .backLeft, .backRight]))
        #expect(seven.channelMap.entries.map(\.output) == [0, 1, 2, 3, 4, 5, 6, 7])

        let tops = try #require(RoomLayout.layout(for: group([.frontLeft, .frontRight, .topFrontLeft, .topFrontRight])))
        #expect(tops.layout == .custom([.left, .right, .topFrontLeft, .topFrontRight]), "a ceiling pair is not a surround pair")

        let lone = try #require(RoomLayout.layout(for: group([.backLeft, .backRight])))
        #expect(lone.layout == .custom([.backLeft, .backRight]))
    }

    @Test("The same speakers in any order give the same layout; the channel map follows the group's outputs, gaps and all")
    func orderAndGaps() throws {
        var g = GroupFixtures.quad()
        g.speakers.reverse()
        #expect(RoomLayout.layout(for: g)?.layout == .quad)
        // Front pair on the DAC's channels 0 and 2 (a gap between), the back pair on the second DAC.
        g = GroupFixtures.quad()
        g.members[0].channelCount = 3
        g.speakers[1].channel = 2
        let fit = try #require(RoomLayout.layout(for: g))
        #expect(Set(fit.channelMap.entries) == [.init(speaker: .left, output: 0), .init(speaker: .right, output: 2),
                                                .init(speaker: .leftSurround, output: 3), .init(speaker: .rightSurround, output: 4)])
        #expect(RoomLayout.layout(for: group([])) == nil)
    }

    // MARK: A profile bound to the group

    @Test("A profile made for a group plays on it while the wiring is the one it was made for, and only then")
    func appliesToGroup() throws {
        let g = GroupFixtures.quad()
        let fit = try #require(RoomLayout.layout(for: g))
        let p = profile(for: g, layout: fit.layout, map: fit.channelMap)
        #expect(p.applies(to: g))
        var rewired = g
        rewired.speakers[0].channel = 1; rewired.speakers[1].channel = 0
        #expect(!p.applies(to: rewired), "left and right swapped")
        var other = g
        other.speakers.removeLast(2)
        #expect(!p.applies(to: other), "no back pair any more")
        var elsewhere = p
        elsewhere.deviceUID = "AppleUSBAudioEngine:Other:1"
        #expect(!elsewhere.applies(to: g))
        var renamed = g
        renamed.name = "Renamed"
        #expect(p.applies(to: renamed), "the name is not the wiring")
    }

    @Test("Choosing a profile for a group binds it, and also makes it the one the output plays when correction is on")
    func binding() throws {
        var g = GroupFixtures.quad()
        let fit = try #require(RoomLayout.layout(for: g))
        var book = RoomProfileBook()
        let mine = book.add(profile(for: g, layout: fit.layout, map: fit.channelMap))
        let foreign = book.add(profile(for: GroupFixtures.quad(id: UUID(), name: "Other"), layout: fit.layout, map: fit.channelMap))
        #expect(GroupRoomProfile.profiles(for: g, in: book).map(\.id) == [mine.id])
        #expect(GroupRoomProfile.chosen(for: g, in: book) == nil)

        g = GroupRoomProfile.bind(mine.id, to: g, in: &book)
        #expect(g.alignmentProfileID == mine.id)
        #expect(GroupRoomProfile.chosen(for: g, in: book)?.id == mine.id)
        #expect(book.active(for: g.outputUID)?.id == mine.id, "correction is on for the group's output")

        // A profile of another group, or one that no longer fits, is not taken.
        let unchanged = GroupRoomProfile.bind(foreign.id, to: g, in: &book)
        #expect(unchanged == g)

        // Unbinding switches it off and forgets the id.
        g = GroupRoomProfile.bind(nil, to: g, in: &book)
        #expect(g.alignmentProfileID == nil && book.active(for: g.outputUID) == nil)

        // A profile that was deleted leaves the group unbound in effect.
        g.alignmentProfileID = UUID()
        #expect(GroupRoomProfile.chosen(for: g, in: book) == nil)
    }

    @Test("A quad profile plays through the engine's chain in the group's output order, delays and levels per output")
    func playbackOrder() throws {
        let g = GroupFixtures.quad()
        let fit = try #require(RoomLayout.layout(for: g))
        let p = profile(for: g, layout: fit.layout, map: fit.channelMap, alignment: [
            .left: RoomSpeakerAlignment(delayMs: 0, levelDB: 0), .right: RoomSpeakerAlignment(delayMs: 0.5, levelDB: -1),
            .leftSurround: RoomSpeakerAlignment(delayMs: 2, levelDB: -3), .rightSurround: RoomSpeakerAlignment(delayMs: 2.5, levelDB: -4)])
        let playback = RoomCorrectionPlayback(profile: p)
        #expect(playback.channels.count == 4)
        #expect(playback.channels.map(\.delayMs) == [0, 0.5, 2, 2.5])
        #expect(playback.channels.map(\.levelDB) == [0, -1, -3, -4])
        #expect(playback.applies(channels: g.totalChannels))
    }
}
