//
// Vespertine: HTTP/1.1 requests and responses for the media server renderers pull from (and the tests' fake renderer).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public struct HTTPRequest: Sendable, Hashable {
    public var method: String
    /// The path without its query, percent-decoded.
    public var path: String
    public var query: [String: String]
    /// Header names in lower case.
    public var headers: [String: String]
    public var body: Data

    public static let maximumHeader = 64 * 1024

    /// The request in `data`, nil until its headers and its whole body (by Content-Length) have arrived.
    public static func parse(_ data: Data) -> HTTPRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = end.upperBound
        guard data.endIndex - bodyStart >= length else { return nil }
        let target = String(parts[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(method: String(parts[0]).uppercased(), path: components?.percentEncodedPath.removingPercentEncoding ?? target,
                           query: query, headers: headers, body: Data(data[bodyStart..<bodyStart + length]))
    }
}

public enum ByteRange: Sendable, Hashable {
    case whole
    case range(ClosedRange<Int64>)
    case unsatisfiable

    /// A `Range` header for a resource of `size` bytes (RFC 9110, 14.1.2). Several ranges, other units or an invalid
    /// header are answered with the whole resource, which the RFC allows.
    public static func parse(_ header: String?, size: Int64) -> ByteRange {
        guard let header = header?.trimmingCharacters(in: .whitespaces), header.lowercased().hasPrefix("bytes=") else { return .whole }
        let spec = header.dropFirst(6).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return .whole }
        let first = spec[..<dash].trimmingCharacters(in: .whitespaces), last = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        if first.isEmpty {
            guard let suffix = Int64(last) else { return .whole }
            guard suffix > 0, size > 0 else { return .unsatisfiable }
            return .range(max(0, size - suffix)...(size - 1))
        }
        guard let start = Int64(first) else { return .whole }
        let end = last.isEmpty ? size - 1 : (Int64(last) ?? -1)
        guard end >= start else { return last.isEmpty ? .unsatisfiable : .whole }
        guard start < size else { return .unsatisfiable }
        return .range(start...min(end, size - 1))
    }
}

public struct HTTPResponse: Sendable {
    public enum Body: Sendable {
        case empty
        case data(Data)
        /// Bytes `range` of a file.
        case file(URL, ClosedRange<Int64>)
        /// A file still being written, from its start: sent as it grows, close-delimited.
        case growing(GrowingFile)
    }

    public var status: Int
    public var headers: [(String, String)]
    public var body: Body
    /// HEAD: the headers of a GET, no body.
    public var headOnly = false

    public init(status: Int, headers: [(String, String)] = [], body: Body = .empty) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func status(_ code: Int) -> HTTPResponse { HTTPResponse(status: code, headers: [("Content-Length", "0")]) }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }

    var head: Data {
        var text = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "Connection: close\r\n\r\n"
        return Data(text.utf8)
    }
}
