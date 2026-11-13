//
// Vespertine: the HTTP server renderers pull music from: byte-exact files, ranges, HEAD, and a file still being written.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineUPnP

/// A temporary file of `count` pseudo-random bytes (every byte value occurs, so an off-by-one can't hide).
func randomFile(_ count: Int, ext: String = "flac") throws -> (URL, Data) {
    var generator = SystemRandomNumberGenerator()
    var bytes = [UInt8](repeating: 0, count: count)
    for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &generator) }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-upnp-\(UUID().uuidString).\(ext)")
    let data = Data(bytes)
    try data.write(to: url)
    return (url, data)
}

func fetch(_ url: URL, method: String = "GET", headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
    request.httpMethod = method
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, try #require(response as? HTTPURLResponse))
}

@Suite("HTTP messages")
struct HTTPMessageTests {
    @Test("A request is parsed once its headers (and body) are complete")
    func parse() throws {
        #expect(HTTPRequest.parse(Data("GET /a HTTP/1.1\r\nHost: x\r\n".utf8)) == nil)
        let r = try #require(HTTPRequest.parse(Data("GET /media/ab.flac?x=1&y=two HTTP/1.1\r\nHost: x\r\nRange: bytes=0-9\r\n\r\n".utf8)))
        #expect(r.method == "GET")
        #expect(r.path == "/media/ab.flac")
        #expect(r.query == ["x": "1", "y": "two"])
        #expect(r.headers["range"] == "bytes=0-9")
        #expect(HTTPRequest.parse(Data("POST /c HTTP/1.1\r\nContent-Length: 5\r\n\r\nab".utf8)) == nil)
        #expect(try #require(HTTPRequest.parse(Data("POST /c HTTP/1.1\r\nContent-Length: 5\r\n\r\nabcde".utf8))).body == Data("abcde".utf8))
    }

    @Test("Byte ranges: closed, open-ended, suffix, clipped, unsatisfiable, several")
    func ranges() {
        #expect(ByteRange.parse("bytes=0-9", size: 100) == .range(0...9))
        #expect(ByteRange.parse("bytes=90-", size: 100) == .range(90...99))
        #expect(ByteRange.parse("bytes=-10", size: 100) == .range(90...99))
        #expect(ByteRange.parse("bytes=-1000", size: 100) == .range(0...99))
        #expect(ByteRange.parse("bytes=50-1000", size: 100) == .range(50...99))
        #expect(ByteRange.parse("bytes=100-", size: 100) == .unsatisfiable)
        #expect(ByteRange.parse("bytes=20-10", size: 100) == .whole)            // invalid: ignored, as RFC 9110 allows
        #expect(ByteRange.parse("bytes=0-1,5-6", size: 100) == .whole)
        #expect(ByteRange.parse("items=0-1", size: 100) == .whole)
        #expect(ByteRange.parse("bytes=-0", size: 100) == .unsatisfiable)
    }
}

@Suite("Media server", .serialized)
struct MediaServerTests {
    @Test("A whole file comes back byte for byte, with DLNA headers")
    func wholeFile() async throws {
        let (file, bytes) = try randomFile(300_000)
        let server = MediaServer()
        try await server.start()
        defer { server.stop() }
        let url = try #require(server.register(.file(file, mime: "audio/flac"), toward: "127.0.0.1"))
        #expect(url.host == "127.0.0.1")
        #expect(url.pathExtension == "flac")
        let (data, response) = try await fetch(url)
        #expect(response.statusCode == 200)
        #expect(data == bytes)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "audio/flac")
        #expect(response.value(forHTTPHeaderField: "Content-Length") == "300000")
        #expect(response.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        #expect(response.value(forHTTPHeaderField: "transferMode.dlna.org") == "Streaming")
        #expect(response.value(forHTTPHeaderField: "contentFeatures.dlna.org")?.contains("DLNA.ORG_OP=01") == true)
    }

    @Test("Ranges return exactly the bytes asked for", arguments: ["bytes=100-199", "bytes=1000-", "bytes=-500", "bytes=0-0", "bytes=299999-"])
    func ranged(_ header: String) async throws {
        let (file, bytes) = try randomFile(300_000)
        let server = MediaServer()
        try await server.start()
        defer { server.stop() }
        let url = try #require(server.register(.file(file, mime: "audio/flac"), toward: "127.0.0.1"))
        let (data, response) = try await fetch(url, headers: ["Range": header])
        guard case .range(let r) = ByteRange.parse(header, size: Int64(bytes.count)) else { Issue.record("range"); return }
        #expect(response.statusCode == 206)
        #expect(data == bytes.subdata(in: Int(r.lowerBound)..<Int(r.upperBound) + 1))
        #expect(response.value(forHTTPHeaderField: "Content-Range") == "bytes \(r.lowerBound)-\(r.upperBound)/300000")
    }

    @Test("A range past the end is 416, HEAD has headers and no body, an unknown token is 404")
    func errors() async throws {
        let (file, _) = try randomFile(1000, ext: "wav")
        let server = MediaServer()
        try await server.start()
        defer { server.stop() }
        let url = try #require(server.register(.file(file, mime: "audio/wav"), toward: "127.0.0.1"))
        let (_, past) = try await fetch(url, headers: ["Range": "bytes=5000-"])
        #expect(past.statusCode == 416)
        #expect(past.value(forHTTPHeaderField: "Content-Range") == "bytes */1000")
        let (body, head) = try await fetch(url, method: "HEAD")
        #expect(head.statusCode == 200)
        #expect(body.isEmpty)
        #expect(head.value(forHTTPHeaderField: "Content-Length") == "1000")
        let other = URL(string: url.absoluteString.replacingOccurrences(of: url.deletingPathExtension().lastPathComponent, with: "0000"))!
        let (_, missing) = try await fetch(other)
        #expect(missing.statusCode == 404)
        let (_, root) = try await fetch(URL(string: "/", relativeTo: url)!.absoluteURL)
        #expect(root.statusCode == 404)
    }

    @Test("A released resource is no longer served; tokens are unguessable")
    func release() async throws {
        let (file, _) = try randomFile(10)
        let server = MediaServer()
        try await server.start()
        defer { server.stop() }
        let url = try #require(server.register(.file(file, mime: "audio/flac"), toward: "127.0.0.1"))
        #expect(url.deletingPathExtension().lastPathComponent.count == 32)
        server.release(url)
        let (_, response) = try await fetch(url)
        #expect(response.statusCode == 404)
    }

    @Test("A file still being written is streamed as it grows, to its end")
    func growing() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-upnp-growing-\(UUID().uuidString).flac")
        let growing = try GrowingFile(url: url)
        let server = MediaServer()
        try await server.start()
        defer { server.stop() }
        let media = try #require(server.register(.growing(growing, mime: "audio/flac"), toward: "127.0.0.1"))
        let chunks = (0..<20).map { i in Data((0..<5000).map { UInt8(($0 &* 7 &+ i) & 0xFF) }) }
        let writer = Task.detached {
            let handle = try FileHandle(forWritingTo: url)
            for chunk in chunks {
                try handle.write(contentsOf: chunk)
                growing.grew()
                try await Task.sleep(for: .milliseconds(20))
            }
            try handle.close()
            growing.finish()
        }
        let (data, response) = try await fetch(media)
        try await writer.value
        #expect(response.statusCode == 200)
        #expect(data == chunks.reduce(Data(), +))
        #expect(response.value(forHTTPHeaderField: "contentFeatures.dlna.org")?.contains("DLNA.ORG_OP=00") == true)
        // Once finished it is an ordinary file: length and ranges.
        let (tail, ranged) = try await fetch(media, headers: ["Range": "bytes=-10"])
        #expect(ranged.statusCode == 206)
        #expect(tail == chunks.reduce(Data(), +).suffix(10))
    }

    @Test("The local address toward a host is one that reaches it")
    func localAddress() {
        #expect(LocalAddress.toward(host: "127.0.0.1") == "127.0.0.1")
        #expect(LocalAddress.toward(host: "not a host name") == nil)
    }
}
