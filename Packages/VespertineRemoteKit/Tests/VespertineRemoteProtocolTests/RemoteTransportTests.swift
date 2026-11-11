//
// Vespertine: the remote's TLS pre-shared-key WebSocket, end to end on this Mac's loopback: a listener holding several
// keys lets in a phone with any one of them, and refuses a wrong key or a key under another phone's identity.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Network)
import Foundation
import Network
import Testing
@testable import VespertineRemoteProtocol

/// One listener that answers every text message with "echo: <message>".
private final class EchoServer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "remote-transport-test.server")

    init(keys: [RemoteTransport.PresharedKey]) throws {
        listener = try NWListener(using: RemoteTransport.parameters(keys: keys), on: .any)
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            func receive() {
                connection.receiveMessage { content, _, _, error in
                    guard error == nil, let content else { connection.cancel(); return }
                    let answer = Data("echo: ".utf8) + content
                    connection.send(content: answer, contentContext: RemoteTransport.textContext, isComplete: true, completion: .contentProcessed { _ in })
                    receive()
                }
            }
            receive()
        }
    }

    func start() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint.Port, any Error>) in
            let once = Once()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: once.run { continuation.resume(returning: listener.port!) }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    deinit { listener.cancel() }
}

/// Resumes a continuation exactly once, whichever callback comes first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

/// Connects with `key`, sends "hello", and returns the answer (nil: the connection failed or nothing came back in time).
private func exchange(port: NWEndpoint.Port, key: RemoteTransport.PresharedKey) async -> String? {
    let connection = NWConnection(host: "127.0.0.1", port: port, using: RemoteTransport.parameters(keys: [key]))
    let queue = DispatchQueue(label: "remote-transport-test.client")
    defer { connection.cancel() }
    return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
        let once = Once()
        queue.asyncAfter(deadline: .now() + 5) { once.run { continuation.resume(returning: nil) } }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data("hello".utf8), contentContext: RemoteTransport.textContext, isComplete: true, completion: .contentProcessed { _ in })
                connection.receiveMessage { content, _, _, error in
                    let text = error == nil ? content.map { String(decoding: $0, as: UTF8.self) } : nil
                    once.run { continuation.resume(returning: text) }
                }
            case .failed, .cancelled:
                once.run { continuation.resume(returning: nil) }
            case .waiting:
                // TLS refused (a wrong key) shows as waiting on some systems: it won't get better by itself.
                once.run { continuation.resume(returning: nil) }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}

@Suite(.serialized) struct Transport {
    let alex = RemoteTransport.PresharedKey(identity: "phone-alex", key: Data(repeating: 0xA1, count: 32))
    let ipad = RemoteTransport.PresharedKey(identity: "phone-ipad", key: Data(repeating: 0xB2, count: 32))

    @Test func eachPairedKeyGetsIn() async throws {
        let server = try EchoServer(keys: [alex, ipad])
        let port = try await server.start()
        #expect(await exchange(port: port, key: alex) == "echo: hello")
        #expect(await exchange(port: port, key: ipad) == "echo: hello")
    }

    @Test func wrongKeysAreRefused() async throws {
        let server = try EchoServer(keys: [alex, ipad])
        let port = try await server.start()
        #expect(await exchange(port: port, key: .init(identity: "phone-alex", key: Data(repeating: 0xC3, count: 32))) == nil)
        // Another phone's identity with this phone's key.
        #expect(await exchange(port: port, key: .init(identity: "phone-alex", key: ipad.key)) == nil)
        #expect(await exchange(port: port, key: .init(identity: "phone-unknown", key: alex.key)) == nil)
    }

    @Test func pairingKeysWork() async throws {
        let secret = PairingSecret.makeTypedCode()
        let pairing = RemoteTransport.PresharedKey(identity: RemoteProtocol.pairingCodeIdentity, key: PairingKey.derive(secret: secret, serverID: "S1"))
        let server = try EchoServer(keys: [alex, pairing])
        let port = try await server.start()
        #expect(await exchange(port: port, key: pairing) == "echo: hello")
        let wrongCode = RemoteTransport.PresharedKey(identity: RemoteProtocol.pairingCodeIdentity, key: PairingKey.derive(secret: "000000", serverID: "S1"))
        #expect(await exchange(port: port, key: wrongCode) == nil)
    }
}
#endif
