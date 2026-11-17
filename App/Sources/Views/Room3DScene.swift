//
// Vespertine: Settings › Speaker Groups › Edit: what the room in three dimensions draws. The floor and its metre grid, the walls
// behind the room (the ones in front of it are left open), the ceiling's outline, each speaker as a cabinet on its stem in its
// DAC's colour, facing the seat, the seat with the way it faces, and the part of the floor people listen in when the group
// fills the room. Farther things first, so nearer ones cover them.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import VespertineAudio

struct Room3DScene {
    let group: SpeakerGroup
    let layout: Room3DLayout
    let selected: UUID?
    let fillsRoom: Bool
    let unit: DistanceUnit

    private static let floorNear = Color(hex: 0x2A2A31), floorFar = Color(hex: 0x1D1D22)
    private static let wallLow = Color(hex: 0x202026), wallHigh = Color(hex: 0x141417)

    /// The tip of the seat's arrow: on the floor, 0.8 m from the seat towards where it faces. The handle that turns it.
    static func arrowTip(of group: SpeakerGroup) -> Point3D {
        let facing = group.listener.facingDegrees * .pi / 180
        return Point3D(x: group.listener.position.x + 0.8 * sin(facing), y: group.listener.position.y + 0.8 * cos(facing), z: 0)
    }

    /// The listening area's corner that sizes it: right and back.
    static func sizingCorner(of area: ListeningArea) -> Point2D {
        Point2D(x: area.center.x + area.width / 2, y: area.center.y - area.depth / 2)
    }

    private func at(_ point: Point3D) -> CGPoint {
        let p = layout.project(point)
        return CGPoint(x: p.x, y: p.y)
    }

    private func path(_ points: [Point3D], closed: Bool = true) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: at(first))
            for point in points.dropFirst() { path.addLine(to: at(point)) }
            if closed { path.closeSubpath() }
        }
    }

    private func line(_ a: Point3D, _ b: Point3D) -> Path { path([a, b], closed: false) }

    func draw(in context: inout GraphicsContext) {
        let w = layout.roomWidth / 2, d = layout.roomDepth / 2, top = layout.roomHeight
        let far = Room3DLayout.Wall.allCases.filter { !layout.isNear($0) }
        let near = Room3DLayout.Wall.allCases.filter { layout.isNear($0) }
        let plan = layout.camera.isPlan

        // The walls behind the room, then the floor in front of them.
        if !plan {
            for wall in far {
                let corners = layout.corners(of: wall)
                let shape = path(corners)
                let low = at(Point3D(x: (corners[0].x + corners[1].x) / 2, y: (corners[0].y + corners[1].y) / 2, z: 0))
                let high = at(Point3D(x: (corners[0].x + corners[1].x) / 2, y: (corners[0].y + corners[1].y) / 2, z: top))
                context.fill(shape, with: .linearGradient(Gradient(colors: [Self.wallLow, Self.wallHigh]), startPoint: low, endPoint: high))
                context.stroke(shape, with: .color(Palette.text3.opacity(0.45)), lineWidth: 1)
            }
        }
        let floor = [Point3D(x: -w, y: -d), Point3D(x: w, y: -d), Point3D(x: w, y: d), Point3D(x: -w, y: d)]
        context.fill(path(floor), with: .linearGradient(Gradient(colors: [Self.floorNear, Self.floorFar]), startPoint: at(Point3D(x: 0, y: -d)), endPoint: at(Point3D(x: 0, y: d))))
        // A line every metre from the middle of the room (every 3 feet would not line up with the 10 cm grid).
        var metre = -Double(Int(w))
        while metre <= w {
            context.stroke(line(Point3D(x: metre, y: -d), Point3D(x: metre, y: d)), with: .color(Palette.text.opacity(metre == 0 ? 0.16 : 0.07)), lineWidth: 0.5)
            metre += 1
        }
        metre = -Double(Int(d))
        while metre <= d {
            context.stroke(line(Point3D(x: -w, y: metre), Point3D(x: w, y: metre)), with: .color(Palette.text.opacity(metre == 0 ? 0.16 : 0.07)), lineWidth: 0.5)
            metre += 1
        }
        context.stroke(path(floor), with: .color(Palette.text3.opacity(0.9)), lineWidth: 1)
        // The front of the room, named on its wall, or along the floor's front edge where the wall is open or seen from above.
        let frontOpen = plan || layout.isNear(.front)
        let label = context.resolve(Text("front").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.text3))
        context.draw(label, at: frontOpen ? CGPoint(x: at(Point3D(x: 0, y: d)).x, y: at(Point3D(x: 0, y: d)).y + (plan ? 9 : -8))
                                          : at(Point3D(x: 0, y: d, z: min(top - 0.25, top * 0.86))))

        if fillsRoom { drawListeningArea(in: &context) }

        // The seat's place on the floor and the speakers' shadows lie under everything that stands.
        drawSeatFloor(in: &context)
        for speaker in group.speakers where speaker.position.isFinite {
            let p = RoomCanvas.point(of: speaker, in: group)
            context.fill(disc(at: Point3D(p.floor, z: 0), radius: Self.size(of: speaker.role).width * 0.62), with: .color(.black.opacity(0.35)))
        }

        // What stands in the room, the farthest first.
        var standing: [(depth: Double, draw: (inout GraphicsContext) -> Void)] = []
        for speaker in group.speakers where speaker.position.isFinite {
            let depth = layout.project(RoomCanvas.point(of: speaker, in: group)).depth
            standing.append((depth, { context in drawSpeaker(speaker, in: &context) }))
        }
        standing.append((layout.project(RoomCanvas.seatPoint(in: group)).depth, { context in drawSeat(in: &context) }))
        for item in standing.sorted(by: { $0.depth < $1.depth }) { item.draw(&context) }

        // The ceiling's outline and the open walls' edges, over everything, faintly: the room stays a room.
        if !plan {
            context.stroke(path(floor.map { Point3D($0.floor, z: top) }), with: .color(Palette.text3.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            for wall in near {
                let corners = layout.corners(of: wall)
                context.stroke(line(corners[0], corners[3]), with: .color(Palette.text3.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                context.stroke(line(corners[1], corners[2]), with: .color(Palette.text3.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
        }
    }

    // MARK: The floor

    /// A circle lying on a level, as the camera sees it.
    private func disc(at centre: Point3D, radius: Double, from: Double = 0, to: Double = 2 * .pi, wedge: Bool = false) -> Path {
        var points: [Point3D] = wedge ? [centre] : []
        let steps = 28
        for i in 0...steps {
            let a = from + (to - from) * Double(i) / Double(steps)
            points.append(Point3D(x: centre.x + radius * sin(a), y: centre.y + radius * cos(a), z: centre.z))
        }
        return path(points)
    }

    private func drawListeningArea(in context: inout GraphicsContext) {
        let area = RoomCanvas.listeningArea(of: group)
        let x0 = area.center.x - area.width / 2, x1 = area.center.x + area.width / 2
        let y0 = area.center.y - area.depth / 2, y1 = area.center.y + area.depth / 2
        let shape = path([Point3D(x: x0, y: y0), Point3D(x: x1, y: y0), Point3D(x: x1, y: y1), Point3D(x: x0, y: y1)])
        context.fill(shape, with: .color(Palette.brass.opacity(0.16)))
        context.stroke(shape, with: .color(Palette.brass.opacity(0.85)), lineWidth: 1.5)
        // The grips: the middle moves it, the corner sizes it.
        let middle = at(Point3D(area.center, z: 0)), corner = at(Point3D(Self.sizingCorner(of: area), z: 0))
        context.stroke(Path(ellipseIn: CGRect(x: middle.x - 6, y: middle.y - 6, width: 12, height: 12)), with: .color(Palette.brass.opacity(0.85)), lineWidth: 1.5)
        context.stroke(Path { $0.move(to: CGPoint(x: middle.x - 3, y: middle.y)); $0.addLine(to: CGPoint(x: middle.x + 3, y: middle.y))
                              $0.move(to: CGPoint(x: middle.x, y: middle.y - 3)); $0.addLine(to: CGPoint(x: middle.x, y: middle.y + 3)) },
                       with: .color(Palette.brass.opacity(0.85)), lineWidth: 1.5)
        context.fill(Path(roundedRect: CGRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10), cornerRadius: 2), with: .color(Palette.brassHi))
    }

    private func drawSeatFloor(in context: inout GraphicsContext) {
        let seat = Point3D(group.listener.position, z: 0)
        let facing = group.listener.facingDegrees * .pi / 180
        let tint = fillsRoom ? Palette.text2 : Palette.brassHi
        context.fill(disc(at: seat, radius: 1.1, from: facing - .pi / 5, to: facing + .pi / 5, wedge: true), with: .color(tint.opacity(fillsRoom ? 0.07 : 0.12)))
        context.fill(disc(at: seat, radius: 0.28), with: .color(tint.opacity(0.22)))
        context.stroke(disc(at: seat, radius: 0.28), with: .color(tint.opacity(0.8)), lineWidth: 1)
        let tip = Self.arrowTip(of: group)
        context.stroke(line(seat, tip), with: .color(tint), lineWidth: 2)
        let end = at(tip)
        context.fill(Path(ellipseIn: CGRect(x: end.x - 5.5, y: end.y - 5.5, width: 11, height: 11)), with: .color(tint))
    }

    // MARK: What stands

    private func drawSeat(in context: inout GraphicsContext) {
        let ears = RoomCanvas.seatPoint(in: group)
        let tint = fillsRoom ? Palette.text2 : Palette.brassHi
        if !layout.camera.isPlan {
            context.stroke(line(Point3D(ears.floor, z: 0), ears), with: .color(tint.opacity(0.7)), lineWidth: 1.5)
        }
        let head = layout.project(ears)
        let radius = max(0.11 * head.pointsPerMetre, 6)
        let circle = Path(ellipseIn: CGRect(x: head.x - radius, y: head.y - radius, width: 2 * radius, height: 2 * radius))
        context.fill(circle, with: .radialGradient(Gradient(colors: [tint, tint.opacity(0.55)]), center: CGPoint(x: head.x - radius * 0.3, y: head.y - radius * 0.35),
                                                   startRadius: 0, endRadius: radius * 1.4))
        context.stroke(circle, with: .color(Palette.base.opacity(0.6)), lineWidth: 1)
    }

    /// A cabinet's width, depth and height in metres: a bookshelf speaker, a wide centre, a subwoofer's cube, a flat ceiling speaker.
    static func size(of role: SpeakerRole) -> (width: Double, depth: Double, height: Double) {
        switch role {
        case .lfe: (0.40, 0.40, 0.40)
        case .center: (0.50, 0.24, 0.20)
        case _ where role.isHeight: (0.30, 0.30, 0.10)
        default: (0.24, 0.26, 0.40)
        }
    }

    private func drawSpeaker(_ speaker: SpeakerGroup.Speaker, in context: inout GraphicsContext) {
        let member = group.members.firstIndex { $0.deviceUID == speaker.deviceUID } ?? 0
        let tint = Room3DView.color(ofMember: member)
        let chosen = selected == speaker.id
        let point = RoomCanvas.point(of: speaker, in: group)
        let size = Self.size(of: speaker.role)
        let top = layout.roomHeight
        // The cabinet is drawn around the speaker's point, and never through the floor or the ceiling.
        let middle = Point3D(point.floor, z: min(max(point.z, size.height / 2), max(top - size.height / 2, size.height / 2)))
        let seat = group.listener.position
        // It faces the seat; one that stands on the seat's own spot faces the front of the room's middle.
        let turn = (seat.x == point.x && seat.y == point.y) ? 0 : atan2(seat.x - point.x, seat.y - point.y)
        let ahead = Point3D(x: sin(turn), y: cos(turn), z: 0), across = Point3D(x: cos(turn), y: -sin(turn), z: 0), up = Point3D(x: 0, y: 0, z: 1)

        // The line of sound to the ears while one seat is listened from, and the stem to the floor (or from the ceiling).
        if !fillsRoom || chosen {
            context.stroke(line(point, RoomCanvas.seatPoint(in: group)), with: .color(tint.opacity(chosen ? 0.7 : 0.16)), style: StrokeStyle(lineWidth: chosen ? 1.5 : 1, dash: chosen ? [] : [2, 3]))
        }
        if !layout.camera.isPlan {
            if speaker.role.isHeight, top - point.z < 0.6 {
                // A ceiling speaker hangs from the ceiling, and a faint plumb line shows what on the floor it is above.
                context.stroke(line(Point3D(point.floor, z: top), middle), with: .color(Palette.text3.opacity(0.7)), lineWidth: 1)
                context.stroke(line(Point3D(point.floor, z: 0), Point3D(point.floor, z: middle.z - size.height / 2)), with: .color(tint.opacity(0.35)),
                               style: StrokeStyle(lineWidth: 1, dash: [1, 4]))
            } else if middle.z - size.height / 2 > 0.01 {
                context.stroke(line(Point3D(point.floor, z: 0), Point3D(point.floor, z: middle.z - size.height / 2)), with: .color(Palette.text3.opacity(0.8)), lineWidth: 1.5)
            }
        }

        func corner(_ a: Double, _ b: Double, _ c: Double) -> Point3D {
            middle.plus3(across, a * size.width / 2).plus3(ahead, b * size.depth / 2).plus3(up, c * size.height / 2)
        }
        // Each face: its outward direction, its corners, and whether it is the front (the one the sound leaves by).
        let faces: [(normal: Point3D, corners: [Point3D], front: Bool)] = [
            (ahead, [corner(-1, 1, -1), corner(1, 1, -1), corner(1, 1, 1), corner(-1, 1, 1)], !speaker.role.isHeight),
            (ahead.negated, [corner(1, -1, -1), corner(-1, -1, -1), corner(-1, -1, 1), corner(1, -1, 1)], false),
            (across, [corner(1, 1, -1), corner(1, -1, -1), corner(1, -1, 1), corner(1, 1, 1)], false),
            (across.negated, [corner(-1, -1, -1), corner(-1, 1, -1), corner(-1, 1, 1), corner(-1, -1, 1)], false),
            (up, [corner(-1, 1, 1), corner(1, 1, 1), corner(1, -1, 1), corner(-1, -1, 1)], false),
            (up.negated, [corner(-1, -1, -1), corner(1, -1, -1), corner(1, 1, -1), corner(-1, 1, -1)], speaker.role.isHeight),
        ]
        let toward = layout.towardCamera
        // The light comes from above the camera's left shoulder.
        let light = Point3D(x: -0.35, y: -0.45, z: 0.82)
        for face in faces {
            let facing = face.normal.x * toward.x + face.normal.y * toward.y + face.normal.z * toward.z
            guard facing > 1e-6 else { continue }
            let lit = max(face.normal.x * light.x + face.normal.y * light.y + face.normal.z * light.z, 0)
            let shape = path(face.corners)
            context.fill(shape, with: .color(face.front ? tint : Palette.raised))
            context.fill(shape, with: .color(.black.opacity(face.front ? 0.18 * (1 - lit) : 0.45 * (1 - lit))))
            if !face.front { context.fill(shape, with: .color(tint.opacity(0.14 + 0.10 * lit))) }
            context.stroke(shape, with: .color(chosen ? Palette.brassHi : tint.opacity(0.9)), lineWidth: chosen ? 1.5 : 0.75)
            if face.front {
                // The driver: a ring on the face the sound leaves by.
                let centre = face.corners.reduce(Point3D()) { $0.plus3($1, 0.25) }
                let p = layout.project(centre)
                let r = max(min(size.width, speaker.role.isHeight ? size.depth : size.height) * 0.28 * p.pointsPerMetre, 2)
                let squash = max(abs(facing), 0.25)
                context.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r * (speaker.role.isHeight ? squash : 1), width: 2 * r,
                                                      height: 2 * r * (speaker.role.isHeight ? squash : 1))),
                               with: .color(Palette.base.opacity(0.55)), lineWidth: 1.2)
            }
        }

        // The speaker's short name on a chip above it.
        let above = layout.project(Point3D(point.floor, z: middle.z + size.height / 2))
        let name = context.resolve(Text(verbatim: speaker.role.rawValue).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(chosen ? Palette.base : Palette.text))
        let measured = name.measure(in: CGSize(width: 80, height: 20))
        let chip = CGRect(x: above.x - measured.width / 2 - 5, y: above.y - measured.height - 9, width: measured.width + 10, height: measured.height + 4)
        context.fill(Path(roundedRect: chip, cornerRadius: 4), with: .color(chosen ? Palette.brassHi : Palette.base.opacity(0.82)))
        context.stroke(Path(roundedRect: chip, cornerRadius: 4), with: .color(tint.opacity(chosen ? 0 : 0.9)), lineWidth: 0.75)
        context.draw(name, at: CGPoint(x: chip.midX, y: chip.midY))
        if chosen {
            // Its distance from the ears, beside the line of sound.
            let ears = RoomCanvas.seatPoint(in: group)
            let length = ((point.x - ears.x) * (point.x - ears.x) + (point.y - ears.y) * (point.y - ears.y) + (point.z - ears.z) * (point.z - ears.z)).squareRoot()
            let half = at(Point3D(x: (point.x + ears.x) / 2, y: (point.y + ears.y) / 2, z: (point.z + ears.z) / 2))
            let text = context.resolve(Text(verbatim: unit.format(length)).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(Palette.text))
            let box = text.measure(in: CGSize(width: 90, height: 20))
            let plate = CGRect(x: half.x - box.width / 2 - 4, y: half.y - box.height / 2 - 2, width: box.width + 8, height: box.height + 4)
            context.fill(Path(roundedRect: plate, cornerRadius: 3), with: .color(Palette.base.opacity(0.85)))
            context.draw(text, at: CGPoint(x: plate.midX, y: plate.midY))
        }
    }
}

private extension Point3D {
    func plus3(_ other: Point3D, _ times: Double) -> Point3D { Point3D(x: x + other.x * times, y: y + other.y * times, z: z + other.z * times) }
    var negated: Point3D { Point3D(x: -x, y: -y, z: -z) }
}
