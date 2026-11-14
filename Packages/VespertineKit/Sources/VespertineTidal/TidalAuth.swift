//
// Vespertine: TIDAL sign-in (OAuth with PKCE through the browser), the stored session, and token refresh that never runs twice at once.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import Security

public actor TidalAuth {
    static let authorizeURL = "https://login.tidal.com/authorize"
    static let tokenURL = URL(string: "https://auth.tidal.com/v1/oauth2/token")!
    static let redirectURI = "https://tidal.com/android/login/auth"
    static let scope = "r_usr+w_usr+w_sub"
    /// Refresh this long before the token expires.
    static let refreshMargin: TimeInterval = 60

    private let credentials: TidalClientCredentials
    private let transport: HTTPTransport
    private let store: TokenStore
    private let clock: @Sendable () -> Date

    private var tokens: TidalTokens?
    private var pending: (verifier: String, uniqueKey: String)?
    private var refreshTask: Task<TidalTokens, Error>?
    /// Bumped by sign-out and login, so a refresh that finishes afterwards doesn't bring a dead session back.
    private var generation = 0

    public init(credentials: TidalClientCredentials, transport: HTTPTransport, store: TokenStore,
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.credentials = credentials
        self.transport = transport
        self.store = store
        self.clock = clock
        self.tokens = store.load()
    }

    public var isSignedIn: Bool { tokens != nil }
    public var session: TidalTokens? { tokens }

    // MARK: Login

    /// A new authorize URL. Each call starts a fresh login (new verifier and unique key); `finishLogin` completes the latest one.
    public func loginURL() -> URL {
        let verifier = Self.base64URL(Self.randomBytes(32))
        let uniqueKey = String(UInt64.random(in: .min ... .max), radix: 16)
        pending = (verifier, uniqueKey)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let query: [String: String] = [
            "response_type": "code",
            "redirect_uri": Self.redirectURI,
            "client_id": credentials.pkceClientId,
            "lang": "EN",
            "appMode": "android",
            "client_unique_key": uniqueKey,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "restrict_signup": "true",
        ]
        return URL(string: Self.authorizeURL + "?" + FormEncoding.encode(query))!
    }

    /// Trades the redirect (`…/login/auth?code=…`) for tokens and stores them.
    public func finishLogin(redirect: URL) async throws {
        guard let pending,
              let code = URLComponents(url: redirect, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty
        else { throw TidalError.notSignedIn }
        let fields: [String: String] = [
            "code": code,
            "client_id": credentials.pkceClientId,
            "grant_type": "authorization_code",
            "redirect_uri": Self.redirectURI,
            "scope": Self.scope,
            "code_verifier": pending.verifier,
            "client_unique_key": pending.uniqueKey,
        ]
        let (data, response) = try await post(fields)
        guard response.statusCode == 200 else {
            throw TidalError.http(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        let new = try Self.parse(data, previous: nil, now: clock())
        // Clear only the login that was just used: loginURL() may have started a newer one while the request was in flight.
        if self.pending?.verifier == pending.verifier { self.pending = nil }
        // A refresh of the previous session that is still in flight must not outlive it.
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        try store.save(new)
        tokens = new
    }

    // MARK: Tokens

    /// A token good for at least another minute, refreshing first when it isn't. Concurrent callers share one refresh.
    public func validAccessToken() async throws -> String {
        guard let current = tokens else { throw TidalError.notSignedIn }
        if current.expiresAt.timeIntervalSince(clock()) > Self.refreshMargin { return current.accessToken }
        return try await refresh().accessToken
    }

    /// Refreshes now (after a 401). With `staleToken`, a token another caller has already replaced is left alone, so several
    /// requests failing together cost one refresh.
    public func forceRefresh(staleToken: String? = nil) async throws {
        guard let current = tokens else { throw TidalError.notSignedIn }
        if let staleToken, current.accessToken != staleToken { return }
        _ = try await refresh()
    }

    public func signOut() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
        pending = nil
        store.clear()
    }

    private func refresh() async throws -> TidalTokens {
        if let refreshTask { return try await refreshTask.value }
        guard let current = tokens else { throw TidalError.notSignedIn }
        let task = Task { try await self.runRefresh(from: current, generation: self.generation) }
        refreshTask = task
        return try await task.value
    }

    private func runRefresh(from current: TidalTokens, generation started: Int) async throws -> TidalTokens {
        defer { if generation == started { refreshTask = nil } }
        let fields: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": current.refreshToken,
            "client_id": credentials.pkceClientId,
            "client_secret": credentials.pkceClientSecret,
            "scope": Self.scope,
        ]
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await post(fields)
        } catch {
            // Signing out (or in again) cancels the request; that is not the waiters' error.
            if generation != started { return try supersededResult() }
            throw error
        }
        guard generation == started else { return try supersededResult() }
        guard response.statusCode == 200 else {
            if response.statusCode == 400 || response.statusCode == 401 {
                // The refresh token is dead (revoked, or rotated by another install): only a new login helps.
                signOut()
                throw TidalError.notSignedIn
            }
            throw TidalError.http(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        let new = try Self.parse(data, previous: current, now: clock())
        try store.save(new)
        tokens = new
        return new
    }

    /// What a refresh that sign-out or a new login overtook hands its waiters: the new session, or notSignedIn.
    private func supersededResult() throws -> TidalTokens {
        guard let tokens else { throw TidalError.notSignedIn }
        return tokens
    }

    private func post(_ fields: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(FormEncoding.encode(fields).utf8)
        return try await transport.send(request)
    }

    // MARK: Parsing

    private struct TokenResponse: Decodable {
        struct User: Decodable { var userId: Int?; var countryCode: String? }
        var accessToken: String
        var refreshToken: String?
        var expiresIn: Double
        var user: User?
        var userId: Int?
        var countryCode: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in"
            case user, userId = "user_id", countryCode
        }
    }

    /// `previous` fills what a refresh response leaves out (the refresh token, and the user when there is no user object).
    private static func parse(_ data: Data, previous: TidalTokens?, now: Date) throws -> TidalTokens {
        guard let response = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw TidalError.http(status: 200, body: String(decoding: data, as: UTF8.self))
        }
        guard let refreshToken = response.refreshToken ?? previous?.refreshToken,
              let userId = response.user?.userId ?? response.userId ?? previous?.userId,
              let country = response.user?.countryCode ?? response.countryCode ?? previous?.countryCode
        else { throw TidalError.http(status: 200, body: String(decoding: data, as: UTF8.self)) }
        return TidalTokens(accessToken: response.accessToken, refreshToken: refreshToken,
                           expiresAt: now.addingTimeInterval(response.expiresIn), userId: userId, countryCode: country)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        }
        return Data(bytes)
    }

    /// Base64url without padding (RFC 7636).
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
