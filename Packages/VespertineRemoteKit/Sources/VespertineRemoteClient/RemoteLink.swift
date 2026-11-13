//
// Vespertine Remote: one TLS (pre-shared key) connection (length-framed JSON) to a Mac, with requests that await their replies.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Network)
import Foundation
import Network
import VespertineRemoteProtocol

/// A connection to a Mac's remote server. Runs on the main actor; Network calls back on the main queue.
@MainActor
final class RemoteLink: RemoteChannel {
    private let connection: NWConnection
    private var pending: [Int: CheckedContinuation<RemoteReply, any Error>] = [:]
    private var pendingReads: [Int: CheckedContinuation<StreamFrame, any Error>] = [:]
    private var opening: CheckedContinuation<Void, any Error>?
    private var nextID = 0
    private(set) var isReady = false
    private(set) var isClosed = false
    private var lastError: String?

    /// Everything the Mac sends that isn't a reply: playback, queue and output updates, and goodbye.
    var onPush: (@MainActor (ServerMessage) -> Void)?
    /// The connection ended (with the reason Network gave, if any).
    var onClose: (@MainActor (String?) -> Void)?

    init(endpoint: NWEndpoint, key: RemoteTransport.PresharedKey) {
        connection = NWConnection(to: endpoint, using: RemoteTransport.parameters(keys: [key]))
    }

    /// The Mac's address and port as this connection reached it.
    var remoteAddress: RemoteAddress? {
        guard case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint else { return nil }
        let name: String
        switch host {
        case .name(let text, _): name = text
        case .ipv4(let address): name = "\(address)"
        case .ipv6(let address): name = "\(address)"
        @unknown default: return nil
        }
        guard var parsed = RemoteAddress(parsing: name.contains(":") ? "[\(name)]" : name) else { return nil }
        parsed.port = port.rawValue
        return parsed
    }

    /// Connects, and returns once TLS is up.
    func open(timeout: Duration = .seconds(10)) async throws {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.changed(state) }
        }
        connection.start(queue: .main)
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, !self.isReady else { return }
            self.fail(opening: RemoteLinkError.timedOut)
            self.close()
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            if isReady { continuation.resume(); return }
            if isClosed { continuation.resume(throwing: RemoteLinkError.couldNotConnect(lastError ?? "")); return }
            opening = continuation
        }
    }

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
            opening?.resume()
            opening = nil
            receive()
        case .waiting(let error):
            // A refused key or an unreachable Mac: it won't get better by waiting on this connection.
            lastError = "\(error)"
            close()
        case .failed(let error):
            lastError = "\(error)"
            close()
        case .cancelled:
            close()
        default:
            break
        }
    }

    private func fail(opening error: any Error) {
        opening?.resume(throwing: error)
        opening = nil
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        fail(opening: RemoteLinkError.couldNotConnect(lastError ?? ""))
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: RemoteLinkError.closed) }
        let reading = pendingReads
        pendingReads.removeAll()
        for continuation in reading.values { continuation.resume(throwing: RemoteLinkError.closed) }
        onClose?(lastError)
    }

    private func receive() {
        connection.receiveMessage { [weak self] content, _, isComplete, error in
            // No content on a complete receive: the Mac closed the connection.
            let ended = error != nil || (content == nil && isComplete)
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                if ended { self.close(); return }
                if let content { self.handle(content) }
                self.receive()
            }
        }
    }

    private func handle(_ data: Data) {
        // A binary frame answers a stream read; everything else is JSON.
        if StreamFrame.isFrame(data) {
            if let frame = StreamFrame(decoding: data) { pendingReads.removeValue(forKey: frame.request)?.resume(returning: frame) }
            return
        }
        guard let message = try? RemoteProtocol.decoder().decode(ServerMessage.self, from: data) else { return }
        if case .reply(let id, let result) = message {
            if let read = pendingReads.removeValue(forKey: id) {
                // The Mac couldn't serve the range: its reason, instead of a frame.
                if case .failed(let reason) = result { read.resume(throwing: RemoteLinkError.readFailed(reason)) } else { read.resume(throwing: RemoteLinkError.readFailed("")) }
                return
            }
            pending.removeValue(forKey: id)?.resume(returning: result)
        } else {
            onPush?(message)
        }
    }

    /// Reads `length` bytes of an open stream from `offset`.
    func read(stream: Int, offset: Int64, length: Int, timeout: Duration = .seconds(30)) async throws -> StreamFrame {
        guard isReady, !isClosed else { throw RemoteLinkError.closed }
        nextID += 1
        let id = nextID
        let data = try RemoteProtocol.encoder().encode(ClientMessage(id: id, command: .streamRead(stream: stream, offset: offset, length: length)))
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.pendingReads.removeValue(forKey: id)?.resume(throwing: RemoteLinkError.timedOut)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StreamFrame, any Error>) in
            pendingReads[id] = continuation
            connection.send(content: data, contentContext: RemoteTransport.textContext, isComplete: true, completion: .contentProcessed { [weak self] error in
                guard error != nil else { return }
                MainActor.assumeIsolated { self?.pendingReads.removeValue(forKey: id)?.resume(throwing: RemoteLinkError.closed) }
            })
        }
    }

    /// Sends `command` and waits for the Mac's reply.
    func request(_ command: RemoteCommand, timeout: Duration = .seconds(15)) async throws -> RemoteReply {
        guard isReady, !isClosed else { throw RemoteLinkError.closed }
        nextID += 1
        let id = nextID
        let data = try RemoteProtocol.encoder().encode(ClientMessage(id: id, command: command))
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.pending.removeValue(forKey: id)?.resume(throwing: RemoteLinkError.timedOut)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RemoteReply, any Error>) in
            pending[id] = continuation
            connection.send(content: data, contentContext: RemoteTransport.textContext, isComplete: true, completion: .contentProcessed { [weak self] error in
                guard error != nil else { return }
                MainActor.assumeIsolated { self?.pending.removeValue(forKey: id)?.resume(throwing: RemoteLinkError.closed) }
            })
        }
    }
}
#endif
