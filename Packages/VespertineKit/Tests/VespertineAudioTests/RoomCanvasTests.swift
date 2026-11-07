//
// Vespertine — speaker groups: the room drawing. Between metres in the room and points on the screen, dragging a speaker or the seat
// (kept inside the room, off the grid, never on top of each other), turning the seat, nudging from the keyboard, snapping to the
// usual angles, feet or metres, and the sentence a screen reader says for a speaker. Pure; no view.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Room canvas")
struct RoomCanvasTests {
    private let fosi = "fosi-uid", fiio = "fiio-uid"

    private func group(room: RoomOutline? = RoomOutline(width: 6, depth: 4)) -> SpeakerGroup {
        SpeakerGroup(name: "Dorm quad",
                     members: [SpeakerGroup.Member(deviceUID: fosi, name: "Fosi ZD3", channelCount: 2),
                               SpeakerGroup.Member(deviceUID: fiio, name: "FiiO K11", channelCount: 2)],
                     clockLeaderUID: fosi,
                     speakers: [SpeakerGroup.Speaker(role: .frontLeft, deviceUID: fosi, channel: 0, position: Point2D(x: -1, y: 1.5)),
                                SpeakerGroup.Speaker(role: .frontRight, deviceUID: fosi, channel: 1, position: Point2D(x: 1, y: 1.5)),
                                SpeakerGroup.Speaker(role: .backLeft, deviceUID: fiio, channel: 0, position: Point2D(x: -1, y: -1.5))],
                     room: room)
    }

    // MARK: Metres and points

    @Test("The room fills the view with a margin, the same scale both ways, and the front of the room at the top")
    func layout() {
        let l = RoomCanvasLayout(group: group(), viewWidth: 640, viewHeight: 480)
        #expect(l.roomWidth == 6 && l.roomDepth == 4)
        let origin = l.viewPoint(Point2D())
        #expect(abs(origin.x - 320) < 1e-9 && abs(origin.y - 240) < 1e-9, "the room's centre is the view's centre")
        let front = l.viewPoint(Point2D(x: 0, y: 1))
        #expect(front.y < origin.y, "forward is up the screen")
        let right = l.viewPoint(Point2D(x: 1, y: 0))
        #expect(right.x > origin.x && abs((right.x - origin.x) - (origin.y - front.y)) < 1e-9, "one metre is as long both ways")
        let corner = l.viewPoint(Point2D(x: -3, y: 2))
        #expect(corner.x >= 0 && corner.y >= 0 && corner.x <= 640 && corner.y <= 480)
    }

    @Test("View points and room points go back and forth")
    func roundTrip() {
        let l = RoomCanvasLayout(group: group(), viewWidth: 640, viewHeight: 480)
        for p in [Point2D(x: 1.25, y: -0.8), Point2D(x: -3, y: 2), Point2D()] {
            let v = l.viewPoint(p)
            let back = l.roomPoint(viewX: v.x, viewY: v.y)
            #expect(abs(back.x - p.x) < 1e-9 && abs(back.y - p.y) < 1e-9)
        }
    }

    @Test("A group with no room drawn gets one that holds every speaker and the seat, at least 4 m across")
    func fitted() {
        var g = group(room: nil)
        let l = RoomCanvasLayout(group: g, viewWidth: 640, viewHeight: 480)
        #expect(l.roomWidth >= 4 && l.roomDepth >= 4)
        g.speakers[0].position = Point2D(x: -5, y: 1)
        let wide = RoomCanvasLayout(group: g, viewWidth: 640, viewHeight: 480)
        #expect(wide.roomWidth >= 10)
    }

    // MARK: Dragging

    @Test("A speaker dragged lands on the grid, inside the room")
    func dragSpeaker() throws {
        let g = group()
        let id = g.speakers[0].id
        let moved = RoomCanvas.move(speaker: id, to: Point2D(x: -1.234, y: 0.987), in: g)
        let p = try #require(moved.speakers.first { $0.id == id }?.position)
        #expect(abs(p.x - -1.2) < 1e-9 && abs(p.y - 1.0) < 1e-9, "\(p)")
        let outside = RoomCanvas.move(speaker: id, to: Point2D(x: -9, y: 7), in: g)
        let q = try #require(outside.speakers.first { $0.id == id }?.position)
        #expect(q.x == -3 && q.y == 2, "held at the walls: \(q)")
        #expect(RoomCanvas.move(speaker: UUID(), to: Point2D(x: 1, y: 1), in: g) == g)
    }

    @Test("Not on the seat, and not on top of another speaker: a drag there is moved aside")
    func notOnTop() throws {
        let g = group()
        let id = g.speakers[0].id
        let seat = RoomCanvas.move(speaker: id, to: g.listener.position, in: g)
        #expect(seat.isValid, "\(seat.issues)")
        #expect(seat.speakers[0].position != g.listener.position)
        let other = RoomCanvas.move(speaker: id, to: g.speakers[1].position, in: g)
        #expect(other.speakers[0].position != other.speakers[1].position)
    }

    @Test("The seat can be dragged too, inside the room and not onto a speaker, and a free drag can be left off the grid")
    func dragSeat() throws {
        let g = group()
        let moved = RoomCanvas.moveListener(to: Point2D(x: 0.52, y: -0.48), in: g)
        #expect(moved.listener.position == Point2D(x: 0.5, y: -0.5))
        #expect(RoomCanvas.moveListener(to: Point2D(x: 99, y: 99), in: g).listener.position == Point2D(x: 3, y: 2))
        let onto = RoomCanvas.moveListener(to: g.speakers[0].position, in: g)
        #expect(onto.isValid, "\(onto.issues)")
        let free = RoomCanvas.move(speaker: g.speakers[0].id, to: Point2D(x: -1.234, y: 0.987), in: g, snap: false)
        #expect(free.speakers[0].position == Point2D(x: -1.234, y: 0.987))
    }

    // MARK: Turning the seat

    @Test("The seat turns to face a point: 0° is up the room, positive to the right, in steps of 5°")
    func turnSeat() {
        let g = group()
        #expect(RoomCanvas.turnListener(toward: Point2D(x: 0, y: 2), in: g).listener.facingDegrees == 0)
        #expect(RoomCanvas.turnListener(toward: Point2D(x: 2, y: 0), in: g).listener.facingDegrees == 90)
        #expect(RoomCanvas.turnListener(toward: Point2D(x: 0, y: -2), in: g).listener.facingDegrees == 180)
        #expect(RoomCanvas.turnListener(toward: Point2D(x: -2, y: 0), in: g).listener.facingDegrees == -90)
        #expect(RoomCanvas.turnListener(toward: Point2D(x: 1, y: 2), in: g).listener.facingDegrees == 25, "26.6° snapped")
        #expect(RoomCanvas.turnListener(toward: g.listener.position, in: g) == g, "nothing to face")
    }

    // MARK: Keyboard

    @Test("Arrow keys nudge a speaker by 10 cm, or 50 cm with the big step, inside the room")
    func nudge() throws {
        let g = group()
        let id = g.speakers[0].id
        let right = RoomCanvas.nudge(speaker: id, dx: 1, dy: 0, large: false, in: g)
        #expect(right.speakers[0].position == Point2D(x: -0.9, y: 1.5))
        let up = RoomCanvas.nudge(speaker: id, dx: 0, dy: 1, large: true, in: g)
        #expect(up.speakers[0].position == Point2D(x: -1, y: 2))
        let wall = RoomCanvas.nudge(speaker: id, dx: -1, dy: 0, large: true, in: RoomCanvas.nudge(speaker: id, dx: -1, dy: 0, large: true, in: RoomCanvas.nudge(speaker: id, dx: -1, dy: 0, large: true, in: g)))
        #expect(wall.speakers[0].position.x == -2.5 || wall.speakers[0].position.x == -3)
        #expect(wall.speakers[0].position.x >= -3)
    }

    // MARK: Usual angles

    @Test("Near the angle its role usually has, a speaker snaps onto it, at the same distance; far from it, it stays")
    func snapAngle() throws {
        let g = group()
        let id = g.speakers[0].id
        // Front left stands at -30° from where the seat faces; put it at -27° at 2 m.
        var near = g
        near.speakers[0].position = Point2D(x: 2 * sin(-27 * .pi / 180), y: 2 * cos(-27 * .pi / 180))
        let snapped = RoomCanvas.snapToUsualAngle(speaker: id, in: near)
        let p = try #require(snapped.speakers.first { $0.id == id }?.position)
        let a = atan2(p.x, p.y) * 180 / .pi
        #expect(abs(a - -30) < 1e-6 && abs(hypot(p.x, p.y) - 2) < 1e-6)
        var far = g
        far.speakers[0].position = Point2D(x: 2 * sin(-50 * .pi / 180), y: 2 * cos(-50 * .pi / 180))
        #expect(RoomCanvas.snapToUsualAngle(speaker: id, in: far) == far)
    }

    @Test("The snap follows where the seat faces")
    func snapFollowsFacing() throws {
        var g = group()
        g.listener = Listener(position: Point2D(), facingDegrees: 90)
        let id = g.speakers[0].id
        // Facing right, front left is 30° to the left of the +x direction: up the room.
        g.speakers[0].position = Point2D(x: 2 * sin(63 * .pi / 180), y: 2 * cos(63 * .pi / 180))
        let p = try #require(RoomCanvas.snapToUsualAngle(speaker: id, in: g).speakers.first { $0.id == id }?.position)
        #expect(abs(atan2(p.x, p.y) * 180 / .pi - 60) < 1e-6)
    }

    // MARK: Units

    @Test("Metres and feet: shown in the unit chosen, and typed values come back as metres")
    func units() {
        #expect(DistanceUnit.metres.format(2.1) == "2.1 m" && DistanceUnit.feet.format(2.1) == "6.9 ft")
        #expect(abs(DistanceUnit.feet.metres(from: 10) - 3.048) < 1e-9 && DistanceUnit.metres.metres(from: 3) == 3)
        #expect(DistanceUnit.metres.spoken(2.1) == "2.1 metres" && DistanceUnit.feet.spoken(2.1) == "6.9 feet")
        #expect(DistanceUnit.metres.spoken(1) == "1 metre" && DistanceUnit.feet.spoken(0.3048) == "1 foot")
    }

    // MARK: Screen reader

    @Test("A speaker is described by its role, distance and angle from where the seat faces")
    func described() {
        var g = group()
        g.speakers[0].position = Point2D(x: 2 * sin(-32 * .pi / 180), y: 2 * cos(-32 * .pi / 180))
        #expect(RoomCanvas.describe(speaker: g.speakers[0], in: g, unit: .metres) == "Front left, 2 metres, 32 degrees left")
        #expect(RoomCanvas.describe(speaker: g.speakers[1], in: g, unit: .metres) == "Front right, 1.8 metres, 34 degrees right")
        g.speakers[1].position = Point2D(x: 0, y: 2)
        #expect(RoomCanvas.describe(speaker: g.speakers[1], in: g, unit: .feet) == "Front right, 6.6 feet, straight ahead")
        #expect(RoomCanvas.describe(speaker: g.speakers[2], in: g, unit: .metres).hasPrefix("Back left, 1.8 metres, "))
        #expect(RoomCanvas.describe(listener: g, unit: .metres) == "Listening seat, facing the front of the room")
    }
}
