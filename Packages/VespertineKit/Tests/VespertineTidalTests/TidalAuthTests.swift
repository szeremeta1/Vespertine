//
// Vespertine: TIDAL PKCE login, token storage and refresh (fake transport, fake clock).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import Testing
@testable import VespertineTidal

@Suite("TIDAL auth")
struct TidalAuthTests {
    private let credentials = TidalClientCredentials(clientId: "test-client", clientSecret: "test-secret",
                                                     pkceClientId: "test-pkce-client", pkceClientSecret: "test-pkce-secret")
    private let redirect = URL(string: "https://tidal.com/android/login/auth?code=abc")!

    private func tokenJSON(access: String = "access-1", refresh: String? = "refresh-1", expiresIn: Int = 3600) -> String {
        let refreshPart = refresh.map { "\"refresh_token\":\"\($0)\"," } ?? ""
        return """
        {"access_token":"\(access)",\(refreshPart)"token_type":"Bearer","expires_in":\(expiresIn),
         "user":{"userId":4242,"countryCode":"DE"}}
        """
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func signedIn(expiresAt: Date, clock: TestClock, transport: FakeTransport,
                          store: MemoryTokenStore = MemoryTokenStore()) -> (TidalAuth, MemoryTokenStore) {
        try? store.save(TidalTokens(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: expiresAt, userId: 4242, countryCode: "DE"))
        return (TidalAuth(credentials: credentials, transport: transport, store: store, clock: clock.callable), store)
    }

    @Test("the login URL carries every PKCE parameter and the challenge is the SHA-256 of the verifier")
    func loginURL() async throws {
        let transport = FakeTransport(always: FakeResponse(json: tokenJSON()))
        let auth = TidalAuth(credentials: credentials, transport: transport, store: MemoryTokenStore())
        let url = await auth.loginURL()
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https" && components.host == "login.tidal.com" && components.path == "/authorize")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["response_type"] == "code")
        #expect(query["redirect_uri"] == "https://tidal.com/android/login/auth")
        #expect(query["client_id"] == "test-pkce-client")
        #expect(query["lang"] == "EN")
        #expect(query["appMode"] == "android")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["restrict_signup"] == "true")
        #expect(Set(query.keys).count == 9)
        let uniqueKey = try #require(query["client_unique_key"])
        #expect(uniqueKey.range(of: "^[0-9a-f]{1,16}$", options: .regularExpression) != nil)

        // The verifier only leaves the actor in the token request.
        try await auth.finishLogin(redirect: redirect)
        let body = try #require(transport.requests.first).formFields
        let verifier = try #require(body["code_verifier"])
        #expect(verifier.count == 43)
        #expect(verifier.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil)
        #expect(query["code_challenge"] == base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))))
        #expect(body["client_unique_key"] == uniqueKey)
    }

    @Test("every login URL has its own verifier and unique key")
    func freshPerLogin() async throws {
        let auth = TidalAuth(credentials: credentials, transport: FakeTransport(always: FakeResponse(json: tokenJSON())), store: MemoryTokenStore())
        let a = await auth.loginURL(), b = await auth.loginURL()
        #expect(a != b)
    }

    @Test("finishLogin posts exactly the listed fields to the token URL and stores the tokens")
    func finishLogin() async throws {
        let clock = TestClock()
        let transport = FakeTransport(always: FakeResponse(json: tokenJSON(expiresIn: 3600)))
        let store = MemoryTokenStore()
        let auth = TidalAuth(credentials: credentials, transport: transport, store: store, clock: clock.callable)
        _ = await auth.loginURL()
        try await auth.finishLogin(redirect: redirect)

        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(request.url?.absoluteString == "https://auth.tidal.com/v1/oauth2/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let fields = request.formFields
        #expect(Set(fields.keys) == ["code", "client_id", "grant_type", "redirect_uri", "scope", "code_verifier", "client_unique_key"])
        #expect(fields["code"] == "abc")
        #expect(fields["client_id"] == "test-pkce-client")
        #expect(fields["grant_type"] == "authorization_code")
        #expect(fields["redirect_uri"] == "https://tidal.com/android/login/auth")
        #expect(fields["scope"] == "r_usr+w_usr+w_sub")

        let session = try #require(await auth.session)
        #expect(session.accessToken == "access-1" && session.refreshToken == "refresh-1")
        #expect(session.userId == 4242 && session.countryCode == "DE")
        #expect(session.expiresAt == clock.now.addingTimeInterval(3600))
        #expect(store.load()?.accessToken == "access-1")
        #expect(await auth.isSignedIn)
    }

    @Test("a redirect without a code is refused and nothing is sent")
    func redirectWithoutCode() async throws {
        let transport = FakeTransport(always: FakeResponse(json: tokenJSON()))
        let auth = TidalAuth(credentials: credentials, transport: transport, store: MemoryTokenStore())
        _ = await auth.loginURL()
        await #expect(throws: TidalError.notSignedIn) {
            try await auth.finishLogin(redirect: URL(string: "https://tidal.com/android/login/auth?error=access_denied")!)
        }
        #expect(transport.requests.isEmpty)
        #expect(await auth.isSignedIn == false)
    }

    @Test("a token endpoint refusal at login surfaces as an HTTP error and stores nothing")
    func loginRefused() async throws {
        let transport = FakeTransport(always: FakeResponse(status: 400, json: #"{"error":"invalid_grant"}"#))
        let store = MemoryTokenStore()
        let auth = TidalAuth(credentials: credentials, transport: transport, store: store)
        _ = await auth.loginURL()
        await #expect(throws: TidalError.http(status: 400, body: #"{"error":"invalid_grant"}"#)) {
            try await auth.finishLogin(redirect: redirect)
        }
        #expect(store.load() == nil)
    }

    @Test("a token 30 s from expiry is refreshed once, with the refresh fields")
    func refreshNearExpiry() async throws {
        let clock = TestClock()
        let transport = FakeTransport(always: FakeResponse(json: tokenJSON(access: "access-2", refresh: "refresh-2")))
        let (auth, store) = signedIn(expiresAt: clock.now.addingTimeInterval(30), clock: clock, transport: transport)
        let token = try await auth.validAccessToken()
        #expect(token == "access-2")
        #expect(transport.requests.count == 1)
        let fields = transport.requests[0].formFields
        #expect(Set(fields.keys) == ["grant_type", "refresh_token", "client_id", "client_secret", "scope"])
        #expect(fields["grant_type"] == "refresh_token" && fields["refresh_token"] == "old-refresh")
        #expect(fields["client_id"] == "test-pkce-client" && fields["client_secret"] == "test-pkce-secret")
        #expect(fields["scope"] == "r_usr+w_usr+w_sub")
        #expect(store.load()?.refreshToken == "refresh-2")
        // The new token is good for an hour: no second refresh.
        _ = try await auth.validAccessToken()
        #expect(transport.requests.count == 1)
    }

    @Test("a token with more than 60 s left is used as it is")
    func noRefreshWhenFresh() async throws {
        let clock = TestClock()
        let transport = FakeTransport(always: FakeResponse(json: tokenJSON()))
        let (auth, _) = signedIn(expiresAt: clock.now.addingTimeInterval(61), clock: clock, transport: transport)
        #expect(try await auth.validAccessToken() == "old-access")
        #expect(transport.requests.isEmpty)
        clock.advance(2)
        #expect(try await auth.validAccessToken() == "access-1")
        #expect(transport.requests.count == 1)
    }

    @Test("ten concurrent callers near expiry cause exactly one refresh request")
    func concurrentRefresh() async throws {
        let clock = TestClock()
        let transport = FakeTransport { _ in
            try await Task.sleep(for: .milliseconds(50))
            return FakeResponse(json: self.tokenJSON(access: "access-2", refresh: "refresh-2"))
        }
        let (auth, _) = signedIn(expiresAt: clock.now.addingTimeInterval(10), clock: clock, transport: transport)
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 { group.addTask { try await auth.validAccessToken() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(tokens == Array(repeating: "access-2", count: 10))
        #expect(transport.requests.count == 1)
    }

    @Test("forceRefresh given a token another caller already replaced does not refresh again")
    func forceRefreshStale() async throws {
        let clock = TestClock()
        let transport = FakeTransport(always: FakeResponse(json: tokenJSON(access: "access-2", refresh: "refresh-2")))
        let (auth, _) = signedIn(expiresAt: clock.now.addingTimeInterval(3000), clock: clock, transport: transport)
        try await auth.forceRefresh(staleToken: "old-access")
        try await auth.forceRefresh(staleToken: "old-access")
        #expect(transport.requests.count == 1)
        try await auth.forceRefresh()
        #expect(transport.requests.count == 2)
    }

    @Test("a refresh response without a refresh token keeps the old one")
    func keepsOldRefreshToken() async throws {
        let clock = TestClock()
        let transport = FakeTransport(always: FakeResponse(json: tokenJSON(access: "access-2", refresh: nil)))
        let (auth, store) = signedIn(expiresAt: clock.now.addingTimeInterval(5), clock: clock, transport: transport)
        try await auth.forceRefresh()
        let session = try #require(await auth.session)
        #expect(session.accessToken == "access-2" && session.refreshToken == "old-refresh")
        #expect(store.load()?.refreshToken == "old-refresh")
        #expect(session.userId == 4242 && session.countryCode == "DE")
    }

    @Test("a refresh response carrying user_id (no user object) fills the user")
    func flatUserFields() async throws {
        let clock = TestClock()
        let transport = FakeTransport(always: FakeResponse(json: #"{"access_token":"a","expires_in":100,"user_id":7,"countryCode":"US"}"#))
        let (auth, _) = signedIn(expiresAt: clock.now, clock: clock, transport: transport)
        try await auth.forceRefresh()
        let session = try #require(await auth.session)
        #expect(session.userId == 7 && session.countryCode == "US")
    }

    @Test("a refresh the server refuses signs the user out; a server error keeps the session")
    func refreshFailures() async throws {
        let clock = TestClock()
        let refused = FakeTransport(always: FakeResponse(status: 400, json: #"{"error":"invalid_grant"}"#))
        let (a, storeA) = signedIn(expiresAt: clock.now, clock: clock, transport: refused)
        await #expect(throws: TidalError.notSignedIn) { try await a.validAccessToken() }
        #expect(storeA.load() == nil)
        #expect(await a.isSignedIn == false)

        let down = FakeTransport(always: FakeResponse(status: 503, json: "unavailable"))
        let (b, storeB) = signedIn(expiresAt: clock.now, clock: clock, transport: down)
        await #expect(throws: TidalError.http(status: 503, body: "unavailable")) { try await b.validAccessToken() }
        #expect(storeB.load() != nil)
        #expect(await b.isSignedIn)
    }

    @Test("signOut clears the store and the session")
    func signOut() async throws {
        let clock = TestClock()
        let (auth, store) = signedIn(expiresAt: clock.now.addingTimeInterval(3000), clock: clock, transport: FakeTransport(always: FakeResponse(json: "{}")))
        #expect(await auth.isSignedIn)
        await auth.signOut()
        #expect(store.load() == nil)
        #expect(await auth.session == nil)
        #expect(await auth.isSignedIn == false)
    }

    @Test("with an empty store there is no access token")
    func emptyStore() async throws {
        let transport = FakeTransport(always: FakeResponse(json: tokenJSON()))
        let auth = TidalAuth(credentials: credentials, transport: transport, store: MemoryTokenStore())
        await #expect(throws: TidalError.notSignedIn) { try await auth.validAccessToken() }
        await #expect(throws: TidalError.notSignedIn) { try await auth.forceRefresh() }
        #expect(transport.requests.isEmpty)
    }

    @Test("tokens saved by one auth are loaded by the next (a relaunch)")
    func relaunch() async throws {
        let clock = TestClock()
        let store = MemoryTokenStore()
        let first = TidalAuth(credentials: credentials, transport: FakeTransport(always: FakeResponse(json: tokenJSON())), store: store, clock: clock.callable)
        _ = await first.loginURL()
        try await first.finishLogin(redirect: redirect)
        let second = TidalAuth(credentials: credentials, transport: FakeTransport(always: FakeResponse(json: "{}")), store: store, clock: clock.callable)
        #expect(try await second.validAccessToken() == "access-1")
    }
}
