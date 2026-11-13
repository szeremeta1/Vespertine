import Foundation
import Testing
import VespertineAudio
import VespertineLibrary
import VespertineTidal
@testable import Vespertine

/// Answers every TIDAL request with a 404: nothing here reaches the network.
struct OfflineTransport: HTTPTransport {
    let requests = Locked<[URLRequest]>([])
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.withLock { $0.append(request) }
        return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
    }
}

/// The network as the test sets it.
final class FakeReachability: TidalReachability {
    var handler: (@MainActor (Bool) -> Void)?
    private(set) var started = 0, stopped = 0
    func start(_ onChange: @escaping @MainActor (Bool) -> Void) { started += 1; handler = onChange }
    func stop() { stopped += 1; handler = nil }
    @MainActor func set(_ up: Bool) { handler?(up) }
}

/// Counts refreshes and answers what the test says.
final class FakeRefresher: TidalSyncing, @unchecked Sendable {
    func playlistTrackIds(_ uuid: String) async throws -> [Int] { [] }
    func pullPlaylist(_ uuid: String) async throws {}
    let calls = Locked(0)
    let error = Locked<Error?>(nil)
    let warnings = Locked<[String]>([])
    func refresh() async throws -> TidalLibrarySync.Summary {
        calls.withLock { $0 += 1 }
        if let error = error.withLock({ $0 }) { throw error }
        return TidalLibrarySync.Summary(added: 0, updated: 0, removed: 0, playlists: 0, warnings: warnings.withLock { $0 })
    }
}

@MainActor
struct TidalModelRig {
    let root: URL
    let settings: AppSettings
    let library: LibraryStore
    let availability = TidalAvailability()
    let reachability = FakeReachability()
    let refresher = FakeRefresher()
    let tokens: MemoryTokenStore
    let transport = OfflineTransport()
    let credentialsURL: URL
    let registered = Locked<[String]>([])

    init(credentials: Bool = true, signedIn: Bool = false, enabled: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-tidal-model-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "tidal-model-\(UUID())")!
        settings = AppSettings(defaults: defaults, dataDirectory: root)
        settings.tidalEnabled = enabled
        settings.tidalDownloadsFolder = root.appendingPathComponent("TIDAL").path
        library = try LibraryStore(dataDirectory: root, includeTidal: enabled)
        credentialsURL = root.appendingPathComponent("tidal-client.json")
        if credentials {
            try TidalConfig.saveCredentials(TidalClientCredentials(clientId: "test-a", clientSecret: "test-b", pkceClientId: "test-c",
                                                                   pkceClientSecret: "test-d"), to: credentialsURL)
        }
        tokens = MemoryTokenStore(signedIn ? TidalTokens(accessToken: "test-access", refreshToken: "test-refresh",
                                                         expiresAt: Date().addingTimeInterval(3600), userId: 42, countryCode: "ES") : nil)
    }

    func model() -> TidalModel {
        let refresher = refresher, registered = registered
        return TidalModel(library: library, settings: settings, availability: availability, environment: TidalModel.Environment(
            credentialsURL: credentialsURL, tokens: tokens, transport: transport, reachability: reachability,
            register: { _ in registered.withLock { $0.append("register") } },
            unregister: { registered.withLock { $0.append("unregister") } },
            makeRefresher: { _, _, _ in refresher }, backoffPoll: .milliseconds(20)))
    }

    func tidalSourceOnline() throws -> Bool? {
        try library.database.writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT isOnline FROM source WHERE path = ?", arguments: [LibrarySource.tidalPath])
        }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
func eventually(_ timeout: Double = 3, _ condition: () throws -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if (try? condition()) == true { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return (try? condition()) == true
}

@Suite("TIDAL model") @MainActor
struct TidalModelTests {
    @Test("No credentials file: missing credentials, no reader, no request, and local playback untouched")
    func missingCredentials() async throws {
        let rig = try TidalModelRig(credentials: false); defer { rig.cleanUp() }
        let model = rig.model()
        model.start()
        #expect(model.state == .missingCredentials)
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.refresher.calls.withLock { $0 } == 0)
        #expect(rig.transport.requests.withLock { $0.isEmpty })
        #expect(rig.registered.withLock { $0 }.isEmpty)
        #expect(!rig.availability.signedIn)
    }

    @Test("Credentials but no session: signed out, and the reader is registered")
    func signedOut() throws {
        let rig = try TidalModelRig(); defer { rig.cleanUp() }
        let model = rig.model()
        model.start()
        #expect(model.state == .signedOut)
        #expect(rig.registered.withLock { $0 } == ["register"])
        #expect(rig.refresher.calls.withLock { $0 } == 0)
    }

    @Test("A stored session: signed in, and starting refreshes once")
    func signedIn() async throws {
        let rig = try TidalModelRig(signedIn: true); defer { rig.cleanUp() }
        let model = rig.model()
        model.start()
        guard case .signedIn = model.state else { Issue.record("state \(model.state)"); return }
        #expect(await eventually { rig.refresher.calls.withLock { $0 } == 1 })
        #expect(await eventually { model.lastSync != nil })
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.refresher.calls.withLock { $0 } == 1)
        #expect(rig.availability.signedIn)
        model.start()   // a second start changes nothing
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.refresher.calls.withLock { $0 } == 1)
    }

    @Test("Switched off, start does nothing")
    func offDoesNothing() async throws {
        let rig = try TidalModelRig(signedIn: true, enabled: false); defer { rig.cleanUp() }
        let model = rig.model()
        model.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.refresher.calls.withLock { $0 } == 0 && rig.registered.withLock { $0 }.isEmpty && rig.reachability.started == 0)
    }

    @Test("Losing the network takes the TIDAL source offline, and it comes back with the network")
    func reachability() async throws {
        let rig = try TidalModelRig(signedIn: true); defer { rig.cleanUp() }
        _ = try rig.library.database.tidalSource(userId: 42)
        let model = rig.model()
        model.start()
        #expect(await eventually { try rig.tidalSourceOnline() == true })
        rig.reachability.set(false)
        #expect(!model.isReachable && !rig.availability.reachable)
        #expect(await eventually { try rig.tidalSourceOnline() == false })
        rig.reachability.set(true)
        #expect(await eventually { try rig.tidalSourceOnline() == true })
    }

    @Test("An abuse backoff takes the source offline and is shown with its reason")
    func backoff() async throws {
        let rig = try TidalModelRig(signedIn: true); defer { rig.cleanUp() }
        _ = try rig.library.database.tidalSource(userId: 42)
        rig.refresher.error.withLock { $0 = TidalError.abuse(retryAfter: 1800) }
        let model = rig.model()
        model.start()
        #expect(await eventually { model.backoff != nil })
        #expect(rig.availability.backingOff)
        #expect(await eventually { try rig.tidalSourceOnline() == false })
        #expect(model.backoffNotice?.contains("30 min") == true)
    }

    @Test("Signing out: signed out, the source offline, the rows stay")
    func signOut() async throws {
        let rig = try TidalModelRig(signedIn: true); defer { rig.cleanUp() }
        let source = try #require(try rig.library.database.tidalSource(userId: 42).id)
        try rig.library.database.upsertTidalTracks([TidalTrackInput(tidalId: 1, title: "Kept")], sourceId: source)
        let model = rig.model()
        model.start()
        model.signOut()
        #expect(model.state == .signedOut && !rig.availability.signedIn)
        #expect(rig.tokens.load() == nil)
        #expect(await eventually { try rig.tidalSourceOnline() == false })
        #expect(try rig.library.database.tidalTrackIds() == [1])
    }

    @Test("Stopping unregisters the reader and stops watching the network")
    func stop() throws {
        let rig = try TidalModelRig(signedIn: true); defer { rig.cleanUp() }
        let model = rig.model()
        model.start()
        model.stop()
        #expect(rig.registered.withLock { $0 } == ["register", "unregister"])
        #expect(rig.reachability.stopped == 1)
    }

    @Test("Saving credentials pasted as JSON: signed out (ready to sign in), and the file is written")
    func saveCredentials() throws {
        let rig = try TidalModelRig(credentials: false); defer { rig.cleanUp() }
        let model = rig.model()
        model.start()
        let json = #"{"clientId": "test-a", "clientSecret": "test-b", "pkceClientId": "test-c", "pkceClientSecret": "test-d"}"#
        try model.saveCredentials(TidalClientCredentials.parse(Data(json.utf8)))
        #expect(model.state == .signedOut)
        #expect(try TidalConfig.loadCredentials(at: rig.credentialsURL)?.pkceClientId == "test-c")
    }

    @Test("A refresh's warnings are kept for Settings")
    func warnings() async throws {
        let rig = try TidalModelRig(signedIn: true); defer { rig.cleanUp() }
        rig.refresher.warnings.withLock { $0 = ["TIDAL sent 0 playlists"] }
        let model = rig.model()
        model.start()
        #expect(await eventually { model.syncWarnings == ["TIDAL sent 0 playlists"] })
    }
}
