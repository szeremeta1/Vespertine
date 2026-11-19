//
// Vespertine: the remote's TLS pre-shared-key connection, end to end on this Mac's loopback: a listener holding several
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

    init(keys: [RemoteTransport.PresharedKey], parameters: NWParameters? = nil) throws {
        listener = try NWListener(using: parameters ?? RemoteTransport.parameters(keys: keys), on: .any)
        listener.newConnectionHandler = { [queue] connection in
            connection.stateUpdateHandler = { state in
                if case .failed(let error) = state { print("transport test: server connection failed: \(error)") }
                if case .waiting(let error) = state { print("transport test: server connection waiting: \(error)") }
            }
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
private func exchange(port: NWEndpoint.Port, key: RemoteTransport.PresharedKey, parameters: NWParameters? = nil) async -> String? {
    let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters ?? RemoteTransport.parameters(keys: [key]))
    let queue = DispatchQueue(label: "remote-transport-test.client")
    defer { connection.cancel() }
    return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
        let once = Once()
        queue.asyncAfter(deadline: .now() + 5) { once.run { continuation.resume(returning: nil) } }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("transport test: client ready (TLS and framing up, if any)")
                connection.send(content: Data("hello".utf8), contentContext: RemoteTransport.textContext, isComplete: true, completion: .contentProcessed { _ in })
                connection.receiveMessage { content, _, _, error in
                    let text = error == nil ? content.map { String(decoding: $0, as: UTF8.self) } : nil
                    once.run { continuation.resume(returning: text) }
                }
            case .failed(let error):
                print("transport test: client failed: \(error)")
                once.run { continuation.resume(returning: nil) }
            case .cancelled:
                once.run { continuation.resume(returning: nil) }
            case .waiting(let error):
                // TLS refused (a wrong key) shows as waiting on some systems: it won't get better by itself.
                print("transport test: client waiting: \(error)")
                once.run { continuation.resume(returning: nil) }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}

/// Connects with `parameters` and returns the cipher suite TLS agreed on (nil: no connection within five seconds).
private func agreedSuite(port: NWEndpoint.Port, parameters: NWParameters) async -> UInt16? {
    let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
    let queue = DispatchQueue(label: "remote-transport-test.suite")
    defer { connection.cancel() }
    return await withCheckedContinuation { (continuation: CheckedContinuation<UInt16?, Never>) in
        let once = Once()
        queue.asyncAfter(deadline: .now() + 5) { once.run { continuation.resume(returning: nil) } }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
                let suite = metadata.map { sec_protocol_metadata_get_negotiated_tls_ciphersuite($0.securityProtocolMetadata).rawValue }
                once.run { continuation.resume(returning: suite) }
            case .failed, .cancelled, .waiting:
                once.run { continuation.resume(returning: nil) }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}

/// Builds the transport with parts switched on or off, to see which part a failure comes from.
private func variant(keys: [RemoteTransport.PresharedKey], tls: Bool, versionLimits: Bool, framing: Bool) -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    let parameters: NWParameters
    if tls {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        for psk in keys {
            let key = psk.key.withUnsafeBytes { DispatchData(bytes: $0) }
            let identity = Data(psk.identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(security, key as __DispatchData, identity as __DispatchData)
        }
        sec_protocol_options_append_tls_ciphersuite(security, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        if versionLimits {
            sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
            sec_protocol_options_set_max_tls_protocol_version(security, .TLSv12)
        }
        parameters = NWParameters(tls: options, tcp: tcp)
    } else {
        parameters = NWParameters(tls: nil, tcp: tcp)
    }
    if framing {
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolFramer.Options(definition: RemoteFrame.definition), at: 0)
    }
    return parameters
}

@Suite(.serialized) struct TransportParts {
    let key = RemoteTransport.PresharedKey(identity: "phone-alex", key: Data(repeating: 0xA1, count: 32))

    /// Reports which combinations get a message through (diagnostic: prints; without TLS it must work). Without the
    /// framing a message only ends when the stream does, so those combinations time out by design.
    @Test func whichPartsWork() async throws {
        for (tls, limits, framing) in [(false, false, true), (true, true, true), (true, false, true), (true, true, false)] {
            let server = try EchoServer(keys: [key], parameters: variant(keys: [key], tls: tls, versionLimits: limits, framing: framing))
            let port = try await server.start()
            let answer = await exchange(port: port, key: key, parameters: variant(keys: [key], tls: tls, versionLimits: limits, framing: framing))
            print("transport test: tls=\(tls) tls12only=\(limits) framing=\(framing) -> \(answer ?? "nil")")
            if !tls { #expect(answer == "echo: hello") }
            withExtendedLifetime(server) {}
        }
    }

    @Test func headersCarryTheLength() {
        for length in [0, 1, 255, 256, 70_000, RemoteProtocol.maximumMessageSize] {
            #expect(RemoteFrame.length(of: RemoteFrame.header(length: length)) == length)
        }
        #expect(RemoteFrame.header(length: 0x01020304) == Data([1, 2, 3, 4]))
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
        withExtendedLifetime(server) {}
    }

    @Test func wrongKeysAreRefused() async throws {
        let server = try EchoServer(keys: [alex, ipad])
        let port = try await server.start()
        #expect(await exchange(port: port, key: .init(identity: "phone-alex", key: Data(repeating: 0xC3, count: 32))) == nil)
        // Another phone's identity with this phone's key.
        #expect(await exchange(port: port, key: .init(identity: "phone-alex", key: ipad.key)) == nil)
        #expect(await exchange(port: port, key: .init(identity: "phone-unknown", key: alex.key)) == nil)
        withExtendedLifetime(server) {}
    }

    @Test func pairingKeysWork() async throws {
        let secret = PairingSecret.makeTypedCode()
        let pairing = RemoteTransport.PresharedKey(identity: RemoteProtocol.pairingCodeIdentity, key: PairingKey.derive(secret: secret, serverID: "S1"))
        let server = try EchoServer(keys: [alex, pairing])
        let port = try await server.start()
        #expect(await exchange(port: port, key: pairing) == "echo: hello")
        let wrongCode = RemoteTransport.PresharedKey(identity: RemoteProtocol.pairingCodeIdentity, key: PairingKey.derive(secret: "000000", serverID: "S1"))
        #expect(await exchange(port: port, key: wrongCode) == nil)
        withExtendedLifetime(server) {}
    }

    /// Two ends of this version agree on ECDHE-PSK, so a recording of a pairing by typed code can't be opened by trying all
    /// 900,000 codes; an end from before (plain PSK only) still gets in, either way round.
    @Test func newEndsAgreeOnForwardSecrecyAndOldEndsStillConnect() async throws {
        let ecdhePSK: UInt16 = 0xCCAC, plainPSK = UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)
        let code = PairingSecret.makeTypedCode()
        let pairing = RemoteTransport.PresharedKey(identity: RemoteProtocol.pairingCodeIdentity, key: PairingKey.derive(secret: code, serverID: "S1"))
        #expect(RemoteTransport.cipherSuites.first?.rawValue == ecdhePSK)

        let mac = try EchoServer(keys: [alex, pairing])
        let port = try await mac.start()
        #expect(await agreedSuite(port: port, parameters: RemoteTransport.parameters(keys: [pairing])) == ecdhePSK)
        #expect(await agreedSuite(port: port, parameters: RemoteTransport.parameters(keys: [alex])) == ecdhePSK)
        #expect(await exchange(port: port, key: pairing) == "echo: hello")
        // A phone app from before offers plain PSK only.
        let oldPhone = variant(keys: [alex], tls: true, versionLimits: true, framing: true)
        #expect(await agreedSuite(port: port, parameters: oldPhone) == plainPSK)
        // A wrong code still gets nowhere.
        let wrong = RemoteTransport.PresharedKey(identity: RemoteProtocol.pairingCodeIdentity, key: PairingKey.derive(secret: "000000", serverID: "S1"))
        #expect(await agreedSuite(port: port, parameters: RemoteTransport.parameters(keys: [wrong])) == nil)
        withExtendedLifetime(mac) {}

        // A Mac from before takes plain PSK only: a new phone still connects to it.
        let oldMac = try EchoServer(keys: [alex], parameters: variant(keys: [alex], tls: true, versionLimits: true, framing: true))
        let oldPort = try await oldMac.start()
        #expect(await agreedSuite(port: oldPort, parameters: RemoteTransport.parameters(keys: [alex])) == plainPSK)
        #expect(await exchange(port: oldPort, key: alex) == "echo: hello")
        withExtendedLifetime(oldMac) {}
    }
}
#endif
