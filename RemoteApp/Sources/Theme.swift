//
// Vespertine Remote: the Obsidian & Brass colours and type, as the Mac app has them, and a few shared pieces.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import UIKit

enum Palette {
    // Ivory is the plan's existing light field. Reuse the brand tokens for contrast.
    static let base = adaptive(light: 0xECE6DA, dark: 0x09090A)
    static let surface = adaptive(light: 0xECE6DA, dark: 0x16161A)
    static let raised = adaptive(light: 0xECE6DA, dark: 0x1C1C21)
    static let hairline = adaptive(light: 0x09090A, dark: 0xECE6DA).opacity(0.07)
    static let hairlineStrong = adaptive(light: 0x09090A, dark: 0xECE6DA).opacity(0.12)
    static let text = adaptive(light: 0x09090A, dark: 0xECE6DA)
    static let text2 = adaptive(light: 0x69645C, dark: 0xA29B8F)
    static let text3 = adaptive(light: 0x69645C, dark: 0x8C867C)
    static let brass = adaptive(light: 0x7C6541, dark: 0xC8A66A)
    static let brassHi = adaptive(light: 0x7C6541, dark: 0xE7CD98)
    static let brassLo = Color(hex: 0x7C6541)
    static let copper = adaptive(light: 0x7C6541, dark: 0xC98B5B)
    // The transport is always a brass object, with dark ink in both appearances.
    static let brassGradient = LinearGradient(colors: [Color(hex: 0xE7CD98), Color(hex: 0xC8A66A)], startPoint: .top, endPoint: .bottom)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let h = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255,
                           blue: CGFloat(h & 255) / 255, alpha: 1)
        })
    }
}

extension Color {
    nonisolated init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

extension Font {
    /// New York, for the names of things (songs, albums, Macs). Follows Dynamic Type.
    static func serif(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .serif, weight: weight)
    }

    /// SF Mono, for every number that describes the signal.
    static func signal(_ style: Font.TextStyle = .caption) -> Font {
        .system(style, design: .monospaced)
    }
}

extension View {
    /// Keep text and controls readable on a full-screen iPad without changing the window background.
    func readablePane(maxWidth: CGFloat = 900) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.base)
    }

    /// Large titles on iPhone; a centred inline title in a regular-width window, where the title would otherwise sit
    /// at the pane's edge while the readable content is centred.
    func screenTitleStyle() -> some View { modifier(ScreenTitleStyle()) }

    /// The app's background behind a screen's content.
    func obsidianBackground() -> some View {
        background(Palette.base.ignoresSafeArea())
    }

    /// A list drawn on obsidian, with surface-coloured rows.
    func obsidianList() -> some View {
        scrollContentBackground(.hidden).background(Palette.base.ignoresSafeArea())
    }
}

/// The brass play and pause button, as on the Mac.
struct PlayPauseFace: View {
    var playing: Bool
    var loading = false
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            Circle().fill(Palette.brassGradient)
            Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5).blendMode(.overlay)
            if loading {
                ProgressView().tint(Color(hex: 0x1A140A))
            } else {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x1A140A))
                    .offset(x: playing ? 0 : size * 0.03)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Palette.brass.opacity(0.28), radius: size * 0.2, y: size * 0.08)
    }
}

/// A small capsule saying one thing ("BIT-PERFECT", "24/96").
struct Chip: View {
    let text: String
    var highlighted = false

    var body: some View {
        Text(text)
            .font(.signal(.caption2).weight(.medium))
            .foregroundStyle(highlighted ? Palette.brassHi : Palette.text2)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(highlighted ? Palette.brass.opacity(0.14) : Palette.text.opacity(0.06)))
            .overlay(Capsule().strokeBorder(highlighted ? Palette.brass.opacity(0.45) : Palette.hairlineStrong, lineWidth: 0.5))
            .lineLimit(1)
    }
}

/// Lays its pieces out left to right and wraps them onto more lines when they don't fit: the signal badges stay whole on
/// a narrow screen and at large text sizes.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    /// Each line in the middle (under a centred title).
    var centered = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return FlowRows.place(sizes(subviews, width: width), width: width, spacing: spacing, lineSpacing: lineSpacing, centered: centered).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = FlowRows.place(sizes(subviews, width: bounds.width), width: bounds.width, spacing: spacing, lineSpacing: lineSpacing, centered: centered)
        for (subview, origin) in zip(subviews, placed.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }

    private func sizes(_ subviews: Subviews, width: CGFloat) -> [CGSize] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil)) }
    }
}

/// The crescent from the logo, drawn (so it needs no image and takes any colour).
nonisolated struct Crescent: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var disc = Path()
        disc.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        let bite = radius * 0.86
        var hole = Path()
        hole.addEllipse(in: CGRect(x: center.x + radius * 0.42 - bite, y: center.y - radius * 0.22 - bite, width: bite * 2, height: bite * 2))
        return disc.subtracting(hole)
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

private struct ScreenTitleStyle: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    func body(content: Content) -> some View {
        content.navigationBarTitleDisplayMode(sizeClass == .regular ? .inline : .automatic)
    }
}
