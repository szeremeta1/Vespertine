//
// Vespertine Remote: the system's AirPlay button, for when music plays on this device: a tap lists the AirPlay speakers,
// Bluetooth headphones and other outputs iOS can send this device's sound to, without leaving the app.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import AVKit
import SwiftUI

/// The AirPlay button, in the app's colours: quiet until an AirPlay output is in use, then brass. iOS draws the symbol,
/// names it for VoiceOver in the system's language and shows its own list of outputs.
struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = Palette.text2UI
        picker.activeTintColor = Palette.brassUI
        picker.prioritizesVideoDevices = false
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {}
}

nonisolated enum RoutePickerPlacement {
    /// The button changes where this device's own sound goes, so it shows only while this device is the one playing:
    /// beside a Mac's outputs it would promise something it can't do.
    static func shows(playsHere: Bool) -> Bool { playsHere }
}
