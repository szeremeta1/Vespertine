//
// Vespertine: the media server faces the whole local network. A malformed request is answered 400 and closed, a client
// that never finishes its headers is cut off, and too many connections at once are refused, and the server keeps serving.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Darwin
import Foundation
import Testing
@testable import VespertineUPnP

/// A plain TCP client: sends `bytes`, then reads until the server closes (or `timeout`). nil when it couldn't connect.
func rawExchange(port: UInt16, send bytes: Data, timeout: Double = 5) -> (response: String, closed: Bool)? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard ok == 0 else { return nil }
    if !bytes.isEmpty { _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, bytes.count, 0) } }
    var out = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 100) > 0 else { continue }
        let n = recv(fd, &buffer, buffer.count, 0)
        if n <= 0 { return (String(decoding: out, as: UTF8.self), true) }
        out.append(contentsOf: buffer[0..<n])
    }
    return (String(decoding: out, as: UTF8.self), false)
}

@Suite("HTTP server hardening", .serialized)
struct HTTPServerHardeningTests {
    @Test("A negative, huge or non-numeric Content-Length is not a request")
    func parserRejects() {
        for value in ["-1", "4611686018427387904", "abc", "12abc", "99999999999999999999"] {
            let data = Data("POST /x HTTP/1.1\r\nContent-Length: \(value)\r\n\r\n".utf8)
            #expect(HTTPRequest.read(data) == .invalid, "Content-Length: \(value)")
        }
        #expect(HTTPRequest.read(Data("GET /x HTTP/1.1\r\n".utf8)) == .incomplete)
        #expect(HTTPRequest.read(Data(repeating: 0x41, count: HTTPRequest.maximumHeader + 10)) == .invalid)
        if case .request = HTTPRequest.read(Data("GET /x HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8)) {} else { Issue.record("a plain GET parses") }
    }

    @Test("Content-Length -1 and 2^62 get 400 and are closed; the server still serves")
    func badLengthOverTheWire() async throws {
        let (file, bytes) = try randomFile(1000)
        let server = MediaServer()
        try await server.start()
        defer { server.stop() }
        let url = try #require(server.register(.file(file, mime: "audio/flac"), toward: "127.0.0.1"))
        let port = try #require(url.port.map(UInt16.init))
        for value in ["-1", "4611686018427387904"] {
            let reply = try #require(rawExchange(port: port, send: Data("POST \(url.path) HTTP/1.1\r\nHost: x\r\nContent-Length: \(value)\r\n\r\n".utf8)))
            #expect(reply.response.hasPrefix("HTTP/1.1 400"), "Content-Length: \(value)")
            #expect(reply.closed)
        }
        let (data, response) = try await fetch(url)
        #expect(response.statusCode == 200)
        #expect(data == bytes)
    }

    @Test("A client that never finishes its headers is cut off")
    func slowLoris() async throws {
        let server = HTTPServer(headerTimeout: 0.5) { _ in .status(404) }
        let port = try await server.start()
        defer { server.stop() }
        let started = Date()
        let reply = try #require(rawExchange(port: port, send: Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8), timeout: 5))
        #expect(reply.closed)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test("Connections over the cap are refused while the others are open, and served again after")
    func connectionCap() async throws {
        let server = HTTPServer(headerTimeout: 2, maximumConnections: 3) { _ in .status(404) }
        let port = try await server.start()
        defer { server.stop() }
        // Three idle connections fill it.
        var idle: [Int32] = []
        for _ in 0..<3 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET); addr.sin_port = port.bigEndian; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            idle.append(fd)
        }
        try await Task.sleep(for: .milliseconds(200))
        // Over the cap: closed on arrival (or, if the close beats the connect, refused outright). Never served.
        if let refused = rawExchange(port: port, send: Data("GET / HTTP/1.1\r\n\r\n".utf8), timeout: 1.5) {
            #expect(refused.closed)
            #expect(!refused.response.hasPrefix("HTTP/1.1 404"))
        }
        idle.forEach { close($0) }
        try await Task.sleep(for: .milliseconds(300))
        let served = try #require(rawExchange(port: port, send: Data("GET / HTTP/1.1\r\n\r\n".utf8)))
        #expect(served.response.hasPrefix("HTTP/1.1 404"))
    }
}
