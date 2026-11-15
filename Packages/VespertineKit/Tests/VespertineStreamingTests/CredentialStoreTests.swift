//
// Vespertine: where a streaming credential is kept. The store in memory and the Keychain's are held to the same answers; the
// Keychain test uses a service of its own and removes what it made.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Security
import Testing
@testable import VespertineStreaming

@Suite("Credential store")
struct CredentialStoreTests {
    /// One item for each provider and account; saving again replaces; deleting removes only that one.
    private func exercise(_ store: any CredentialStore) throws {
        #expect(store.load(provider: "opensubsonic", account: "a") == nil)
        try store.save(Data("first".utf8), provider: "opensubsonic", account: "a")
        try store.save(Data("other account".utf8), provider: "opensubsonic", account: "b")
        try store.save(Data("other provider".utf8), provider: "fake", account: "a")
        #expect(store.load(provider: "opensubsonic", account: "a") == Data("first".utf8))
        try store.save(Data("second".utf8), provider: "opensubsonic", account: "a")
        #expect(store.load(provider: "opensubsonic", account: "a") == Data("second".utf8))
        #expect(store.load(provider: "opensubsonic", account: "b") == Data("other account".utf8))
        #expect(store.load(provider: "fake", account: "a") == Data("other provider".utf8))
        store.delete(provider: "opensubsonic", account: "a")
        #expect(store.load(provider: "opensubsonic", account: "a") == nil)
        #expect(store.load(provider: "opensubsonic", account: "b") == Data("other account".utf8))
        store.delete(provider: "opensubsonic", account: "a")   // gone already: nothing happens
        store.delete(provider: "opensubsonic", account: "b")
        store.delete(provider: "fake", account: "a")
        #expect(store.load(provider: "fake", account: "a") == nil)
    }

    @Test("In memory")
    func memory() throws {
        let store = MemoryCredentialStore()
        try exercise(store)
        #expect(store.isEmpty)
        #expect(store.loadCount > 0)
    }

    @Test("The service is org.szeremeta.vespertine.streaming.<provider>")
    func service() {
        #expect(KeychainCredentialStore().service(for: "opensubsonic") == "org.szeremeta.vespertine.streaming.opensubsonic")
    }

    @Test("In the Keychain: one generic-password item for each provider and account, deleted on sign-out")
    func keychain() throws {
        let prefix = "org.szeremeta.vespertine.streaming-test.\(UUID().uuidString)."
        let store = KeychainCredentialStore(servicePrefix: prefix)
        defer {
            for (provider, account) in [("opensubsonic", "a"), ("opensubsonic", "b"), ("fake", "a")] { store.delete(provider: provider, account: account) }
        }
        try exercise(store)

        // What is saved is one generic-password item under the provider's service, and deleting it leaves none.
        try store.save(Data("kept".utf8), provider: "opensubsonic", account: "a")
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: prefix + "opensubsonic",
                                    kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true]
        var found: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess)
        let items = found as? [[String: Any]] ?? []
        #expect(items.count == 1)
        #expect(items.first?[kSecAttrAccount as String] as? String == "a")
        store.delete(provider: "opensubsonic", account: "a")
        #expect(SecItemCopyMatching(query as CFDictionary, &found) == errSecItemNotFound)
    }
}
