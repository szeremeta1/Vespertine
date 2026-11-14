//
// Vespertine: the shares this phone plays from, with their passwords, kept in the Keychain (this device only).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

/// A share the user added: where it is, what it is called here, and the password it is signed in to with.
public struct SavedShare: Codable, Sendable, Equatable, Identifiable {
    /// `share-` and a random part: what the share's session, index and kept songs are filed under.
    public var id: String
    public var name: String
    public var address: ShareAddress
    public var password: String
    public var addedAt: Date

    public init(id: String = SavedShare.newID(), name: String, address: ShareAddress, password: String, addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.address = address
        self.password = password
        self.addedAt = addedAt
    }

    public static func newID() -> String { ShareMac.prefix + UUID().uuidString.lowercased() }

    /// The name shown when none was typed: the share's own, or its last folder.
    public static func suggestedName(for address: ShareAddress) -> String {
        address.folder.split(separator: "/").last.map(String.init) ?? address.share
    }

    /// The share's files, on a connection that is made when first needed.
    public func files(timeout: TimeInterval = 15) -> SMBShare { SMBShare(address: address, password: password, timeout: timeout) }
}

#if canImport(Security)
import Security

/// The saved shares, as one Keychain item that never leaves this device (no iCloud Keychain, no backups to another
/// device): a password typed here stays here.
public struct ShareKeychain: Sendable {
    public var service: String

    public init(service: String = "org.szeremeta.VespertineRemote.shares") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "shares"]
    }

    public func load() -> [SavedShare] {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return [] }
        return (try? JSONDecoder().decode([SavedShare].self, from: data)) ?? []
    }

    @discardableResult
    public func save(_ shares: [SavedShare]) -> Bool {
        guard let data = try? JSONEncoder().encode(shares) else { return false }
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

    /// Adds the share, or replaces the one with its ID.
    public func upsert(_ share: SavedShare) {
        var all = load().filter { $0.id != share.id }
        all.append(share)
        save(all)
    }

    public func remove(id: String) {
        save(load().filter { $0.id != id })
    }
}
#endif
