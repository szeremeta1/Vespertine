//
// Vespertine Remote: what first-run setup is drawn with: the slow brass light behind it, its cards and buttons, and the
// small moving pictures of a Mac, this device and what goes between them. As the Mac app's setup looks.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI

// MARK: - Backdrop

/// Slow brass light and flowing lines behind every step. Still with Reduce Motion on.
struct SetupBackdrop: View {
    let step: SetupStep
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Palette.base
            // The glow drifts across as you go through the steps.
            GeometryReader { geometry in
                let size = max(geometry.size.width, geometry.size.height)
                RadialGradient(colors: [Palette.brass.opacity(0.22), Palette.copper.opacity(0.07), .clear],
                               center: .center, startRadius: 0, endRadius: size * 0.45)
                    .frame(width: size * 0.9, height: size * 0.9)
                    .position(x: geometry.size.width * Self.glowX(step), y: geometry.size.height * (step == .done ? 0.36 : 0.24))
                    .animation(reduceMotion ? nil : .spring(response: 1.6, dampingFraction: 0.9), value: step)
            }
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
                let time = reduceMotion ? 12 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000)
                Canvas { context, size in
                    Self.drawRibbons(in: &context, size: size, time: time)
                    Self.drawMotes(in: &context, size: size, time: time)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Where the glow sits across the screen, 0…1: in the middle for the welcome and the end, and moving from the leading
    /// side to the trailing side through the steps between.
    nonisolated static func glowX(_ step: SetupStep) -> CGFloat {
        switch step {
        case .welcome, .done: 0.5
        default: 0.2 + 0.15 * CGFloat(step.rawValue - 1)
        }
    }

    /// Six sine ribbons across the lower part, each with its own speed, like a slow waveform.
    private static func drawRibbons(in context: inout GraphicsContext, size: CGSize, time: Double) {
        guard size.width > 0 else { return }
        for index in 0..<6 {
            let k = Double(index)
            let base = size.height * (0.74 + 0.028 * k)
            let amplitude = size.height * (0.03 + 0.008 * k)
            let frequency = 2 * Double.pi / size.width * (1.0 + 0.16 * k)
            let phase = time * (0.22 + 0.05 * k) + k * 1.7
            var path = Path()
            var x = 0.0
            while x <= size.width {
                let envelope = sin(Double.pi * x / size.width)
                let y = base + amplitude * envelope * (sin(x * frequency + phase) + 0.35 * sin(x * frequency * 2.3 - phase * 1.3))
                if x == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                x += 6
            }
            let opacity = 0.07 + 0.04 * Double((index * 7) % 3)
            context.stroke(path, with: .color(Palette.brassHi.opacity(opacity)), lineWidth: index == 2 ? 1.4 : 1)
        }
    }

    /// Specks of light rising slowly.
    private static func drawMotes(in context: inout GraphicsContext, size: CGSize, time: Double) {
        guard size.height > 0 else { return }
        for index in 0..<28 {
            let seed = Double(index) * 12.9898
            let rx = (sin(seed) * 43_758.5453).truncatingRemainder(dividingBy: 1).magnitude
            let ry = (sin(seed * 1.7) * 23_421.631).truncatingRemainder(dividingBy: 1).magnitude
            let speed = 6 + 10 * rx
            let y = size.height - ((ry * size.height + time * speed).truncatingRemainder(dividingBy: size.height + 20)) + 10
            let x = rx * size.width + 14 * sin(time * 0.3 + seed)
            let radius = 0.6 + 1.1 * ry
            let twinkle = 0.5 + 0.5 * sin(time * (0.6 + rx) + seed)
            context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                         with: .color(Palette.brassHi.opacity(0.12 + 0.24 * twinkle * (1 - y / size.height))))
        }
    }
}

// MARK: - Buttons

/// The brass button that takes setup forward.
struct SetupPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        SetupPrimaryButton(label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct SetupPrimaryButton: View {
    let label: ButtonStyleConfiguration.Label
    let pressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        label
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(Color(hex: 0x1A140A))
            .padding(.horizontal, 26).padding(.vertical, 12)
            .frame(minHeight: 48)
            .background(Palette.brassGradient, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5).blendMode(.overlay))
            .shadow(color: Palette.brass.opacity(0.3), radius: 10, y: 3)
            .scaleEffect(reduceMotion ? 1 : pressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.7), value: pressed)
            .contentShape(Capsule())
    }
}

/// A quiet button: Back, and the buttons that add something on a step.
struct SetupQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .frame(minWidth: 48, minHeight: 48)
            .background(Palette.text.opacity(configuration.isPressed ? 0.14 : 0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairlineStrong, lineWidth: 0.5))
            .contentShape(Capsule())
    }
}

// MARK: - Pieces

/// Fades and rises into place, after `delay`.
private struct SetupReveal: ViewModifier {
    let shown: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 16)
            .blur(radius: shown || reduceMotion ? 0 : 5)
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.7, dampingFraction: 0.82).delay(delay), value: shown)
    }
}

extension View {
    func setupReveal(_ shown: Bool, delay: Double = 0) -> some View { modifier(SetupReveal(shown: shown, delay: delay)) }
}

/// A step's title and explanation.
struct SetupHeading: View {
    let title: Text
    let detail: Text
    let shown: Bool

    var body: some View {
        VStack(spacing: 10) {
            title
                .font(.system(.title, design: .serif))
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .setupReveal(shown)
                .accessibilityAddTraits(.isHeader)
            detail
                .font(.subheadline)
                .foregroundStyle(Palette.text2)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .setupReveal(shown, delay: 0.06)
        }
    }
}

/// A card that glows when it's the chosen one.
struct SetupCard<Content: View>: View {
    var selected = false
    var padding: CGFloat = 14
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Palette.surface.opacity(0.82))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.brass.opacity(selected ? 0.12 : 0)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? Palette.brass.opacity(0.75) : Palette.hairlineStrong, lineWidth: selected ? 1.5 : 1)
            }
            .shadow(color: selected ? Palette.brass.opacity(0.26) : .black.opacity(0.18), radius: selected ? 16 : 8, y: 4)
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: selected)
    }
}

/// A round symbol in brass, for the cards. At the accessibility text sizes it steps aside: the words need the width.
struct SetupSymbol: View {
    let name: String
    var selected = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if !typeSize.isAccessibilitySize {
            Image(systemName: name)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(selected ? Palette.brassHi : Palette.brass)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Palette.brass.opacity(selected ? 0.2 : 0.09)))
                .overlay(Circle().strokeBorder(Palette.brass.opacity(selected ? 0.55 : 0.22), lineWidth: 1))
                .symbolEffect(.bounce, value: reduceMotion ? false : selected)
                .accessibilityHidden(true)
        }
    }
}

/// One of several choices on a step (where the music is, where it plays): a card with a tick when it's the chosen one.
/// To VoiceOver it is one button that says whether it is selected.
struct SetupChoice: View {
    /// A choice as VoiceOver says it: its name, then what it means.
    nonisolated static func spoken(title: String, detail: String) -> String { detail.isEmpty ? title : "\(title). \(detail)" }

    let symbol: String
    let title: String
    let detail: String
    let selected: Bool
    var enabled = true
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            SetupCard(selected: selected) {
                HStack(alignment: .center, spacing: 14) {
                    SetupSymbol(name: symbol, selected: selected)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: title).font(.body.weight(.semibold)).foregroundStyle(Palette.text)
                        Text(verbatim: detail).font(.footnote).foregroundStyle(Palette.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 6)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Palette.brass : Palette.text3)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityElement(children: .ignore)
        // What the choice means is part of what it is called: a hint is spoken late, and not at all when hints are off.
        .accessibilityLabel(Text(verbatim: SetupChoice.spoken(title: title, detail: detail)))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .sensoryFeedback(.selection, trigger: selected)
    }
}

/// One setting on the Sound and Extras steps: what it is, what it does, and its control: beside the words when it is a
/// switch, under them when it is a row of choices.
struct SetupOption<Control: View>: View {
    let symbol: String
    let title: Text
    let detail: Text
    var on = false
    /// The control goes under the words (a segmented row needs the width).
    var below = false
    @ViewBuilder var control: Control
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        SetupCard(selected: on) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    SetupSymbol(name: symbol, selected: on)
                    VStack(alignment: .leading, spacing: 3) {
                        title.font(.body.weight(.semibold)).foregroundStyle(Palette.text)
                            // A long name wraps: beside a switch it was cut short with an ellipsis.
                            .fixedSize(horizontal: false, vertical: true)
                        detail.font(.footnote).foregroundStyle(Palette.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if !stacks { control }
                }
                if stacks { control }
            }
        }
        // The parts stay separate: the switch or picker keeps its own name, role and value.
        .accessibilityElement(children: .contain)
    }

    private var stacks: Bool { below || typeSize.isAccessibilitySize }
}

// MARK: - Pictures

/// Two things and what travels between them: a Mac and this device, with dots going the way the songs or the commands
/// go, and a small speaker on the one that makes the sound. Only a picture: VoiceOver passes over it.
struct SetupFlowPicture: View {
    let leading: String
    let trailing: String
    /// The dots travel toward the trailing thing.
    var towardTrailing = true
    /// Which of the two makes the sound, if either.
    var sounds: HorizontalEdge?
    /// Rings spread from the trailing thing while it looks for the other.
    var searching = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            endpoint(leading, sounding: sounds == .leading, rings: false)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
                let time = reduceMotion ? 0.4 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1_000)
                Canvas { context, size in
                    Self.drawDots(in: &context, size: size, time: time, towardTrailing: towardTrailing)
                }
            }
            .frame(width: 84, height: 30)
            endpoint(trailing, sounding: sounds == .trailing, rings: searching)
        }
        // A picture of two machines, not text: the same way round in every language.
        .environment(\.layoutDirection, .leftToRight)
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.75), value: sounds)
        .accessibilityHidden(true)
    }

    private func endpoint(_ symbol: String, sounding: Bool, rings: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 34, weight: .light))
            .foregroundStyle(sounding ? Palette.brassHi : Palette.brass)
            .frame(width: 78, height: 78)
            .background(Circle().fill(Palette.brass.opacity(sounding ? 0.2 : 0.08)))
            .overlay(Circle().strokeBorder(Palette.brass.opacity(sounding ? 0.6 : 0.22), lineWidth: 1))
            .background { if rings { SetupRings() } }
            .shadow(color: Palette.brass.opacity(sounding ? 0.45 : 0), radius: 18)
            .overlay(alignment: .topTrailing) {
                if sounding {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x1A140A))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Palette.brassGradient))
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                        .offset(x: 4, y: -4)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .scaleEffect(sounding ? 1.06 : 1)
    }

    /// Five dots along the line, each brightest in the middle of its way.
    static func drawDots(in context: inout GraphicsContext, size: CGSize, time: Double, towardTrailing: Bool) {
        guard size.width > 0 else { return }
        let count = 5
        for index in 0..<count {
            let travelled = dotPosition(index: index, of: count, time: time)
            let place = towardTrailing ? travelled : 1 - travelled
            let x = 8 + (size.width - 16) * place
            let glow = sin(Double.pi * travelled)
            let radius = 1.6 + 1.6 * glow
            context.fill(Path(ellipseIn: CGRect(x: x - radius, y: size.height / 2 - radius, width: radius * 2, height: radius * 2)),
                         with: .color(Palette.brassHi.opacity(0.25 + 0.75 * glow)))
        }
    }

    /// How far along its way dot `index` of `count` is at `time`, 0…1: the dots follow one another, evenly spaced.
    nonisolated static func dotPosition(index: Int, of count: Int, time: Double) -> Double {
        let position = (time * 0.45 + Double(index) / Double(max(count, 1))).truncatingRemainder(dividingBy: 1)
        return position < 0 ? position + 1 : position
    }
}

/// Rings spreading out, for something that is looking.
private struct SetupRings: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spread = false

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { index in
                Circle()
                    .strokeBorder(Palette.brass.opacity(spread ? 0 : 0.5), lineWidth: 1)
                    .scaleEffect(spread ? 1.7 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 2.2).repeatForever(autoreverses: false).delay(Double(index) * 1.1), value: spread)
            }
        }
        .onAppear { spread = true }
    }
}

/// A tick drawn in a ring, with a few sparks, for something that worked.
struct SetupCheck: View {
    var size: CGFloat = 96
    @State private var ring: CGFloat = 0
    @State private var check: CGFloat = 0
    @State private var burst: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(0..<14, id: \.self) { index in
                let angle = Double(index) / 14 * 2 * Double.pi + 0.2
                let distance = size * (index.isMultiple(of: 2) ? 0.74 : 0.6)
                Circle()
                    .fill(index.isMultiple(of: 3) ? Palette.copper : Palette.brassHi)
                    .frame(width: index.isMultiple(of: 2) ? 5 : 3.5, height: index.isMultiple(of: 2) ? 5 : 3.5)
                    .offset(x: cos(angle) * distance * burst, y: sin(angle) * distance * burst)
                    .opacity(burst == 0 ? 0 : Double(1 - burst))
            }
            Circle().stroke(Palette.hairlineStrong, lineWidth: 2)
            Circle()
                .trim(from: 0, to: ring)
                .stroke(Palette.brassGradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: Palette.brass.opacity(0.7), radius: 8)
            SetupCheckShape()
                .trim(from: 0, to: check)
                .stroke(Palette.brassHi, style: StrokeStyle(lineWidth: size * 0.045, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.38, height: size * 0.29)
        }
        .frame(width: size, height: size)
        // A check mark reads the same in every language; don't mirror it.
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { ring = 1; check = 1; return }
            withAnimation(.easeOut(duration: 0.7)) { ring = 1 }
            withAnimation(.easeOut(duration: 0.35).delay(0.5)) { check = 1 }
            withAnimation(.easeOut(duration: 0.9).delay(0.6)) { burst = 1 }
        }
    }
}

nonisolated struct SetupCheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
