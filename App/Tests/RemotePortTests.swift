import Foundation
import Network
import Testing
import VespertineRemoteProtocol
@testable import Vespertine

/// The phone remote's fixed port: the Mac binds the same port every time it starts (so a paired phone's saved address
/// keeps working), moves to the next free one when something else has it, says where it is on Bonjour, and keeps its
/// pairings across restarts. These tests use their own port range, so they pass whatever the real app is doing.
@MainActor
struct RemotePortTests {
    /// A range of ports for one test, away from the real defaults and from each other.
    private static func base() -> UInt16 { UInt16.random(in: 30_000...45_000) }

    private func library() throws -> (folder: URL, defaults: UserDefaults) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-port-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, UserDefaults(suiteName: "vespertine-port-test-\(UUID().uuidString)")!)
    }

    private func running(_ server: RemoteServer, timeout: Duration = .seconds(8)) async -> UInt16? {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if case .running(let port) = server.status { return port }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    /// Something else holding a port, as another app would.
    private func occupy(_ port: UInt16) async throws -> NWListener {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { $0.cancel() }
        let ready = AsyncStream<Bool> { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.yield(true); continuation.finish()
                case .failed, .cancelled: continuation.yield(false); continuation.finish()
                default: break
                }
            }
        }
        listener.start(queue: .main)
        for await ok in ready { try #require(ok, "couldn't occupy \(port) for the test") }
        return listener
    }

    private func server(in library: (folder: URL, defaults: UserDefaults), base: UInt16) -> RemoteServer {
        let store = RemoteStore(dataDirectory: library.folder, defaults: library.defaults)
        store.enabled = true
        return RemoteServer(store: store, preferredPort: base)
    }

    @Test func aFreshServerTakesThePreferredPortAndSavesIt() async throws {
        let library = try library()
        let base = Self.base()
        let server = server(in: library, base: base)
        server.apply()
        #expect(await running(server) == base)
        #expect(server.store.port == base)
        // Saved beside the server ID, so another library has its own.
        #expect(RemoteStore(dataDirectory: library.folder, defaults: library.defaults).port == base)
        #expect(RemoteStore(dataDirectory: try self.library().folder, defaults: library.defaults).port == nil)
        server.store.enabled = false
        server.apply()
    }

    @Test func theSamePortComesBackAfterARestart() async throws {
        let library = try library()
        let base = Self.base()
        let first = server(in: library, base: base)
        first.apply()
        let port = try #require(await running(first))
        first.store.enabled = false
        first.apply()
        #expect(first.status == .off)

        // The app starts again: a new store and a new server over the same files.
        let second = server(in: library, base: base)
        second.apply()
        #expect(await running(second) == port)
        second.store.enabled = false
        second.apply()
    }

    @Test func aBusyPreferredPortMovesToTheNextFreeOne() async throws {
        let library = try library()
        let base = Self.base()
        let other = try await occupy(base)
        defer { other.cancel() }
        let server = server(in: library, base: base)
        server.apply()
        #expect(await running(server) == base + 1)
        #expect(server.store.port == base + 1)
        server.store.enabled = false
        server.apply()
    }

    @Test func aMovedPortStaysWhereItWasEvenWhenThePreferredOneIsFreeAgain() async throws {
        // The phone learned the moved port (Bonjour, then remembered): snapping back would strand it.
        let library = try library()
        let base = Self.base()
        let other = try await occupy(base)
        let first = server(in: library, base: base)
        first.apply()
        #expect(await running(first) == base + 1)
        first.store.enabled = false
        first.apply()
        other.cancel()
        try await Task.sleep(for: .milliseconds(200))

        let second = server(in: library, base: base)
        second.apply()
        #expect(await running(second) == base + 1)
        second.store.enabled = false
        second.apply()
    }

    @Test func aSavedPortThatIsNowTakenFallsBackAndSavesTheNewOne() async throws {
        let library = try library()
        let base = Self.base()
        let first = server(in: library, base: base)
        first.apply()
        #expect(await running(first) == base)
        first.store.enabled = false
        first.apply()
        try await Task.sleep(for: .milliseconds(200))

        let other = try await occupy(base)
        defer { other.cancel() }
        let second = server(in: library, base: base)
        second.apply()
        #expect(await running(second) == base + 1)
        #expect(second.store.port == base + 1)
        second.store.enabled = false
        second.apply()
    }

    @Test func twoServersNeverShareAPort() async throws {
        let base = Self.base()
        let one = server(in: try library(), base: base)
        let two = server(in: try library(), base: base)
        one.apply()
        let first = await running(one)
        two.apply()
        let second = await running(two)
        #expect(first == base)
        #expect(second == base + 1)
        for server in [one, two] { server.store.enabled = false; server.apply() }
    }

    @Test func bonjourSaysThePort() {
        let info = ServerInfo(name: "Studio", serverID: "S-1", appVersion: "1.1.2")
        let record = RemoteServer.txtRecord(info: info, port: 47_822)
        #expect(record[RemoteProtocol.TXTKey.port] == "47822")
        #expect(record[RemoteProtocol.TXTKey.serverID] == "S-1")
        #expect(record[RemoteProtocol.TXTKey.protocolVersion] == String(RemoteProtocol.version))
        #expect(record[RemoteProtocol.TXTKey.appVersion] == "1.1.2")
        // Before the system picks a port (the last resort), there's nothing to say.
        #expect(RemoteServer.txtRecord(info: info, port: nil)[RemoteProtocol.TXTKey.port] == nil)
    }

    @Test func aPairedPhonesKeyStillGetsInAfterARestart() async throws {
        // The pairing is the phone's key in a file, not anything tied to the port or to this run of the app.
        let library = try library()
        let base = Self.base()
        let first = server(in: library, base: base)
        let credential = DeviceCredential.make()
        first.store.add(PairedRemote(id: credential.device, name: "Alex's iPhone", key: credential.key, pairedAt: .now, lastSeen: nil))
        first.apply()
        let port = try #require(await running(first))
        let key = RemoteTransport.PresharedKey(identity: credential.device, key: credential.key)
        #expect(first.acceptedKeys.contains(key))
        first.store.enabled = false
        first.apply()

        let second = server(in: library, base: base)
        #expect(second.store.serverID == first.store.serverID)
        second.apply()
        #expect(await running(second) == port)
        #expect(second.acceptedKeys.contains(key))
        #expect(second.store.device(credential.device)?.key == credential.key)
        // A key nobody paired still isn't accepted.
        #expect(!second.acceptedKeys.contains(.init(identity: credential.device, key: Data(repeating: 7, count: 32))))
        second.store.enabled = false
        second.apply()
    }
}
