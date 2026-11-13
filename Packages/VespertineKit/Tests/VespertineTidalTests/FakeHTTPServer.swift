//
// Vespertine: a CDN on 127.0.0.1 for the TIDAL reader tests: files served with Range support, and the trouble a real CDN gives
// (a stall, a slow link, a signed URL that expires, a dropped connection). Never reachable from outside the machine.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network

final class FakeHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var query: String?
        /// The `Range` header, as sent.
        var range: String?
        var status: Int
        var started: Date
        var finished: Date
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-http-server", attributes: .concurrent)
    private let condition = NSCondition()
    private var files: [String: Data] = [:]
    private var stalled = false
    private var bytesPerSecond: Double?
    /// Path → bytes a token may be used for before the CDN answers 403.
    private var expiring: [String: Int] = [:]
    /// Path + token → bytes served under it.
    private var served: [String: Int] = [:]
    /// Path → how many coming requests get their connection closed without an answer.
    private var drops: [String: Int] = [:]
    /// Path → statuses the coming requests get instead of the file, in order.
    private var failures: [String: [Int]] = [:]
    private var log: [Request] = []
    private var active = 0
    private var mostActive = 0
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, let port = listener.port?.rawValue else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
        self.port = port
    }

    deinit { listener.cancel() }

    func stop() {
        listener.cancel()
        stall(false)
    }

    // MARK: Configuration

    func serve(_ path: String, _ data: Data) { condition.withLock { files[path] = data } }

    func url(_ path: String, token: String? = nil) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)" + (token.map { "?token=\($0)" } ?? ""))!
    }

    /// Requests that arrive from now on wait (before any byte of the answer) until `stall(false)`.
    func stall(_ value: Bool) { condition.withLock { stalled = value; condition.broadcast() } }

    /// Bodies are sent at about this rate (nil: as fast as the machine goes).
    func throttle(_ value: Double?) { condition.withLock { bytesPerSecond = value } }

    /// Each `?token=` of `path` serves `bytes` (counted by whole answers) and then gets 403, the way a signed URL expires.
    func expire(_ path: String, afterBytes bytes: Int) { condition.withLock { expiring[path] = bytes } }

    /// The next `count` requests for `path` have their connection closed without an answer.
    func drop(_ path: String, count: Int) { condition.withLock { drops[path] = count } }

    /// The next requests for `path` are answered with `statuses`, one each, before the file is served again.
    func fail(_ path: String, with statuses: [Int]) { condition.withLock { failures[path] = statuses } }

    var requests: [Request] { condition.withLock { log } }
    /// The most requests that were being answered at once.
    var peakConcurrency: Int { condition.withLock { mostActive } }
    var waitingOnStall: Int { condition.withLock { stalledCount } }
    private var stalledCount = 0

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHead(connection, buffer: Data())
    }

    private func receiveHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                Thread.detachNewThread { self.answer(head, on: connection) }
            } else if complete || error != nil || buffer.count > 1 << 20 {
                connection.cancel()
            } else {
                self.receiveHead(connection, buffer: buffer)
            }
        }
    }

    private func answer(_ head: String, on connection: NWConnection) {
        let started = Date()
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let target = parts.count > 1 ? String(parts[1]) : "/"
        let components = URLComponents(string: target)
        let path = components?.path ?? target
        let query = components?.query
        let token = components?.queryItems?.first { $0.name == "token" }?.value ?? ""
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let range = headers["range"]

        condition.lock()
        active += 1
        mostActive = max(mostActive, active)
        while stalled { stalledCount += 1; condition.wait(); stalledCount -= 1 }
        let file = files[path]
        let dropping = (drops[path] ?? 0) > 0
        if dropping { drops[path]! -= 1 }
        let failure = failures[path]?.first
        if failure != nil { failures[path]!.removeFirst() }
        let limit = expiring[path]
        let used = served[path + "?" + token] ?? 0
        let rate = bytesPerSecond
        condition.unlock()

        func finish(_ status: Int) {
            condition.withLock {
                active -= 1
                log.append(Request(method: method, path: path, query: query, range: range, status: status, started: started, finished: Date()))
            }
        }

        if dropping {
            finish(0)
            connection.cancel()
            return
        }
        if let failure { return respond(connection, status: failure, headers: [:], body: Data("busy".utf8), rate: nil, finish: finish) }
        guard let file else { return respond(connection, status: 404, headers: [:], body: Data("not found".utf8), rate: nil, finish: finish) }
        if let limit, used >= limit { return respond(connection, status: 403, headers: [:], body: Data("expired".utf8), rate: nil, finish: finish) }

        var status = 200
        var body = file
        var extra: [String: String] = [:]
        if let range, let (start, end) = Self.parseRange(range, size: file.count) {
            guard start < file.count, start <= end else {
                return respond(connection, status: 416, headers: ["Content-Range": "bytes */\(file.count)"], body: Data(), rate: nil, finish: finish)
            }
            status = 206
            body = file.subdata(in: start..<(end + 1))
            extra["Content-Range"] = "bytes \(start)-\(end)/\(file.count)"
        }
        if limit != nil { condition.withLock { served[path + "?" + token, default: 0] += body.count } }
        respond(connection, status: status, headers: extra, body: method == "HEAD" ? Data() : body,
                contentLength: body.count, rate: rate, finish: finish)
    }

    /// `bytes=a-b` or `bytes=a-` (the end clamped to the file).
    private static func parseRange(_ value: String, size: Int) -> (Int, Int)? {
        guard value.hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard spec.count == 2, let start = Int(spec[0]) else { return nil }
        let end = spec[1].isEmpty ? size - 1 : min(Int(spec[1]) ?? (size - 1), size - 1)
        return (start, end)
    }

    private func respond(_ connection: NWConnection, status: Int, headers: [String: String], body: Data, contentLength: Int? = nil,
                         rate: Double?, finish: (Int) -> Void) {
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : status == 206 ? "Partial Content" : "Error")\r\n"
        head += "Content-Length: \(contentLength ?? body.count)\r\nConnection: close\r\nAccept-Ranges: bytes\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        // The last piece goes out after the request is counted as done: the client can't ask again before it has it, so a
        // finished request is never counted alongside the next one.
        var pieces: [Data] = []
        let step = rate.map { max(1024, Int($0 / 50)) } ?? max(1, body.count)
        var offset = 0
        while offset < body.count {
            pieces.append(body.subdata(in: offset..<min(body.count, offset + step)))
            offset += step
        }
        send(connection, Data(head.utf8))
        for (index, piece) in pieces.enumerated() {
            if let rate, rate > 0 { Thread.sleep(forTimeInterval: Double(piece.count) / rate) }
            if index == pieces.count - 1 { finish(status) }
            send(connection, piece)
        }
        if pieces.isEmpty { finish(status) }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Sends and waits until the bytes have been handed to the network.
    private func send(_ connection: NWConnection, _ data: Data) {
        let sent = DispatchSemaphore(value: 0)
        connection.send(content: data, completion: .contentProcessed { _ in sent.signal() })
        _ = sent.wait(timeout: .now() + 30)
    }
}
