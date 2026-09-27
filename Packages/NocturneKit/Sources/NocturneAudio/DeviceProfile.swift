//
// Nocturne — known-device knowledge (AirPods Max over USB-C, Bluetooth caveats, …).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public struct DeviceProfile: Sendable, Hashable {
    public enum Kind: String, Sendable {
        case airPodsMaxUSB       // AirPods Max (USB-C) / AirPods Max 2 on the cable: 24-bit / 48 kHz lossless
        case airPodsMaxBluetooth // same headphones over Bluetooth: AAC, not lossless
        case bluetooth
        case airPlay
        case builtIn
        case usbDAC
        case other
    }

    public var kind: Kind
    /// Short tag shown next to the device, e.g. "USB-C · LOSSLESS".
    public var tag: String
    /// One-sentence explanation for the device picker and signal-path view.
    public var note: String?
    /// Whether a bit-perfect path to the transducer is possible at all.
    public var canBeBitPerfect: Bool
    public var symbol: String

    public static func detect(_ device: OutputDevice) -> DeviceProfile {
        let name = device.name.lowercased()
        let isAirPodsMax = name.contains("airpods max")

        switch device.transport {
        case .usb where isAirPodsMax:
            return DeviceProfile(
                kind: .airPodsMaxUSB, tag: "USB-C · LOSSLESS",
                note: "AirPods Max take lossless 24-bit / 48 kHz over USB-C. Other rates are converted to 48 kHz; 48 kHz material plays bit-perfect.",
                canBeBitPerfect: true, symbol: "headphones")
        case .bluetooth, .bluetoothLE:
            if isAirPodsMax {
                return DeviceProfile(
                    kind: .airPodsMaxBluetooth, tag: "BLUETOOTH · AAC",
                    note: "Over Bluetooth, AirPods Max receive AAC, which is lossy. Connect the USB-C cable for lossless 24-bit / 48 kHz.",
                    canBeBitPerfect: false, symbol: "headphones")
            }
            return DeviceProfile(
                kind: .bluetooth, tag: "BLUETOOTH",
                note: "Bluetooth re-encodes audio with a lossy codec, so the output can't be bit-perfect.",
                canBeBitPerfect: false, symbol: name.contains("airpods") || name.contains("headphone") ? "headphones" : "hifispeaker")
        case .airPlay:
            return DeviceProfile(kind: .airPlay, tag: "AIRPLAY", note: "AirPlay streams at 44.1 kHz; the receiver controls the final format.",
                                 canBeBitPerfect: false, symbol: "airplay.audio")
        case .builtIn:
            let speakers = name.contains("speaker")
            return DeviceProfile(kind: .builtIn, tag: "BUILT-IN", note: nil, canBeBitPerfect: true,
                                 symbol: speakers ? "laptopcomputer" : "headphones")
        case .usb, .thunderbolt, .fireWire, .pci:
            return DeviceProfile(kind: .usbDAC, tag: device.transport.label.uppercased(), note: nil, canBeBitPerfect: true,
                                 symbol: "hifireceiver")
        default:
            return DeviceProfile(kind: .other, tag: device.transport.label.uppercased(), note: nil, canBeBitPerfect: true,
                                 symbol: "speaker.wave.2")
        }
    }
}
