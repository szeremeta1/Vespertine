//
// Vespertine: Settings › Speaker Groups › Edit: the room in three dimensions. Drag the room to turn it, a speaker or the seat to
// move it across the floor (Shift: up and down), the arrow to turn the seat; the room's size, the ears' height and the chosen
// speaker's place can be typed. One seat, or the part of the floor people listen in when the group fills the room. Arrow keys
// nudge the speaker that has the focus, and a screen reader hears each speaker's distance, angle and height.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The rules (the camera, what is under the pointer, the walls, the grid, the heights, the sentences) are `Room3DLayout` and
// `RoomCanvas` in VespertineKit, with tests. From above (`RoomCamera.plan`) it is the drawing the room always was.
//

import SwiftUI
import VespertineAudio

struct Room3DView: View {
    @Binding var group: SpeakerGroup
    @AppStorage("speakerGroupsUnit") private var unitName = DistanceUnit.metres.rawValue
    @State private var camera = Room3DView.openingCamera
    @State private var orbitFrom: RoomCamera?
    @State private var zoomFrom: RoomCamera?
    @State private var grab: Grab?
    @State private var selected: UUID?
    @State private var choseForQA = false
    @FocusState private var focused: UUID?

    /// What a drag took hold of, and where: so a speaker doesn't jump to the pointer, and its height is counted from where it was.
    private struct Grab {
        var id: UUID?
        var offset: CGSize
        var from: Point3D
        var area: ListeningArea?
    }

    private static let space = "room3d"
    /// One colour per output, in the group's order, so it shows which speaker hangs on which DAC.
    private static let memberColors: [Color] = [Palette.brass, Color(hex: 0x6FA8A0), Palette.copper, Color(hex: 0x9A8FC8), Color(hex: 0x8FB573),
                                                Color(hex: 0xC87F8F), Color(hex: 0x7F9FC8), Color(hex: 0xB8B07A)]

    /// QA: `-VespertineRoomView top|back|side` opens the room from there.
    private static var openingCamera: RoomCamera {
        switch LaunchArguments().string(forKey: "VespertineRoomView") {
        case "top": .plan
        case "back": .fromBehind
        case "side": .fromTheSide
        default: .threeQuarter
        }
    }

    private var unit: DistanceUnit { DistanceUnit(rawValue: unitName) ?? .metres }
    private var fillsRoom: Bool { GroupPolicies.roomRenderOn(group) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text("Drag the speakers and the seat to where they are. The arrow turns the seat; Option while dragging turns the 10 cm grid off.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Drag the room to turn it, and pinch to zoom. Hold Shift while dragging a speaker to raise or lower it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            GeometryReader { geo in
                let layout = Room3DLayout(group: group, camera: camera, viewWidth: geo.size.width, viewHeight: geo.size.height)
                ZStack {
                    Canvas { context, _ in Room3DScene(group: group, layout: layout, selected: selected, fillsRoom: fillsRoom, unit: unit).draw(in: &context) }
                        .accessibilityHidden(true)
                        .contentShape(Rectangle())
                        .gesture(orbit)
                        .simultaneousGesture(zoom)
                        .onTapGesture(count: 2) { camera = RoomCamera(yawDegrees: camera.yawDegrees, pitchDegrees: camera.pitchDegrees) }
                        .onTapGesture { selected = nil }
                    if fillsRoom { areaHandles(layout) }
                    seatHandles(layout)
                    ForEach(group.speakers) { speaker in
                        if speaker.position.isFinite { speakerHandle(speaker, layout: layout) }
                    }
                }
                .coordinateSpace(name: Self.space)
            }
            .frame(height: 400)
            .onAppear {
                // QA: `-VespertineRoomSelect FL` chooses that speaker as a click on it does.
                guard !choseForQA, let role = LaunchArguments().string(forKey: "VespertineRoomSelect") else { return }
                choseForQA = true
                selected = group.speakers.first { $0.role.rawValue == role }?.id
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.panel))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairlineStrong))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if group.speakers.isEmpty {
                Text("No speakers are placed yet. Choose a speaker for each channel first.").font(.caption).foregroundStyle(.secondary)
            } else {
                legend
            }
            sizes
            if let speaker = group.speakers.first(where: { $0.id == selected }) { place(of: speaker) }
            listening
        }
    }

    // MARK: Around the drawing

    private var header: some View {
        HStack {
            Text("Room").font(.headline)
            Spacer()
            Picker(selection: Binding(get: { Self.preset(of: camera) }, set: { if let next = $0.camera { camera = next } })) {
                Text(verbatim: "3D").tag(ViewPreset.threeQuarter)
                Text("From above").tag(ViewPreset.plan)
                Text("From the back").tag(ViewPreset.back)
                Text("From the side").tag(ViewPreset.side)
            } label: { Text("View") }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Picker(selection: $unitName) {
                Text("Metres").tag(DistanceUnit.metres.rawValue)
                Text("Feet").tag(DistanceUnit.feet.rawValue)
            } label: { Text("Units") }
            .pickerStyle(.segmented).labelsHidden().frame(width: 140)
        }
    }

    private enum ViewPreset: Hashable {
        case threeQuarter, plan, back, side, other

        var camera: RoomCamera? {
            switch self {
            case .threeQuarter: .threeQuarter
            case .plan: .plan
            case .back: .fromBehind
            case .side: .fromTheSide
            case .other: nil
            }
        }
    }

    /// The segment that is lit: the view the camera stands at, none once the room has been turned by hand.
    private static func preset(of camera: RoomCamera) -> ViewPreset {
        for preset in [ViewPreset.threeQuarter, .plan, .back, .side] where preset.camera == camera { return preset }
        return .other
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(Array(group.members.enumerated()), id: \.offset) { index, member in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(Self.color(ofMember: index)).frame(width: 10, height: 10)
                    Text(verbatim: member.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var sizes: some View {
        HStack(spacing: 14) {
            length(Text("Width"), get: { RoomCanvas.room(of: group).width }, set: { group = RoomCanvas.setRoom(width: $0, in: group) })
            length(Text("Depth"), get: { RoomCanvas.room(of: group).depth }, set: { group = RoomCanvas.setRoom(depth: $0, in: group) })
            length(Text("Ceiling"), get: { RoomCanvas.ceiling(of: group) }, set: { group = RoomCanvas.setRoom(height: $0, in: group) })
            length(Text("Ear height"), get: { group.listener.ears }, set: { group = RoomCanvas.setEarHeight($0, in: group) })
        }
    }

    /// The chosen speaker's place, to type: across from the middle of the room (right is positive), along it (the front is
    /// positive), and above the floor.
    private func place(of speaker: SpeakerGroup.Speaker) -> some View {
        HStack(spacing: 14) {
            Text(verbatim: speaker.role.plainName).font(.body.weight(.medium))
            length(Text("Left or right"), get: { speaker.position.x },
                   set: { group = RoomCanvas.move(speaker: speaker.id, to: Point2D(x: $0, y: speaker.position.y), in: group, snap: false) })
            length(Text("Back or front"), get: { speaker.position.y },
                   set: { group = RoomCanvas.move(speaker: speaker.id, to: Point2D(x: speaker.position.x, y: $0), in: group, snap: false) })
            length(Text("Above the floor"), get: { RoomCanvas.point(of: speaker, in: group).z },
                   set: { group = RoomCanvas.setHeight(speaker: speaker.id, aboveFloor: $0, in: group, snap: false) })
        }
    }

    /// A length in the chosen unit, to two places, typed as metres into the group.
    private func length(_ label: Text, get: @escaping () -> Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 5) {
            label.font(.caption).foregroundStyle(.secondary).fixedSize()
            TextField(value: Binding(get: { (unit.value(get()) * 100).rounded() / 100 }, set: { set(unit.metres(from: $0)) }),
                      format: .number.precision(.fractionLength(0...2))) { label }
                .labelsHidden().textFieldStyle(.roundedBorder).monospacedDigit().multilineTextAlignment(.trailing).frame(width: 58)
            Text(verbatim: unit.symbol).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var listening: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Listening").font(.headline)
                Spacer()
                Picker(selection: Binding(get: { fillsRoom }, set: { group = GroupPolicies.setRoomRender($0, in: group) })) {
                    Text("One seat").tag(false)
                    Text(verbatim: GroupPolicies.roomRenderTitle).tag(true)
                } label: { Text("Listening") }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if fillsRoom {
                Text(verbatim: GroupPolicies.roomRenderDetail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let style = GroupPolicies.roomRenderStyle(group) {
                    Picker(selection: Binding(get: { style }, set: { group = GroupPolicies.setRoomRenderStyle($0, in: group) })) {
                        ForEach(RoomRenderSettings.Style.allCases, id: \.self) { Text(verbatim: GroupPolicies.roomRenderStyleTitle($0)).tag($0) }
                    } label: { Text(verbatim: GroupPolicies.roomRenderTitle) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Text(verbatim: GroupPolicies.roomRenderStyleDetail(style)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("The lit part of the floor is where people listen. Drag it to move it, and its corner to size it.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { group.listeningArea = nil } label: { Text("Use the Whole Floor") }
                        .controlSize(.small).disabled(group.listeningArea == nil)
                }
            }
        }
    }

    // MARK: Turning the room

    private var orbit: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let from = orbitFrom ?? camera
                orbitFrom = from
                camera = from.orbited(dx: value.translation.width, dy: value.translation.height)
            }
            .onEnded { _ in orbitFrom = nil }
    }

    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let from = zoomFrom ?? camera
                zoomFrom = from
                camera = from.zoomed(by: value.magnification)
            }
            .onEnded { _ in zoomFrom = nil }
    }

    // MARK: Speakers

    static func color(ofMember index: Int) -> Color { memberColors[max(index, 0) % memberColors.count] }

    private func speakerHandle(_ speaker: SpeakerGroup.Speaker, layout: Room3DLayout) -> some View {
        let point = RoomCanvas.point(of: speaker, in: group)
        let p = layout.project(point)
        return Circle().fill(Color.white.opacity(0.001)).frame(width: 36, height: 36)
            .contentShape(Circle())
            .position(x: p.x, y: p.y)
            .zIndex(100 + p.depth)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    selected = speaker.id
                    focused = speaker.id
                    let held = grab ?? Grab(id: speaker.id, offset: CGSize(width: p.x - value.startLocation.x, height: p.y - value.startLocation.y), from: point)
                    grab = held
                    let flags = NSEvent.modifierFlags
                    if flags.contains(.shift) {
                        guard let change = layout.heightChange(viewDY: value.translation.height, at: held.from) else { return }
                        group = RoomCanvas.setHeight(speaker: speaker.id, aboveFloor: held.from.z + change, in: group, snap: !flags.contains(.option))
                    } else if let to = layout.roomPoint(viewX: value.location.x + held.offset.width, viewY: value.location.y + held.offset.height, height: point.z) {
                        group = RoomCanvas.move(speaker: speaker.id, to: to, in: group, snap: !flags.contains(.option))
                    }
                }
                .onEnded { _ in
                    grab = nil
                    group = RoomCanvas.snapToUsualAngle(speaker: speaker.id, in: group)
                })
            .focusable()
            .focused($focused, equals: speaker.id)
            .onChange(of: focused) { _, now in if now == speaker.id { selected = speaker.id } }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
                let large = press.modifiers.contains(.shift)
                if press.modifiers.contains(.option), press.key == .upArrow || press.key == .downArrow {
                    raise(speaker.id, by: (press.key == .upArrow ? 1 : -1) * (large ? 0.25 : RoomCanvas.heightGrid))
                    return .handled
                }
                let (right, up): (Double, Double) = switch press.key {
                case .leftArrow: (-1, 0)
                case .rightArrow: (1, 0)
                case .upArrow: (0, 1)
                default: (0, -1)
                }
                let step = camera.floorStep(right: right, up: up)
                group = RoomCanvas.nudge(speaker: speaker.id, dx: step.dx, dy: step.dy, large: large, in: group)
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: RoomCanvas.describe(speaker: speaker, in: group, unit: unit)))
            .accessibilityValue(Text("\(unit.spoken(point.z)) above the floor", comment: "Screen reader: how high a speaker stands; the height comes first, as “1.2 metres”."))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text("Move left")) { group = RoomCanvas.nudge(speaker: speaker.id, dx: -1, dy: 0, large: false, in: group) }
            .accessibilityAction(named: Text("Move right")) { group = RoomCanvas.nudge(speaker: speaker.id, dx: 1, dy: 0, large: false, in: group) }
            .accessibilityAction(named: Text("Move forward")) { group = RoomCanvas.nudge(speaker: speaker.id, dx: 0, dy: 1, large: false, in: group) }
            .accessibilityAction(named: Text("Move back")) { group = RoomCanvas.nudge(speaker: speaker.id, dx: 0, dy: -1, large: false, in: group) }
            .accessibilityAction(named: Text("Raise")) { raise(speaker.id, by: 0.1) }
            .accessibilityAction(named: Text("Lower")) { raise(speaker.id, by: -0.1) }
    }

    private func raise(_ id: UUID, by metres: Double) {
        guard let speaker = group.speakers.first(where: { $0.id == id }) else { return }
        group = RoomCanvas.setHeight(speaker: id, aboveFloor: RoomCanvas.point(of: speaker, in: group).z + metres, in: group)
    }

    // MARK: The seat

    private func seatHandles(_ layout: Room3DLayout) -> some View {
        let seat = RoomCanvas.seatPoint(in: group)
        let head = layout.project(seat)
        let tip = layout.project(Room3DScene.arrowTip(of: group))
        return ZStack {
            Circle().fill(Color.white.opacity(0.001)).frame(width: 26, height: 26).contentShape(Circle())
                .position(x: tip.x, y: tip.y)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)).onChanged { value in
                    if let toward = layout.roomPoint(viewX: value.location.x, viewY: value.location.y) { group = RoomCanvas.turnListener(toward: toward, in: group) }
                })
                .accessibilityLabel(Text("Turn the seat"))
                .accessibilityAction(named: Text("Turn right")) { group.listener.facingDegrees = Self.turned(group.listener.facingDegrees, by: 15) }
                .accessibilityAction(named: Text("Turn left")) { group.listener.facingDegrees = Self.turned(group.listener.facingDegrees, by: -15) }
            Circle().fill(Color.white.opacity(0.001)).frame(width: 34, height: 34).contentShape(Circle())
                .position(x: head.x, y: head.y)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        let held = grab ?? Grab(id: nil, offset: CGSize(width: head.x - value.startLocation.x, height: head.y - value.startLocation.y), from: seat)
                        grab = held
                        if let to = layout.roomPoint(viewX: value.location.x + held.offset.width, viewY: value.location.y + held.offset.height, height: seat.z) {
                            group = RoomCanvas.moveListener(to: to, in: group, snap: !NSEvent.modifierFlags.contains(.option))
                        }
                    }
                    .onEnded { _ in grab = nil })
                .accessibilityLabel(Text(verbatim: RoomCanvas.describe(listener: group, unit: unit)))
        }
        .zIndex(100 + head.depth)
    }

    private static func turned(_ degrees: Double, by step: Double) -> Double {
        var d = (degrees + step).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        return d
    }

    // MARK: The listening area

    /// The lit floor moves the area when dragged anywhere on it, and its near right corner sizes it about its centre.
    private func areaHandles(_ layout: Room3DLayout) -> some View {
        let area = RoomCanvas.listeningArea(of: group)
        let corner = layout.project(Point3D(Room3DScene.sizingCorner(of: area), z: 0))
        let w = area.width / 2, d = area.depth / 2
        let outline = Path { path in
            let points = [(-w, -d), (w, -d), (w, d), (-w, d)].map { layout.project(Point3D(Point2D(x: area.center.x + $0.0, y: area.center.y + $0.1), z: 0)) }
            path.addLines(points.map { CGPoint(x: $0.x, y: $0.y) })
            path.closeSubpath()
        }
        return ZStack {
            outline.fill(Color.white.opacity(0.001)).contentShape(outline)
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        // Moved by as far across the floor as the pointer went, so the area stays under it wherever it was taken hold of.
                        let held = grab ?? Grab(id: nil, offset: .zero, from: Point3D(area.center, z: 0), area: area)
                        grab = held
                        guard let start = layout.roomPoint(viewX: value.startLocation.x, viewY: value.startLocation.y),
                              let now = layout.roomPoint(viewX: value.location.x, viewY: value.location.y) else { return }
                        group = RoomCanvas.moveListeningArea(to: Point2D(x: held.from.x + now.x - start.x, y: held.from.y + now.y - start.y), in: group,
                                                             snap: !NSEvent.modifierFlags.contains(.option))
                    }
                    .onEnded { _ in grab = nil })
                // The whole floor has nowhere to move to, and a drag on it turns the room as it does everywhere else.
                .allowsHitTesting(group.listeningArea != nil)
                .accessibilityLabel(Text("Listening area"))
                .accessibilityAction(named: Text("Move left")) { group = RoomCanvas.moveListeningArea(to: Point2D(x: area.center.x - 0.1, y: area.center.y), in: group) }
                .accessibilityAction(named: Text("Move right")) { group = RoomCanvas.moveListeningArea(to: Point2D(x: area.center.x + 0.1, y: area.center.y), in: group) }
                .accessibilityAction(named: Text("Move forward")) { group = RoomCanvas.moveListeningArea(to: Point2D(x: area.center.x, y: area.center.y + 0.1), in: group) }
                .accessibilityAction(named: Text("Move back")) { group = RoomCanvas.moveListeningArea(to: Point2D(x: area.center.x, y: area.center.y - 0.1), in: group) }
            Circle().fill(Color.white.opacity(0.001)).frame(width: 26, height: 26).contentShape(Circle())
                .position(x: corner.x, y: corner.y)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)).onChanged { value in
                    guard let to = layout.roomPoint(viewX: value.location.x, viewY: value.location.y) else { return }
                    group = RoomCanvas.sizeListeningArea(width: (abs(to.x - area.center.x) * 2 * 10).rounded() / 10,
                                                         depth: (abs(to.y - area.center.y) * 2 * 10).rounded() / 10, in: group)
                })
                .accessibilityHidden(true)
        }
        .zIndex(50)
    }
}
