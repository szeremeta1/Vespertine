//
// Vespertine: known-device knowledge (AirPods Max over USB-C, Bluetooth caveats, …).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import IOKit

/// The AirPods Max models for which Vespertine ships an individual correction.
public enum AirPodsMaxEQModel: Hashable, Sendable {
    case usbCFirstGeneration
    case secondGeneration

    /// Bluetooth product IDs from Apple's AirPods model registry (A3184 = 0x201F, A3454 = 0x202D).
    public static func from(productID: UInt32) -> AirPodsMaxEQModel? {
        switch productID {
        case 0x201F: .usbCFirstGeneration
        case 0x202D: .secondGeneration
        default: nil
        }
    }
}

public struct DeviceProfile: Sendable, Hashable {
    public enum Kind: String, Sendable {
        case airPodsMaxUSB       // AirPods Max (USB-C) / AirPods Max 2 on the cable: 24-bit / 48 kHz lossless
        case airPodsMaxBluetooth // same headphones over Bluetooth: AAC, not lossless
        case bluetooth
        case airPlay
        case builtIn
        case speakers            // the Mac's own speakers: macOS tunes them with its own processing
        case virtualDevice       // aggregate, multi-output and virtual devices: the audio goes on to something else
        case speakerGroup        // Vespertine's own speaker group: several DACs as one output (its badge comes from the members)
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
        if device.uid.hasPrefix(SpeakerGroup.outputUIDPrefix) {
            var profile = speakerGroup(canBeBitPerfect: false)
            profile.connection = "Speaker group"
            return profile
        }
        var profile = classify(device)
        profile.connection = profile.kind == .airPodsMaxUSB ? String(localized: "USB-C (lossless)") : device.transport.label
        return profile
    }

    /// The tag of an aggregate or multi-output device (also how the signal path tells it from a virtual one).
    static var aggregateTag: String { String(localized: "AGGREGATE", comment: "Short uppercase tag for an aggregate or multi-output device.") }

    /// A speaker group (several DACs played as one). Whether it can be bit-perfect depends on the members, so the caller says
    /// (`GroupSignalPath.isBitPerfect`) rather than the kind fixing it.
    public static func speakerGroup(canBeBitPerfect: Bool) -> DeviceProfile {
        DeviceProfile(kind: .speakerGroup, tag: "SPEAKER GROUP",
                      note: "Several DACs played as one output. The DAC that leads the clock can be bit-perfect; the others are resampled by a few millionths to stay in step with it.",
                      canBeBitPerfect: canBeBitPerfect, symbol: "hifispeaker.2")
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
                kind: .airPodsMaxUSB, tag: String(localized: "USB-C · LOSSLESS", comment: "Short uppercase tag shown next to the device."),
                note: String(localized: "AirPods Max take lossless 24-bit / 48 kHz over USB-C. Other rates are converted to 48 kHz; 48 kHz material plays bit-perfect. (macOS still lists them as Bluetooth; that's only the control link.)"),
                canBeBitPerfect: true, symbol: "headphones")
        case .bluetooth, .bluetoothLE:
            if isAirPodsMax {
                return DeviceProfile(
                    kind: .airPodsMaxBluetooth, tag: String(localized: "BLUETOOTH · AAC", comment: "Short uppercase tag shown next to the device."),
                    note: String(localized: "Over Bluetooth, AirPods Max receive AAC, which is lossy. Connect the USB-C cable for lossless 24-bit / 48 kHz."),
                    canBeBitPerfect: false, symbol: "headphones")
            }
            return DeviceProfile(
                kind: .bluetooth, tag: String(localized: "BLUETOOTH", comment: "Short uppercase tag shown next to the device."),
                note: String(localized: "Bluetooth re-encodes audio with a lossy codec, so the output can't be bit-perfect."),
                canBeBitPerfect: false, symbol: name.contains("airpods") || name.contains("headphone") ? "headphones" : "hifispeaker")
        case .airPlay:
            return DeviceProfile(kind: .airPlay, tag: String(localized: "AIRPLAY", comment: "Short uppercase tag shown next to the device."),
                                 note: String(localized: "AirPlay streams at 44.1 kHz; the receiver controls the final format."),
                                 canBeBitPerfect: false, symbol: "airplay.audio")
        case .builtIn:
            let speakers = isBuiltInSpeaker(uid: device.uid, name: name, dataSource: device.builtInDataSource)
            return DeviceProfile(kind: speakers ? .speakers : .builtIn, tag: String(localized: "BUILT-IN", comment: "Short uppercase tag shown next to the device."),
                                 note: speakers ? String(localized: "macOS tunes the Mac's own speakers with processing of its own, so music can't reach them bit-perfect.") : nil,
                                 canBeBitPerfect: !speakers, symbol: speakers ? "laptopcomputer" : "headphones")
        case .aggregate, .virtual:
            let aggregate = device.transport == .aggregate
            return DeviceProfile(
                kind: .virtualDevice, tag: aggregate ? aggregateTag : String(localized: "VIRTUAL", comment: "Short uppercase tag for a virtual audio device."),
                note: aggregate
                    ? String(localized: "An aggregate or multi-output device hands the audio on to the devices inside it, and can resample it to keep them in step, so what reaches them can't be promised bit-perfect.")
                    : String(localized: "A virtual device (an equalizer, a recorder, a router) hands the audio on to other software, which can change it, so what reaches your speakers can't be promised bit-perfect."),
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

extension DeviceProfile {
    /// The data sources of a built-in output: the Mac's speakers and the headphone jack.
    static let internalSpeakerSource: UInt32 = 0x6973_706B   // 'ispk'
    static let headphonesSource: UInt32 = 0x6864_706E        // 'hdpn'

    /// Whether a built-in output is the Mac's own speakers. macOS names them in the system's language ("Haut-parleurs
    /// MacBook Pro", "MacBook Pro-Lautsprecher"), so the name is the last resort: the data source says it on any Mac, and
    /// on Apple silicon the speakers are their own device, "BuiltInSpeakerDevice".
    static func isBuiltInSpeaker(uid: String, name: String, dataSource: UInt32?) -> Bool {
        if dataSource == internalSpeakerSource { return true }
        if dataSource == headphonesSource { return false }
        return uid.localizedCaseInsensitiveContains("BuiltInSpeaker") || name.lowercased().contains("speaker")
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
