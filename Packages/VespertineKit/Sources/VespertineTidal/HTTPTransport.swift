//
// Vespertine: the one seam every TIDAL request goes through, so tests can answer without a network.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The real transport: an ephemeral `URLSession` (no cookies, no disk cache of authorized responses).
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// `application/x-www-form-urlencoded` bodies and query strings. Everything but the unreserved characters is percent-encoded
/// (so `+` in a scope becomes `%2B`, as python-tidal's `requests` sends it), keys sorted so the bytes are stable.
enum FormEncoding {
    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func encode(_ fields: [String: String]) -> String {
        fields.keys.sorted().map { "\(escape($0))=\(escape(fields[$0] ?? ""))" }.joined(separator: "&")
    }

    /// The fields of a form body or query string, percent-decoded (a `+` stays a `+`).
    static func decode(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first?.removingPercentEncoding else { continue }
            result[key] = parts.count > 1 ? (parts[1].removingPercentEncoding ?? String(parts[1])) : ""
        }
        return result
    }
}
