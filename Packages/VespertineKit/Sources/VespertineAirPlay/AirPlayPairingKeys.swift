//
// Vespertine: what the app keeps, and does, to play to a receiver that shows a PIN (an Apple TV set to ask once). The
// receiver puts the PIN on its screen, the listener types it, and what comes of the exchange (this Mac's name and key,
// the receiver's name and key) is kept so every later session opens with no PIN. The kept values are opaque here: the
// app stores them as they encode (in the keychain) and hands them back.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network
import SystemConfiguration

/// This Mac as receivers know it once paired: one for the Mac, made once and kept.
public struct AirPlayPairingIdentity: Codable, Sendable, Equatable {
    let identity: PairingIdentity

    /// A new one, with a random name and key.
    public init() { identity = PairingIdentity() }

    init(_ identity: PairingIdentity) { self.identity = identity }
}

/// A pairing with one receiver: this Mac's identity as it was then, and the receiver's name and key.
public struct AirPlayPairingKeys: Codable, Sendable, Equatable {
    let identity: PairingIdentity
    let receiver: PairedReceiver

    init(identity: PairingIdentity, receiver: PairedReceiver) {
        self.identity = identity
        self.receiver = receiver
    }
}

/// Pairing with a receiver by the PIN on its screen. `begin()` makes the receiver show the PIN; `finish(pin:identity:)`
/// trades keys. After a wrong PIN the receiver wants to show a new one: `begin()` again.
public actor AirPlayPINPairing {
    private let endpoint: NWEndpoint
    private var connection: RTSPConnection?
    private var exchange: PairingExchange?

    /// nil when the device has nowhere to connect to for AirPlay 2.
    public init?(device: AirPlayDevice) {
        guard device.airPlay2Entry != nil, let endpoint = AirPlayPlayback.endpoint(for: device, airPlay2: true) else { return nil }
        self.endpoint = endpoint
    }

    init(endpoint: NWEndpoint) { self.endpoint = endpoint }

    /// Connects and asks the receiver to show its PIN.
    public func begin() async throws {
        await cancel()
        let made = RTSPConnection(endpoint: endpoint)
        connection = made
        do {
            try await made.connect()
            let exchange = PairingExchange(connection: made)
            try await exchange.showPIN()
            self.exchange = exchange
        } catch {
            await cancel()
            throw error
        }
    }

    /// Trades keys with the receiver, which is showing `pin`. Whatever comes of it, the connection is closed.
    public func finish(pin: String, identity: AirPlayPairingIdentity) async throws -> AirPlayPairingKeys {
        try await finish(pin: pin, identity: identity, secret: nil)
    }

    /// `secret`: SRP's private number (random unless a test gives one).
    func finish(pin: String, identity: AirPlayPairingIdentity, secret: Data?) async throws -> AirPlayPairingKeys {
        guard let exchange else { throw RAOPError.closed }
        do {
            let receiver = try await exchange.setup(pin: pin.trimmingCharacters(in: .whitespaces), identity: identity.identity, secret: secret)
            await cancel()
            return AirPlayPairingKeys(identity: identity.identity, receiver: receiver)
        } catch {
            await cancel()
            throw error
        }
    }

    /// Lets go of the receiver (its PIN goes from the screen by itself).
    public func cancel() async {
        let open = connection
        connection = nil
        exchange = nil
        await open?.close()
    }
}

extension AirPlay2Sender {
    /// This Mac: its name, model and macOS version, and a device ID made up for this run of Vespertine (never the Mac's
    /// real network address).
    static let thisMac: AirPlay2Sender = {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...UInt8.max) }
        // "Locally administered", and not a group address: the form made-up addresses take.
        bytes[0] = (bytes[0] | 0x02) & 0xFE
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return AirPlay2Sender(deviceID: deviceID(bytes), name: (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac", model: hardwareModel(),
                              osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
    }()

    /// "Mac14,5"; "Mac" when the system doesn't say.
    static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "Mac" }
        let model = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return model.isEmpty ? "Mac" : model
    }
}
