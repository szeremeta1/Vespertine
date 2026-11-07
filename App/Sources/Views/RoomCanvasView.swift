//
// Vespertine — Settings › Speaker Groups › Edit: the room drawn from above. Drag a speaker or the seat, drag the arrow to turn the
// seat, arrow keys nudge the speaker that has the focus (Shift: 50 cm), and a screen reader hears each speaker's distance and angle.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plain English with `verbatim` text: these strings join the catalog together with the screens that stay. The rules (snapping, the
// grid, the walls, the sentences) are `RoomCanvas` in VespertineKit, with tests.
//

import SwiftUI
import VespertineAudio

struct RoomCanvasView: View {
    @Binding var group: SpeakerGroup
    @AppStorage("speakerGroupsUnit") private var unitName = DistanceUnit.metres.rawValue
    @FocusState private var focused: UUID?

    private var unit: DistanceUnit { DistanceUnit(rawValue: unitName) ?? .metres }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: "Room").font(.headline)
                Spacer()
                Picker(selection: $unitName) {
                    Text(verbatim: "Metres").tag(DistanceUnit.metres.rawValue)
                    Text(verbatim: "Feet").tag(DistanceUnit.feet.rawValue)
                } label: { Text(verbatim: "Units") }
                .pickerStyle(.segmented).labelsHidden().frame(width: 140)
            }
            Text(verbatim: "Drag the speakers and the seat to where they are. The arrow turns the seat; Option while dragging turns the 10 cm grid off.")
                .font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                let layout = RoomCanvasLayout(group: group, viewWidth: geo.size.width, viewHeight: geo.size.height)
                ZStack {
                    floor(layout)
                    ForEach(group.speakers) { speaker in
                        dot(speaker, layout: layout)
                    }
                    seat(layout)
                }
                .coordinateSpace(name: "room")
            }
            .frame(height: 300)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            if group.speakers.isEmpty {
                Text(verbatim: "No speakers are placed yet. Choose a speaker for each channel first.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func floor(_ layout: RoomCanvasLayout) -> some View {
        Canvas { context, _ in
            let a = layout.viewPoint(Point2D(x: -layout.roomWidth / 2, y: layout.roomDepth / 2))
            let b = layout.viewPoint(Point2D(x: layout.roomWidth / 2, y: -layout.roomDepth / 2))
            let rect = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
            context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(.secondary), lineWidth: 1)
            // A line every metre (every 3 feet would not line up with the grid), the front of the room marked at the top.
            var metre = -Double(Int(layout.roomWidth / 2))
            while metre <= layout.roomWidth / 2 {
                let p = layout.viewPoint(Point2D(x: metre, y: 0))
                context.stroke(Path { $0.move(to: CGPoint(x: p.x, y: rect.minY)); $0.addLine(to: CGPoint(x: p.x, y: rect.maxY)) },
                               with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
                metre += 1
            }
            var line = -Double(Int(layout.roomDepth / 2))
            while line <= layout.roomDepth / 2 {
                let p = layout.viewPoint(Point2D(x: 0, y: line))
                context.stroke(Path { $0.move(to: CGPoint(x: rect.minX, y: p.y)); $0.addLine(to: CGPoint(x: rect.maxX, y: p.y)) },
                               with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
                line += 1
            }
            context.draw(Text(verbatim: "front").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: rect.midX, y: rect.minY + 8))
        }
        .accessibilityHidden(true)
    }

    private func dot(_ speaker: SpeakerGroup.Speaker, layout: RoomCanvasLayout) -> some View {
        let p = layout.viewPoint(speaker.position)
        let chosen = focused == speaker.id
        return ZStack {
            Circle().fill(chosen ? Color.accentColor : Color.accentColor.opacity(0.75)).frame(width: 26, height: 26)
            Text(verbatim: speaker.role.rawValue).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
        }
        .position(x: p.x, y: p.y)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("room"))
            .onChanged { value in
                focused = speaker.id
                group = RoomCanvas.move(speaker: speaker.id, to: layout.roomPoint(viewX: value.location.x, viewY: value.location.y), in: group,
                                        snap: !NSEvent.modifierFlags.contains(.option))
            }
            .onEnded { _ in group = RoomCanvas.snapToUsualAngle(speaker: speaker.id, in: group) })
        .focusable()
        .focused($focused, equals: speaker.id)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
            let (dx, dy): (Double, Double) = switch press.key {
            case .leftArrow: (-1, 0)
            case .rightArrow: (1, 0)
            case .upArrow: (0, 1)
            default: (0, -1)
            }
            group = RoomCanvas.nudge(speaker: speaker.id, dx: dx, dy: dy, large: press.modifiers.contains(.shift), in: group)
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: RoomCanvas.describe(speaker: speaker, in: group, unit: unit)))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(verbatim: "Move left")) { group = RoomCanvas.nudge(speaker: speaker.id, dx: -1, dy: 0, large: false, in: group) }
        .accessibilityAction(named: Text(verbatim: "Move right")) { group = RoomCanvas.nudge(speaker: speaker.id, dx: 1, dy: 0, large: false, in: group) }
        .accessibilityAction(named: Text(verbatim: "Move forward")) { group = RoomCanvas.nudge(speaker: speaker.id, dx: 0, dy: 1, large: false, in: group) }
        .accessibilityAction(named: Text(verbatim: "Move back")) { group = RoomCanvas.nudge(speaker: speaker.id, dx: 0, dy: -1, large: false, in: group) }
    }

    private func seat(_ layout: RoomCanvasLayout) -> some View {
        let p = layout.viewPoint(group.listener.position)
        let facing = group.listener.facingDegrees * .pi / 180
        // The arrow's tip, 0.8 m from the seat towards where it faces: the handle that turns it.
        let tip = layout.viewPoint(Point2D(x: group.listener.position.x + 0.8 * sin(facing), y: group.listener.position.y + 0.8 * cos(facing)))
        return ZStack {
            Path { path in path.move(to: CGPoint(x: p.x, y: p.y)); path.addLine(to: CGPoint(x: tip.x, y: tip.y)) }
                .stroke(Color.orange, lineWidth: 2)
            Circle().fill(Color.orange).frame(width: 14, height: 14).position(x: tip.x, y: tip.y)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("room")).onChanged { value in
                    group = RoomCanvas.turnListener(toward: layout.roomPoint(viewX: value.location.x, viewY: value.location.y), in: group)
                })
                .accessibilityLabel(Text(verbatim: "Turn the seat"))
                .accessibilityAction(named: Text(verbatim: "Turn right")) { group.listener.facingDegrees = Self.turned(group.listener.facingDegrees, by: 15) }
                .accessibilityAction(named: Text(verbatim: "Turn left")) { group.listener.facingDegrees = Self.turned(group.listener.facingDegrees, by: -15) }
            Circle().stroke(Color.orange, lineWidth: 3).background(Circle().fill(Color.orange.opacity(0.25))).frame(width: 22, height: 22)
                .position(x: p.x, y: p.y)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("room")).onChanged { value in
                    group = RoomCanvas.moveListener(to: layout.roomPoint(viewX: value.location.x, viewY: value.location.y), in: group,
                                                    snap: !NSEvent.modifierFlags.contains(.option))
                })
                .accessibilityLabel(Text(verbatim: RoomCanvas.describe(listener: group, unit: unit)))
        }
    }

    private static func turned(_ degrees: Double, by step: Double) -> Double {
        var d = (degrees + step).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        return d
    }
}
