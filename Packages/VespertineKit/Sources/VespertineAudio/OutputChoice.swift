//
// Vespertine — which output plays when the one you chose isn't connected.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// What plays when the output you chose isn't connected (a DAC unplugged, AirPods in their case).
public enum OutputFallback: String, CaseIterable, Sendable, Identifiable {
    /// The most capable output that is connected: an external DAC first, then the Mac's sound output.
    case bestAvailable
    /// The Mac's sound output (System Settings → Sound).
    case systemDefault
    /// Nothing: playback waits for the chosen output to come back.
    case waitForChosen

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .bestAvailable: "The best connected output"
        case .systemDefault: "The Mac's sound output"
        case .waitForChosen: "Nothing (wait for it)"
        }
    }
}

/// An output as remembered between launches, to recognize it when macOS gives it another UID: some USB DACs
/// without a serial number get a new one in another port or behind a hub.
public struct OutputIdentity: Codable, Sendable, Hashable {
    public var uid: String
    public var name: String
    public var manufacturer: String
    public var modelUID: String?
    public var transport: Transport

    public init(_ device: OutputDevice) {
        uid = device.uid
        name = device.name
        manufacturer = device.manufacturer
        modelUID = device.modelUID
        transport = device.transport
    }

    public init(uid: String, name: String, manufacturer: String = "", modelUID: String? = nil, transport: Transport = .unknown) {
        self.uid = uid
        self.name = name
        self.manufacturer = manufacturer
        self.modelUID = modelUID
        self.transport = transport
    }
}

public enum OutputChoice {
    /// The output that plays in place of a chosen one that isn't connected, nil to wait for it.
    public static func substitute(among devices: [OutputDevice], fallback: OutputFallback) -> OutputDevice? {
        switch fallback {
        case .waitForChosen: return nil
        case .systemDefault: return devices.first(where: \.isDefault) ?? best(among: devices)
        case .bestAvailable: return best(among: devices)
        }
    }

    /// The most capable output connected. External DACs and interfaces (USB, Thunderbolt, PCI, FireWire) come first,
    /// then the Mac's sound output, then its own speakers and headphone jack, then the rest (HDMI, Bluetooth,
    /// AirPlay). Within each, the highest sample rate wins, then DoP, then integer formats and bit depth. Virtual
    /// outputs (meeting apps, loopback drivers) and aggregates are only chosen when there's nothing else.
    public static func best(among devices: [OutputDevice]) -> OutputDevice? {
        let real = devices.filter { $0.transport != .virtual && $0.transport != .aggregate }
        return (real.isEmpty ? devices : real).max { rank($0).lexicographicallyPrecedes(rank($1)) }
    }

    static func rank(_ device: OutputDevice) -> [Double] {
        let tier: Double = switch device.transport {
        case .usb, .thunderbolt, .pci, .fireWire: 3
        case _ where device.isDefault: 2
        case .builtIn: 1
        default: 0
        }
        let caps = device.capabilities
        let integerDepth = caps.physicalFormats.filter(\.isInteger).map(\.bitDepth).max() ?? 0
        return [tier, caps.sampleRates.last ?? device.nominalSampleRate, caps.supportsDoP ? 1 : 0, Double(integerDepth),
                Double(caps.outputChannels), device.isDefault ? 1 : 0]
    }

    /// A connected output that is `remembered` under a new UID: same name, transport and model, and the only one
    /// like it (two identical DACs can't be told apart, so neither is taken for the other).
    public static func sameOutput(as remembered: OutputIdentity, among devices: [OutputDevice]) -> OutputDevice? {
        guard !devices.contains(where: { $0.uid == remembered.uid }) else { return nil }
        let matches = devices.filter { d in
            d.name == remembered.name && d.transport == remembered.transport && d.manufacturer == remembered.manufacturer
                && (d.modelUID == nil || remembered.modelUID == nil || d.modelUID == remembered.modelUID)
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
