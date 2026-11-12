//
// Vespertine: the web remote. When Settings › Remote also allows web browsers (off by default), this Mac serves a small
// page on the local network that does what the phone app does: a browser pairs once with the 6-digit code from Pair a
// Phone and gets a cookie; then it follows playback with Server-Sent Events and sends commands as JSON.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plain HTTP/1.1, one request per connection (the event stream stays open). Browsers can't speak TLS with a pre-shared
// key, so this traffic isn't encrypted: Settings says so, and it's a separate switch.
//

import CryptoKit
import Foundation
import Network
import VespertineRemoteProtocol

@MainActor
final class RemoteWebServer {
    /// The port the page is on, once listening.
    private(set) var port: UInt16? { didSet { if port != oldValue { onPortChange?(port) } } }
    /// Tells Settings the address changed.
    var onPortChange: (@MainActor (UInt16?) -> Void)?
    private(set) var failure: String?
    weak var server: RemoteServer?

    private var listener: NWListener?
    private var streams: [ObjectIdentifier: RemoteWebStream] = [:]

    /// The port tried first, so a bookmark keeps working; any free port if it's taken.
    static let preferredPort: UInt16 = 47_820
    private static let cookieName = "vespertine-remote"
    private static let maximumRequest = 64 * 1024

    var hasListeners: Bool { !streams.isEmpty }
    var isRunning: Bool { listener != nil }

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = false
            // The usual port, or any free one when something else has it.
            let listener: NWListener
            if let preferred = try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.preferredPort)!) {
                listener = preferred
            } else {
                listener = try NWListener(using: parameters)
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready: self.port = listener.port?.rawValue; self.failure = nil
                    case .failed(let error): self.failure = error.localizedDescription; self.stop()
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            failure = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        for stream in streams.values { stream.close() }
        streams.removeAll()
    }

    /// Closes the event streams of a browser that was removed in Settings.
    func disconnect(device: String) {
        for (id, stream) in streams where stream.device == device {
            stream.close()
            streams[id] = nil
        }
    }

    func push(player: PlayerState, queue: QueueState?, outputs: OutputsState) {
        for stream in streams.values { stream.update(player: player, queue: queue, outputs: outputs) }
    }

    var connectedDevices: Set<String> { Set(streams.values.map(\.device)) }

    // MARK: Requests

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] content, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                var buffer = buffer
                if let content { buffer.append(content) }
                if buffer.count > Self.maximumRequest || error != nil { connection.cancel(); return }
                if let request = HTTPRequest(buffer) {
                    self.handle(request, on: connection)
                } else if complete {
                    connection.cancel()
                } else {
                    self.read(connection, buffer: buffer)
                }
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        guard let server, let model = server.model else { return respond(connection, status: 503) }
        let device = authenticatedDevice(request)
        switch (request.method, request.path) {
        case ("GET", "/"):
            respond(connection, status: 200, type: "text/html; charset=utf-8", body: Data(RemoteWebPage.html(serverName: RemoteServer.computerName).utf8),
                    headers: ["Content-Security-Policy": RemoteWebPage.contentSecurityPolicy])
        // What a phone needs to put the remote on its home screen: nothing here says anything about this Mac or its music.
        case ("GET", "/manifest.webmanifest"):
            respond(connection, status: 200, type: "application/manifest+json", body: RemoteWebPage.manifest(), headers: ["Cache-Control": "no-cache"])
        case ("GET", let path) where RemoteWebIcon.sizes[path] != nil:
            if let icon = RemoteWebIcon.png(path: path) {
                respond(connection, status: 200, type: "image/png", body: icon, headers: ["Cache-Control": "public, max-age=86400"])
            } else {
                respond(connection, status: 404)
            }
        case ("GET", "/icon.svg"):
            respond(connection, status: 200, type: "image/svg+xml", body: Data(RemoteWebIcon.svg.utf8), headers: ["Cache-Control": "public, max-age=86400"])
        case ("GET", "/session"):
            if device != nil {
                respondJSON(connection, server.serverInfo)
            } else {
                respond(connection, status: 401)
            }
        case ("POST", "/pair"):
            guard request.isJSON, let body = try? JSONDecoder().decode(PairRequest.self, from: request.body) else { return respond(connection, status: 400) }
            switch server.pairBrowser(code: body.code, name: body.name) {
            case .success(let token):
                respond(connection, status: 200, type: "application/json", body: Data("{}".utf8), headers: [
                    "Set-Cookie": "\(Self.cookieName)=\(token); Path=/; Max-Age=31536000; HttpOnly; SameSite=Strict",
                ])
            case .failure(let reason):
                respondJSON(connection, ["error": reason.message], status: 403)
            }
        case ("GET", "/events"):
            guard let device else { return respond(connection, status: 401) }
            let stream = RemoteWebStream(connection: connection, device: device)
            let id = ObjectIdentifier(stream)
            stream.onClose = { [weak self] in self?.streams[id] = nil; self?.server?.webDevicesChanged() }
            streams[id] = stream
            stream.open()
            let bridge = RemoteBridge(model: model)
            let (player, queue, outputs) = server.snapshot(bridge)
            stream.update(player: player, queue: queue, outputs: outputs)
            server.webDevicesChanged()
        case ("POST", "/command"):
            guard device != nil else { return respond(connection, status: 401) }
            guard request.isJSON, let command = try? RemoteProtocol.decoder().decode(RemoteCommand.self, from: request.body) else {
                return respond(connection, status: 400)
            }
            switch command {
            case .hello, .pair, .artwork:
                respond(connection, status: 400)
            default:
                let reply = RemoteBridge(model: model).perform(command)
                respondJSON(connection, reply)
                server.pushSoon()
            }
        case ("GET", "/artwork"):
            guard device != nil else { return respond(connection, status: 401) }
            let key = request.query["key"] ?? ""
            let size = Int(request.query["size"] ?? "") ?? 600
            let store = ArtworkCache.shared.store
            Task { [weak self] in
                let found = await RemoteBridge.artwork(key: key, size: size, store: store)
                guard let self else { connection.cancel(); return }
                if let found {
                    self.respond(connection, status: 200, type: found.mimeType, body: found.data, headers: ["Cache-Control": "private, max-age=86400"])
                } else {
                    self.respond(connection, status: 404)
                }
            }
        default:
            respond(connection, status: 404)
        }
    }

    private struct PairRequest: Decodable {
        var code: String
        var name: String?
    }

    /// The paired browser whose cookie this request carries.
    private func authenticatedDevice(_ request: HTTPRequest) -> String? {
        guard let token = request.cookies[Self.cookieName], !token.isEmpty, let server else { return nil }
        let hash = Self.hash(token)
        guard let device = server.store.devices.first(where: { $0.isWeb && Self.constantTimeEqual($0.key, hash) }) else { return nil }
        return device.id
    }

    static func hash(_ token: String) -> Data { Data(SHA256.hash(data: Data(token.utf8))) }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    // MARK: Responses

    private func respondJSON<T: Encodable>(_ connection: NWConnection, _ value: T, status: Int = 200) {
        let body = (try? RemoteProtocol.encoder().encode(value)) ?? Data("{}".utf8)
        respond(connection, status: status, type: "application/json", body: body)
    }

    private func respond(_ connection: NWConnection, status: Int, type: String = "text/plain; charset=utf-8", body: Data = Data(),
                         headers: [String: String] = [:]) {
        let head = Self.head(status: status, type: type, length: body.count, headers: headers)
        connection.send(content: Data(head.utf8) + body, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// A response's status line and headers. Nothing is cached unless the caller says how (covers and icons do: a cover
    /// asked for again on every screen made the lists flicker and the Mac read the same file over and over).
    nonisolated static func head(status: Int, type: String, length: Int, headers: [String: String] = [:]) -> String {
        var head = "HTTP/1.1 \(status) \(reason(status))\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\n"
        head += "Connection: close\r\nCache-Control: \(headers["Cache-Control"] ?? "no-store")\r\n"
        head += "X-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) where name != "Cache-Control" { head += "\(name): \(value)\r\n" }
        return head + "\r\n"
    }

    nonisolated static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        default: "Service Unavailable"
        }
    }
}

/// One browser's event stream (Server-Sent Events): what changed since it last heard.
@MainActor
final class RemoteWebStream {
    let connection: NWConnection
    let device: String
    var onClose: (@MainActor () -> Void)?
    private var closed = false
    private var sentPlayer: PlayerState?
    private var sentQueueRevision: Int?
    private var sentOutputs: OutputsState?
    private var keepAlive: Task<Void, Never>?

    init(connection: NWConnection, device: String) {
        self.connection = connection
        self.device = device
    }

    func open() {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\nX-Accel-Buffering: no\r\n\r\n"
        write(head + "retry: 2000\n\n")
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: MainActor.assumeIsolated { self?.close() }
            default: break
            }
        }
        // Notices a browser that went away, and keeps proxies and sleepy Wi-Fi from closing an idle stream.
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.write(": keep-alive\n\n")
            }
        }
    }

    func update(player: PlayerState, queue: QueueState?, outputs: OutputsState) {
        guard !closed else { return }
        if sentPlayer.map({ $0.differs(from: player) }) ?? true {
            sentPlayer = player
            event("player", player)
        }
        if let queue, queue.revision != sentQueueRevision {
            sentQueueRevision = queue.revision
            event("queue", queue)
        }
        if outputs != sentOutputs {
            sentOutputs = outputs
            event("outputs", outputs)
        }
    }

    private func event<T: Encodable>(_ name: String, _ value: T) {
        guard let data = try? RemoteProtocol.encoder().encode(value) else { return }
        write("event: \(name)\ndata: \(String(decoding: data, as: UTF8.self))\n\n")
    }

    private func write(_ text: String) {
        guard !closed else { return }
        connection.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            MainActor.assumeIsolated { self?.close() }
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        keepAlive?.cancel()
        connection.cancel()
        onClose?()
    }
}

/// A parsed HTTP/1.1 request, once all of it has arrived.
nonisolated struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    /// nil until the headers and the whole body (by Content-Length) are in `data`.
    init?(_ data: Data) {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        method = String(requestLine[0])
        let target = String(requestLine[1])
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard length >= 0, data.count - (bodyStart - data.startIndex) >= length else { return nil }
        body = Data(data[bodyStart..<(bodyStart + length)])
        let components = URLComponents(string: target)
        path = components?.path ?? target
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        self.query = query
    }

    var isJSON: Bool { headers["content-type"]?.lowercased().hasPrefix("application/json") == true }

    var cookies: [String: String] {
        var result: [String: String] = [:]
        for part in (headers["cookie"] ?? "").split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { result[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1].trimmingCharacters(in: .whitespaces) }
        }
        return result
    }
}
