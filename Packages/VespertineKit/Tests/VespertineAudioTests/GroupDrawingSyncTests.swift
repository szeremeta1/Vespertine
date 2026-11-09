//
// Vespertine: speaker groups and room correction, on screen: the drawn profile kept up to date as the drawing changes (never made
// by itself, never touching a measured profile), and "use the drawing" for a group, which makes it if need be and binds the group.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Drawing sync for room correction")
struct GroupDrawingSyncTests {
    private func group() -> SpeakerGroup {
        var g = GroupFixtures.quad()
        g.speakers[2].position = Point2D(x: -2.5, y: -1.5)
        g.speakers[3].position = Point2D(x: 2.5, y: -1.5)
        return g
    }

    private func measured(for group: SpeakerGroup) throws -> RoomProfile {
        let fit = try #require(RoomLayout.layout(for: group))
        var p = RoomProfile(id: UUID(), name: "Measured", createdAt: Date(timeIntervalSince1970: 1_793_000_000), sessionID: UUID(), deviceUID: group.outputUID,
                            layout: fit.layout, channelMap: fit.channelMap, micSerial: "7001", calibrationSHA256: nil, target: .flat,
                            filters: RoomFilterSet(version: 1, channels: [:]))
        p.alignment = [.left: RoomSpeakerAlignment(delayMs: 1, levelDB: 0)]
        return p
    }

    @Test("With no drawn profile yet nothing is made: the book is as it was and the answer is no change")
    func neverMadeByItself() {
        var book = RoomProfileBook()
        #expect(GroupRoomProfile.syncDrawing(of: group(), in: &book) == false)
        #expect(book.profiles.isEmpty)
    }

    @Test("A speaker moved in the drawing: the drawn profile's numbers follow, its id, name and choice stay")
    func follows() throws {
        var g = group()
        var book = RoomProfileBook()
        let made = try #require(GroupGeometryProfile.refresh(in: &book, for: g))
        book.choose(made.id, for: g.outputUID)
        g.speakers[0].position = Point2D(x: -1, y: 4)
        #expect(GroupRoomProfile.syncDrawing(of: g, in: &book) == true)
        let after = try #require(book.profile(made.id))
        #expect(after.id == made.id && after.name == made.name && book.chosenID(for: g.outputUID) == made.id)
        #expect(after.alignment != made.alignment)
        #expect(book.profiles(for: g.outputUID).count == 1)
    }

    @Test("An unchanged drawing changes nothing, so a drag that does not move a speaker writes no file")
    func idempotent() throws {
        let g = group()
        var book = RoomProfileBook()
        _ = GroupGeometryProfile.refresh(in: &book, for: g)
        let before = book
        #expect(GroupRoomProfile.syncDrawing(of: g, in: &book) == false)
        #expect(book == before)
    }

    @Test("A measured profile is never touched, whatever the drawing does")
    func measuredUntouched() throws {
        var g = group()
        var book = RoomProfileBook()
        _ = GroupGeometryProfile.refresh(in: &book, for: g)
        let m = book.add(try measured(for: g), makeChosen: true)
        g.speakers[1].position = Point2D(x: 3, y: 3)
        _ = GroupRoomProfile.syncDrawing(of: g, in: &book)
        #expect(book.profile(m.id)?.alignment == m.alignment)
    }

    @Test("A group wired to nothing leaves the drawn profile as it is")
    func notWired() throws {
        var g = group()
        var book = RoomProfileBook()
        let made = try #require(GroupGeometryProfile.refresh(in: &book, for: g))
        g.speakers = []
        #expect(GroupRoomProfile.syncDrawing(of: g, in: &book) == false)
        #expect(book.profile(made.id) == made)
    }

    @Test("Use the drawing: made the first time, the group bound to it, switched on for the output")
    func useFirstTime() throws {
        var book = RoomProfileBook()
        let g = group()
        let bound = try #require(GroupRoomProfile.useDrawing(for: g, in: &book))
        let id = try #require(bound.alignmentProfileID)
        #expect(book.profile(id)?.origin == .geometry && book.chosenID(for: g.outputUID) == id && book.isEnabled(g.outputUID))
        #expect(GroupRoomProfile.chosen(for: bound, in: book)?.id == id)
    }

    @Test("Use the drawing again: the same profile, brought up to date, not a second one; a measured profile stays in the list")
    func useAgain() throws {
        var g = group()
        var book = RoomProfileBook()
        let first = try #require(GroupRoomProfile.useDrawing(for: g, in: &book))
        let m = book.add(try measured(for: g), makeChosen: false)
        g.speakers[0].position = Point2D(x: -1, y: 4)
        let second = try #require(GroupRoomProfile.useDrawing(for: g, in: &book))
        #expect(second.alignmentProfileID == first.alignmentProfileID)
        #expect(book.profiles(for: g.outputUID).filter { $0.origin == .geometry }.count == 1)
        #expect(book.profile(m.id) != nil)
    }

    @Test("A group with no speaker on an output has no drawing to use: nothing is changed")
    func useNothing() {
        var g = group()
        g.speakers = []
        var book = RoomProfileBook()
        #expect(GroupRoomProfile.useDrawing(for: g, in: &book) == nil)
        #expect(book.profiles.isEmpty)
    }

    @Test("The window's lines: the warning, the offer to use the drawing, and the state of it")
    func state() throws {
        var g = group()
        var book = RoomProfileBook()
        #expect(GroupRoomProfile.drawingState(for: g, in: book) == .notMade)
        let bound = try #require(GroupRoomProfile.useDrawing(for: g, in: &book))
        g = bound
        #expect(GroupRoomProfile.drawingState(for: g, in: book) == .inUse)
        let m = book.add(try measured(for: g), makeChosen: true)
        g = GroupRoomProfile.bind(m.id, to: g, in: &book)
        #expect(GroupRoomProfile.drawingState(for: g, in: book) == .available)
        g.speakers = []
        #expect(GroupRoomProfile.drawingState(for: g, in: book) == .unavailable)
    }
}
