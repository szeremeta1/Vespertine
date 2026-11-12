//
// Vespertine: DoP auto-setup for DACs that aren't on the known list: when to suggest the test, and what its answer saves.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// What the signal path should say about DoP for the output now playing DSD as PCM.
public enum DoPSetupHint: Equatable, Sendable {
    /// Nothing: a known DAC, a choice already made, no DoP carrier, or not a USB-class output.
    case none
    /// An unknown DAC that offers the DoP carrier rate: the one-tap test is offered, with no claim about the DAC.
    case offerTest
    /// The same, and its maker is on the DSD-capable list: DoP is suggested, naming the maker.
    case suggestTest(maker: String)

    /// The lowest rate DoP needs: DSD64 is carried at 176.4 kHz.
    public static let minimumCarrierRate: Double = 176_400

    /// `on` and `off` are the user's stored DoP choices (`dopDeviceUIDs`, `dopOffDeviceUIDs`): a device in either has been
    /// decided, by the DoP switch or by the test, and is left alone.
    public static func decide(identity: DoPDeviceIdentity, transport: Transport, capabilities: DeviceCapabilities,
                              on: Set<String>, off: Set<String>, list: DoPDACList) -> DoPSetupHint {
        guard transport == .usb || transport == .thunderbolt else { return .none }
        guard !capabilities.supportsDoP, !on.contains(identity.uid), !off.contains(identity.uid) else { return .none }
        guard list.knownDAC(for: identity) == nil else { return .none }
        guard let top = capabilities.sampleRates.max(), top >= minimumCarrierRate - 0.5 else { return .none }
        if let maker = list.maker(for: identity) { return .suggestTest(maker: maker.name) }
        return .offerTest
    }
}

/// What the listener heard.
public enum DoPTestOutcome: Sendable {
    case music
    case hiss
}

/// The user's DoP choices, as the app stores them: a set of UIDs with DoP on and one with it off. The test's answer goes
/// into the same two sets as the DoP switch, so everything that reads the switch (the engine, the device list, the
/// UID-change migration) already honours it.
public struct DoPChoices: Equatable, Sendable {
    public var on: Set<String>
    public var off: Set<String>

    public init(on: Set<String>, off: Set<String>) { self.on = on; self.off = off }

    public mutating func record(_ outcome: DoPTestOutcome, for uid: String) {
        switch outcome {
        case .music: on.insert(uid); off.remove(uid)
        case .hiss: on.remove(uid); off.insert(uid)
        }
    }
}
