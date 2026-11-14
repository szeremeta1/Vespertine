//
// Vespertine: the line to an SMB server: a TCP connection that sends and receives whole runs of bytes, with a time
// limit on each. A protocol, so the client above it can be tested against a recorded conversation.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// What went wrong talking to a share, in the terms the app explains it in.
public enum SMBError: Error, Equatable, Sendable {
    /// No connection could be made (wrong address, server off, VPN off).
    case unreachable
    /// The server stopped answering.
    case timedOut
    /// The connection closed.
    case closed
    /// The server sent something that isn't SMB as this client knows it.
    case malformed
    /// The server only speaks a version of SMB this client doesn't (SMB 1, or nothing below 3.1.1), or insists on encryption.
    case unsupported
    /// The name or password was refused.
    case signInFailed
    /// Signed in, but not allowed to use that share or folder.
    case accessDenied
    /// The server has no share by that name.
    case noSuchShare
    /// No such file or folder.
    case notFound
    /// A reply's signature didn't match: it didn't come from the server signed in to.
    case badSignature
    /// Any other refusal, with the server's status code.
    case status(UInt32)
}

public protocol SMBTransport: AnyObject, Sendable {
    func send(_ bytes: [UInt8]) throws
    /// Exactly `count` bytes, or an error.
    func receive(_ count: Int) throws -> [UInt8]
    func close()
}

/// A TCP connection with blocking reads and writes. Closing it from another thread ends a read that is waiting.
public final class SocketTransport: SMBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    /// Connects to `host` (a name or an address) on `port`, trying each address the name has.
    public init(host: String, port: Int = 445, timeout: TimeInterval = 10) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else { throw SMBError.unreachable }
        defer { freeaddrinfo(list) }

        var connected: Int32 = -1
        var next: UnsafeMutablePointer<addrinfo>? = first
        while let info = next, connected < 0 {
            next = info.pointee.ai_next
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            if Self.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen, timeout: timeout) {
                connected = fd
            } else {
                _ = Self.closeDescriptor(fd)
            }
        }
        guard connected >= 0 else { throw SMBError.unreachable }
        var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(connected, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(connected, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(connected, Int32(IPPROTO_TCP), TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        setsockopt(connected, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        descriptor = connected
    }

    deinit { close() }

    private static func closeDescriptor(_ fd: Int32) -> Int32 {
        #if canImport(Glibc)
        Glibc.close(fd)
        #else
        Darwin.close(fd)
        #endif
    }

    /// Connects without waiting longer than `timeout`.
    private static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t, timeout: TimeInterval) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }
        #if canImport(Glibc)
        let result = Glibc.connect(fd, address, length)
        #else
        let result = Darwin.connect(fd, address, length)
        #endif
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var waiting = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&waiting, 1, Int32(timeout * 1000)) == 1 else { return false }
        var problem: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &problem, &size) == 0 else { return false }
        return problem == 0
    }

    private var current: Int32 { lock.withLock { descriptor } }

    public func send(_ bytes: [UInt8]) throws {
        let fd = current
        guard fd >= 0 else { throw SMBError.closed }
        var sent = 0
        try bytes.withUnsafeBytes { raw in
            while sent < raw.count {
                #if canImport(Glibc)
                let n = Glibc.send(fd, raw.baseAddress! + sent, raw.count - sent, Int32(MSG_NOSIGNAL))
                #else
                let n = Darwin.send(fd, raw.baseAddress! + sent, raw.count - sent, 0)
                #endif
                if n > 0 {
                    sent += n
                } else if n < 0, errno == EINTR {
                    continue
                } else {
                    throw (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) ? SMBError.timedOut : SMBError.closed
                }
            }
        }
    }

    public func receive(_ count: Int) throws -> [UInt8] {
        let fd = current
        guard fd >= 0 else { throw SMBError.closed }
        var out = [UInt8](repeating: 0, count: count)
        var got = 0
        try out.withUnsafeMutableBytes { raw in
            while got < count {
                let n = recv(fd, raw.baseAddress! + got, count - got, 0)
                if n > 0 {
                    got += n
                } else if n < 0, errno == EINTR {
                    continue
                } else {
                    throw (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) ? SMBError.timedOut : SMBError.closed
                }
            }
        }
        return out
    }

    public func close() {
        let fd = lock.withLock { () -> Int32 in
            defer { descriptor = -1 }
            return descriptor
        }
        guard fd >= 0 else { return }
        shutdown(fd, Int32(SHUT_RDWR))
        _ = Self.closeDescriptor(fd)
    }
}
