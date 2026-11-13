//
// Vespertine: the TIDAL request gate: headers, backoff rules, the 401 retry, and priority order (fake transport, fake clock).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineTidal

@Suite("TIDAL gate")
struct TidalGateTests {
    private let credentials = TidalClientCredentials(clientId: "test-client", clientSecret: "test-secret",
                                                     pkceClientId: "test-pkce-client", pkceClientSecret: "test-pkce-secret")

    private func makeAuth(_ clock: TestClock, authTransport: FakeTransport? = nil) -> TidalAuth {
        let store = MemoryTokenStore(TidalTokens(accessToken: "token-1", refreshToken: "refresh-1",
                                                 expiresAt: clock.now.addingTimeInterval(3600), userId: 4242, countryCode: "DE"))
        let transport = authTransport ?? FakeTransport(always: FakeResponse(status: 500, json: "unexpected"))
        return TidalAuth(credentials: credentials, transport: transport, store: store, clock: clock.callable)
    }

    private func makeGate(_ clock: TestClock, transport: FakeTransport, authTransport: FakeTransport? = nil) -> TidalGate {
        TidalGate(auth: makeAuth(clock, authTransport: authTransport), transport: transport, clock: clock.callable, sleep: { _ in })
    }

    @Test("every request carries countryCode, the bearer token, the user agent and the client version")
    func headers() async throws {
        let clock = TestClock()
        let transport = FakeTransport(always: FakeResponse(json: "{}"))
        let gate = makeGate(clock, transport: transport)
        _ = try await gate.get("tracks/1", query: ["limit": "5"], priority: .interactive)
        let request = try #require(transport.requests.first)
        let url = try #require(request.url)
        #expect(url.absoluteString.hasPrefix("https://api.tidal.com/v1/tracks/1?"))
        let query = FormEncoding.decode(url.query ?? "")
        #expect(query == ["countryCode": "DE", "limit": "5"])
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
        #expect(request.value(forHTTPHeaderField: "User-Agent") ==
                "Mozilla/5.0 (Linux; Android 12; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/91.0.4472.114 Safari/537.36")
        #expect(request.value(forHTTPHeaderField: "x-tidal-client-version") == "2025.7.16")
    }

    @Test("send posts a form body and puts the ETag in If-None-Match")
    func sendForm() async throws {
        let clock = TestClock()
        let transport = FakeTransport(always: FakeResponse(json: "{}"))
        let gate = makeGate(clock, transport: transport)
        let (_, response) = try await gate.send(method: "POST", path: "/playlists/x/items", form: ["trackIds": "1,2", "onDupes": "SKIP"],
                                                priority: .interactive, ifMatch: "\"7\"")
        #expect(response.statusCode == 200)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/playlists/x/items")
        #expect(request.formFields == ["trackIds": "1,2", "onDupes": "SKIP"])
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"7\"")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    }

    @Test("the typed get decodes JSON")
    func typedGet() async throws {
        struct Thing: Decodable, Equatable { var id: Int }
        let clock = TestClock()
        let gate = makeGate(clock, transport: FakeTransport(always: FakeResponse(json: #"{"id":9}"#)))
        #expect(try await gate.get("things/9", priority: .sync, as: Thing.self) == Thing(id: 9))
    }

    @Test("429 with Retry-After: 12 backs off for 12 s and throws backingOff")
    func rateLimitWithHeader() async throws {
        let clock = TestClock()
        let transport = FakeTransport(always: FakeResponse(status: 429, json: "{}", headers: ["Retry-After": "12"]))
        let gate = makeGate(clock, transport: transport)
        let start = clock.now
        do {
            _ = try await gate.get("tracks/1", priority: .interactive)
            Issue.record("expected backingOff")
        } catch let TidalError.backingOff(remaining, reason) {
            #expect(remaining == 12)
            #expect(reason.contains("429"))
        }
        #expect(await gate.backoff?.until == start.addingTimeInterval(12))
    }

    @Test("429 without the header backs off for 60 s")
    func rateLimitDefault() async throws {
        let clock = TestClock()
        let gate = makeGate(clock, transport: FakeTransport(always: FakeResponse(status: 429, json: "{}")))
        let start = clock.now
        await #expect(throws: TidalError.self) { try await gate.get("tracks/1", priority: .interactive) }
        #expect(await gate.backoff?.until == start.addingTimeInterval(60))
    }

    @Test("403 whose body says abuse (or suspend) backs off for 30 minutes and throws abuse")
    func abuse() async throws {
        for body in [#"{"userMessage":"abuse detected"}"#, #"{"userMessage":"Account SUSPENDED"}"#] {
            let clock = TestClock()
            let gate = makeGate(clock, transport: FakeTransport(always: FakeResponse(status: 403, json: body)))
            let start = clock.now
            await #expect(throws: TidalError.abuse(retryAfter: 1800)) { try await gate.get("tracks/1", priority: .interactive) }
            #expect(await gate.backoff?.until == start.addingTimeInterval(1800))
        }
    }

    @Test("an abuse 403 with Retry-After uses it")
    func abuseWithHeader() async throws {
        let clock = TestClock()
        let gate = makeGate(clock, transport: FakeTransport(always: FakeResponse(status: 403, json: "abuse", headers: ["Retry-After": "90"])))
        await #expect(throws: TidalError.abuse(retryAfter: 90)) { try await gate.get("x", priority: .interactive) }
    }

    @Test("an ordinary 403 is an HTTP error, not a backoff")
    func ordinary403() async throws {
        let clock = TestClock()
        let gate = makeGate(clock, transport: FakeTransport(always: FakeResponse(status: 403, json: #"{"userMessage":"nope"}"#)))
        await #expect(throws: TidalError.http(status: 403, body: #"{"userMessage":"nope"}"#)) { try await gate.get("x", priority: .interactive) }
        #expect(await gate.backoff == nil)
    }

    @Test("a call during a backoff throws backingOff and sends nothing; after it ends requests flow again")
    func refusedDuringBackoff() async throws {
        let clock = TestClock()
        let counter = Counter()
        let transport = FakeTransport { _ in
            counter.next() == 0 ? FakeResponse(status: 429, json: "{}", headers: ["Retry-After": "30"]) : FakeResponse(json: "{}")
        }
        let gate = makeGate(clock, transport: transport)
        await #expect(throws: TidalError.self) { try await gate.get("a", priority: .interactive) }
        #expect(transport.requests.count == 1)

        clock.advance(10)
        do {
            _ = try await gate.get("b", priority: .playback)
            Issue.record("expected backingOff")
        } catch let TidalError.backingOff(remaining, _) {
            #expect(remaining == 20)
        }
        #expect(transport.requests.count == 1)

        clock.advance(20)
        _ = try await gate.get("c", priority: .interactive)
        #expect(transport.requests.count == 2)
        #expect(await gate.backoff == nil)
    }

    @Test("a shorter Retry-After during a longer backoff does not shorten it")
    func neverShortened() async throws {
        let clock = TestClock()
        // The first answer starts a 100 s backoff; the second request was already in flight and comes back with 5 s.
        let latch = Latch()
        let transport = FakeTransport { request in
            if request.url?.path.hasSuffix("/slow") == true {
                await latch.wait()
                return FakeResponse(status: 429, json: "{}", headers: ["Retry-After": "5"])
            }
            return FakeResponse(status: 429, json: "{}", headers: ["Retry-After": "100"])
        }
        let gate = makeGate(clock, transport: transport)
        let start = clock.now
        let slow = Task { try await gate.get("slow", priority: .interactive) }
        #expect(await eventually { await latch.waitingCount == 1 })
        await #expect(throws: TidalError.self) { try await gate.get("fast", priority: .interactive) }
        await latch.releaseAll()
        await #expect(throws: TidalError.self) { try await slow.value }
        #expect(await gate.backoff?.until == start.addingTimeInterval(100))
    }

    @Test("a 401 refreshes once and retries once; a second 401 is an HTTP 401")
    func unauthorized() async throws {
        let clock = TestClock()
        let authTransport = FakeTransport(always: FakeResponse(json: #"{"access_token":"token-2","expires_in":3600,"user":{"userId":4242,"countryCode":"DE"}}"#))
        // First call: 401 then success with the new token.
        let transport = FakeTransport { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer token-1" ? FakeResponse(status: 401, json: "{}") : FakeResponse(json: "{}")
        }
        let gate = makeGate(clock, transport: transport, authTransport: authTransport)
        _ = try await gate.get("tracks/1", priority: .interactive)
        #expect(authTransport.requests.count == 1)
        #expect(transport.requests.count == 2)
        #expect(transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer token-2")

        // Always 401: one refresh, one retry, then the error.
        let authTransport2 = FakeTransport(always: FakeResponse(json: #"{"access_token":"token-2","expires_in":3600,"user":{"userId":4242,"countryCode":"DE"}}"#))
        let always401 = FakeTransport(always: FakeResponse(status: 401, json: "denied"))
        let gate2 = makeGate(clock, transport: always401, authTransport: authTransport2)
        await #expect(throws: TidalError.http(status: 401, body: "denied")) { try await gate2.get("tracks/1", priority: .interactive) }
        #expect(authTransport2.requests.count == 1)
        #expect(always401.requests.count == 2)
    }

    @Test("signed out: the call fails with notSignedIn and nothing is sent")
    func signedOut() async throws {
        let clock = TestClock()
        let transport = FakeTransport(always: FakeResponse(json: "{}"))
        let auth = TidalAuth(credentials: credentials, transport: transport, store: MemoryTokenStore(), clock: clock.callable)
        let gate = TidalGate(auth: auth, transport: transport, clock: clock.callable, sleep: { _ in })
        await #expect(throws: TidalError.notSignedIn) { try await gate.get("tracks/1", priority: .playback) }
        #expect(transport.requests.isEmpty)
    }

    @Test("at most 4 requests are in flight")
    func fourInFlight() async throws {
        let clock = TestClock()
        let latch = Latch()
        let transport = FakeTransport { _ in await latch.wait(); return FakeResponse(json: "{}") }
        let gate = makeGate(clock, transport: transport)
        let tasks = (0..<7).map { index in Task { try await gate.get("t/\(index)", priority: .sync) } }
        #expect(await eventually { await latch.waitingCount == 4 })
        #expect(await eventually { await gate.queuedCount == 3 })
        #expect(transport.requests.count == 4)
        await latch.releaseAll()
        for task in tasks { _ = try await task.value }
        #expect(transport.requests.count == 7)
    }

    @Test("with 4 requests blocking, a queued download and a later playback request: playback is sent first")
    func priority() async throws {
        let clock = TestClock()
        let latch = Latch()
        let transport = FakeTransport { request in
            if request.url?.path.contains("/block/") == true { await latch.wait() }
            return FakeResponse(json: "{}")
        }
        let gate = makeGate(clock, transport: transport)
        let blockers = (0..<4).map { index in Task { try await gate.get("block/\(index)", priority: .interactive) } }
        #expect(await eventually { await latch.waitingCount == 4 })
        let download = Task { try await gate.get("download", priority: .download) }
        #expect(await eventually { await gate.queuedCount == 1 })
        let sync = Task { try await gate.get("sync", priority: .sync) }
        #expect(await eventually { await gate.queuedCount == 2 })
        let playback = Task { try await gate.get("playback", priority: .playback) }
        #expect(await eventually { await gate.queuedCount == 3 })
        let secondDownload = Task { try await gate.get("download2", priority: .download) }
        #expect(await eventually { await gate.queuedCount == 4 })

        await latch.releaseAll()
        for task in blockers + [download, sync, playback, secondDownload] { _ = try await task.value }
        let order = transport.requests.dropFirst(4).compactMap { $0.url?.lastPathComponent }
        #expect(order == ["playback", "sync", "download", "download2"])
    }

    @Test("requests queued when a backoff starts are refused, not sent")
    func queuedDuringBackoff() async throws {
        let clock = TestClock()
        let latch = Latch()
        let transport = FakeTransport { _ in
            await latch.wait()
            return FakeResponse(status: 429, json: "{}", headers: ["Retry-After": "30"])
        }
        let gate = makeGate(clock, transport: transport)
        let tasks = (0..<8).map { index in Task { try await gate.get("t/\(index)", priority: .sync) } }
        #expect(await eventually { await latch.waitingCount == 4 })
        #expect(await eventually { await gate.queuedCount == 4 })
        await latch.releaseAll()
        var refused = 0
        for task in tasks {
            do { _ = try await task.value } catch TidalError.backingOff { refused += 1 }
        }
        #expect(refused == 8)
        #expect(transport.requests.count == 4)
    }

    @Test("a cancelled waiter leaves the queue")
    func cancelledWaiter() async throws {
        let clock = TestClock()
        let latch = Latch()
        let transport = FakeTransport { _ in await latch.wait(); return FakeResponse(json: "{}") }
        let gate = makeGate(clock, transport: transport)
        let blockers = (0..<4).map { index in Task { try await gate.get("b/\(index)", priority: .sync) } }
        #expect(await eventually { await latch.waitingCount == 4 })
        let waiter = Task { try await gate.get("w", priority: .sync) }
        #expect(await eventually { await gate.queuedCount == 1 })
        waiter.cancel()
        #expect(await eventually { await gate.queuedCount == 0 })
        await #expect(throws: CancellationError.self) { try await waiter.value }
        await latch.releaseAll()
        for task in blockers { _ = try await task.value }
        #expect(transport.requests.count == 4)
    }
}
