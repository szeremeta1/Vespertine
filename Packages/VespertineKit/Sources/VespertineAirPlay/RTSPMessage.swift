//
// Vespertine: RTSP as AirPlay 1 speaks it: HTTP-like requests and answers on one TCP connection, numbered by CSeq, a body
// when Content-Length says so. The same parser reads answers (the sender) and requests (the test receiver).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public struct RTSPMessage: Sendable, Equatable {
    /// Request: method and URL; response: nil.
    public var method: String?
    public var url: String?
    /// Response: status code and reason; request: 0.
    public var status: Int
    public var reason: String
    /// In order; looked up case-insensitively.
    public var headers: [(String, String)]
    public var body: Data

    public static func == (a: RTSPMessage, b: RTSPMessage) -> Bool {
        a.method == b.method && a.url == b.url && a.status == b.status && a.body == b.body
            && a.headers.map { "\($0.0):\($0.1)" } == b.headers.map { "\($0.0):\($0.1)" }
    }

    public static func request(_ method: String, _ url: String, headers: [(String, String)] = [], body: Data = Data()) -> RTSPMessage {
        RTSPMessage(method: method, url: url, status: 0, reason: "", headers: headers, body: body)
    }

    public static func response(_ status: Int, _ reason: String = "OK", headers: [(String, String)] = [], body: Data = Data()) -> RTSPMessage {
        RTSPMessage(method: nil, url: nil, status: status, reason: reason, headers: headers, body: body)
    }

    public subscript(name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    public func encoded() -> Data {
        var head = method.map { "\($0) \(url ?? "*") RTSP/1.0\r\n" } ?? "RTSP/1.0 \(status) \(reason)\r\n"
        for (k, v) in headers where k.caseInsensitiveCompare("Content-Length") != .orderedSame { head += "\(k): \(v)\r\n" }
        if !body.isEmpty { head += "Content-Length: \(body.count)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

public enum RTSPParseError: Error, Equatable { case malformed, tooLarge }

/// Collects bytes and hands out whole messages.
public struct RTSPParser: Sendable {
    private var buffer = Data()
    static let headerLimit = 64 * 1024
    static let bodyLimit = 4 * 1024 * 1024

    public init() {}

    public mutating func append(_ data: Data) { buffer += data }

    /// The next whole message, nil when more bytes are needed.
    public mutating func next() throws -> RTSPMessage? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.headerLimit { throw RTSPParseError.tooLarge }
            return nil
        }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw RTSPParseError.malformed }
        let start = lines.removeFirst()
        var headers: [(String, String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw RTSPParseError.malformed }
            headers.append((String(line[..<colon]).trimmingCharacters(in: .whitespaces), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
        }
        let length = headers.first { $0.0.caseInsensitiveCompare("Content-Length") == .orderedSame }.map { Int($0.1) } ?? 0
        guard let length, length >= 0, length <= Self.bodyLimit else { throw RTSPParseError.malformed }
        let bodyStart = end.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer = Data(buffer[bodyEnd...])
        let parts = start.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { throw RTSPParseError.malformed }
        if parts[0].hasPrefix("RTSP/") {
            guard let status = Int(parts[1]) else { throw RTSPParseError.malformed }
            return .response(status, parts.count > 2 ? parts[2] : "", headers: headers, body: body)
        }
        guard parts.count == 3, parts[2].hasPrefix("RTSP/") else { throw RTSPParseError.malformed }
        return .request(parts[0], parts[1], headers: headers, body: body)
    }
}

/// The ports a SETUP answer gives.
public struct RAOPTransport: Sendable, Equatable {
    public var server: UInt16
    public var control: UInt16
    public var timing: UInt16?

    public static func request(control: UInt16, timing: UInt16) -> String {
        "RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;control_port=\(control);timing_port=\(timing)"
    }

    public static func parse(_ header: String) -> RAOPTransport? {
        var values: [String: UInt16] = [:]
        for part in header.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, let v = UInt16(kv[1]) { values[kv[0]] = v }
        }
        guard let server = values["server_port"], let control = values["control_port"] else { return nil }
        return RAOPTransport(server: server, control: control, timing: values["timing_port"])
    }
}
