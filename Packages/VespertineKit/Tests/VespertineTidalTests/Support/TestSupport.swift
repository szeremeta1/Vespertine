//
// Vespertine: fixtures and a ready-made signed-in gate for the TIDAL tests.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
@testable import VespertineTidal

enum Fixture {
    /// The bytes of `Fixtures/<name>` in the test bundle.
    static func data(_ name: String) throws -> Data {
        let url = try requiredURL(name)
        return try Data(contentsOf: url)
    }

    static func string(_ name: String) throws -> String { String(decoding: try data(name), as: UTF8.self) }

    static func url(_ name: String) throws -> URL { try requiredURL(name) }

    private static func requiredURL(_ name: String) throws -> URL {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
        return url
    }
}

/// A gate with a signed-in session (user 4242, country DE), a fake clock and no real sleeping.
func makeSignedInGate(transport: HTTPTransport, clock: TestClock = TestClock()) -> TidalGate {
    let store = MemoryTokenStore(TidalTokens(accessToken: "test-token", refreshToken: "test-refresh",
                                             expiresAt: clock.now.addingTimeInterval(3600), userId: 4242, countryCode: "DE"))
    let credentials = TidalClientCredentials(clientId: "test-client", clientSecret: "test-secret",
                                             pkceClientId: "test-pkce-client", pkceClientSecret: "test-pkce-secret")
    let auth = TidalAuth(credentials: credentials, transport: FakeTransport(always: FakeResponse(status: 500, json: "unexpected")),
                         store: store, clock: clock.callable)
    return TidalGate(auth: auth, transport: transport, clock: clock.callable, sleep: { _ in })
}
