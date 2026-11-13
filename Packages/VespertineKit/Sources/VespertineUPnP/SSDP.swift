//
// Vespertine: SSDP, how network renderers are found: an M-SEARCH sent to the UPnP multicast group, and the replies
// (UPnP Device Architecture 1.1, section 1.3).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Darwin
import Foundation

public enum SSDP {
    public static let multicastHost = "239.255.255.250"
    public static let port: UInt16 = 1900
    /// What a search asks for: UPnP AV renderers, and OpenHome ones (some announce only their Product service).
    public static let rendererTargets = [
        "urn:schemas-upnp-org:device:MediaRenderer:1",
        "urn:av-openhome-org:service:Product:1",
    ]

    public static func searchMessage(target: String, mx: Int) -> Data {
        let lines: [String] = [
            "M-SEARCH * HTTP/1.1",
            "HOST: \(multicastHost):\(port)",
            "MAN: \"ssdp:discover\"",
            "MX: \(mx)",
            "ST: \(target)",
            "USER-AGENT: macOS/1 UPnP/1.1 Vespertine/1",
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }
}

/// A reply to an M-SEARCH: where the device's description is, and who it is.
public struct SSDPResponse: Sendable, Hashable {
    public var location: URL
    public var st: String
    public var usn: String
    /// The device's unique name, `uuid:…` (the USN up to `::`).
    public var udn: String
    public var server: String?
    public var maxAge: Int?

    public static func parse(_ data: Data) -> SSDPResponse? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n").flatMap { $0.components(separatedBy: "\n") }
        guard let status = lines.first, status.uppercased().hasPrefix("HTTP/1."), status.contains(" 200") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let locationText = headers["location"], let location = URL(string: locationText), location.host != nil,
              let usn = headers["usn"], !usn.isEmpty else { return nil }
        let udn = usn.components(separatedBy: "::").first ?? usn
        let maxAge = headers["cache-control"].flatMap { value -> Int? in
            guard let range = value.range(of: "max-age", options: .caseInsensitive) else { return nil }
            let rest = value[range.upperBound...].drop { $0 == " " || $0 == "=" }
            return Int(rest.prefix { $0.isNumber })
        }
        return SSDPResponse(location: location, st: headers["st"] ?? "", usn: usn, udn: udn, server: headers["server"], maxAge: maxAge)
    }
}

/// Sends M-SEARCHes from a UDP socket of its own and collects the unicast replies. The address is the multicast group;
/// tests point it at a responder on 127.0.0.1.
public final class SSDPSearcher: Sendable {
    let host: String
    let port: UInt16

    public init(host: String = SSDP.multicastHost, port: UInt16 = SSDP.port) {
        self.host = host
        self.port = port
    }

    /// Searches for each of `targets`, and returns every distinct reply (by USN) that arrives within `wait` seconds.
    public func search(targets: [String], mx: Int = 2, wait: TimeInterval) async -> [SSDPResponse] {
        let host = host, port = port
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.run(host: host, port: port, targets: targets, mx: mx, wait: wait))
            }
        }
    }

    private static func run(host: String, port: UInt16, targets: [String], mx: Int, wait: TimeInterval) -> [SSDPResponse] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var to = sockaddr_in()
        to.sin_family = sa_family_t(AF_INET)
        to.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &to.sin_addr) == 1 else { return [] }
        // Each search goes out twice: UDP may drop one (the UDA recommends repeating).
        for _ in 0..<2 {
            for target in targets {
                let message = [UInt8](SSDP.searchMessage(target: target, mx: mx))
                _ = withUnsafePointer(to: &to) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, message, message.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
        }
        var seen = Set<String>()
        var replies: [SSDPResponse] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(wait)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(max(1, left * 1000))) > 0 else { continue }
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0, let reply = SSDPResponse.parse(Data(buffer[0..<n])) else { continue }
            if seen.insert(reply.usn).inserted { replies.append(reply) }
        }
        return replies
    }
}
