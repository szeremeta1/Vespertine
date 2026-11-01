//
// Vespertine — the transitions switch: its glyph, its button and the note shown the first time it's turned on.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// Two of Vespertine's crescents, one passing into the other. Each is the logo's moon: a disc with a disc 0.86 its
/// size cut from it, set 0.42 of its radius right and 0.22 up (docs/brand/logo-mono-ivory.svg). A thin gap keeps the
/// front one apart from the one behind it.
nonisolated struct TransitionsGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let r = side * 0.34
        func crescent(_ cx: CGFloat, _ cy: CGFloat) -> Path {
            let moon = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
            let cut = r * 0.86, x = cx + r * 0.42, y = cy - r * 0.22
            return moon.subtracting(Path(ellipseIn: CGRect(x: x - cut, y: y - cut, width: 2 * cut, height: 2 * cut)))
        }
        let back = crescent(rect.midX - side * 0.15, rect.midY + side * 0.05)
        let front = crescent(rect.midX + side * 0.15, rect.midY - side * 0.05)
        let gap = front.strokedPath(StrokeStyle(lineWidth: side * 0.09, lineJoin: .round))
        return back.subtracting(gap).union(front)
    }
}

/// The master switch as an icon, lit while transitions are on (transport bar, Up Next).
struct TransitionsButton: View {
    @Environment(AppModel.self) private var model
    var size: CGFloat = 14

    var body: some View {
        let on = model.settings.transitions.enabled
        Button { model.toggleTransitions() } label: {
            TransitionsGlyph().frame(width: size + 3, height: size + 3)
        }
        .buttonStyle(TransportIconStyle(active: on))
        .help("Transitions (⌥⌘X)")
        .accessibilityLabel("Transitions")
        .accessibilityValue(on ? String(localized: "On", comment: "Transitions state") : String(localized: "Off", comment: "Transitions state"))
    }
}

/// Shown once, the first time transitions are turned on.
struct TransitionsExplainerSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                TransitionsGlyph()
                    .frame(width: 30, height: 30)
                    .foregroundStyle(Palette.brass)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Transitions").font(Typeface.serif(22)).foregroundStyle(Palette.text)
                    Text("Transitions change the sound only during each fade; the rest of every song stays bit-perfect.")
                        .font(Typeface.ui(12.5)).foregroundStyle(Palette.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
            Hairline()
            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .buttonStyle(BrassButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 420)
        .background(Palette.panel)
    }
}
