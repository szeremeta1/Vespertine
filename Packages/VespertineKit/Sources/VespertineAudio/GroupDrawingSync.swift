//
// Vespertine — speaker groups and room correction, on screen: the drawn profile follows the drawing, and "use the drawing" binds a
// group to it. The drawn profile is only ever made when someone asks; once there, it is kept up to date so a speaker dragged in the
// editor is heard (and its warning checked) with the next play. Measured and imported profiles are never touched.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Where a group stands with the profile made from its drawing.
public enum GroupDrawingState: Equatable, Sendable {
    /// No speaker is wired to an output, so there is nothing to draw.
    case unavailable
    /// The drawing can make a profile; none has been made yet.
    case notMade
    /// Made, and the group plays with something else (or nothing).
    case available
    /// The group plays with it.
    case inUse
}

extension GroupRoomProfile {
    /// Brings the drawn profile of `group`, if it has one in `book`, up to date with the drawing. Never makes one. True when the book
    /// changed; an unchanged drawing changes nothing, so a drag that doesn't move a speaker writes no file.
    @discardableResult
    public static func syncDrawing(of group: SpeakerGroup, in book: inout RoomProfileBook) -> Bool {
        guard let existing = book.profiles(for: group.outputUID).first(where: { $0.origin == .geometry }),
              let fresh = GroupGeometryProfile.make(for: group) else { return false }
        guard existing.layout != fresh.layout || existing.channelMap != fresh.channelMap || existing.alignment != fresh.alignment else { return false }
        GroupGeometryProfile.refresh(in: &book, for: group)
        return true
    }

    /// "Use the drawing": the profile from the drawing is made (or brought up to date) and `group` is bound to it, which also makes it
    /// the one its output plays with, switched on. nil, and nothing changed, when the group has no drawing to make a profile of.
    public static func useDrawing(for group: SpeakerGroup, in book: inout RoomProfileBook) -> SpeakerGroup? {
        var next = book
        guard let profile = GroupGeometryProfile.refresh(in: &next, for: group) else { return nil }
        let bound = bind(profile.id, to: group, in: &next)
        guard bound.alignmentProfileID == profile.id else { return nil }
        book = next
        return bound
    }

    /// What the window should offer for `group`.
    public static func drawingState(for group: SpeakerGroup, in book: RoomProfileBook) -> GroupDrawingState {
        guard GroupGeometryProfile.make(for: group) != nil else { return .unavailable }
        guard let drawn = book.profiles(for: group.outputUID).first(where: { $0.origin == .geometry }) else { return .notMade }
        return chosen(for: group, in: book)?.id == drawn.id ? .inUse : .available
    }
}
