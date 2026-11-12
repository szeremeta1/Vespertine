//
// Vespertine Remote: the phone's session and pairing against a small stand-in for the Mac's server, on loopback.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Network)
import Foundation
import Network
import Testing
import VespertineRemoteClient
@testable import VespertineRemoteProtocol

/// Answers hello with welcome plus a player push, pair with a fresh credential, anything else with ok.
private final class FakeMac: @unchecked Sendable {
    let listener: NWListener
    let info = ServerInfo(name: "Test Mac", serverID: "S-TEST", appVersion: "1.1.0")
    let paired = DeviceCredential(device: "phone-test", key: Data(repeating: 0x5A, count: 32))
    private let queue = DispatchQueue(label: "remote-client-test.server")

    init(keys: [RemoteTransport.PresharedKey]) throws {
        listener = try NWListener(using: RemoteTransport.parameters(keys: keys), on: .any)
        listener.newConnectionHandler = { [queue, info, paired] connection in
            connection.start(queue: queue)
            func send(_ message: ServerMessage) {
                let data = try! RemoteProtocol.encoder().encode(message)
                connection.send(content: data, contentContext: RemoteTransport.textContext, isComplete: true, completion: .contentProcessed { _ in })
            }
            func receive() {
                connection.receiveMessage { content, _, _, error in
                    guard error == nil, let content, let message = try? RemoteProtocol.decoder().decode(ClientMessage.self, from: content) else {
                        connection.cancel(); return
                    }
                    switch message.command {
                    case .hello:
                        send(.reply(id: message.id, result: .welcome(info)))
                        send(.player(PlayerState(playback: .playing, loading: false, nowPlaying: nil, position: 12, positionAt: .now, duration: 200,
                                                 shuffle: false, repeatMode: .off, signal: nil, output: "Test DAC",
                                                 volume: VolumeState(route: .fixed, level: nil, muted: false), waitingFor: nil, error: nil, transitions: nil)))
                    case .pair:
                        send(.reply(id: message.id, result: .paired(device: paired.device, key: paired.key, server: info)))
                    default:
                        send(.reply(id: message.id, result: .ok))
                    }
                    receive()
                }
            }
            receive()
        }
    }

    func start() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint.Port, any Error>) in
            let resumed = Box(false)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: if !resumed.value { resumed.value = true; continuation.resume(returning: listener.port!) }
                case .failed(let error): if !resumed.value { resumed.value = true; continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    deinit { listener.cancel() }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@MainActor
private func waitUntil(_ condition: () -> Bool, seconds: Double = 5) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

@Suite(.serialized) @MainActor struct Client {
    @Test func pairsWithTheCodeThenSignsIn() async throws {
        let code = "482913"
        let pairingKey = RemoteTransport.PresharedKey(identity: RemoteProtocol.pairingCodeIdentity, key: PairingKey.derive(secret: code, serverID: "S-TEST"))
        let device = RemoteTransport.PresharedKey(identity: "phone-test", key: Data(repeating: 0x5A, count: 32))
        let mac = try FakeMac(keys: [pairingKey, device])
        let port = try await mac.start()
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)

        // A wrong code is refused by TLS.
        await #expect(throws: RemoteSession.PairingError.refused) {
            _ = try await RemoteSession.pair(endpoint: endpoint, serverID: "S-TEST", secret: "000000", viaLink: false, clientName: "Test phone")
        }

        let saved = try await RemoteSession.pair(endpoint: endpoint, serverID: "S-TEST", secret: code, viaLink: false, clientName: "Test phone")
        #expect(saved.device == "phone-test")
        #expect(saved.serverID == "S-TEST")

        let session = RemoteSession(pairing: saved, clientName: "Test phone") { _ in endpoint }
        session.connect()
        #expect(await waitUntil { session.isConnected && session.player != nil })
        #expect(session.server?.name == "Test Mac")
        #expect(session.player?.output == "Test DAC")
        #expect(await session.send(.playPause) == .ok)
        session.close()
        #expect(session.phase == .closed)
    }

    @Test func aRemovedPhoneCantSignIn() async throws {
        let other = RemoteTransport.PresharedKey(identity: "phone-other", key: Data(repeating: 0x11, count: 32))
        let mac = try FakeMac(keys: [other])
        let port = try await mac.start()
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let session = RemoteSession(pairing: SavedPairing(serverID: "S-TEST", name: "Test Mac", device: "phone-test", key: Data(repeating: 0x5A, count: 32)),
                                    clientName: "Test phone") { _ in endpoint }
        session.connect()
        #expect(await waitUntil { if case .unreachable = session.phase { true } else { false } })
        #expect(!session.isConnected)
        session.close()
    }
}
#endif
