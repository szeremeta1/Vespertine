//
// Vespertine: Bluetooth outputs, whose rate and codec belong to macOS and the headset.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A Bluetooth headset runs at one rate at a time and macOS moves it: A2DP (music, AAC) at 44.1 or 48 kHz, or a 24 kHz mono
// call mode (hands-free) for as long as any app has the headset's microphone open ("Hey Siri" listening, a call app, dictation).
// While the microphone is open, macOS refuses a request for any other rate ('!dat', "unsupported format"), so a player that
// insists on a rate never starts: Vespertine 1.1.1 asked AirPods Max for 48 kHz while they were in call mode, was refused,
// waited five seconds and asked again, for ever. So Vespertine never holds, switches or reformats a Bluetooth link: it
// converts the music to the rate the link is at right now, and follows it when macOS moves it.
//

import CoreAudio
import Foundation

extension OutputDevice {
    /// A Bluetooth (classic or LE) output that is a radio link. Not AirPods Max with the USB-C cable in: macOS keeps them on
    /// their Bluetooth device object, but the audio runs over the cable, lossless, and that is an output Vespertine configures.
    public var isBluetoothLink: Bool {
        (transport == .bluetooth || transport == .bluetoothLE) && profile.kind != .airPodsMaxUSB
    }

    /// What a plan may choose from. A Bluetooth link offers the rate it is at and no other: the others it lists are modes
    /// macOS moves it between (call mode is 24 kHz mono), and asking for one is refused for as long as a microphone is open.
    /// The device picker still shows everything the device lists (`capabilities`).
    public var planningCapabilities: DeviceCapabilities {
        guard isBluetoothLink, nominalSampleRate > 0 else { return capabilities }
        var pinned = capabilities
        pinned.sampleRates = [nominalSampleRate]
        return pinned
    }
}

extension SignalPath {
    /// The Bluetooth headset is in its call (hands-free) mode: macOS puts it there while an app has its microphone open, at
    /// 24 kHz or lower, mono. Music over it sounds like a phone call until the microphone is released.
    public var isBluetoothCallMode: Bool {
        (deviceProfile.kind == .bluetooth || deviceProfile.kind == .airPodsMaxBluetooth) && applied.sampleRate < 32_000
    }

    /// What Vespertine did about a Bluetooth link, in plain words. nil for anything else.
    public var bluetoothNote: String? {
        guard deviceProfile.kind == .bluetooth || deviceProfile.kind == .airPodsMaxBluetooth else { return nil }
        let rate = SampleRate.format(applied.sampleRate)
        if isBluetoothCallMode {
            return String(localized: "\(deviceName) is in call mode (macOS does this while an app has its microphone open), so it plays at \(rate) kHz, mono, like a phone call. Vespertine doesn't change a Bluetooth link; music returns to full quality when the microphone is released.",
                          comment: "Signal path: a Bluetooth headset is in its hands-free call mode. %1$@ is the headset's name, %2$@ the rate in kHz.")
        }
        if plan.resamples {
            return String(localized: "Bluetooth sets this link to \(rate) kHz; Vespertine leaves it alone and converts the music to it.",
                          comment: "Signal path: a Bluetooth link's rate was kept and the music converted to it. %@ is the rate in kHz.")
        }
        return String(localized: "Bluetooth sets this link to \(rate) kHz; Vespertine leaves it alone.",
                      comment: "Signal path: a Bluetooth link's rate was kept. %@ is the rate in kHz.")
    }
}
