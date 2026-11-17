//
// Vespertine: speaker groups: the room in three dimensions. The camera, where a point of the room lands on the screen and back,
// the walls in the way, the ceiling, the ears' and the speakers' heights above the floor, the listening area, and that a group
// saved before any of it reads as it did. Pure; no view.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Room in three dimensions")
struct Room3DTests {
    private let fosi = "fosi-uid", fiio = "fiio-uid"

    private func group(room: RoomOutline? = RoomOutline(width: 6, depth: 4, height: 2.6)) -> SpeakerGroup {
        SpeakerGroup(name: "Downstairs quad",
                     members: [SpeakerGroup.Member(deviceUID: fosi, name: "Fosi ZD3", channelCount: 2),
                               SpeakerGroup.Member(deviceUID: fiio, name: "FiiO K11", channelCount: 2)],
                     clockLeaderUID: fosi,
                     speakers: [SpeakerGroup.Speaker(role: .frontLeft, deviceUID: fosi, channel: 0, position: Point2D(x: -1, y: 1.5)),
                                SpeakerGroup.Speaker(role: .frontRight, deviceUID: fosi, channel: 1, position: Point2D(x: 1, y: 1.5)),
                                SpeakerGroup.Speaker(role: .topBackLeft, deviceUID: fiio, channel: 0, position: Point2D(x: -1, y: -1.5), height: 1.4)],
                     room: room)
    }

    private func layout(_ camera: RoomCamera, _ g: SpeakerGroup? = nil) -> Room3DLayout {
        Room3DLayout(group: g ?? group(), camera: camera, viewWidth: 640, viewHeight: 480)
    }

    // MARK: Camera

    @Test("A camera is held to what it can be: yaw wraps, pitch stays between a little above the floor and straight down, zoom in range")
    func cameraHeld() {
        let c = RoomCamera(yawDegrees: 370, pitchDegrees: 120, zoom: 99)
        #expect(c.yawDegrees == 10 && c.pitchDegrees == 90 && c.zoom == RoomCamera.zoomRange.upperBound)
        #expect(RoomCamera(yawDegrees: -190, pitchDegrees: -5, zoom: 0).yawDegrees == 170)
        #expect(RoomCamera(yawDegrees: 0, pitchDegrees: -5).pitchDegrees == RoomCamera.pitchRange.lowerBound)
        let odd = RoomCamera(yawDegrees: .nan, pitchDegrees: .infinity, zoom: .nan)
        #expect(odd.yawDegrees == 0 && odd.zoom == 1 && odd.pitchDegrees.isFinite)
        #expect(RoomCamera.plan.isPlan && !RoomCamera.threeQuarter.isPlan)
    }

    @Test("Dragging orbits: the room turns with the pointer, dragging down looks from higher, and an orbit never ends straight down")
    func orbit() {
        let start = RoomCamera.threeQuarter
        let turned = start.orbited(dx: 50, dy: 0)
        #expect(turned.yawDegrees == start.yawDegrees - 20 && turned.pitchDegrees == start.pitchDegrees)
        #expect(start.orbited(dx: 0, dy: 25).pitchDegrees == start.pitchDegrees + 10)
        #expect(start.orbited(dx: 0, dy: 10_000).pitchDegrees == RoomCamera.steepestOrbit)
        #expect(start.orbited(dx: 0, dy: -10_000).pitchDegrees == RoomCamera.pitchRange.lowerBound)
        let fromPlan = RoomCamera.plan.orbited(dx: 0, dy: -10)
        #expect(!fromPlan.isPlan && fromPlan.pitchDegrees == 81)
        #expect(start.orbited(dx: .nan, dy: 1) == start)
        #expect(start.zoomed(by: 2).zoom == 2 && start.zoomed(by: 0) == start && start.zoomed(by: 100).zoom == RoomCamera.zoomRange.upperBound)
    }

    @Test("An arrow key steps along the room's axis that points that way on the screen, whichever way the room is turned")
    func arrowKeys() {
        #expect(RoomCamera.plan.floorStep(right: 1, up: 0) == (1, 0) && RoomCamera.plan.floorStep(right: 0, up: 1) == (0, 1))
        #expect(RoomCamera.threeQuarter.floorStep(right: -1, up: 0) == (-1, 0), "a quarter turn or less keeps the axes")
        let side = RoomCamera.fromTheSide
        #expect(side.floorStep(right: 1, up: 0) == (0, 1), "from the right wall, right on the screen is towards the front")
        #expect(side.floorStep(right: 0, up: 1) == (-1, 0), "and away from the camera is towards the left wall")
        let front = RoomCamera(yawDegrees: 180, pitchDegrees: 30)
        #expect(front.floorStep(right: 1, up: 0) == (-1, 0) && front.floorStep(right: 0, up: -1) == (0, 1))
        #expect(RoomCamera.plan.floorStep(right: 0, up: 0) == (0, 0))
    }

    // MARK: Projection

    @Test("The plan is the drawing from above: to scale, the front at the top, and a speaker's height doesn't move it")
    func plan() {
        let l = layout(.plan)
        let origin = l.project(Point3D()), front = l.project(Point3D(x: 0, y: 1, z: 0)), right = l.project(Point3D(x: 1, y: 0, z: 0))
        #expect(abs(origin.x - 320) < 1e-9 && abs(origin.y - 240) < 1e-9)
        #expect(front.y < origin.y && right.x > origin.x)
        #expect(abs((right.x - origin.x) - (origin.y - front.y)) < 1e-9 && abs((right.x - origin.x) - l.scale) < 1e-9)
        let raised = l.project(Point3D(x: 1, y: 0, z: 2))
        #expect(abs(raised.x - right.x) < 1e-9 && abs(raised.y - right.y) < 1e-9 && raised.depth > right.depth)
        for x in [-3.0, 3.0] {
            for y in [-2.0, 2.0] {
                let p = l.project(Point3D(x: x, y: y, z: 0))
                #expect(p.x >= 0 && p.x <= 640 && p.y >= 0 && p.y <= 480)
            }
        }
    }

    @Test("From any side the whole room is inside the view, higher is up the screen, and nearer is drawn larger and later")
    func perspective() {
        for camera in [RoomCamera.threeQuarter, .fromBehind, .fromTheSide, RoomCamera(yawDegrees: 140, pitchDegrees: 55), RoomCamera(yawDegrees: -100, pitchDegrees: 85)] {
            let l = layout(camera)
            for x in [-3.0, 3.0] {
                for y in [-2.0, 2.0] {
                    for z in [0.0, 2.6] {
                        let p = l.project(Point3D(x: x, y: y, z: z))
                        #expect(p.x >= -1e-6 && p.x <= 640 + 1e-6 && p.y >= -1e-6 && p.y <= 480 + 1e-6, "\(camera): \(p)")
                    }
                }
            }
            #expect(l.project(Point3D(x: 0, y: 0, z: 2)).y < l.project(Point3D(x: 0, y: 0, z: 0)).y)
        }
        let l = layout(.fromBehind)
        let near = l.project(Point3D(x: 0, y: -2, z: 1.3)), far = l.project(Point3D(x: 0, y: 2, z: 1.3))
        #expect(near.depth > far.depth && near.pointsPerMetre > far.pointsPerMetre)
        #expect(l.project(Point3D(x: 1, y: 0, z: 1.3)).x > l.project(Point3D(x: -1, y: 0, z: 1.3)).x, "from behind, the room's right is on the right")
        let side = layout(.fromTheSide)
        #expect(side.project(Point3D(x: 0, y: 1, z: 1.3)).x > side.project(Point3D(x: 0, y: -1, z: 1.3)).x, "from the right wall, the front of the room is on the right")
    }

    @Test("The point under the pointer is the point that was drawn there, on the floor and at a speaker's height")
    func roundTrip() throws {
        for camera in [RoomCamera.plan, .threeQuarter, RoomCamera(yawDegrees: 140, pitchDegrees: 55), RoomCamera(yawDegrees: -75, pitchDegrees: 20, zoom: 1.7)] {
            let l = layout(camera)
            for point in [Point3D(x: -1, y: 1.5, z: 0), Point3D(x: 2.2, y: -0.7, z: 1.2), Point3D(x: 0, y: 0, z: 2.6)] {
                let p = l.project(point)
                let back = try #require(l.roomPoint(viewX: p.x, viewY: p.y, height: point.z))
                #expect(abs(back.x - point.x) < 1e-6 && abs(back.y - point.y) < 1e-6, "\(camera) \(point): \(back)")
            }
        }
        #expect(layout(.threeQuarter).roomPoint(viewX: .nan, viewY: 0) == nil)
    }

    @Test("Dragging up raises a speaker by what a metre measures there; from above there is no height to drag")
    func heightDrag() throws {
        let l = layout(.fromBehind)
        let at = Point3D(x: 0, y: 0, z: 1)
        let perMetre = l.project(at).y - l.project(Point3D(x: 0, y: 0, z: 2)).y
        let change = try #require(l.heightChange(viewDY: -perMetre / 2, at: at))
        #expect(abs(change - 0.5) < 1e-9)
        #expect(layout(.plan).heightChange(viewDY: -10, at: at) == nil)
        #expect(layout(RoomCamera(yawDegrees: 0, pitchDegrees: 89)).heightChange(viewDY: -10, at: at) == nil)
    }

    @Test("The walls between the camera and the room are the ones drawn open; from above none is")
    func walls() {
        let behind = layout(.fromBehind)
        #expect(behind.isNear(.back) && !behind.isNear(.front) && !behind.isNear(.left) && !behind.isNear(.right))
        let quarter = layout(.threeQuarter)
        #expect(quarter.isNear(.back) && quarter.isNear(.left) && !quarter.isNear(.front) && !quarter.isNear(.right))
        #expect(Room3DLayout.Wall.allCases.allSatisfy { !layout(.plan).isNear($0) })
        let front = behind.corners(of: .front)
        #expect(front.count == 4 && front.allSatisfy { $0.y == 2 } && front.map(\.z) == [0, 0, 2.6, 2.6])
    }

    // MARK: Heights

    @Test("A speaker's height above the floor is the ears' height and its own above them; the ceiling is the room's or the usual one, never under a speaker")
    func heights() {
        let g = group()
        #expect(g.heightAboveFloor(of: g.speakers[0]) == 1.2)
        #expect(abs(g.heightAboveFloor(of: g.speakers[2]) - 2.6) < 1e-9)
        #expect(RoomCanvas.ceiling(of: g) == 2.6)
        #expect(abs(RoomCanvas.ceiling(of: group(room: RoomOutline(width: 6, depth: 4))) - 2.6) < 1e-9, "no height given: at least as high as the highest speaker")
        var low = group(room: nil)
        low.speakers.removeLast()
        #expect(RoomCanvas.ceiling(of: low) == RoomOutline.defaultHeight)
        #expect(RoomCanvas.seatPoint(in: g) == Point3D(x: 0, y: 0, z: 1.2))
    }

    @Test("Raising a speaker: between the floor and the ceiling, on a 5 cm grid, and level with the ears is saved as no height")
    func setHeight() {
        let g = group()
        let id = g.speakers[0].id
        #expect(RoomCanvas.setHeight(speaker: id, aboveFloor: 2.03, in: g).speakers[0].height == 0.85)
        #expect(RoomCanvas.setHeight(speaker: id, aboveFloor: 2.03, in: g, snap: false).speakers[0].height == 0.83)
        #expect(RoomCanvas.setHeight(speaker: id, aboveFloor: 9, in: g).speakers[0].height == 1.4, "the ceiling")
        #expect(RoomCanvas.setHeight(speaker: id, aboveFloor: -1, in: g).speakers[0].height == -1.2, "the floor")
        let raised = RoomCanvas.setHeight(speaker: id, aboveFloor: 2, in: g)
        #expect(RoomCanvas.setHeight(speaker: id, aboveFloor: 1.2, in: raised).speakers[0].height == nil)
        #expect(RoomCanvas.setHeight(speaker: id, aboveFloor: .nan, in: g) == g && RoomCanvas.setHeight(speaker: UUID(), aboveFloor: 1, in: g) == g)
        #expect(raised.isValid, "\(raised.issues)")
    }

    @Test("Moving the ears moves no speaker: each keeps its height above the floor")
    func earHeight() {
        let g = group()
        let lower = RoomCanvas.setEarHeight(1.0, in: g)
        #expect(lower.listener.earHeight == 1.0)
        for (before, after) in zip(g.speakers, lower.speakers) {
            #expect(abs(g.heightAboveFloor(of: before) - lower.heightAboveFloor(of: after)) < 1e-9)
        }
        #expect(lower.speakers[0].height == 0.2)
        let back = RoomCanvas.setEarHeight(1.2, in: lower)
        #expect(back.listener.earHeight == nil && back.speakers[0].height == nil && back == g)
        #expect(RoomCanvas.setEarHeight(9, in: g).listener.earHeight == 2.5)
        #expect(RoomCanvas.setEarHeight(.nan, in: g) == g)
    }

    // MARK: The room's size

    @Test("Giving the room a size keeps the other two, holds it to what a room can be, and brings everything inside")
    func setRoom() {
        let g = group()
        let narrow = RoomCanvas.setRoom(width: 1.6, in: g)
        #expect(narrow.room == RoomOutline(width: 1.6, depth: 4, height: 2.6))
        #expect(narrow.speakers[0].position.x == -0.8 && narrow.speakers[1].position.x == 0.8)
        let low = RoomCanvas.setRoom(height: 2.0, in: g)
        #expect(low.room?.height == 2.0 && abs(low.heightAboveFloor(of: low.speakers[2]) - 2.0) < 1e-9, "a ceiling speaker comes down with the ceiling")
        #expect(RoomCanvas.setRoom(height: 0.2, in: g).room?.height == RoomOutline.heightRange.lowerBound)
        #expect(RoomCanvas.setRoom(width: 900, depth: .nan, in: g).room == RoomOutline(width: 50, depth: 4, height: 2.6))
        let drawn = RoomCanvas.setRoom(depth: 5, in: group(room: nil))
        #expect(drawn.room?.width == 4 && drawn.room?.depth == 5 && drawn.room?.height == nil, "a room that was never sized takes the size it was drawn at")
        #expect(narrow.isValid && low.isValid, "\(narrow.issues) \(low.issues)")
    }

    @Test("Two speakers brought to the same wall don't land on each other")
    func setRoomKeepsApart() {
        var g = group()
        g.speakers[0].position = Point2D(x: 2, y: 1.5)
        g.speakers[1].position = Point2D(x: 2.5, y: 1.5)
        let narrow = RoomCanvas.setRoom(width: 2, in: g)
        #expect(narrow.speakers[0].position != narrow.speakers[1].position)
        #expect(narrow.isValid, "\(narrow.issues)")
    }

    // MARK: The listening area

    @Test("The listening area is the whole floor until it is given, and stays inside the room")
    func listeningArea() {
        let g = group()
        #expect(RoomCanvas.listeningArea(of: g) == ListeningArea(center: Point2D(), width: 6, depth: 4))
        let sized = RoomCanvas.sizeListeningArea(width: 3, depth: 2, in: g)
        #expect(sized.listeningArea == ListeningArea(center: Point2D(), width: 3, depth: 2))
        let moved = RoomCanvas.moveListeningArea(to: Point2D(x: 9, y: -0.44), in: sized)
        #expect(moved.listeningArea == ListeningArea(center: Point2D(x: 1.5, y: -0.4), width: 3, depth: 2))
        #expect(RoomCanvas.sizeListeningArea(width: 99, depth: 99, in: moved).listeningArea == nil, "as large as the floor is the whole room")
        #expect(RoomCanvas.sizeListeningArea(width: 0, in: sized).listeningArea?.width == ListeningArea.smallest)
        let smaller = RoomCanvas.setRoom(width: 2, in: moved)
        #expect(smaller.listeningArea == ListeningArea(center: Point2D(x: 0, y: -0.4), width: 2, depth: 2), "a smaller room holds it")
        #expect(moved.isValid && smaller.isValid)
    }

    // MARK: Saved groups

    @Test("A group saved before the room had a height reads as it did, and the new fields come back as they were saved")
    func coding() throws {
        var old = group(room: RoomOutline(width: 6, depth: 4))
        old.speakers[2].height = nil
        let data = try SpeakerGroupCoding.encode(old)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("earHeight") && !text.contains("listeningArea") && !text.contains("\"height\""), "nothing new is written until it is set")
        #expect(try SpeakerGroupCoding.decode(data) == old)

        var new = group()
        new.listener.earHeight = 1.05
        new.listeningArea = ListeningArea(center: Point2D(x: 0.5, y: 0), width: 3, depth: 2)
        new.roomRender = RoomRenderSettings()
        let read = try SpeakerGroupCoding.decode(try SpeakerGroupCoding.encode(new))
        #expect(read == new && read.room?.height == 2.6 && read.listener.ears == 1.05)
    }

    @Test("A height, an ear height or a listening area that isn't one is an issue")
    func validation() {
        var g = group()
        #expect(g.isValid, "\(g.issues)")
        g.room?.height = -1
        #expect(g.issues == [.roomInvalid])
        g.room?.height = 2.6
        g.listener.earHeight = .nan
        #expect(g.issues == [.listenerInvalid])
        g.listener.earHeight = nil
        g.listeningArea = ListeningArea(center: Point2D(), width: 0, depth: 2)
        #expect(g.issues == [.roomInvalid])
    }
}
