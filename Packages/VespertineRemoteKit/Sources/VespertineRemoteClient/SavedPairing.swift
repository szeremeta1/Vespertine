//
// Vespertine Remote: the Macs this phone has paired with, kept in the Keychain (this device only).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Security)
import Foundation
import Security
import VespertineRemoteProtocol

/// What a phone keeps after pairing: which Mac, and the device ID and key the Mac gave it.
public struct SavedPairing: Codable, Sendable, Equatable, Identifiable {
    public var id: String { serverID }
    public var serverID: String
    public var name: String
    public var device: String
    public var key: Data
    public var pairedAt: Date
    /// An address the user typed for this Mac (its Tailscale name, say), for when Bonjour doesn't find it.
    public var address: RemoteAddress?
    /// Where the last connection to this Mac went. The Mac's port can change when Vespertine restarts, and nothing but
    /// Bonjour announces it, so the phone remembers it from each connection.
    public var lastKnown: RemoteAddress?

    public init(serverID: String, name: String, device: String, key: Data, pairedAt: Date = .now,
                address: RemoteAddress? = nil, lastKnown: RemoteAddress? = nil) {
        self.serverID = serverID
        self.name = name
        self.device = device
        self.key = key
        self.pairedAt = pairedAt
        self.address = address
        self.lastKnown = lastKnown
    }

    /// The addresses to try besides Bonjour, most likely first: the typed one (with the last known port if it has
    /// none), then the last known one. Addresses without a port are left out.
    public var savedAddresses: [RemoteAddress] {
        var out: [RemoteAddress] = []
        if let typed = address?.withPort(from: lastKnown), typed.port != nil { out.append(typed) }
        if let lastKnown, lastKnown.port != nil, !out.contains(lastKnown) { out.append(lastKnown) }
        return out
    }

    public var presharedKey: RemoteTransport.PresharedKey {
        .init(identity: device, key: key)
    }
}

/// The saved pairings, as one Keychain item that never leaves this device (no iCloud Keychain, no backups to
/// another device): a key only works from the phone it was given to.
public struct PairingKeychain: Sendable {
    public var service: String

    public init(service: String = "org.szeremeta.VespertineRemote.pairings") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "pairings"]
    }

    public func load() -> [SavedPairing] {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return [] }
        return (try? JSONDecoder().decode([SavedPairing].self, from: data)) ?? []
    }

    @discardableResult
    public func save(_ pairings: [SavedPairing]) -> Bool {
        guard let data = try? JSONEncoder().encode(pairings) else { return false }
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(update) { _, new in new }
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    /// Adds or replaces the pairing for its Mac.
    public func upsert(_ pairing: SavedPairing) {
        var all = load().filter { $0.serverID != pairing.serverID }
        all.append(pairing)
        save(all)
    }

    public func remove(serverID: String) {
        save(load().filter { $0.serverID != serverID })
    }
}
#endif
