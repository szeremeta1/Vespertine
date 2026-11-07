//
// Vespertine — speaker groups and room correction: the drawing of the room as a room profile of its own kind (delays and levels
// from where the speakers stand, no filters), which one a group plays with, and the warning when a measurement and the drawing
// disagree by more than the measurement can explain.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Geometry as a room profile")
struct GroupGeometryProfileTests {
    /// His two speakers 1.5 m from the seat, the roommate's two 2.5 m (the dorm of the plan), on two DACs.
    private func dorm() -> SpeakerGroup {
        SpeakerGroup(
            name: "Dorm", members: [.init(deviceUID: "a", name: "A", channelCount: 2), .init(deviceUID: "b", name: "B", channelCount: 2)], clockLeaderUID: "a",
            speakers: [
                .init(role: .frontLeft, deviceUID: "a", channel: 0, position: Point2D(x: -1.5, y: 0)),
                .init(role: .frontRight, deviceUID: "a", channel: 1, position: Point2D(x: 1.5, y: 0)),
                .init(role: .backLeft, deviceUID: "b", channel: 0, position: Point2D(x: -2.5, y: 0)),
                .init(role: .backRight, deviceUID: "b", channel: 1, position: Point2D(x: 2.5, y: 0)),
            ])
    }

    private func measured(for group: SpeakerGroup, delays: [RoomSpeaker: Double], source: RoomProfileSource = .measured) throws -> RoomProfile {
        let fit = try #require(RoomLayout.layout(for: group))
        var p = RoomProfile(id: UUID(), name: "Measured", createdAt: Date(timeIntervalSince1970: 1_793_000_000), sessionID: UUID(), deviceUID: group.outputUID,
                            layout: fit.layout, channelMap: fit.channelMap, micSerial: "7001", calibrationSHA256: nil, target: .flat,
                            filters: RoomFilterSet(version: 1, channels: [:]))
        p.alignment = delays.mapValues { RoomSpeakerAlignment(delayMs: $0, levelDB: 0) }
        p.source = source
        return p
    }

    // MARK: The kind

    @Test("Geometry is a profile source of its own, stored by name, and a profile of it says where it came from")
    func source() throws {
        #expect(RoomProfileSource.geometry.rawValue == "geometry")
        let p = try #require(GroupGeometryProfile.make(for: dorm()))
        #expect(p.origin == .geometry && p.source == .geometry)
    }

    // MARK: The profile from the drawing

    @Test("The dorm: the near speakers wait 2.92 ms for the far ones and are turned down 4.4 dB; the far ones neither")
    func dormNumbers() throws {
        let g = dorm()
        let p = try #require(GroupGeometryProfile.make(for: g))
        #expect(p.deviceUID == g.outputUID)
        #expect(p.layout == .quad)
        #expect(p.alignment(for: .left).delayMs == 2.92 && p.alignment(for: .right).delayMs == 2.92)
        #expect(p.alignment(for: .left).levelDB == -4.4)
        #expect(p.alignment(for: .leftSurround) == RoomSpeakerAlignment() && p.alignment(for: .rightSurround) == RoomSpeakerAlignment())
        #expect(p.channelMap.entries.map(\.output).sorted() == [0, 1, 2, 3])
    }

    @Test("No filters at all: the bands, the preamp and the impulses are empty, so only the delays and levels play")
    func noFilters() throws {
        let p = try #require(GroupGeometryProfile.make(for: dorm()))
        #expect(p.filters.channels.values.allSatisfy(\.isEmpty) && p.filters.preampDB == 0)
        #expect(p.impulses == nil && p.measured == nil)
        let playback = RoomCorrectionPlayback(profile: p)
        #expect(playback.channels.map(\.delayMs) == [2.92, 2.92, 0, 0])
        #expect(playback.channels.map(\.levelDB) == [-4.4, -4.4, 0, 0])
        #expect(playback.channels.allSatisfy { $0.bands.isEmpty && $0.impulse == nil })
    }

    @Test("A speaker's own trims are not in it (the group's chain adds them), so nothing is counted twice")
    func trimsStayOut() throws {
        var g = dorm()
        g.speakers[0].delayTrimMs = 1.5
        g.speakers[0].trimDB = -2
        let p = try #require(GroupGeometryProfile.make(for: g))
        #expect(p.alignment(for: .left).delayMs == 2.92 && p.alignment(for: .left).levelDB == -4.4)
    }

    @Test("Equal distances are no alignment, and a profile that does nothing is flat for the engine")
    func flat() throws {
        var g = dorm()
        g.speakers[0].position = Point2D(x: -2.5, y: 0); g.speakers[1].position = Point2D(x: 2.5, y: 0)
        let p = try #require(GroupGeometryProfile.make(for: g))
        #expect(RoomCorrectionPlayback(profile: p).isFlat)
    }

    @Test("A group with no speaker on an output has no profile; a speaker standing at the seat is left out of it")
    func degenerate() throws {
        #expect(GroupGeometryProfile.make(for: SpeakerGroup(name: "Empty", members: [.init(deviceUID: "a", name: "A", channelCount: 2)], clockLeaderUID: "a")) == nil)
        var g = dorm()
        g.speakers[0].position = Point2D(x: 0, y: 0)
        let p = try #require(GroupGeometryProfile.make(for: g))
        #expect(p.channelMap.entries.count == 4)
        #expect(p.alignment?[.left] == nil)
    }

    @Test("Refreshing the drawing's profile in the library replaces its numbers and keeps its id, name and choice; a first one is added")
    func refresh() throws {
        var g = dorm()
        var book = RoomProfileBook()
        let first = GroupGeometryProfile.refresh(in: &book, for: g)
        #expect(first != nil && book.profiles.count == 1)
        g.speakers[0].position = Point2D(x: -2.0, y: 0)
        let again = try #require(GroupGeometryProfile.refresh(in: &book, for: g))
        #expect(book.profiles.count == 1 && again.id == first?.id && again.name == first?.name)
        #expect(book.profile(again.id)?.alignment(for: .left).delayMs == 1.46)
        // A measured profile of the group is never touched by it.
        let m = book.add(try measured(for: g, delays: [.left: 1]))
        _ = GroupGeometryProfile.refresh(in: &book, for: g)
        #expect(book.profile(m.id)?.alignment(for: .left).delayMs == 1)
    }

    // MARK: Measured against drawn

    @Test("The tolerance is a quarter of a millisecond")
    func tolerance() {
        #expect(GeometryCheck.toleranceMs == 0.25)
    }

    @Test("A measurement that matches the drawing, to within the tolerance, raises nothing")
    func agrees() throws {
        let g = dorm()
        let geometry = try #require(GroupGeometryProfile.make(for: g))
        let close = try measured(for: g, delays: [.left: 2.92 + 0.1, .right: 2.92 - 0.1, .leftSurround: 0, .rightSurround: 0.2])
        #expect(GeometryCheck.disagreements(measured: close, geometry: geometry).isEmpty)
        #expect(GeometryCheck.disagreements(measured: geometry, geometry: geometry).isEmpty)
    }

    @Test("One speaker 0.6 ms off its drawn place is named, with the distance that is; the others are fine")
    func oneOff() throws {
        let g = dorm()
        let geometry = try #require(GroupGeometryProfile.make(for: g))
        let off = try measured(for: g, delays: [.left: 2.92, .right: 2.92, .leftSurround: 0, .rightSurround: 0.6])
        let found = GeometryCheck.disagreements(measured: off, geometry: geometry)
        #expect(found.map(\.speaker) == [.rightSurround])
        let one = try #require(found.first)
        #expect(abs(one.differenceMs - 0.6) < 1e-9 && abs(one.distanceCm - 0.6 * 34.3) < 0.01)
    }

    @Test("A constant shift of the whole measurement is not a disagreement (the reference speaker differs), and exactly 0.25 ms is within")
    func commonOffset() throws {
        let g = dorm()
        let geometry = try #require(GroupGeometryProfile.make(for: g))
        let shifted = try measured(for: g, delays: [.left: 3.92, .right: 3.92, .leftSurround: 1, .rightSurround: 1])
        #expect(GeometryCheck.disagreements(measured: shifted, geometry: geometry).isEmpty)
        let edge = try measured(for: g, delays: [.left: 2.92, .right: 2.92, .leftSurround: 0, .rightSurround: 0.25])
        #expect(GeometryCheck.disagreements(measured: edge, geometry: geometry).isEmpty)
        let over = try measured(for: g, delays: [.left: 2.92, .right: 2.92, .leftSurround: 0, .rightSurround: 0.26])
        #expect(GeometryCheck.disagreements(measured: over, geometry: geometry).map(\.speaker) == [.rightSurround])
    }

    @Test("Fewer than two speakers in common can't be compared")
    func tooFew() throws {
        let g = dorm()
        let geometry = try #require(GroupGeometryProfile.make(for: g))
        let one = try measured(for: g, delays: [.left: 9])
        #expect(GeometryCheck.disagreements(measured: one, geometry: geometry).isEmpty)
    }

    @Test("The warning names the speakers, the milliseconds and the centimetres, and says the drawing or the cabling may be off")
    func warningText() throws {
        let g = dorm()
        let geometry = try #require(GroupGeometryProfile.make(for: g))
        let off = try measured(for: g, delays: [.left: 2.92, .right: 2.92, .leftSurround: 0, .rightSurround: 0.6])
        let text = try #require(GeometryCheck.warning(GeometryCheck.disagreements(measured: off, geometry: geometry)))
        #expect(text.contains("Right surround") && text.contains("0.6 ms") && text.contains("21 cm"), "\(text)")
        #expect(text.contains("drawing") && text.contains("cabling"))
        #expect(GeometryCheck.warning([]) == nil)
    }

    @Test("For a group: the bound profile, if measured, is compared with the drawing as it is now; a drawn profile or none raises nothing")
    func forGroup() throws {
        var g = dorm()
        var book = RoomProfileBook()
        #expect(GroupRoomProfile.geometryWarning(for: g, in: book) == nil)
        let off = book.add(try measured(for: g, delays: [.left: 2.92, .right: 2.92, .leftSurround: 0, .rightSurround: 0.6]))
        g = GroupRoomProfile.bind(off.id, to: g, in: &book)
        #expect(GroupRoomProfile.geometryWarning(for: g, in: book)?.contains("Right surround") == true)
        // Moving the speaker in the drawing to where it was measured clears it.
        g.speakers[3].position = Point2D(x: 2.5 - 0.6 * 0.343, y: 0)
        #expect(GroupRoomProfile.geometryWarning(for: g, in: book) == nil)
        // A profile from the drawing is never compared with itself.
        let drawn = try #require(GroupGeometryProfile.refresh(in: &book, for: g))
        g = GroupRoomProfile.bind(drawn.id, to: g, in: &book)
        #expect(GroupRoomProfile.geometryWarning(for: g, in: book) == nil)
    }

    // MARK: Which profile a group plays with

    @Test("Suggested: the one it is bound to; else the newest measured or imported; else the drawing's; else none")
    func suggested() throws {
        var g = dorm()
        var book = RoomProfileBook()
        #expect(GroupRoomProfile.suggested(for: g, in: book) == nil)
        let drawn = try #require(GroupGeometryProfile.refresh(in: &book, for: g))
        #expect(GroupRoomProfile.suggested(for: g, in: book)?.id == drawn.id)
        let measuredProfile = book.add(try measured(for: g, delays: [.left: 2.9, .right: 2.9, .leftSurround: 0, .rightSurround: 0]))
        #expect(GroupRoomProfile.suggested(for: g, in: book)?.id == measuredProfile.id, "a measurement replaces the drawing")
        g = GroupRoomProfile.bind(drawn.id, to: g, in: &book)
        #expect(GroupRoomProfile.suggested(for: g, in: book)?.id == drawn.id, "an explicit choice wins")
    }
}
