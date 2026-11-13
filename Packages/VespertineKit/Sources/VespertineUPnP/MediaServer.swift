//
// Vespertine: the media server a renderer pulls the music from. It serves only what playback registered, under random
// tokens (`/media/<32 hex>.<ext>`): the original file's bytes (pass-through, with ranges), or the FLAC Vespertine is
// still writing (processed). Nothing else on this Mac can be reached through it.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Darwin
import Foundation

/// A file being written by someone else (the FLAC encoder): readers follow it as it grows, until `finish()`.
public final class GrowingFile: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var finished = false
    private var failed = false

    /// Creates (or empties) the file at `url`.
    public init(url: URL) throws {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
    }

    public var isFinished: Bool { lock.withLock { finished } }
    public var size: Int64 { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 }

    /// The writer added bytes (readers also look on their own every 20 ms).
    public func grew() {}
    /// The writer is done: the file is complete.
    public func finish() { lock.withLock { finished = true } }
    /// The writer gave up: readers stop where the file ends.
    public func fail() { lock.withLock { finished = true; failed = true } }

    /// Up to `max` bytes from `offset`, waiting for them while the file is still being written; nil at its end.
    public func read(from offset: Int64, max: Int) async -> Data? {
        while !Task.isCancelled {
            let done = isFinished
            let available = size - offset
            if available > 0 {
                guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
                defer { try? handle.close() }
                try? handle.seek(toOffset: UInt64(offset))
                return try? handle.read(upToCount: Int(min(Int64(max), available)))
            }
            if done { return nil }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}

public enum MediaResource: Sendable {
    case file(URL, mime: String)
    case growing(GrowingFile, mime: String)

    var mime: String {
        switch self {
        case .file(_, let mime), .growing(_, let mime): mime
        }
    }

    var pathExtension: String {
        switch MediaType.normalise(mime) {
        case "audio/flac": "flac"
        case "audio/wav": "wav"
        case "audio/aiff": "aiff"
        case "audio/mp4": "m4a"
        case "audio/mpeg": "mp3"
        case "audio/x-dsf": "dsf"
        case "audio/x-dff": "dff"
        case "audio/ogg": "ogg"
        default:
            switch self {
            case .file(let url, _): url.pathExtension.isEmpty ? "bin" : url.pathExtension.lowercased()
            case .growing: "bin"
            }
        }
    }
}

/// The address of this Mac on the interface that reaches a host.
public enum LocalAddress {
    /// The IPv4 address the system would send from to reach `host` (a UDP socket "connected" to it sends nothing).
    public static func toward(host: String) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: 0, ai_addrlen: 0,
                             ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "9", &hints, &info) == 0, let first = info else { return nil }
        defer { freeaddrinfo(info) }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard got == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &local.sin_addr, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text == "0.0.0.0" ? nil : text
    }
}

public final class MediaServer: @unchecked Sendable {
    private let lock = NSLock()
    private var resources: [String: MediaResource] = [:]
    private var server: HTTPServer?
    private var port: UInt16?

    public init() {}

    public var isRunning: Bool { lock.withLock { port != nil } }

    /// Starts listening (once; again after `stop`).
    public func start() async throws {
        guard lock.withLock({ server == nil }) else { return }
        let server = HTTPServer { [weak self] request in
            guard let self else { return .status(503) }
            return self.respond(to: request)
        }
        lock.withLock { self.server = server }
        let port = try await server.start()
        lock.withLock { self.port = port }
    }

    public func stop() {
        let server = lock.withLock { () -> HTTPServer? in
            defer { self.server = nil; port = nil; resources.removeAll() }
            return self.server
        }
        server?.stop()
    }

    /// The URL `resource` is served at for a renderer at `host`; nil while not running or when no interface reaches it.
    public func register(_ resource: MediaResource, toward host: String) -> URL? {
        guard let port = lock.withLock({ port }), let address = LocalAddress.toward(host: host) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        lock.withLock { resources[token] = resource }
        return URL(string: "http://\(address):\(port)/media/\(token).\(resource.pathExtension)")
    }

    public func release(_ url: URL) {
        let token = url.deletingPathExtension().lastPathComponent
        lock.withLock { _ = resources.removeValue(forKey: token) }
    }

    /// Every registered URL's token, for tests and bookkeeping.
    var tokens: Set<String> { lock.withLock { Set(resources.keys) } }

    static let dlnaFlags = "01700000000000000000000000000000"

    func respond(to request: HTTPRequest) -> HTTPResponse {
        guard request.method == "GET" || request.method == "HEAD" else { return .status(405) }
        let parts = request.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "media" else { return .status(404) }
        let token = parts[1].split(separator: ".").first.map(String.init) ?? ""
        guard let resource = lock.withLock({ resources[token] }) else { return .status(404) }
        let common: [(String, String)] = [("Content-Type", resource.mime), ("transferMode.dlna.org", "Streaming"), ("Server", "macOS UPnP/1.0 Vespertine/1")]
        let file: URL
        switch resource {
        case .growing(let growing, _) where !growing.isFinished:
            return HTTPResponse(status: 200, headers: common + [("contentFeatures.dlna.org", "DLNA.ORG_OP=00;DLNA.ORG_CI=1;DLNA.ORG_FLAGS=\(Self.dlnaFlags)"),
                                                        ("Transfer-Encoding", "chunked")],
                                body: .growing(growing))
        case .growing(let growing, _): file = growing.url
        case .file(let url, _): file = url
        }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) else { return .status(404) }
        var headers = common + [("Accept-Ranges", "bytes"), ("contentFeatures.dlna.org", "DLNA.ORG_OP=01;DLNA.ORG_FLAGS=\(Self.dlnaFlags)")]
        switch ByteRange.parse(request.headers["range"], size: size) {
        case .unsatisfiable:
            return HTTPResponse(status: 416, headers: headers + [("Content-Range", "bytes */\(size)"), ("Content-Length", "0")])
        case .range(let r):
            headers += [("Content-Range", "bytes \(r.lowerBound)-\(r.upperBound)/\(size)"), ("Content-Length", "\(r.upperBound - r.lowerBound + 1)")]
            return HTTPResponse(status: 206, headers: headers, body: .file(file, r))
        case .whole:
            headers.append(("Content-Length", "\(size)"))
            return HTTPResponse(status: 200, headers: headers, body: size > 0 ? .file(file, 0...(size - 1)) : .empty)
        }
    }
}
