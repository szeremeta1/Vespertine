//
// Vespertine: a small HTTP/1.1 server on NWListener: one request per connection, bodies sent with flow control (each
// chunk waits for the previous one to be taken), files read in chunks and never loaded whole.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network
import os

public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let handler: Handler
    private let queue = DispatchQueue(label: "org.szeremeta.vespertine.upnp.http", qos: .userInitiated)
    private let state = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    static let chunk = 256 * 1024
    private static let log = Logger(subsystem: "org.szeremeta.vespertine.player", category: "renderer")
    /// A client has this long to send its whole request, then it is cut off (a slow client can't hold a connection open).
    let headerTimeout: TimeInterval
    /// Connections open at once; more are closed as they arrive.
    let maximumConnections: Int

    /// Whether a connection from this address is taken at all (nil: from anywhere). A refused one is closed before a byte is read.
    let admits: (@Sendable (String?) -> Bool)?

    public init(headerTimeout: TimeInterval = 10, maximumConnections: Int = 32, admits: (@Sendable (String?) -> Bool)? = nil,
                handler: @escaping Handler) {
        self.headerTimeout = headerTimeout
        self.maximumConnections = maximumConnections
        self.admits = admits
        self.handler = handler
    }

    /// The address at the other end of `connection`, without a zone ("%en0") and with an IPv4-mapped IPv6 address as IPv4.
    static func peer(of connection: NWConnection) -> String? {
        guard case .hostPort(let host, _) = connection.endpoint else { return nil }
        switch host {
        case .ipv4(let address): return address.rawValue.map(String.init).joined(separator: ".")
        case .ipv6(let address):
            if let mapped = address.asIPv4 { return mapped.rawValue.map(String.init).joined(separator: ".") }
            let raw = [UInt8](address.rawValue)
            return stride(from: 0, to: 16, by: 2).map { String(UInt16(raw[$0]) << 8 | UInt16(raw[$0 + 1]), radix: 16) }.joined(separator: ":")
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }

    /// Listens on every interface, on `port` (0: any free one), and returns the port once ready.
    public func start(port: UInt16 = 0) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        state.withLock { self.listener = listener }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                case .cancelled: once.run { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        let (listener, open) = state.withLock { () -> (NWListener?, [NWConnection]) in
            defer { self.listener = nil; connections.removeAll() }
            return (self.listener, Array(connections.values))
        }
        listener?.cancel()
        open.forEach { $0.cancel() }
    }

    /// Connections held open now (the tests wait on it, not on a guessed length of time).
    var connectionCount: Int { state.withLock { connections.count } }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let peer = Self.peer(of: connection)
        let welcome = admits?(peer) ?? true
        let admitted = state.withLock { () -> Bool in
            guard welcome, connections.count < maximumConnections else { return false }
            connections[id] = connection
            return true
        }
        guard admitted else {
            // Over the cap, or from an address that is not taken: closed at once, before anything is read.
            connection.start(queue: queue)
            connection.forceCancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.state.withLock { _ = self?.connections.removeValue(forKey: id) }
            default: break
            }
        }
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { connection.forceCancel() }
        queue.asyncAfter(deadline: .now() + headerTimeout, execute: deadline)
        receive(connection, peer: peer, buffer: Data(), deadline: deadline)
    }

    private func receive(_ connection: NWConnection, peer: String?, buffer: Data, deadline: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let content { buffer.append(content) }
            if error != nil { deadline.cancel(); connection.cancel(); return }
            switch HTTPRequest.read(buffer) {
            case .request(var request):
                deadline.cancel()
                request.peer = peer
                let handler = self.handler
                Task {
                    var response = await handler(request)
                    if request.method == "HEAD" { response.headOnly = true }
                    await Self.send(response, on: connection)
                    connection.cancel()
                }
            case .invalid:
                deadline.cancel()
                Task {
                    await Self.send(.status(400), on: connection)
                    connection.cancel()
                }
            case .incomplete:
                if complete { deadline.cancel(); connection.cancel() } else { self.receive(connection, peer: peer, buffer: buffer, deadline: deadline) }
            }
        }
    }

    /// Sends `data`; false once the peer has gone.
    private static func write(_ data: Data, on connection: NWConnection, final: Bool = false) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, contentContext: final ? .finalMessage : .defaultMessage, isComplete: final,
                            completion: .contentProcessed { error in continuation.resume(returning: error == nil) })
        }
    }

    private static func send(_ response: HTTPResponse, on connection: NWConnection) async {
        guard await write(response.head, on: connection) else { return }
        if response.headOnly { return }
        switch response.body {
        case .empty:
            break
        case .data(let data):
            guard await write(data, on: connection) else { return }
        case .file(let url, let range):
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            var offset = range.lowerBound
            do {
                try handle.seek(toOffset: UInt64(offset))
                while offset <= range.upperBound {
                    let count = Int(min(Int64(chunk), range.upperBound - offset + 1))
                    guard let data = try handle.read(upToCount: count), !data.isEmpty else { return }
                    guard await write(data, on: connection) else { return }
                    offset += Int64(data.count)
                }
            } catch { return }
        case .growing(let file):
            var offset: Int64 = 0
            // Chunked (RFC 9112, 7.1): the length isn't known until the writer is done.
            do {
                while let data = try await file.read(from: offset, max: chunk) {
                    var framed = Data("\(String(data.count, radix: 16))\r\n".utf8)
                    framed.append(data)
                    framed.append(Data("\r\n".utf8))
                    guard await write(framed, on: connection) else { return }
                    offset += Int64(data.count)
                }
            } catch {
                // The file has more and it can't be read. The last chunk ("0") says "that was the whole song", so it is not
                // sent: the connection is dropped instead, which every client takes as a transfer that failed.
                log.error("A stream was cut off at byte \(offset, privacy: .public): its file could not be read: \(String(describing: error), privacy: .public)")
                connection.forceCancel()
                return
            }
            guard await write(Data("0\r\n\r\n".utf8), on: connection) else { return }
        }
    }
}

/// Runs the first closure it is given, and no other.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in defer { done = true }; return !done }
        if first { body() }
    }
}
