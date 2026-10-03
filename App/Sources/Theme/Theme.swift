//
// Vespertine — Obsidian & Brass design tokens and shared components.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

enum Palette {
    static let window = Color(hex: 0x0D0D0F)
    static let base = Color(hex: 0x09090A)
    static let sidebar = Color(hex: 0x111114)
    static let surface = Color(hex: 0x16161A)
    static let raised = Color(hex: 0x1C1C21)
    static let panel = Color(hex: 0x0C0C0E)
    static let hairline = Color(hex: 0xECE6DA, opacity: 0.07)
    static let hairlineStrong = Color(hex: 0xECE6DA, opacity: 0.12)

    static let text = Color(hex: 0xECE6DA)
    static let text2 = Color(hex: 0xA29B8F)
    static let text3 = Color(hex: 0x8C867C)   // at least 4.5:1 on every background here (WCAG AA), even at 10 pt

    static let brass = Color(hex: 0xC8A66A)
    static let brassHi = Color(hex: 0xE7CD98)
    static let brassLo = Color(hex: 0x7C6541)
    static let copper = Color(hex: 0xC98B5B)

    static let brassGradient = LinearGradient(colors: [brassHi, brass], startPoint: .top, endPoint: .bottom)
}

enum Typeface {
    /// New York — names of things.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .serif) }
    /// SF Pro — interface.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    /// SF Mono — every number that describes the signal.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

// MARK: - Small components

/// Uppercase section label ("SIGNAL PATH").
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Typeface.ui(10.5, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(Palette.text3)
    }
}

struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Palette.hairline)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Status badge: brass (bit-perfect), copper (converted) or neutral.
struct StatusBadge: View {
    enum Kind { case perfect, converted, neutral }
    let text: String
    var kind: Kind = .neutral

    var body: some View {
        HStack(spacing: 6) {
            switch kind {
            case .perfect:
                Circle().fill(Palette.brassHi).frame(width: 6, height: 6).shadow(color: Palette.brass, radius: 4)
            case .converted:
                Circle().strokeBorder(Palette.copper, lineWidth: 1.5).frame(width: 7, height: 7)
            case .neutral:
                EmptyView()
            }
            Text(text)
                .font(Typeface.mono(10, weight: .semibold))
                .tracking(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(background, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(border, lineWidth: 1))
        .fixedSize()
    }

    private var foreground: Color {
        switch kind { case .perfect: Palette.brassHi; case .converted: Palette.copper; case .neutral: Palette.text2 }
    }
    private var background: Color {
        switch kind { case .perfect: Palette.brass.opacity(0.10); case .converted: Palette.copper.opacity(0.08); case .neutral: .clear }
    }
    private var border: Color {
        switch kind { case .perfect: Palette.brass.opacity(0.35); case .converted: Palette.copper.opacity(0.45); case .neutral: Palette.hairlineStrong }
    }
}

/// Filled brass button (primary action).
struct BrassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.ui(12.5, weight: .medium))
            .foregroundStyle(Color(hex: 0x1A140A))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Palette.brassGradient, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.25), lineWidth: 0.5).blendMode(.overlay))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .saturation(isEnabled ? 1 : 0.2)
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Quiet bordered button (secondary).
struct QuietButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.ui(compact ? 11.5 : 12.5, weight: .medium))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: compact ? 26 : 30)
            .background(configuration.isPressed ? Palette.raised : Palette.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.hairlineStrong, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Round icon button used in the transport.
struct TransportIconStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? Palette.brassHi : (configuration.isPressed ? Palette.text : Palette.text2))
            .frame(width: 28, height: 28)
            // On is also a dot under the symbol, not only a colour (shuffle, repeat, queue, inspector).
            .overlay(alignment: .bottom) {
                if active { Circle().fill(Palette.brassHi).frame(width: 3, height: 3).offset(y: 1) }
            }
            .contentShape(Rectangle())
            .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Selectable filter chip.
struct Chip: View {
    let title: String
    var symbol: String? = nil
    let isOn: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9.5)) }
                Text(title)
            }
            .font(Typeface.ui(11.5))
            .foregroundStyle(isOn ? Palette.brassHi : Palette.text2)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isOn ? Palette.brass.opacity(0.08) : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? Palette.brass.opacity(0.45) : Palette.hairlineStrong, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Thin brass scrubber with a glowing thumb.
struct BrassSlider: View {
    @Binding var value: Double          // 0…1
    var tint: Color = Palette.brass
    var showsThumb = true
    /// What VoiceOver calls it ("Position", "Volume"), how it reads the value, and how far one swipe moves it.
    var accessibilityName = ""
    var accessibilityValueText: (Double) -> String = { "\(Int((max(0, min(1, $0)) * 100).rounded())) percent" }
    var accessibilityStep = 0.05
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = max(0, min(1, value)) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.text.opacity(0.10)).frame(height: 3)
                Capsule().fill(tint).frame(width: x, height: 3)
                if showsThumb {
                    Circle()
                        .fill(Palette.brassHi)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Palette.brass.opacity(0.18), lineWidth: 6).opacity(hovering || dragging ? 1 : 0.6))
                        .offset(x: x - 5)
                        .scaleEffect(dragging ? 1.15 : 1)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !dragging { dragging = true; onEditingChanged(true) }
                    value = max(0, min(1, g.location.x / w))
                }
                .onEnded { _ in dragging = false; onEditingChanged(false) })
            .onHover { hovering = $0 }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.12), value: dragging)
        // Drawn from shapes, so it says what it is and takes VoiceOver's (and Full Keyboard Access's) adjust actions,
        // as one edit each (a seek happens when the edit ends, as after a drag).
        .accessibilityElement()
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(accessibilityValueText(value))
        .accessibilityAdjustableAction { direction in
            let delta: Double = switch direction {
            case .increment: accessibilityStep
            case .decrement: -accessibilityStep
            @unknown default: 0
            }
            onEditingChanged(true)
            value = max(0, min(1, value + delta))
            onEditingChanged(false)
        }
    }
}

extension TimeInterval {
    /// 3:12 or 1:02:45
    var clock: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let s = Int(self.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    var longDuration: String {
        let minutes = Int(self / 60)
        return minutes >= 60 ? "\(minutes / 60) HR \(minutes % 60) MIN" : "\(minutes) MIN"
    }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
