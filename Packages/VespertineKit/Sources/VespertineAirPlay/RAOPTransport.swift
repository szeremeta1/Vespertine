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
        case .socket(let e): String(localized: "network error: \(String(cString: strerror(e)))")
        case .refused(_, 453): String(localized: "it is busy with another sender")
        case .refused(_, 401): String(localized: "it didn't accept the password", comment: "Why an AirPlay receiver couldn't play: goes in “%1$@ couldn't play the song (%2$@).”")
        case .refused(let what, let status): String(localized: "it refused \(what) (\(status))")
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
    /// A reader thread was started: it closes the descriptor when it stops (see `close`).
    private var readerCloses = false

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
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }
        // Sent under the lock the descriptor is closed under: a closed descriptor's number is soon another socket's, and a
        // datagram sent a moment after `close` would go out from that one. (A UDP send doesn't wait.)
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        let sent = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            } }
        }
        return sent == data.count
    }

    /// Calls `handler` on a thread of its own for every datagram, with the sender's address and port, until closed. Once only.
    public func startReceiving(name: String, _ handler: @escaping @Sendable (Data, String, UInt16) -> Void) {
        let fd = self.fd
        let lock = self.lock
        let starts = lock.withLock { () -> Bool in
            guard !closed, !readerCloses else { return false }
            readerCloses = true
            return true
        }
        guard starts else { return }
        let thread = Thread { [weak self] in
            // Room for the largest audio packet whole: 352 frames of 24-bit stereo that would not compress are 2112 bytes
            // before the header, the seal and the nonce. A shorter buffer would cut such a packet and it would not open.
            var buffer = [UInt8](repeating: 0, count: 4096)
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
            // Closed by the thread that reads it, once it has stopped reading: nothing is left that could use the number.
            lock.withLock { _ = Darwin.close(fd) }
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        lock.withLock { reader = thread }
        thread.start()
    }

    public func close() {
        // With a reader, the descriptor is the reader's to close: it notices within its poll interval, and closes it only
        // when it has left its loop. Closing it from here, on a timer, let a reader that was late (a busy machine, a slow
        // handler) poll and read a number that had become another socket's by then, and take that socket's datagrams.
        // Without a reader nothing else uses it (a send holds this lock), so it is closed now.
        lock.withLock {
            guard !closed else { return }
            closed = true
            if !readerCloses { Darwin.close(fd) }
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

    /// Requests go one at a time: a keep-alive can't slip between another request and its answer (the actor alone would let
    /// it, at the awaits).
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }

    /// Once a receiver has been paired with, everything on the connection is sealed (`PairingChannel`), both ways.
    private var channel: PairingChannel?

    /// From the next request on, the connection is sealed with `keys`. Waits its turn behind a request under way, so the
    /// answer to that one is still read in the clear.
    func secure(keys: PairingChannelKeys) async {
        await acquire()
        defer { release() }
        channel = PairingChannel(keys: keys)
    }

    var isSecured: Bool { channel != nil }

    /// Sends `request` and waits for its answer.
    public func send(_ request: RTSPMessage) async throws -> RTSPMessage {
        await acquire()
        defer { release() }
        return try await exchange(request)
    }

    private func exchange(_ request: RTSPMessage) async throws -> RTSPMessage {
        let connection = self.connection
        var bytes = request.encoded()
        if channel != nil {
            guard let sealed = try? channel?.seal(bytes) else { throw RAOPError.closed }
            bytes = sealed
        }
        let outgoing = bytes
        try await withTimeout {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                connection.send(content: outgoing, completion: .contentProcessed { error in
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
            if channel != nil {
                // A frame that doesn't open: the connection is of no more use (the counts on the two sides have parted).
                guard let plain = try? channel?.open(data) else {
                    connection.cancel()
                    throw RAOPError.closed
                }
                parser.append(plain)
            } else {
                parser.append(data)
            }
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
