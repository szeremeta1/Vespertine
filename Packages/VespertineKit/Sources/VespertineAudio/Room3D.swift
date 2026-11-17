//
// Vespertine: speaker groups: the room in three dimensions. The camera that orbits it, where a point of the room lands on the
// screen and which point of the room is under the pointer, which walls stand between the camera and the room, and the room's
// third dimension itself: its ceiling, the ears' height, each speaker's height above the floor, and the part of the floor people
// listen in when the group fills the room. Plain data; the view is a thin layer.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The room is the box `RoomCanvas` draws from above with a height: x to the right, y towards the front, z up from the floor, in
// metres, centred on the origin across the floor. A speaker's saved `height` stays what it was (metres above the ears); what is
// shown and typed is the height above the floor.
//

import Foundation

public struct Point3D: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(_ floor: Point2D, z: Double) {
        self.init(x: floor.x, y: floor.y, z: z)
    }

    public var floor: Point2D { Point2D(x: x, y: y) }

    func dot(_ o: Point3D) -> Double { x * o.x + y * o.y + z * o.z }
    func plus(_ o: Point3D, times k: Double = 1) -> Point3D { Point3D(x: x + o.x * k, y: y + o.y * k, z: z + o.z * k) }
    func minus(_ o: Point3D) -> Point3D { Point3D(x: x - o.x, y: y - o.y, z: z - o.z) }
}

/// Where the room is looked at from: around it (yaw), from how high (pitch), and how close.
public struct RoomCamera: Hashable, Sendable {
    /// The lowest the camera goes is a little above the floor; 90° is straight down, the plan.
    public static let pitchRange: ClosedRange<Double> = 8...90
    /// The steepest an orbit goes. Straight down is only reached by choosing the plan.
    public static let steepestOrbit = 85.0
    public static let zoomRange: ClosedRange<Double> = 0.5...4
    /// Degrees the camera turns for a point the pointer is dragged.
    public static let degreesPerPoint = 0.4

    /// 0°: from behind the back wall, the front of the room at the top. Positive: the camera moves to the room's right.
    public var yawDegrees: Double
    /// 90°: from straight above. Lower: nearer the floor.
    public var pitchDegrees: Double
    /// 1: the room fills the view.
    public var zoom: Double

    public init(yawDegrees: Double, pitchDegrees: Double, zoom: Double = 1) {
        var yaw = yawDegrees.isFinite ? yawDegrees.truncatingRemainder(dividingBy: 360) : 0
        if yaw > 180 { yaw -= 360 } else if yaw <= -180 { yaw += 360 }
        self.yawDegrees = yaw
        self.pitchDegrees = pitchDegrees.isFinite ? min(max(pitchDegrees, Self.pitchRange.lowerBound), Self.pitchRange.upperBound) : 90
        self.zoom = zoom.isFinite ? min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound) : 1
    }

    /// From straight above, as the room was always drawn.
    public static let plan = RoomCamera(yawDegrees: 0, pitchDegrees: 90)
    /// From behind the seat's left shoulder and above: the view a room opens in.
    public static let threeQuarter = RoomCamera(yawDegrees: -28, pitchDegrees: 30)
    /// From the back of the room at standing height, facing the front wall.
    public static let fromBehind = RoomCamera(yawDegrees: 0, pitchDegrees: 8)
    /// From the right wall, facing the left one.
    public static let fromTheSide = RoomCamera(yawDegrees: 90, pitchDegrees: 8)

    /// Straight down: drawn without perspective, so the plan is to scale everywhere.
    public var isPlan: Bool { pitchDegrees >= 89.999 }

    /// The camera after the pointer was dragged by (`dx`, `dy`) points across the room: the room turns with the pointer, and
    /// dragging down looks from higher up. An orbit never ends straight down.
    public func orbited(dx: Double, dy: Double) -> RoomCamera {
        guard dx.isFinite, dy.isFinite else { return self }
        let pitch = min(max(min(pitchDegrees, Self.steepestOrbit) + dy * Self.degreesPerPoint, Self.pitchRange.lowerBound), Self.steepestOrbit)
        return RoomCamera(yawDegrees: yawDegrees - dx * Self.degreesPerPoint, pitchDegrees: pitch, zoom: zoom)
    }

    /// An arrow key as a step across the floor: the room's axis that points most nearly that way on the screen. `right` and
    /// `up` are the key's direction on the screen (-1, 0 or 1); the answer is the step along the room's x and y.
    public func floorStep(right: Double, up: Double) -> (dx: Double, dy: Double) {
        let yaw = yawDegrees * .pi / 180
        // The screen's right and up, laid on the floor.
        let x = right * cos(yaw) - up * sin(yaw), y = right * sin(yaw) + up * cos(yaw)
        if abs(x) < 1e-9, abs(y) < 1e-9 { return (0, 0) }
        return abs(x) >= abs(y) ? (x < 0 ? -1 : 1, 0) : (0, y < 0 ? -1 : 1)
    }

    public func zoomed(by factor: Double) -> RoomCamera {
        guard factor.isFinite, factor > 0 else { return self }
        return RoomCamera(yawDegrees: yawDegrees, pitchDegrees: pitchDegrees, zoom: zoom * factor)
    }
}

/// Where the room is on the screen, seen through a camera.
public struct Room3DLayout: Equatable, Sendable {
    public enum Wall: CaseIterable, Sendable { case front, back, left, right }

    public struct Projected: Equatable, Sendable {
        public var x: Double
        public var y: Double
        /// Metres towards the camera from the middle of the room: the larger, the nearer. What is nearer is drawn later.
        public var depth: Double
        /// How large a metre is drawn at this point, in points.
        public var pointsPerMetre: Double
    }

    public let roomWidth: Double
    public let roomDepth: Double
    public let roomHeight: Double
    public let camera: RoomCamera
    public let viewWidth: Double
    public let viewHeight: Double
    /// Points per metre at the middle of the room.
    public private(set) var scale = 1.0
    private var centerX = 0.0
    private var centerY = 0.0
    private let right: Point3D
    private let up: Point3D
    private let toward: Point3D
    private let target: Point3D
    /// How far the camera is from the middle of the room; nil for the plan, which has no perspective.
    private let distance: Double?

    /// How far the camera stands back, in room diagonals: near enough for depth to read, far enough not to distort.
    static let standBack = 2.4

    public init(group: SpeakerGroup, camera: RoomCamera, viewWidth: Double, viewHeight: Double, margin: Double = 28) {
        let room = RoomCanvas.room(of: group)
        self.init(roomWidth: room.width, roomDepth: room.depth, roomHeight: RoomCanvas.ceiling(of: group), camera: camera,
                  viewWidth: viewWidth, viewHeight: viewHeight, margin: margin)
    }

    public init(roomWidth: Double, roomDepth: Double, roomHeight: Double, camera: RoomCamera, viewWidth: Double, viewHeight: Double,
                margin: Double = 28) {
        self.roomWidth = roomWidth
        self.roomDepth = roomDepth
        self.roomHeight = roomHeight
        self.camera = camera
        self.viewWidth = viewWidth
        self.viewHeight = viewHeight
        let yaw = camera.yawDegrees * .pi / 180, pitch = camera.pitchDegrees * .pi / 180
        toward = Point3D(x: sin(yaw) * cos(pitch), y: -cos(yaw) * cos(pitch), z: sin(pitch))
        right = Point3D(x: cos(yaw), y: sin(yaw), z: 0)
        up = Point3D(x: -sin(yaw) * sin(pitch), y: cos(yaw) * sin(pitch), z: cos(pitch))
        target = Point3D(x: 0, y: 0, z: roomHeight / 2)
        let diagonal = (roomWidth * roomWidth + roomDepth * roomDepth + roomHeight * roomHeight).squareRoot()
        distance = camera.isPlan ? nil : max(diagonal, 1) * Self.standBack

        // The box, fitted to the view: its eight corners at one point a metre, then scaled and centred. The plan fits the floor
        // alone, so it is the drawing from above it always was.
        let heights = camera.isPlan ? [0.0] : [0.0, roomHeight]
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for x in [-roomWidth / 2, roomWidth / 2] {
            for y in [-roomDepth / 2, roomDepth / 2] {
                for z in heights {
                    let p = unit(Point3D(x: x, y: y, z: z))
                    minX = min(minX, p.x); maxX = max(maxX, p.x)
                    minY = min(minY, p.y); maxY = max(maxY, p.y)
                }
            }
        }
        let fit = max(min((viewWidth - 2 * margin) / max(maxX - minX, 1e-9), (viewHeight - 2 * margin) / max(maxY - minY, 1e-9)), 1)
        scale = fit * camera.zoom
        centerX = viewWidth / 2 - scale * (minX + maxX) / 2
        centerY = viewHeight / 2 + scale * (minY + maxY) / 2
    }

    /// The direction from the middle of the room to the camera: what a face must be turned towards to be seen.
    public var towardCamera: Point3D { toward }

    /// A point as the camera sees it, a metre a unit: across, up, and how much larger for being nearer.
    private func unit(_ point: Point3D) -> (x: Double, y: Double, depth: Double, size: Double) {
        let v = point.minus(target)
        let depth = v.dot(toward)
        let size = distance.map { $0 / max($0 - depth, $0 * 0.05) } ?? 1
        return (v.dot(right) * size, v.dot(up) * size, depth, size)
    }

    public func project(_ point: Point3D) -> Projected {
        let p = unit(point)
        return Projected(x: centerX + scale * p.x, y: centerY - scale * p.y, depth: p.depth, pointsPerMetre: scale * p.size)
    }

    /// The point of the room under a point of the view, on the level `height` metres above the floor; nil when the camera looks
    /// along that level (it never crosses it) or the level is behind the camera.
    public func roomPoint(viewX: Double, viewY: Double, height: Double = 0) -> Point2D? {
        guard viewX.isFinite, viewY.isFinite, height.isFinite else { return nil }
        let across = (viewX - centerX) / scale, above = (centerY - viewY) / scale
        // The point of the plane through the middle of the room that is drawn there, and the line of sight through it.
        let through = target.plus(right, times: across).plus(up, times: above)
        let origin: Point3D, direction: Point3D
        if let distance {
            origin = target.plus(toward, times: distance)
            direction = through.minus(origin)
        } else {
            origin = through
            direction = Point3D(x: -toward.x, y: -toward.y, z: -toward.z)
        }
        guard abs(direction.z) > 1e-9 else { return nil }
        let t = (height - origin.z) / direction.z
        guard t.isFinite, distance == nil || t > 0 else { return nil }
        let hit = origin.plus(direction, times: t)
        return hit.floor.isFinite ? hit.floor : nil
    }

    /// How many metres higher something at `point` is after the pointer moved `viewDY` points down the screen (up is negative);
    /// nil from straight above and from so nearly above that a metre of height is a few points.
    public func heightChange(viewDY: Double, at point: Point3D) -> Double? {
        let perMetre = project(point).y - project(Point3D(x: point.x, y: point.y, z: point.z + 1)).y
        guard perMetre >= 12, viewDY.isFinite else { return nil }
        return -viewDY / perMetre
    }

    /// A wall that stands between the camera and the room: drawn open, so the room can be seen into.
    public func isNear(_ wall: Wall) -> Bool {
        guard !camera.isPlan else { return false }
        let outward: Point3D = switch wall {
        case .front: Point3D(x: 0, y: 1, z: 0)
        case .back: Point3D(x: 0, y: -1, z: 0)
        case .left: Point3D(x: -1, y: 0, z: 0)
        case .right: Point3D(x: 1, y: 0, z: 0)
        }
        return outward.dot(toward) > 1e-9
    }

    /// The corners of a wall, around it: floor, floor, ceiling, ceiling.
    public func corners(of wall: Wall) -> [Point3D] {
        let w = roomWidth / 2, d = roomDepth / 2
        let (a, b): (Point2D, Point2D) = switch wall {
        case .front: (Point2D(x: -w, y: d), Point2D(x: w, y: d))
        case .back: (Point2D(x: w, y: -d), Point2D(x: -w, y: -d))
        case .left: (Point2D(x: -w, y: -d), Point2D(x: -w, y: d))
        case .right: (Point2D(x: w, y: d), Point2D(x: w, y: -d))
        }
        return [Point3D(a, z: 0), Point3D(b, z: 0), Point3D(b, z: roomHeight), Point3D(a, z: roomHeight)]
    }
}

extension RoomCanvas {
    public static let roomSizeRange: ClosedRange<Double> = 1...50
    public static let heightGrid = 0.05

    /// The ceiling as drawn: the room's, or the usual one, and never under a speaker or the ears.
    public static func ceiling(of group: SpeakerGroup) -> Double {
        if let height = group.room?.height, height > 0, height.isFinite { return height }
        let tallest = group.speakers.map { group.heightAboveFloor(of: $0) }.filter(\.isFinite).max() ?? 0
        return max(RoomOutline.defaultHeight, tallest, group.listener.ears.isFinite ? group.listener.ears : 0)
    }

    public static func point(of speaker: SpeakerGroup.Speaker, in group: SpeakerGroup) -> Point3D {
        Point3D(speaker.position, z: min(max(group.heightAboveFloor(of: speaker), 0), ceiling(of: group)))
    }

    /// The listener's ears.
    public static func seatPoint(in group: SpeakerGroup) -> Point3D {
        Point3D(group.listener.position, z: min(max(group.listener.ears, 0), ceiling(of: group)))
    }

    private static func onHeightGrid(_ v: Double) -> Double { (v / heightGrid).rounded() * heightGrid }
    private static func tidy(_ v: Double) -> Double { let r = (v * 1000).rounded() / 1000; return r == 0 ? 0 : r }

    /// A speaker raised or lowered to `metres` above the floor: between the floor and the ceiling, on a 5 cm grid (`snap`). A
    /// speaker level with the ears is saved as it always was, with no height of its own.
    public static func setHeight(speaker id: UUID, aboveFloor metres: Double, in group: SpeakerGroup, snap: Bool = true) -> SpeakerGroup {
        guard let index = group.speakers.firstIndex(where: { $0.id == id }), metres.isFinite else { return group }
        let held = min(max(snap ? onHeightGrid(metres) : metres, 0), ceiling(of: group))
        let above = tidy(held - group.listener.ears)
        var result = group
        result.speakers[index].height = above == 0 ? nil : above
        return result
    }

    /// The ears moved to `metres` above the floor (a lower sofa, a standing desk). No speaker moves: each keeps its height
    /// above the floor, so its height above the ears changes by as much.
    public static func setEarHeight(_ metres: Double, in group: SpeakerGroup) -> SpeakerGroup {
        guard metres.isFinite else { return group }
        let range = Listener.earHeightRange
        let ears = tidy(min(max(metres, range.lowerBound), min(range.upperBound, ceiling(of: group))))
        guard ears != group.listener.ears else { return group }
        var result = group
        for index in result.speakers.indices {
            let above = tidy(group.heightAboveFloor(of: group.speakers[index]) - ears)
            result.speakers[index].height = above == 0 ? nil : above
        }
        result.listener.earHeight = ears == Listener.defaultEarHeight ? nil : ears
        return result
    }

    /// The room given a size: any of the three that is nil stays as drawn. Held to what a room can be, never lower than the
    /// ears, and every speaker, the seat and the listening area are brought inside it.
    public static func setRoom(width: Double? = nil, depth: Double? = nil, height: Double? = nil, in group: SpeakerGroup) -> SpeakerGroup {
        let drawn = room(of: group)
        func held(_ value: Double?, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            guard let value, value.isFinite else { return fallback }
            return tidy(min(max(value, range.lowerBound), range.upperBound))
        }
        var result = group
        var outline = RoomOutline(width: held(width, drawn.width, roomSizeRange), depth: held(depth, drawn.depth, roomSizeRange), height: group.room?.height)
        if height != nil {
            outline.height = max(held(height, ceiling(of: group), RoomOutline.heightRange), tidy(group.listener.ears))
        }
        result.room = outline
        let halfWidth = outline.width / 2, halfDepth = outline.depth / 2
        func inside(_ p: Point2D) -> Point2D { Point2D(x: min(max(p.x, -halfWidth), halfWidth), y: min(max(p.y, -halfDepth), halfDepth)) }
        result.listener.position = inside(result.listener.position)
        for index in result.speakers.indices {
            let speaker = result.speakers[index]
            guard speaker.position.isFinite else { continue }
            result.speakers[index].position = inside(speaker.position)
            // Under a lower ceiling, a speaker that stood above it hangs from it.
            if let top = outline.height, result.heightAboveFloor(of: speaker) > top {
                let above = tidy(top - result.listener.ears)
                result.speakers[index].height = above == 0 ? nil : above
            }
        }
        // Two things brought to the same wall may have landed on each other: move the later one off, as a drag would.
        for speaker in result.speakers where speaker.position.isFinite {
            result = move(speaker: speaker.id, to: speaker.position, in: result, snap: false)
        }
        if let area = result.listeningArea { result.listeningArea = fitted(area, in: result) }
        return result
    }

    // MARK: The listening area

    /// The listening area as drawn: the group's, held inside the room, or the whole floor.
    public static func listeningArea(of group: SpeakerGroup) -> ListeningArea {
        let r = room(of: group)
        guard let area = group.listeningArea else { return ListeningArea(center: Point2D(), width: r.width, depth: r.depth) }
        return fitted(area, in: group)
    }

    private static func fitted(_ area: ListeningArea, in group: SpeakerGroup) -> ListeningArea {
        let r = room(of: group)
        guard area.center.isFinite, area.width.isFinite, area.depth.isFinite else { return ListeningArea(center: Point2D(), width: r.width, depth: r.depth) }
        let width = min(max(area.width, min(ListeningArea.smallest, r.width)), r.width)
        let depth = min(max(area.depth, min(ListeningArea.smallest, r.depth)), r.depth)
        let x = min(max(area.center.x, -r.width / 2 + width / 2), r.width / 2 - width / 2)
        let y = min(max(area.center.y, -r.depth / 2 + depth / 2), r.depth / 2 - depth / 2)
        return ListeningArea(center: Point2D(x: tidy(x), y: tidy(y)), width: tidy(width), depth: tidy(depth))
    }

    /// The listening area moved so its centre is at `point`, staying inside the room, on the grid.
    public static func moveListeningArea(to point: Point2D, in group: SpeakerGroup, snap: Bool = true) -> SpeakerGroup {
        guard point.isFinite else { return group }
        var area = listeningArea(of: group)
        area.center = snap ? Point2D(x: (point.x * 10).rounded() / 10, y: (point.y * 10).rounded() / 10) : point
        var result = group
        result.listeningArea = fitted(area, in: group)
        return result
    }

    /// The listening area given a size, about its centre; either that is nil stays. An area as large as the floor is saved as
    /// none: the whole room.
    public static func sizeListeningArea(width: Double? = nil, depth: Double? = nil, in group: SpeakerGroup) -> SpeakerGroup {
        var area = listeningArea(of: group)
        if let width, width.isFinite { area.width = width }
        if let depth, depth.isFinite { area.depth = depth }
        let fit = fitted(area, in: group)
        let r = room(of: group)
        var result = group
        result.listeningArea = fit.width >= r.width - 1e-9 && fit.depth >= r.depth - 1e-9 ? nil : fit
        return result
    }
}
