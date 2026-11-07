//
// Vespertine — speaker groups: the room drawing. Between metres in the room and points on the screen, dragging a speaker or the seat
// (kept inside the room, on a 10 cm grid unless told otherwise, never on top of each other), turning the seat, nudging from the
// keyboard, snapping to the usual angles, feet or metres, and the sentence a screen reader says for a speaker. Plain data; the view
// is a thin layer.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The room is a rectangle centred on the origin, x to the right and y towards the front (the top of the drawing); angles are 0°
// towards +y and positive to the right, as the geometry has them.
//

import Foundation

public enum DistanceUnit: String, Codable, CaseIterable, Sendable {
    case metres, feet

    static let metresPerFoot = 0.3048

    /// The unit's number for a distance in metres.
    func value(_ metres: Double) -> Double { self == .feet ? metres / Self.metresPerFoot : metres }

    /// Metres from a number typed in this unit.
    public func metres(from value: Double) -> Double { self == .feet ? value * Self.metresPerFoot : value }

    private func number(_ metres: Double) -> String {
        let v = (value(metres) * 10).rounded() / 10
        return v == v.rounded() ? String(Int(v)) : String(v)
    }

    /// "2.1 m", "6.9 ft"
    public func format(_ metres: Double) -> String { "\(number(metres)) \(self == .feet ? "ft" : "m")" }

    /// "2.1 metres", "1 foot"
    public func spoken(_ metres: Double) -> String {
        let n = number(metres)
        switch self {
        case .metres: return n == "1" ? "1 metre" : "\(n) metres"
        case .feet: return n == "1" ? "1 foot" : "\(n) feet"
        }
    }
}

/// Where the room is on the screen.
public struct RoomCanvasLayout: Equatable, Sendable {
    public var roomWidth: Double
    public var roomDepth: Double
    public var viewWidth: Double
    public var viewHeight: Double
    public var margin: Double
    /// Points per metre, the same both ways.
    public var scale: Double

    public init(group: SpeakerGroup, viewWidth: Double, viewHeight: Double, margin: Double = 24) {
        let room = RoomCanvas.room(of: group)
        roomWidth = room.width
        roomDepth = room.depth
        self.viewWidth = viewWidth
        self.viewHeight = viewHeight
        self.margin = margin
        scale = max(min((viewWidth - 2 * margin) / room.width, (viewHeight - 2 * margin) / room.depth), 1)
    }

    public func viewPoint(_ point: Point2D) -> (x: Double, y: Double) {
        (viewWidth / 2 + point.x * scale, viewHeight / 2 - point.y * scale)
    }

    public func roomPoint(viewX: Double, viewY: Double) -> Point2D {
        Point2D(x: (viewX - viewWidth / 2) / scale, y: (viewHeight / 2 - viewY) / scale)
    }
}

public enum RoomCanvas {
    public static let grid = 0.1
    public static let bigStep = 0.5
    public static let turnStep = 5.0
    /// How far from its usual angle a speaker still snaps onto it.
    public static let snapWithin = 5.0

    /// The room as drawn, or one that holds every speaker and the seat with a metre to spare, at least 4 m each way.
    static func room(of group: SpeakerGroup) -> (width: Double, depth: Double) {
        if let room = group.room, room.width > 0, room.depth > 0 { return (room.width, room.depth) }
        let points = group.speakers.map(\.position) + [group.listener.position]
        let halfWidth = max(2, (points.map { abs($0.x) }.max() ?? 0) + 1)
        let halfDepth = max(2, (points.map { abs($0.y) }.max() ?? 0) + 1)
        return (2 * halfWidth, 2 * halfDepth)
    }

    private static func snapped(_ v: Double) -> Double { let s = (v * 10).rounded() / 10; return s == 0 ? 0 : s }

    private static func clamped(_ point: Point2D, in group: SpeakerGroup, snap: Bool) -> Point2D {
        let r = room(of: group)
        var x = snap ? snapped(point.x) : point.x, y = snap ? snapped(point.y) : point.y
        x = min(max(x, -r.width / 2), r.width / 2)
        y = min(max(y, -r.depth / 2), r.depth / 2)
        return Point2D(x: x, y: y)
    }

    /// The point itself, or the nearest free one up the room from it: not on the seat and not on another speaker (`ignoring` is the
    /// one being moved).
    private static func free(_ point: Point2D, in group: SpeakerGroup, ignoring: UUID?, seat: Bool) -> Point2D {
        var taken = group.speakers.filter { $0.id != ignoring }.map(\.position)
        if !seat { taken.append(group.listener.position) }
        var p = point
        let top = room(of: group).depth / 2
        var tries = 0
        while taken.contains(p), tries < 200 {
            p = Point2D(x: p.x, y: (p.y + grid <= top ? p.y + grid : p.y - 2 * grid))
            p.y = (p.y * 10).rounded() / 10
            tries += 1
        }
        return p
    }

    /// A speaker dragged to `point`: inside the room, on the grid (`snap`), and not on the seat or another speaker.
    public static func move(speaker id: UUID, to point: Point2D, in group: SpeakerGroup, snap: Bool = true) -> SpeakerGroup {
        guard let index = group.speakers.firstIndex(where: { $0.id == id }), point.isFinite else { return group }
        var result = group
        result.speakers[index].position = free(clamped(point, in: group, snap: snap), in: group, ignoring: id, seat: false)
        return result
    }

    /// The seat dragged to `point`: inside the room, on the grid, and not on a speaker.
    public static func moveListener(to point: Point2D, in group: SpeakerGroup, snap: Bool = true) -> SpeakerGroup {
        guard point.isFinite else { return group }
        var result = group
        var seat = clamped(point, in: group, snap: snap)
        let speakers = Set(group.speakers.map(\.position))
        var tries = 0
        while speakers.contains(seat), tries < 200 {
            seat = Point2D(x: seat.x, y: (seat.y * 10 - 1).rounded() / 10)
            tries += 1
        }
        result.listener.position = seat
        return result
    }

    /// The seat turned to face `point`, in steps of 5°. Nothing to face at the seat itself.
    public static func turnListener(toward point: Point2D, in group: SpeakerGroup) -> SpeakerGroup {
        let dx = point.x - group.listener.position.x, dy = point.y - group.listener.position.y
        guard dx.isFinite, dy.isFinite, (dx != 0 || dy != 0) else { return group }
        var degrees = (atan2(dx, dy) * 180 / .pi / turnStep).rounded() * turnStep
        if degrees == -180 { degrees = 180 }
        var result = group
        result.listener.facingDegrees = degrees
        return result
    }

    /// An arrow key: 10 cm a step, 50 cm with the big step. `dx` and `dy` are the direction (-1, 0 or 1).
    public static func nudge(speaker id: UUID, dx: Double, dy: Double, large: Bool, in group: SpeakerGroup) -> SpeakerGroup {
        guard let speaker = group.speakers.first(where: { $0.id == id }) else { return group }
        let step = large ? bigStep : grid
        return move(speaker: id, to: Point2D(x: speaker.position.x + dx * step, y: speaker.position.y + dy * step), in: group)
    }

    /// A speaker within 5° of the angle its role usually has (from where the seat faces) moves onto it, at the same distance.
    public static func snapToUsualAngle(speaker id: UUID, in group: SpeakerGroup) -> SpeakerGroup {
        guard let index = group.speakers.firstIndex(where: { $0.id == id }), let usual = group.speakers[index].role.defaultAzimuth else { return group }
        let speaker = group.speakers[index]
        let seat = group.listener.position
        let distance = SpeakerGeometry.distance(from: group.listener, to: speaker.position)
        let azimuth = SpeakerGeometry.azimuth(from: group.listener, to: speaker.position)
        guard distance > 0, abs(azimuth - usual) <= snapWithin, azimuth != usual else { return group }
        let bearing = (group.listener.facingDegrees + usual) * .pi / 180
        var result = group
        result.speakers[index].position = Point2D(x: seat.x + distance * sin(bearing), y: seat.y + distance * cos(bearing))
        return result
    }

    // MARK: Screen reader

    /// "Front left, 2.1 metres, 32 degrees left"
    public static func describe(speaker: SpeakerGroup.Speaker, in group: SpeakerGroup, unit: DistanceUnit) -> String {
        let distance = SpeakerGeometry.distance(from: group.listener, to: speaker.position)
        let azimuth = SpeakerGeometry.azimuth(from: group.listener, to: speaker.position)
        return "\(speaker.role.plainName), \(unit.spoken(distance)), \(direction(azimuth))"
    }

    public static func describe(listener group: SpeakerGroup, unit: DistanceUnit) -> String {
        let facing = group.listener.facingDegrees
        return "Listening seat, facing " + (abs(facing) < 0.5 ? "the front of the room" : direction(facing))
    }

    private static func direction(_ azimuth: Double) -> String {
        let a = abs(azimuth).rounded()
        if a < 1 { return "straight ahead" }
        if a >= 180 { return "directly behind" }
        return "\(Int(a)) degrees \(azimuth < 0 ? "left" : "right")"
    }
}

extension SpeakerRole {
    /// The role in plain words, for the grid and the screen reader.
    public var plainName: String {
        switch self {
        case .frontLeft: "Front left"
        case .frontRight: "Front right"
        case .center: "Center"
        case .lfe: "Subwoofer (LFE)"
        case .sideLeft: "Side left"
        case .sideRight: "Side right"
        case .backLeft: "Back left"
        case .backRight: "Back right"
        case .backCenter: "Back center"
        case .wideLeft: "Wide left"
        case .wideRight: "Wide right"
        case .topFrontLeft: "Top front left"
        case .topFrontRight: "Top front right"
        case .topMiddleLeft: "Top middle left"
        case .topMiddleRight: "Top middle right"
        case .topBackLeft: "Top back left"
        case .topBackRight: "Top back right"
        }
    }
}
