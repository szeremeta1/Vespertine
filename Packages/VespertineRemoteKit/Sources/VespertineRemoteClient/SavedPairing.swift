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
    /// Where the Mac said it can be reached, the last time it was asked (`ServerInfo.addresses`): its addresses at home and
    /// its Tailscale or VPN address. This is what finds the Mac from away without anybody typing anything.
    public var advertised: [RemoteAddress]?
    /// The Mac said it is a notebook, the last time it was asked (nil: it never said).
    public var portable: Bool?

    /// The SF Symbol that pictures a Mac: a notebook when it says it is one, else the small desktop (a music Mac is
    /// most often one, and nothing says which desktop it is).
    public static func symbol(portable: Bool?) -> String { portable == true ? "laptopcomputer" : "macmini" }

    public init(serverID: String, name: String, device: String, key: Data, pairedAt: Date = .now,
                address: RemoteAddress? = nil, lastKnown: RemoteAddress? = nil, advertised: [RemoteAddress]? = nil) {
        self.serverID = serverID
        self.name = name
        self.device = device
        self.key = key
        self.pairedAt = pairedAt
        self.address = address
        self.lastKnown = lastKnown
        self.advertised = advertised
    }

    /// The most addresses tried at once besides Bonjour.
    public static let maximumAddresses = 10

    /// The addresses to try besides Bonjour, most likely first: the typed one (with the last known port if it has
    /// none), the ones the Mac told (home first, then Tailscale), then the last known one; then the typed and last known
    /// hosts at the port the Mac tries first (`RemotePort.preferred`), for a Mac that restarted on it (and for a pairing
    /// made before the port was fixed). A host with no port known anywhere is only tried at that port.
    public var savedAddresses: [RemoteAddress] {
        var out: [RemoteAddress] = []
        func add(_ address: RemoteAddress?) {
            if let address, address.port != nil, !out.contains(address) { out.append(address) }
        }
        add(address?.withPort(from: lastKnown ?? advertised?.first))
        for told in advertised ?? [] { add(told) }
        add(lastKnown)
        for host in [address?.host, lastKnown?.host] {
            if let host { add(RemoteAddress(host: host, port: RemotePort.preferred)) }
        }
        return Array(out.prefix(Self.maximumAddresses))
    }

    /// This pairing after the Mac said hello: its name, and the addresses it can be reached at now. A Mac that tells no
    /// addresses (an older Vespertine) leaves the ones known alone.
    public func noting(server: ServerInfo) -> SavedPairing {
        var copy = self
        if !server.name.isEmpty { copy.name = server.name }
        if let portable = server.portable { copy.portable = portable }
        if let told = server.addresses, !told.isEmpty {
            copy.advertised = Array(told.filter { $0.port != nil }.prefix(LocalAddresses.maximumAdvertised))
        }
        return copy
    }

    /// Whether any saved way to this Mac works from another network (a Tailscale or VPN address, or a typed one).
    public var hasRouteFromAway: Bool {
        savedAddresses.contains { $0.kind != .localNetwork }
    }

    /// Whether a Tailscale address or name is among the saved ways.
    public var hasTailscaleRoute: Bool {
        savedAddresses.contains { $0.kind == .tailscale }
    }

    /// This pairing after the Mac announced `port` (Bonjour TXT): where it was last seen moves to that port, so a typed
    /// name reached from away (Tailscale) uses it. A typed address with a port of its own is the user's choice and stays.
    public func noting(advertisedPort port: UInt16) -> SavedPairing {
        var copy = self
        if let host = lastKnown?.host ?? address?.host, lastKnown?.port != port {
            copy.lastKnown = RemoteAddress(host: host, port: port)
        }
        if let told = advertised { copy.advertised = told.map { RemoteAddress(host: $0.host, port: port) } }
        return copy
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

#if canImport(Security)
/// Why a paired Mac can't be reached right now, as far as the phone can tell.
public enum ReachTrouble: Equatable, Sendable {
    /// This device has no network at all.
    case offline
    /// The Mac isn't on this network, and it is only known by addresses that work at home.
    case notOnThisNetwork
    /// The Mac has a Tailscale address, but Tailscale isn't connected on this device.
    case tailscaleOff
    /// There is a way to the Mac and nothing answers on it: asleep, off, or Vespertine isn't open.
    case notAnswering
}

public extension SavedPairing {
    /// `nearby`: Bonjour lists the Mac on this network. `tailscaleOn`: this device has a Tailscale address
    /// (`LocalAddresses.hasTailscale`).
    func trouble(online: Bool, nearby: Bool, tailscaleOn: Bool) -> ReachTrouble {
        if !online { return .offline }
        if nearby { return .notAnswering }
        if hasTailscaleRoute, !tailscaleOn {
            // Another way from away (a typed address, another VPN) may still work: then the Mac itself isn't answering.
            return savedAddresses.contains { $0.kind == .other } ? .notAnswering : .tailscaleOff
        }
        return hasRouteFromAway ? .notAnswering : .notOnThisNetwork
    }
}
#endif
