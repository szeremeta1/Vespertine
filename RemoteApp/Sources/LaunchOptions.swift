//
// Vespertine Remote: launch arguments for taking screenshots and trying screens in the Simulator (debug builds only):
//   -VTDemo YES                  open the demo Mac
//   -VTScreen <name>             nowPlaying | library | albums | coverFlow | album | queue | output | settings | connection | macs
//   -VTVinyl YES|NO              Now Playing's record on or off
//   -VTTilt "x,y"                a fixed tilt for Cover Flow (-1…1 each), since the Simulator has no gyroscope
//   -VTSamplePairing YES         a made-up paired Mac with a Tailscale address (never saved)
//   -VTPlay YES                  start the demo playing
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if DEBUG
import Foundation

enum LaunchOptions {
    private static var defaults: UserDefaults { .standard }

    static var demo: Bool { defaults.bool(forKey: "VTDemo") }
    static var screen: String? { defaults.string(forKey: "VTScreen") }
    static var samplePairing: Bool { defaults.bool(forKey: "VTSamplePairing") }
    static var play: Bool { defaults.bool(forKey: "VTPlay") }
    static var vinyl: Bool? { defaults.object(forKey: "VTVinyl") == nil ? nil : defaults.bool(forKey: "VTVinyl") }

    static var tilt: Tilt? {
        guard let text = defaults.string(forKey: "VTTilt") else { return nil }
        let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        return Tilt(x: max(-1, min(1, parts[0])), y: max(-1, min(1, parts[1])))
    }
}
#endif
