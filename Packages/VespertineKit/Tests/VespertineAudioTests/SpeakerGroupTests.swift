//
// Vespertine — speaker groups, the saved description: roles and their places, validation, coding, the channel map.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

enum GroupFixtures {
    static let fosi = "AppleUSBAudioEngine:Fosi:ZD3:1"
    static let fiio = "AppleUSBAudioEngine:FiiO:K11:2"

    /// The dorm quad: the Fosi's two outputs in front, the FiiO's two behind.
    static func quad(id: UUID = UUID(), name: String = "Dorm quad") -> SpeakerGroup {
        SpeakerGroup(
            id: id, name: name,
            members: [.init(deviceUID: fosi, name: "Fosi Audio ZD3", channelCount: 2),
                      .init(deviceUID: fiio, name: "FiiO K11", channelCount: 2)],
            clockLeaderUID: fosi,
            speakers: [
                .init(role: .frontLeft, deviceUID: fosi, channel: 0, position: Point2D(x: -1, y: 1.5)),
                .init(role: .frontRight, deviceUID: fosi, channel: 1, position: Point2D(x: 1, y: 1.5)),
                .init(role: .backLeft, deviceUID: fiio, channel: 0, position: Point2D(x: -1, y: -1.5)),
                .init(role: .backRight, deviceUID: fiio, channel: 1, position: Point2D(x: 1, y: -1.5)),
            ])
    }
}

@Suite("Speaker group model")
struct SpeakerGroupTests {
    // MARK: Roles

    @Test("Every role has a Core Audio label of its own, and the label leads back to the role")
    func roleLabels() {
        let labels = SpeakerRole.allCases.map(\.channelLabel)
        #expect(Set(labels).count == SpeakerRole.allCases.count)
        for role in SpeakerRole.allCases {
            #expect(SpeakerRole(label: role.channelLabel) == role)
        }
    }

    @Test("Labels files use for the same place find the same role: the older height names, the WAVE side pair, a mono centre")
    func roleAliases() {
        #expect(SpeakerRole(label: kAudioChannelLabel_LeftTopFront) == .topFrontLeft)
        #expect(SpeakerRole(label: kAudioChannelLabel_TopBackRight) == .topBackRight)
        #expect(SpeakerRole(label: kAudioChannelLabel_LeftSurroundDirect) == .sideLeft)
        #expect(SpeakerRole(label: kAudioChannelLabel_Mono) == .center)
        #expect(SpeakerRole(label: kAudioChannelLabel_LFE2) == .lfe)
        #expect(SpeakerRole(label: kAudioChannelLabel_Unknown) == nil)
    }

    @Test("Default angles are the standard ones: ±30° front, 0° centre, ±90° sides, ±135° backs; the LFE has none")
    func defaultAzimuths() {
        #expect(SpeakerRole.frontLeft.defaultAzimuth == -30 && SpeakerRole.frontRight.defaultAzimuth == 30)
        #expect(SpeakerRole.center.defaultAzimuth == 0)
        #expect(SpeakerRole.sideLeft.defaultAzimuth == -90 && SpeakerRole.sideRight.defaultAzimuth == 90)
        #expect(SpeakerRole.backLeft.defaultAzimuth == -135 && SpeakerRole.backRight.defaultAzimuth == 135)
        #expect(SpeakerRole.lfe.defaultAzimuth == nil)
        #expect(SpeakerRole.topFrontLeft.isHeight && !SpeakerRole.frontLeft.isHeight)
    }

    // MARK: Identity

    @Test("A group is an output of its own: its UID is the prefix and the group's id, and it can be told from a device's")
    func outputUID() {
        let id = UUID()
        let group = GroupFixtures.quad(id: id)
        #expect(group.outputUID == "vespertine-group:" + id.uuidString.lowercased())
        #expect(SpeakerGroup.groupID(fromOutputUID: group.outputUID) == id)
        #expect(SpeakerGroup.groupID(fromOutputUID: GroupFixtures.fosi) == nil)
        #expect(SpeakerGroup.groupID(fromOutputUID: "vespertine-group:not-a-uuid") == nil)
    }

    // MARK: Channel map

    @Test("Channels count on through the members in group order: the leader's first, then the next member's")
    func channelOffsets() {
        let group = GroupFixtures.quad()
        #expect(group.totalChannels == 4)
        #expect(group.channelOffset(ofMember: GroupFixtures.fosi) == 0)
        #expect(group.channelOffset(ofMember: GroupFixtures.fiio) == 2)
        #expect(group.channelOffset(ofMember: "nobody") == nil)
        #expect(group.aggregateChannels == [.frontLeft: 0, .frontRight: 1, .backLeft: 2, .backRight: 3])
    }

    @Test("The member order decides the stream order, not the speaker order")
    func channelOffsetsFollowMemberOrder() {
        var group = GroupFixtures.quad()
        group.members.reverse()
        #expect(group.aggregateChannels == [.backLeft: 0, .backRight: 1, .frontLeft: 2, .frontRight: 3])
    }

    @Test("A speaker on a DAC's second output lands one channel further along")
    func channelWithinMember() {
        var group = GroupFixtures.quad()
        group.members[0].channelCount = 4
        group.speakers[1].channel = 3
        #expect(group.aggregateChannels[.frontRight] == 3)
        #expect(group.aggregateChannels[.backLeft] == 4)
    }

    @Test("Speakers in output order: the role heard on each aggregate channel, nil for a channel nobody uses")
    func rolesByChannel() {
        var group = GroupFixtures.quad()
        group.members[1].channelCount = 4
        #expect(group.rolesByAggregateChannel == [.frontLeft, .frontRight, .backLeft, .backRight, nil, nil])
    }

    // MARK: Validation

    @Test("The dorm quad is valid")
    func valid() {
        #expect(GroupFixtures.quad().issues.isEmpty)
    }

    @Test("A group needs two outputs, a name, and a leader that is one of them")
    func membersAndLeader() {
        var group = GroupFixtures.quad()
        group.name = "   "
        #expect(group.issues.contains(.emptyName))
        group = GroupFixtures.quad()
        group.members.removeLast()
        group.speakers.removeAll { $0.deviceUID == GroupFixtures.fiio }
        #expect(group.issues.contains(.tooFewMembers))
        group = GroupFixtures.quad()
        group.clockLeaderUID = "elsewhere"
        #expect(group.issues.contains(.leaderNotAMember("elsewhere")))
        group = GroupFixtures.quad()
        group.members.append(group.members[0])
        #expect(group.issues.contains(.duplicateMember(GroupFixtures.fosi)))
    }

    @Test("Speakers must sit on a member's real output, each output and each role once")
    func speakerPlacement() {
        var group = GroupFixtures.quad()
        group.speakers[0].deviceUID = "elsewhere"
        #expect(group.issues.contains(.speakerOnUnknownDevice(group.speakers[0].id)))

        group = GroupFixtures.quad()
        group.speakers[1].channel = 2
        #expect(group.issues.contains(.channelOutOfRange(group.speakers[1].id)))
        group.speakers[1].channel = -1
        #expect(group.issues.contains(.channelOutOfRange(group.speakers[1].id)))

        group = GroupFixtures.quad()
        group.speakers[1].channel = 0
        #expect(group.issues.contains(.channelShared(device: GroupFixtures.fosi, channel: 0)))

        group = GroupFixtures.quad()
        group.speakers[3].role = .backLeft
        #expect(group.issues.contains(.roleRepeated(.backLeft)))
    }

    @Test("More than 16 channels across the members is refused: the real-time path carries 16")
    func channelLimit() {
        var group = GroupFixtures.quad()
        group.members[1].channelCount = 16
        #expect(group.issues.contains(.tooManyChannels(18)))
        group.members[1].channelCount = 14
        #expect(!group.issues.contains(.tooManyChannels(16)))
    }

    @Test("Positions, trims and the room must be real numbers within sane limits; a speaker can't be at the listener")
    func numbers() {
        var group = GroupFixtures.quad()
        group.speakers[0].position = Point2D(x: .nan, y: 1)
        #expect(group.issues.contains(.positionInvalid(group.speakers[0].id)))

        group = GroupFixtures.quad()
        group.speakers[0].position = Point2D(x: 500, y: 0)
        #expect(group.issues.contains(.positionInvalid(group.speakers[0].id)))

        group = GroupFixtures.quad()
        group.speakers[0].position = group.listener.position
        #expect(group.issues.contains(.speakerAtListener(group.speakers[0].id)))

        group = GroupFixtures.quad()
        group.speakers[1].trimDB = 30
        group.speakers[2].delayTrimMs = -1
        #expect(group.issues.contains(.trimInvalid(group.speakers[1].id)))
        #expect(group.issues.contains(.trimInvalid(group.speakers[2].id)))

        group = GroupFixtures.quad()
        group.listener.position = Point2D(x: .infinity, y: 0)
        #expect(group.issues.contains(.listenerInvalid))

        group = GroupFixtures.quad()
        group.room = RoomOutline(width: 0, depth: 4)
        #expect(group.issues.contains(.roomInvalid))
        group.room = RoomOutline(width: 4, depth: 5)
        #expect(!group.issues.contains(.roomInvalid))
    }

    @Test("A member's drift quality is held to Core Audio's 0…127")
    func driftQuality() {
        var group = GroupFixtures.quad()
        group.members[1].driftQuality = 200
        #expect(group.issues.contains(.driftQualityInvalid(GroupFixtures.fiio)))
        group.members[1].driftQuality = 0x7F
        #expect(group.issues.isEmpty)
    }

    // MARK: Coding

    @Test("A group saved and read back is the same group")
    func roundTrip() throws {
        var group = GroupFixtures.quad()
        group.room = RoomOutline(width: 4.2, depth: 5)
        group.stereoPolicy = .mirror(trimDB: -3)
        group.lfePolicy = .toAll(dB: -6)
        group.onMemberLoss = .continueOnRemaining
        group.alignmentProfileID = UUID()
        group.members[1].extraLatencyFrames = 96
        group.speakers[2].height = 1.1
        group.speakers[3].invertPolarity = true
        let data = try SpeakerGroupCoding.encode(group)
        #expect(try SpeakerGroupCoding.decode(data) == group)
    }

    @Test("The file is stable: sorted keys, so the same group always writes the same bytes")
    func stableBytes() throws {
        let group = GroupFixtures.quad()
        #expect(try SpeakerGroupCoding.encode(group) == SpeakerGroupCoding.encode(group))
    }

    @Test("A file with only the essentials still loads: everything newer than it falls back to its default")
    func defaultsForMissingKeys() throws {
        let json = """
        {"schemaVersion":1,"id":"6F1F3A60-1D5E-4F49-9A3B-0A5C2B7A9E10","name":"Minimal",
         "members":[{"deviceUID":"a","name":"A","channelCount":2},{"deviceUID":"b","name":"B","channelCount":2}],
         "clockLeaderUID":"a","speakers":[]}
        """
        let group = try SpeakerGroupCoding.decode(Data(json.utf8))
        #expect(group.name == "Minimal" && group.members.count == 2)
        #expect(group.members[0].driftQuality == 0x7F && group.members[0].extraLatencyFrames == 0)
        #expect(group.stereoPolicy == .frontOnly && group.lfePolicy == .drop && group.onMemberLoss == .pause)
        #expect(group.listener == Listener() && group.room == nil && group.alignmentProfileID == nil)
    }

    @Test("A file from a newer Vespertine is refused as newer, not as damaged; one with no version is refused too")
    func schemaChecks() throws {
        let newer = #"{"schemaVersion":2,"id":"6F1F3A60-1D5E-4F49-9A3B-0A5C2B7A9E10"}"#
        #expect(throws: SpeakerGroupError.newerSchema(2)) { try SpeakerGroupCoding.decode(Data(newer.utf8)) }
        let none = #"{"id":"6F1F3A60-1D5E-4F49-9A3B-0A5C2B7A9E10"}"#
        #expect(throws: SpeakerGroupError.missingSchema) { try SpeakerGroupCoding.decode(Data(none.utf8)) }
        #expect(throws: SpeakerGroupError.unreadable) { try SpeakerGroupCoding.decode(Data("[]".utf8)) }
        let broken = #"{"schemaVersion":1,"id":"x"}"#
        #expect(throws: SpeakerGroupError.unreadable) { try SpeakerGroupCoding.decode(Data(broken.utf8)) }
    }

    @Test("A drift quality outside 0…127 in a file is kept as it was read, for validation to report")
    func qualityNotClampedOnRead() throws {
        var group = GroupFixtures.quad()
        group.members[1].driftQuality = 999
        let read = try SpeakerGroupCoding.decode(SpeakerGroupCoding.encode(group))
        #expect(read.members[1].driftQuality == 999)
    }
}
