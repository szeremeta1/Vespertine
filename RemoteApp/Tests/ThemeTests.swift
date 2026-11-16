//
// Vespertine Remote: the colours are asked for by whoever draws. SwiftUI draws animated transitions on a thread of its own
// and resolves each colour there, so a colour that insisted on the main thread stopped the app (the crash on "Choose
// Another Mac" and on opening an album).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import SwiftUI
import Testing
import UIKit
@testable import VespertineRemote

@Suite struct PaletteColours {
    @Test func aColourResolvesOffTheMainThread() async {
        nonisolated(unsafe) let colour = Palette.dynamic(light: 0xECE6DA, dark: 0x09090A)
        let (light, dark): ([CGFloat], [CGFloat]) = await Task.detached {
            func parts(_ style: UIUserInterfaceStyle) -> [CGFloat] {
                var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
                colour.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
                return [r, g, b].map { ($0 * 255).rounded() }
            }
            return (parts(.light), parts(.dark))
        }.value
        #expect(light == [0xEC, 0xE6, 0xDA])
        #expect(dark == [0x09, 0x09, 0x0A])
    }

    /// The AirPlay button is UIKit's: its two colours are the palette's own, in both appearances.
    @Test @MainActor func theAirPlayButtonUsesThePalette() {
        func parts(_ colour: UIColor, _ style: UIUserInterfaceStyle) -> [CGFloat] {
            var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            colour.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b].map { ($0 * 255).rounded() }
        }
        #expect(parts(Palette.brassUI, .dark) == [0xC8, 0xA6, 0x6A])
        #expect(parts(Palette.brassUI, .light) == [0x7C, 0x65, 0x41])
        #expect(parts(UIColor(Palette.brass), .dark) == parts(Palette.brassUI, .dark))
        #expect(parts(UIColor(Palette.text2), .light) == parts(Palette.text2UI, .light))
    }

    /// It shows only while this device is the one playing: it can't change where a Mac plays.
    @Test func theAirPlayButtonShowsOnlyWhenThisDevicePlays() {
        #expect(RoutePickerPlacement.shows(playsHere: true))
        #expect(!RoutePickerPlacement.shows(playsHere: false))
    }

    @Test func aBadgeRowIsLaidOutOffTheMainThread() async {
        let placed = await Task.detached {
            FlowRows.place([CGSize(width: 80, height: 20), CGSize(width: 80, height: 20)], width: 100, spacing: 6, lineSpacing: 6, centered: false)
        }.value
        #expect(placed.origins.count == 2 && placed.origins[1].y > 0)
    }
}
