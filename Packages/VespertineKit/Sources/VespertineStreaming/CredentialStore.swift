//
// Vespertine: where a streaming account's credential lives between launches: one generic-password item in the login Keychain
// for each provider and account, and nowhere else. Memory in tests. Generalised from the token store marcocebrian wrote for
// TIDAL in #323.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Security

/// Holds each account's credential as the bytes its provider chose (JSON). A credential is never written to UserDefaults, the
/// library database, a log, crash text, the remote protocol or a URL kept on disk: this store is the one place.
public protocol CredentialStore: Sendable {
    func load(provider: String, account: String) -> Data?
    func save(_ credential: Data, provider: String, account: String) throws
    /// Signing out deletes the item.
    func delete(provider: String, account: String)
}

/// One generic-password item for each provider and account: service "org.szeremeta.vespertine.streaming.<provider>", account
/// the account's id. (The data-protection keychain would need a provisioning profile, which a Developer ID build doesn't have.)
public struct KeychainCredentialStore: CredentialStore {
    public static let servicePrefix = "org.szeremeta.vespertine.streaming."
    private let prefix: String

    /// `servicePrefix`: tests use one of their own, so they never touch a listener's items.
    public init(servicePrefix: String = KeychainCredentialStore.servicePrefix) {
        prefix = servicePrefix
    }

    public func service(for provider: String) -> String { prefix + provider }

    private func query(_ provider: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service(for: provider), kSecAttrAccount as String: account]
    }

    public func load(provider: String, account: String) -> Data? {
        var query = query(provider, account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public func save(_ credential: Data, provider: String, account: String) throws {
        let query = query(provider, account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: credential] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = credential
            item[kSecAttrLabel as String] = "Vespertine (\(provider))"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public func delete(provider: String, account: String) {
        SecItemDelete(query(provider, account) as CFDictionary)
    }
}

/// Holds credentials in memory only. For tests, and for a process that must not touch the Keychain. It counts its reads, so a
/// test can show that a provider that is off never asked for one.
public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var loads = 0

    public init() {}

    private func key(_ provider: String, _ account: String) -> String { provider + "\u{1F}" + account }

    /// How many times a credential was asked for.
    public var loadCount: Int { lock.withLock { loads } }
    public var isEmpty: Bool { lock.withLock { items.isEmpty } }

    public func load(provider: String, account: String) -> Data? {
        lock.withLock {
            loads += 1
            return items[key(provider, account)]
        }
    }

    public func save(_ credential: Data, provider: String, account: String) throws {
        lock.withLock { items[key(provider, account)] = credential }
    }

    public func delete(provider: String, account: String) {
        lock.withLock { items[key(provider, account)] = nil }
    }
}
