//
// Vespertine: which networks this Mac is on, for the receiver's rule that control comes only from the Mac's own subnets, and
// which interfaces its announcements go out on.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Darwin
import Foundation
import VespertineAudio

public struct LocalNetwork: Sendable, Hashable {
    /// The interface's name ("en0").
    public var interface: String
    /// This Mac's address on it and the network's mask, in network order: 4 bytes each for IPv4, 16 for IPv6.
    public var address: [UInt8]
    public var mask: [UInt8]
    public var isLoopback: Bool
    public var supportsMulticast: Bool

    public init(interface: String, address: [UInt8], mask: [UInt8], isLoopback: Bool = false, supportsMulticast: Bool = true) {
        self.interface = interface
        self.address = address
        self.mask = mask
        self.isLoopback = isLoopback
        self.supportsMulticast = supportsMulticast
    }

    public var isIPv4: Bool { address.count == 4 }

    public func contains(_ other: [UInt8]) -> Bool {
        guard other.count == address.count, mask.count == address.count else { return false }
        return zip(zip(address, other), mask).allSatisfy { pair, mask in pair.0 & mask == pair.1 & mask }
    }

    /// "192.0.2.10" for an IPv4 network's address.
    public var addressText: String { address.count == 4 ? address.map(String.init).joined(separator: ".") : LocalNetworks.text(ofIPv6: address) }
}

public enum LocalNetworks {
    /// The networks of every interface that is up, loopback included.
    public static func current() -> [LocalNetwork] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var found: [LocalNetwork] = []
        var next = list
        while let entry = next {
            defer { next = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, let address = entry.pointee.ifa_addr, let mask = entry.pointee.ifa_netmask else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let family = Int32(address.pointee.sa_family)
            if family == AF_INET {
                let a = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in withUnsafeBytes(of: p.pointee.sin_addr) { Array($0) } }
                let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in withUnsafeBytes(of: p.pointee.sin_addr) { Array($0) } }
                found.append(LocalNetwork(interface: name, address: a, mask: m, isLoopback: flags & IFF_LOOPBACK != 0, supportsMulticast: flags & IFF_MULTICAST != 0))
            } else if family == AF_INET6 {
                let a = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) } }
                let m = mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) } }
                found.append(LocalNetwork(interface: name, address: a, mask: m, isLoopback: flags & IFF_LOOPBACK != 0, supportsMulticast: flags & IFF_MULTICAST != 0))
            }
        }
        return found
    }

    /// The bytes of an address written as text ("192.0.2.7", "fe80::1", "fe80::1%en0"); nil when it isn't one.
    public static func bytes(of text: String) -> [UInt8]? {
        let plain = text.split(separator: "%").first.map(String.init) ?? text
        var v4 = in_addr()
        if inet_pton(AF_INET, plain, &v4) == 1 { return withUnsafeBytes(of: v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, plain, &v6) == 1 {
            let raw = withUnsafeBytes(of: v6) { Array($0) }
            // An IPv4 address written as IPv6 (::ffff:192.0.2.7) is that IPv4 address.
            if raw[0..<10].allSatisfy({ $0 == 0 }), raw[10] == 0xff, raw[11] == 0xff { return Array(raw[12..<16]) }
            return raw
        }
        return nil
    }

    static func text(ofIPv6 bytes: [UInt8]) -> String {
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes.prefix(16)) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `peer` is on one of `networks`: on the same subnet as one of this Mac's interfaces (or this Mac itself).
    public static func isOnOwnSubnet(_ peer: String?, networks: [LocalNetwork]) -> Bool {
        guard let peer, let bytes = bytes(of: peer) else { return false }
        return networks.contains { $0.contains(bytes) }
    }

    /// `peer` is an address of a private or local network (RFC 1918, carrier-grade NAT as VPNs use it, link-local, unique
    /// local IPv6, or this Mac): never an address on the open internet.
    public static func isPrivate(_ peer: String?) -> Bool {
        guard let peer, let a = bytes(of: peer) else { return false }
        if a.count == 4 {
            return a[0] == 10 || a[0] == 127 || (a[0] == 172 && (16...31).contains(a[1])) || (a[0] == 192 && a[1] == 168)
                || (a[0] == 169 && a[1] == 254) || (a[0] == 100 && (64...127).contains(a[1]))
        }
        if a[0..<15].allSatisfy({ $0 == 0 }), a[15] == 1 { return true }
        return a[0] & 0xfe == 0xfc || (a[0] == 0xfe && a[1] & 0xc0 == 0x80)
    }
}
