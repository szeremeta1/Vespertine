//
// Nocturne — format badges ("DOLBY | ATMOS", "DSD | 256").
// SPDX-License-Identifier: GPL-3.0-or-later
//

import NocturneLibrary
import SwiftUI

/// The format's name in Nocturne's own badge style ("DOLBY ATMOS", "DSD256"), plus what carries it.
/// Deliberately plain: the same mono type and outline as every other badge, never a company's logo or
/// lettering, so it reads as a description of the file and not a certification mark.
struct FormatMarkView: View {
    let mark: FormatMark
    var size: CGFloat = 10
    var showsCarrier = true

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { plate; carrierText }
            VStack(alignment: .leading, spacing: 6) { plate; carrierText }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mark.text + (mark.carrier.map { ", \($0)" } ?? ""))
    }

    private var plate: some View {
        Text(mark.product.isEmpty ? mark.brand : "\(mark.brand) \(mark.product)")
            .font(Typeface.mono(size, weight: .semibold))
            .tracking(1)
            .foregroundStyle(ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ink.opacity(0.45), lineWidth: 1))
            .fixedSize()
    }

    @ViewBuilder private var carrierText: some View {
        if showsCarrier, let carrier = mark.carrier {
            Text(carrier.uppercased()).font(Typeface.mono(size * 0.9)).tracking(0.8).foregroundStyle(Palette.text3).fixedSize()
        }
    }

    /// Surround formats in silver, audiophile ones in brass.
    private var ink: Color {
        switch mark.family {
        case .dolby, .dts: Palette.text
        case .dsd, .hiRes: Palette.brassHi
        case .lossless: Palette.text2
        }
    }
}
