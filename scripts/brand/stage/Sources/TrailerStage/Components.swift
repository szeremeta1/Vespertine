// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

// MARK: - Brand tokens (docs/brand, the app's Theme.swift)

enum Brand {
    static let obsidian = Color(hex: 0x09090A)
    static let window = Color(hex: 0x0D0D0F)
    static let surface = Color(hex: 0x16161A)
    static let ivory = Color(hex: 0xECE6DA)
    static let ash = Color(hex: 0xA29B8F)
    static let muted = Color(hex: 0x69645C)
    static let brass = Color(hex: 0xC8A66A)
    static let brassHi = Color(hex: 0xE7CD98)
    static let brassLo = Color(hex: 0x7C6541)
    static let copper = Color(hex: 0xC98B5B)
    static let brassGradient = LinearGradient(colors: [Color(hex: 0xF0DAAA), brass, brassLo], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

// MARK: - Backdrop

/// Obsidian with a slow brass glow that follows the action.
struct Backdrop: View {
    let size: CGSize
    var glow: CGPoint
    var glowStrength: Double = 1
    var body: some View {
        ZStack {
            Brand.obsidian
            RadialGradient(colors: [Brand.brass.opacity(0.16 * glowStrength), .clear], center: UnitPoint(x: glow.x / size.width, y: glow.y / size.height),
                           startRadius: 0, endRadius: max(size.width, size.height) * 0.55)
            RadialGradient(colors: [Brand.copper.opacity(0.06), .clear], center: .bottomLeading, startRadius: 0, endRadius: size.width * 0.6)
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - The app window, as layers

/// How the recorded window is shown: where, how big, how tilted, and how far apart its layers are.
struct RigPose {
    var center: CGPoint
    var scale: CGFloat
    var tiltX: Double = 0          // degrees, top away from the viewer when positive
    var tiltY: Double = 0          // degrees, right side away when positive
    var opacity: Double = 1
    var explode: Double = 0        // 0 = one window, 1 = sidebar and inspector lifted off
    var sidebarLift = CGSize(width: -70, height: 0)
    var inspectorLift = CGSize(width: 60, height: 0)
    var contentDim: Double = 0     // darkens and softens the window body behind lifted layers
    var contentBlur: CGFloat = 0
    var inspectorScale: CGFloat = 1.06
    var sidebarScale: CGFloat = 1.04
    var shadow: Double = 1
    var sidebarTiltY: Double = 0    // degrees, applied as the sidebar lifts
    var inspectorTiltY: Double = 0
}

/// Window buttons, drawn as vectors where the recording shows macOS's capture indicator.
struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 9) {
            light(0xFF5F57, 0xE2463F); light(0xFEBC2E, 0xDFA023); light(0x28C840, 0x1AAB29)
        }
        .frame(width: 104, height: 40, alignment: .leading)
        .padding(.leading, 18.8)
    }
    func light(_ fill: UInt32, _ edge: UInt32) -> some View {
        Circle().fill(Color(hex: fill)).overlay(Circle().strokeBorder(Color(hex: edge), lineWidth: 0.5)).frame(width: 14, height: 14)
    }
}

struct WindowRig: View {
    let frame: CGImage?
    let sidebar: CGImage?
    let sidebarColor: Color
    var pose: RigPose
    /// Drawn in the inspector's coordinates, moving with it (e.g. light running down the signal path).
    var inspectorOverlay: AnyView? = nil
    /// Drawn in window coordinates over the window body, moving with the window (e.g. album covers lifting).
    var windowOverlay: AnyView? = nil

    private var size: CGSize { AppWindow.size }

    var body: some View {
        let e = pose.explode
        ZStack(alignment: .topLeading) {
            // Window body.
            ZStack(alignment: .topLeading) {
                if let frame { Image(decorative: frame, scale: 2).resizable().frame(width: size.width, height: size.height) }
                // Where lifted layers came from: a recess in the window.
                recess(AppWindow.sidebar).opacity(smooth(e * 2.5))
                recess(AppWindow.inspector).opacity(smooth(e * 2.5))
                Color.black.opacity(0.45 * pose.contentDim)
                windowOverlay
            }
            .blur(radius: pose.contentBlur)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.55 * pose.shadow), radius: 60, y: 30)


            // Sidebar on real Liquid Glass.
            if let sidebar {
                ZStack(alignment: .topLeading) {
                    if e > 0.001 {
                        RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.clear)
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                            .opacity(smooth(e * 2))
                    } else {
                        sidebarColor
                    }
                    Image(decorative: sidebar, scale: 2).resizable().frame(width: AppWindow.sidebar.width, height: AppWindow.sidebar.height)
                    TrafficLights().offset(y: AppWindow.indicator.minY)
                }
                .frame(width: AppWindow.sidebar.width, height: AppWindow.sidebar.height)
                .clipShape(RoundedRectangle(cornerRadius: mix(22, 26, e), style: .continuous))
                .shadow(color: .black.opacity(0.5 * e), radius: 40 * CGFloat(e), x: 0, y: 24 * CGFloat(e))
                .scaleEffect(mix(1, pose.sidebarScale, e), anchor: .center)
                .rotation3DEffect(.degrees(pose.sidebarTiltY * e), axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.5)
                .offset(x: pose.sidebarLift.width * CGFloat(e), y: pose.sidebarLift.height * CGFloat(e))
            }

            // Now Playing, lifted toward the viewer.
            if let frame, e > 0.001 {
                Image(decorative: crop(frame, AppWindow.inspector), scale: 2).resizable()
                    .frame(width: AppWindow.inspector.width, height: AppWindow.inspector.height)
                    .overlay(alignment: .topLeading) { inspectorOverlay }
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.28), Color.white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                    .shadow(color: .black.opacity(0.6 * e), radius: 50 * CGFloat(e), y: 30 * CGFloat(e))
                    .scaleEffect(mix(1, pose.inspectorScale, e), anchor: .center)
                    .rotation3DEffect(.degrees(pose.inspectorTiltY * e), axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.5)
                    .offset(x: AppWindow.inspector.minX + pose.inspectorLift.width * CGFloat(e),
                            y: AppWindow.inspector.minY + pose.inspectorLift.height * CGFloat(e))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .scaleEffect(pose.scale)
        .rotation3DEffect(.degrees(pose.tiltX), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.45)
        .rotation3DEffect(.degrees(pose.tiltY), axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.45)
        .opacity(pose.opacity)
        .position(pose.center)
    }

    private func recess(_ r: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(hex: 0x060607))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            .frame(width: r.width - 8, height: r.height - 8)
            .offset(x: r.minX + 4, y: r.minY + 4)
    }
}

// MARK: - Type

/// A tagline in Newsreader Light that resolves from soft focus, word by word.
struct Tagline: View {
    let text: String
    let size: CGFloat
    let t: Double
    let start: Double
    var stagger = 0.075
    var alignment: HorizontalAlignment = .leading
    var width: CGFloat? = nil

    var body: some View {
        // "\n" in the text forces a line break; words keep animating in order across lines.
        let lines = text.components(separatedBy: "\n").map { $0.split(separator: " ").map(String.init) }
        let firsts = lines.indices.map { i in lines[..<i].map(\.count).reduce(0, +) }
        let font = Font(BrandFont.serif(size, 300))
        return VStack(alignment: alignment, spacing: size * 0.06) {
            ForEach(lines.indices, id: \.self) { l in
                FlowLine(words: lines[l], spacing: size * 0.24, lineSpacing: size * 0.06, alignment: alignment, width: width) { i, word in
                    let p = spring(t, start: start + Double(firsts[l] + i) * stagger, response: 0.7, damping: 0.9)
                    Text(word).font(font).foregroundStyle(Brand.ivory).kerning(-size * 0.02)
                        .opacity(clamp01(p * 1.4))
                        .blur(radius: CGFloat(1 - clamp01(p)) * size * 0.14)
                        .offset(y: CGFloat(1 - p) * size * 0.35)
                }
            }
        }
    }
}

/// Lays words out left to right, wrapping at `width`, so each word can animate on its own.
struct FlowLine<Item: View>: View {
    let words: [String]
    let spacing: CGFloat
    let lineSpacing: CGFloat
    var alignment: HorizontalAlignment = .leading
    let width: CGFloat?
    @ViewBuilder let item: (Int, String) -> Item

    var body: some View {
        WrapLayout(spacing: spacing, lineSpacing: lineSpacing, maxWidth: width, alignment: alignment) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, word in item(i, word) }
        }
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    var maxWidth: CGFloat?
    var alignment: HorizontalAlignment

    func lines(_ subviews: Subviews, limit: CGFloat) -> [[(Int, CGSize)]] {
        var lines: [[(Int, CGSize)]] = [[]]; var x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > limit { lines.append([]); x = 0 }
            lines[lines.count - 1].append((i, s)); x += s.width + spacing
        }
        return lines
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = maxWidth ?? proposal.width ?? .infinity
        let ls = lines(subviews, limit: limit)
        let w = ls.map { l in l.map(\.1.width).reduce(0, +) + spacing * CGFloat(max(0, l.count - 1)) }.max() ?? 0
        let h = ls.map { $0.map(\.1.height).max() ?? 0 }.reduce(0, +) + lineSpacing * CGFloat(max(0, ls.count - 1))
        return CGSize(width: min(w, limit), height: h)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ls = lines(subviews, limit: maxWidth ?? bounds.width)
        var y = bounds.minY
        for l in ls {
            let lw = l.map(\.1.width).reduce(0, +) + spacing * CGFloat(max(0, l.count - 1))
            var x = alignment == .center ? bounds.midX - lw / 2 : (alignment == .trailing ? bounds.maxX - lw : bounds.minX)
            let lh = l.map(\.1.height).max() ?? 0
            for (i, s) in l {
                subviews[i].place(at: CGPoint(x: x, y: y + lh - s.height), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += lh + lineSpacing
        }
    }
}

/// A mono label in the brand style: "BIT-PERFECT · 24-BIT · 192 kHz".
struct BrandLabel: View {
    let text: String
    var size: CGFloat = 15
    var brass = false
    var copper = false
    var dot = false
    var body: some View {
        let color = copper ? Brand.copper : (brass ? Brand.brass : Brand.ash)
        HStack(spacing: size * 0.6) {
            if dot { Circle().fill(color).frame(width: size * 0.45, height: size * 0.45) }
            Text(text.uppercased()).font(Font(BrandFont.mono(size, 500))).kerning(size * 0.12).foregroundStyle(color)
        }
        .padding(.horizontal, size * 0.75).padding(.vertical, size * 0.45)
        .overlay(RoundedRectangle(cornerRadius: size * 0.45, style: .continuous).strokeBorder(color.opacity(brass || copper ? 0.6 : 0.22), lineWidth: 1))
    }
}

extension View {
    /// Appears with a soft spring from `start`.
    func arrive(_ t: Double, at start: Double, rise: CGFloat = 18, blur: CGFloat = 8) -> some View {
        let p = spring(t, start: start, response: 0.6, damping: 0.88)
        return self.opacity(clamp01(p * 1.3)).blur(radius: CGFloat(1 - clamp01(p)) * blur).offset(y: CGFloat(1 - p) * rise)
    }
}
