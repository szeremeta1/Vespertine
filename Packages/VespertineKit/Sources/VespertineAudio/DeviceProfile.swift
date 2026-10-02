//
// Vespertine — known-device knowledge (AirPods Max over USB-C, Bluetooth caveats, …).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import IOKit

public struct DeviceProfile: Sendable, Hashable {
    public enum Kind: String, Sendable {
        case airPodsMaxUSB       // AirPods Max (USB-C) / AirPods Max 2 on the cable: 24-bit / 48 kHz lossless
        case airPodsMaxBluetooth // same headphones over Bluetooth: AAC, not lossless
        case bluetooth
        case airPlay
        case builtIn
        case speakers            // the Mac's own speakers: macOS tunes them with its own processing
        case virtualDevice       // aggregate, multi-output and virtual devices: the audio goes on to something else
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
    /// Plain-language connection, e.g. "USB", "USB-C (lossless)", "Bluetooth".
    public var connection: String = ""

    public static func detect(_ device: OutputDevice) -> DeviceProfile {
        var profile = classify(device)
        profile.connection = profile.kind == .airPodsMaxUSB ? "USB-C (lossless)" : device.transport.label
        return profile
    }

    private static func classify(_ device: OutputDevice) -> DeviceProfile {
        let name = device.name.lowercased()
        let isAirPodsMax = name.contains("airpods max")

        // macOS keeps AirPods Max on their Bluetooth device object even when audio runs over the USB-C cable
        // (Bluetooth stays the control link). The tell is Apple's USB audio interface being attached.
        let usbAudioActive = isAirPodsMax && USBRegistry.isConnected(productContaining: "AirPods Max USB Audio")

        switch device.transport {
        case .usb where isAirPodsMax, .bluetooth where usbAudioActive, .bluetoothLE where usbAudioActive:
            return DeviceProfile(
                kind: .airPodsMaxUSB, tag: "USB-C · LOSSLESS",
                note: "AirPods Max take lossless 24-bit / 48 kHz over USB-C. Other rates are converted to 48 kHz; 48 kHz material plays bit-perfect. (macOS still lists them as Bluetooth; that's only the control link.)",
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
            return DeviceProfile(kind: speakers ? .speakers : .builtIn, tag: "BUILT-IN",
                                 note: speakers ? "macOS tunes the Mac's own speakers with processing of its own, so music can't reach them bit-perfect." : nil,
                                 canBeBitPerfect: !speakers, symbol: speakers ? "laptopcomputer" : "headphones")
        case .aggregate, .virtual:
            let aggregate = device.transport == .aggregate
            return DeviceProfile(
                kind: .virtualDevice, tag: aggregate ? "AGGREGATE" : "VIRTUAL",
                note: aggregate
                    ? "An aggregate or multi-output device hands the audio on to the devices inside it, and can resample it to keep them in step, so what reaches them can't be promised bit-perfect."
                    : "A virtual device (an equalizer, a recorder, a router) hands the audio on to other software, which can change it, so what reaches your speakers can't be promised bit-perfect.",
                canBeBitPerfect: false, symbol: "speaker.wave.2")
        case .usb, .thunderbolt, .fireWire, .pci:
            return DeviceProfile(kind: .usbDAC, tag: device.transport.label.uppercased(), note: nil, canBeBitPerfect: true,
                                 symbol: "hifireceiver")
        default:
            return DeviceProfile(kind: .other, tag: device.transport.label.uppercased(), note: nil, canBeBitPerfect: true,
                                 symbol: "speaker.wave.2")
        }
    }
}

/// Minimal IOKit lookup: is a USB device with this product name attached?
enum USBRegistry {
    static func isConnected(productContaining name: String) -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let product = IORegistryEntryCreateCFProperty(service, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String, product.localizedCaseInsensitiveContains(name) {
                return true
            }
        }
        return false
    }
}
