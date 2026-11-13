//
// Vespertine: the sockets of a RAOP session. RTSP on one TCP connection (Network framework, which also resolves a Bonjour
// service and tells which local address reaches the receiver), and the UDP ports for audio, control and timing (BSD sockets
// bound to ephemeral ports, IPv4, one reader thread each).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Darwin
import Foundation
import Network
import os

public enum RAOPError: Error, Equatable, LocalizedError {
    case unreachable
    case timeout
    case closed
    case socket(Int32)
    /// The receiver answered a request with this status.
    case refused(String, Int)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable: String(localized: "it can't be reached")
        case .timeout: String(localized: "it didn't answer in time")
        case .closed: String(localized: "it closed the connection")
        case .socket(let e): String(localized: "network error \(e)")
        case .refused(let what, let status): status == 453 ? String(localized: "it is busy with another sender") : String(localized: "it refused \(what) (\(status))")
        case .badResponse(let what): String(localized: "it answered \(what) in a way Vespertine doesn't understand")
        }
    }
}

/// A UDP socket on an ephemeral port.
public final class UDPSocket: @unchecked Sendable {
    public let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    private var reader: Thread?

    public init(bind address: String = "0.0.0.0") throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw RAOPError.socket(errno) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_port = 0
        inet_pton(AF_INET, address, &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { let e = errno; Darwin.close(fd); throw RAOPError.socket(e) }
        var size = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int>.size))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        var local = sockaddr_in()
        _ = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        self.fd = fd
        port = UInt16(bigEndian: local.sin_port)
    }

    deinit { close() }

    @discardableResult
    public func send(_ data: Data, to host: String, port: UInt16) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1, lock.withLock({ !closed }) else { return false }
        let sent = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            } }
        }
        return sent == data.count
    }

    /// Calls `handler` on a thread of its own for every datagram, with the sender's address and port, until closed.
    public func startReceiving(name: String, _ handler: @escaping @Sendable (Data, String, UInt16) -> Void) {
        let fd = self.fd
        let thread = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 2048)
            while let self, !self.lock.withLock({ self.closed }) {
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, 200) > 0 else { continue }
                var from = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = buffer.withUnsafeMutableBytes { raw in
                    withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &length) } }
                }
                guard n > 0 else { continue }
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &from.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
                handler(Data(buffer[0..<n]), String(cString: text), UInt16(bigEndian: from.sin_port))
            }
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        lock.withLock { reader = thread }
        thread.start()
    }

    public func close() {
        let go = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        // The reader notices within its poll interval; the descriptor goes once it can't be used for a send any more.
        if go {
            let fd = self.fd
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { Darwin.close(fd) }
        }
    }
}

/// One RTSP connection: requests answered in order.
public actor RTSPConnection {
    private let connection: NWConnection
    private var parser = RTSPParser()
    private let queue = DispatchQueue(label: "org.szeremeta.vespertine.airplay.rtsp")
    public private(set) var remoteAddress = ""
    public private(set) var localAddress = ""
    public static let timeout: Duration = .seconds(5)

    public init(endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        connection = NWConnection(to: endpoint, using: parameters)
    }

    public func connect() async throws {
        let connection = self.connection
        try await withTimeout {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = OnceFlag()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: if once.take() { continuation.resume() }
                    case .failed, .cancelled: if once.take() { continuation.resume(throwing: RAOPError.unreachable) }
                    case .waiting: if once.take() { continuation.resume(throwing: RAOPError.unreachable) }
                    default: break
                    }
                }
                connection.start(queue: self.queue)
            }
        }
        if case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint { remoteAddress = Self.text(host) }
        if case .hostPort(let host, _)? = connection.currentPath?.localEndpoint { localAddress = Self.text(host) }
    }

    static func text(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let a): "\(a)".split(separator: "%").first.map(String.init) ?? "\(a)"
        case .ipv6(let a): "\(a)"
        case .name(let n, _): n
        @unknown default: "\(host)"
        }
    }

    /// Sends `request` and waits for its answer.
    public func send(_ request: RTSPMessage) async throws -> RTSPMessage {
        let connection = self.connection
        try await withTimeout {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                connection.send(content: request.encoded(), completion: .contentProcessed { error in
                    if error != nil { c.resume(throwing: RAOPError.closed) } else { c.resume() }
                })
            }
        }
        while true {
            if let message = try parser.next() { return message }
            let data: Data = try await withTimeout {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                        if let data, !data.isEmpty { c.resume(returning: data) } else if error != nil || complete { c.resume(throwing: RAOPError.closed) } else { c.resume(returning: Data()) }
                    }
                }
            }
            parser.append(data)
        }
    }

    public func close() { connection.cancel() }

    private func withTimeout<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let connection = self.connection
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: Self.timeout)
                connection.cancel()
                throw RAOPError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

/// True the first time only.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
