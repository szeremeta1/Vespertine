//
// Vespertine: a Mac's address as a person types it ("mac-mini.tailnet.ts.net", "100.101.102.103:51234"), for reaching
// a paired Mac where Bonjour doesn't (away from home over Tailscale or another VPN, or a network that blocks Bonjour).
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

public struct RemoteAddress: Codable, Sendable, Hashable {
    /// A host name or an IP address (IPv6 without brackets), lowercased.
    public var host: String
    /// nil: not known yet (the phone fills it in from the last connection it made to that Mac).
    public var port: UInt16?

    public init(host: String, port: UInt16? = nil) {
        self.host = host
        self.port = port
    }

    /// What kind of network an address belongs to, as far as its text says.
    public enum Kind: String, Sendable, Equatable {
        /// A Tailscale name (`….ts.net`) or address (100.64.0.0/10, fd7a:115c:a1e0::/48).
        case tailscale
        /// A private address or a `.local` name: reachable on the same network (or over a VPN into it).
        case localNetwork
        case other
    }

    /// Reads "host", "host:port", "1.2.3.4:port", "[v6]:port" or a bare IPv6 address; forgives spaces around it, a
    /// `scheme://` in front and a path behind. nil for anything that can't be an address.
    public init?(parsing text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
        if let slash = rest.firstIndex(of: "/") { rest = rest[..<slash] }
        var host: Substring
        var portText: Substring?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = rest[rest.index(after: rest.startIndex)..<close]
            let after = rest[rest.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { return nil }
                portText = after.dropFirst()
            }
            guard host.contains(":") else { return nil }
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            host = rest[..<colon]
            portText = rest[rest.index(after: colon)...]
        } else {
            host = rest
        }
        while host.hasSuffix(".") { host = host.dropLast() }
        guard !host.isEmpty, host.count <= 253, host.allSatisfy(Self.isHostCharacter) else { return nil }
        if let portText {
            guard let value = UInt16(portText), value > 0 else { return nil }
            port = value
        } else {
            port = nil
        }
        self.host = host.lowercased()
    }

    private static func isHostCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || character.isNumber || "-._:%".contains(character)
    }

    /// "host", "host:port" or "[v6]:port".
    public var text: String {
        guard let port else { return host }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// The same address with `port` where this one has none.
    public func withPort(from other: RemoteAddress?) -> RemoteAddress {
        port == nil ? RemoteAddress(host: host, port: other?.port) : self
    }

    public var kind: Kind {
        if host.hasSuffix(".ts.net") || host.hasPrefix("fd7a:115c:a1e0:") { return .tailscale }
        if host.hasSuffix(".local") || host.hasPrefix("fe80:") { return .localNetwork }
        if let v4 = Self.ipv4(host) {
            if v4[0] == 100, (64...127).contains(v4[1]) { return .tailscale }
            if v4[0] == 10 || (v4[0] == 172 && (16...31).contains(v4[1])) || (v4[0] == 192 && v4[1] == 168) || (v4[0] == 169 && v4[1] == 254) {
                return .localNetwork
            }
        }
        if host.hasPrefix("fc") || host.hasPrefix("fd"), host.contains(":") { return .localNetwork }
        return .other
    }

    private static func ipv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber), let value = Int(part), value <= 255 else { return nil }
            return value
        }
        return numbers.count == 4 ? numbers : nil
    }
}
