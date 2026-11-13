//
// Vespertine: where the TIDAL session lives between launches (the login Keychain; memory in tests).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Security

public struct TidalTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var userId: Int
    public var countryCode: String

    public init(accessToken: String, refreshToken: String, expiresAt: Date, userId: Int, countryCode: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.userId = userId
        self.countryCode = countryCode
    }
}

public protocol TokenStore: Sendable {
    func load() -> TidalTokens?
    func save(_ tokens: TidalTokens) throws
    func clear()
}

/// One generic-password item in the login Keychain holding the tokens as JSON. (The data-protection keychain would need a
/// provisioning profile, which a Developer ID build doesn't have.)
public struct KeychainTokenStore: TokenStore {
    public static let service = "org.szeremeta.vespertine.tidal"
    private let service: String
    private let account: String

    public init(service: String = KeychainTokenStore.service, account: String = "session") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() -> TidalTokens? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(TidalTokens.self, from: data)
    }

    public func save(_ tokens: TidalTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Holds the tokens in memory only. For tests, and for a process that must not touch the Keychain.
public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: TidalTokens?

    public init(_ tokens: TidalTokens? = nil) { self.tokens = tokens }

    public func load() -> TidalTokens? { lock.withLock { tokens } }
    public func save(_ tokens: TidalTokens) throws { lock.withLock { self.tokens = tokens } }
    public func clear() { lock.withLock { tokens = nil } }
}
