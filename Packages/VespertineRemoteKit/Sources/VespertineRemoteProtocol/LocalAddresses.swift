//
// Vespertine: this machine's own network addresses. The Mac tells a paired phone where it can be reached (its addresses
// at home, and its Tailscale or other VPN address); the phone looks at its own to say whether Tailscale is on.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

public enum LocalAddresses {
    /// One address of one network interface, as the system lists it.
    public struct Entry: Sendable, Equatable {
        public var interface: String
        /// The address as text (IPv6 without a zone), lowercased.
        public var host: String
        public var isUp: Bool
        public var isLoopback: Bool

        public init(interface: String, host: String, isUp: Bool = true, isLoopback: Bool = false) {
            self.interface = interface
            self.host = host
            self.isUp = isUp
            self.isLoopback = isLoopback
        }
    }

    /// The most addresses a Mac tells a phone (each is one more connection the phone tries).
    public static let maximumAdvertised = 8

    /// The addresses worth telling a phone, best first: this network's private IPv4 addresses, then Tailscale's (IPv4, then
    /// IPv6), then any other private or VPN address. Loopback, link-local and interfaces that are down are left out, and so
    /// are public IPv6 addresses (they change, and a home router doesn't let a phone in through them). `port` is the one the
    /// Mac listens on; `names` are host names known for it (its Tailscale name), put right after the Tailscale addresses.
    public static func advertised(from entries: [Entry], port: UInt16, names: [String] = []) -> [RemoteAddress] {
        var local: [RemoteAddress] = [], tailscale: [RemoteAddress] = [], other: [RemoteAddress] = []
        for entry in entries where entry.isUp && !entry.isLoopback {
            let host = entry.host.lowercased()
            guard !host.isEmpty, !host.hasPrefix("fe80:"), !host.hasPrefix("169.254."), host != "::1", !host.hasPrefix("127.") else { continue }
            let address = RemoteAddress(host: host, port: port)
            let isV6 = host.contains(":")
            switch address.kind {
            case .tailscale: tailscale.append(address)
            case .localNetwork: if isV6 { other.append(address) } else { local.append(address) }
            // A public IPv4 address on an interface (a Mac straight on the internet, or a VPN that hands them out).
            case .other: if !isV6 { other.append(address) }
            }
        }
        // IPv4 before IPv6 within Tailscale: the shorter one is the one people recognise.
        tailscale.sort { !$0.host.contains(":") && $1.host.contains(":") }
        let named = names.compactMap { RemoteAddress(parsing: $0) }.map { RemoteAddress(host: $0.host, port: port) }
        var out: [RemoteAddress] = []
        for address in local + tailscale + named + other where !out.contains(address) { out.append(address) }
        return Array(out.prefix(maximumAdvertised))
    }

    /// Whether any of `entries` is a Tailscale address on an interface that is up: Tailscale is connected on this machine.
    public static func hasTailscale(_ entries: [Entry]) -> Bool {
        entries.contains { $0.isUp && !$0.isLoopback && RemoteAddress(host: $0.host.lowercased()).kind == .tailscale }
    }

    #if canImport(Darwin)
    /// Every IPv4 and IPv6 address of this machine's interfaces right now.
    public static func current() -> [Entry] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var out: [Entry] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var text = String(cString: host)
            if let zone = text.firstIndex(of: "%") { text = String(text[..<zone]) }
            let flags = Int32(item.pointee.ifa_flags)
            out.append(Entry(interface: String(cString: item.pointee.ifa_name), host: text.lowercased(),
                             isUp: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0, isLoopback: flags & IFF_LOOPBACK != 0))
        }
        return out
    }

    /// The name the network's DNS gives `host` (an IP address), or nil: Tailscale's MagicDNS answers with the machine's
    /// `….ts.net` name. Asks the resolver, so call it off the main thread.
    public static func name(for host: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_socktype = SOCK_STREAM
        var found: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &found) == 0, let info = found else { return nil }
        defer { freeaddrinfo(found) }
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NAMEREQD) == 0 else { return nil }
        var text = String(cString: name).lowercased()
        while text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty || text == host ? nil : text
    }
    #endif
}
