//
// Vespertine: speaker groups and room correction: the layout a group is measured and aligned as, the channel map onto its
// outputs, and a room profile bound to the group (made for its UID, valid only while it is wired the way it was made for).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A group's setup as room correction sees it.
public struct GroupRoomLayout: Equatable, Sendable {
    public var layout: RoomLayout
    /// Each speaker on its output of the group (the aggregate's channel), unverified.
    public var channelMap: RoomChannelMap
    /// The room speaker each of the group's roles became (a quad's back pair is its surround pair).
    public var speakers: [SpeakerRole: RoomSpeaker]
}

extension RoomLayout {
    /// The layout `group` is measured and aligned as, and its speakers on the group's outputs. Left and right alone are stereo;
    /// with a surround pair (sides or back, not both) a quad; with the centre and the LFE as well a 5.1; any other set lists its
    /// own speakers, in the order of the roles. nil when no speaker is wired to an output.
    public static func layout(for group: SpeakerGroup) -> GroupRoomLayout? {
        let wired = group.aggregateChannels
        guard !wired.isEmpty else { return nil }
        let roles = Set(wired.keys)
        let front: Set<SpeakerRole> = [.frontLeft, .frontRight]
        let sides: Set<SpeakerRole> = [.sideLeft, .sideRight], backs: Set<SpeakerRole> = [.backLeft, .backRight]
        let surrounds: [SpeakerRole: RoomSpeaker]
        let layout: RoomLayout
        switch roles {
        case front:
            layout = .stereo; surrounds = [:]
        case front.union(sides), front.union(backs):
            layout = .quad; surrounds = Self.surroundPair(of: roles.subtracting(front))
        case front.union([.center, .lfe]).union(sides), front.union([.center, .lfe]).union(backs):
            layout = .surround51; surrounds = Self.surroundPair(of: roles.subtracting(front).subtracting([.center, .lfe]))
        default:
            let ordered = SpeakerRole.allCases.filter(roles.contains)
            layout = .custom(ordered.map { RoomSpeaker(role: $0) }); surrounds = [:]
        }
        func speaker(_ role: SpeakerRole) -> RoomSpeaker { surrounds[role] ?? RoomSpeaker(role: role) }
        let byLayout: [SpeakerRole] = layout.speakers.compactMap { target in roles.first { speaker($0) == target } }
        let entries = byLayout.map { RoomChannelMap.Entry(speaker: speaker($0), output: wired[$0] ?? 0) }
        return GroupRoomLayout(layout: layout, channelMap: RoomChannelMap(entries: entries, verified: false),
                               speakers: Dictionary(uniqueKeysWithValues: roles.map { ($0, speaker($0)) }))
    }

    /// A left-right pair standing as the surrounds of a quad or a 5.1.
    private static func surroundPair(of roles: Set<SpeakerRole>) -> [SpeakerRole: RoomSpeaker] {
        var map: [SpeakerRole: RoomSpeaker] = [:]
        for role in roles {
            switch role {
            case .sideLeft, .backLeft: map[role] = .leftSurround
            case .sideRight, .backRight: map[role] = .rightSurround
            default: break
            }
        }
        return map
    }
}

extension RoomProfile {
    /// The profile was made for `group` (its UID) and the group is still wired the way it was: the same layout and the same
    /// speaker on each output.
    public func applies(to group: SpeakerGroup) -> Bool {
        guard let fit = RoomLayout.layout(for: group) else { return false }
        return applies(deviceUID: group.outputUID, layout: fit.layout, channelMap: fit.channelMap)
    }
}

/// Profiles bound to a speaker group. The group's `alignmentProfileID` is the one it plays with; the library
/// (`RoomProfileBook`) keys profiles by output UID, and a group's UID is its output's.
public enum GroupRoomProfile {
    /// The profiles in `book` that fit `group` as it is wired now, newest first.
    public static func profiles(for group: SpeakerGroup, in book: RoomProfileBook) -> [RoomProfile] {
        book.profiles(for: group.outputUID).filter { $0.applies(to: group) }
    }

    /// The profile the group is bound to, while it exists and still fits.
    public static func chosen(for group: SpeakerGroup, in book: RoomProfileBook) -> RoomProfile? {
        group.alignmentProfileID.flatMap { book.profile($0) }.flatMap { $0.deviceUID == group.outputUID && $0.applies(to: group) ? $0 : nil }
    }

    /// Binds `group` to the profile `id`, which is also made the one its output plays with, switched on. A profile that is not the
    /// group's, or no longer fits it, is not taken (the group comes back unchanged). nil unbinds: the output's correction goes
    /// off (the choice is kept for switching back on).
    public static func bind(_ id: UUID?, to group: SpeakerGroup, in book: inout RoomProfileBook) -> SpeakerGroup {
        var result = group
        guard let id else {
            book.setEnabled(false, for: group.outputUID)
            result.alignmentProfileID = nil
            return result
        }
        guard let profile = book.profile(id), profile.deviceUID == group.outputUID, profile.applies(to: group) else { return group }
        book.choose(id, for: group.outputUID)
        book.setEnabled(true, for: group.outputUID)
        result.alignmentProfileID = id
        return result
    }
}
