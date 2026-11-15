//
// Vespertine: how control apps find the receiver: it answers SSDP searches (M-SEARCH) and announces itself on the UPnP multicast
// group (UPnP Device Architecture 1.1, section 1), and says goodbye (ssdp:byebye) when it stops. Nothing is bound or sent until
// `start()`, which the app calls only while the receiver's switch is on.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Darwin
import Foundation

public final class ReceiverAdvertiser: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var udn: String
        /// The port the description is served on.
        public var httpPort: UInt16
        public var server: String
        public var maxAge = 1800
        /// Where to listen: the multicast group on port 1900 (nil), or one address and port for tests (port 0: any free one).
        public var listenOn: (host: String, port: UInt16)?
        /// Where announcements go: the multicast group (nil), or one address and port for tests.
        public var announceTo: (host: String, port: UInt16)?
        /// Whether a search from this address is answered (the receiver's own-subnets rule).
        public var answers: @Sendable (String) -> Bool = { _ in true }
        /// How long to wait before answering a search that allows `mx` seconds (the UDA asks for a random wait, so that a
        /// network full of devices doesn't answer all at once).
        public var responseDelay: @Sendable (Int) -> TimeInterval = { mx in Double.random(in: 0..<Double(min(max(mx, 1), 2))) * 0.5 }
        /// The networks announcements go out on (and whose addresses are named in them).
        public var networks: @Sendable () -> [LocalNetwork] = { LocalNetworks.current() }

        public init(udn: String, httpPort: UInt16, server: String) {
            self.udn = udn
            self.httpPort = httpPort
            self.server = server
        }
    }

    private let configuration: Configuration
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var running = false
    private var stopped = DispatchSemaphore(value: 0)
    private var boundPort: UInt16 = 0
    private var joined: Set<String> = []
    /// Searches answered and announcements sent since it started (for tests and the Settings line).
    private var _answered = 0

    public init(_ configuration: Configuration) { self.configuration = configuration }

    public var isRunning: Bool { lock.withLock { running } }
    public var port: UInt16 { lock.withLock { boundPort } }
    public var answered: Int { lock.withLock { _answered } }

    public enum StartError: Error { case socket(Int32), bind(Int32) }

    /// Binds the socket and starts answering; returns the UDP port it listens on.
    @discardableResult
    public func start() throws -> UInt16 {
        if let port = lock.withLock({ running ? boundPort : nil }) { return port }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw StartError.socket(errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var loop: UInt8 = 1   // a control app on this Mac hears the announcements too
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, socklen_t(MemoryLayout<UInt8>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        if let listenOn = configuration.listenOn {
            address.sin_port = listenOn.port.bigEndian
            inet_pton(AF_INET, listenOn.host, &address.sin_addr)
        } else {
            address.sin_port = SSDP.port.bigEndian
            address.sin_addr.s_addr = INADDR_ANY
        }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { let code = errno; close(fd); throw StartError.bind(code) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        let port = UInt16(bigEndian: actual.sin_port)
        let done = DispatchSemaphore(value: 0)
        lock.withLock { self.fd = fd; running = true; boundPort = port; stopped = done; joined = [] }
        let thread = Thread { [self] in run(fd: fd, done: done) }
        thread.name = "Vespertine receiver announcements"
        thread.qualityOfService = .utility
        thread.start()
        return port
    }

    /// Says goodbye, closes the socket and returns once nothing more will be sent.
    public func stop() {
        let (was, done) = lock.withLock { () -> (Bool, DispatchSemaphore) in
            defer { running = false }
            return (running, stopped)
        }
        guard was else { return }
        done.wait()
    }

    // MARK: The loop

    private struct Reply { var due: Date; var to: sockaddr_in; var type: String; var usn: String; var location: String }

    private func run(fd: Int32, done: DispatchSemaphore) {
        defer {
            close(fd)
            lock.withLock { self.fd = -1; boundPort = 0 }
            done.signal()
        }
        var replies: [Reply] = []
        var nextAnnouncement = Date()
        var buffer = [UInt8](repeating: 0, count: 2048)
        while lock.withLock({ running }) {
            let now = Date()
            if now >= nextAnnouncement {
                joinGroup(fd: fd)
                announce(fd: fd, alive: true)
                // Well inside the lifetime each announcement states, with a spread so that devices don't all speak at once.
                nextAnnouncement = now.addingTimeInterval(Double(configuration.maxAge) / 3 + Double.random(in: 0..<30))
            }
            let due = replies.filter { $0.due <= now }
            replies.removeAll { $0.due <= now }
            for reply in due { send(fd: fd, to: reply.to, text: searchResponse(type: reply.type, usn: reply.usn, location: reply.location)) }
            if !due.isEmpty { lock.withLock { _answered += due.count } }
            let wait = min(0.25, max(0.01, (replies.map(\.due).min() ?? .distantFuture).timeIntervalSinceNow))
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(wait * 1000)) > 0 else { continue }
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLength) }
            }
            guard n > 0, let search = Search.parse(Data(buffer[0..<n])) else { continue }
            let peer = Self.text(of: from)
            guard configuration.answers(peer), replies.count < 64 else { continue }
            guard let host = configuration.listenOn?.host ?? LocalAddress.toward(host: peer) else { continue }
            let location = "http://\(host):\(configuration.httpPort)\(ReceiverDescription.descriptionPath)"
            let at = Date().addingTimeInterval(max(0, configuration.responseDelay(search.mx)))
            for item in ReceiverDescription.advertisements(udn: configuration.udn) where search.target == "ssdp:all" || search.target == item.type {
                // A search for everything is answered with each type's own name; a search for one type, with that type.
                replies.append(Reply(due: at, to: from, type: item.type, usn: item.usn, location: location))
            }
        }
        announce(fd: fd, alive: false)
    }

    struct Search: Equatable {
        var target: String
        var mx: Int

        /// An M-SEARCH with `MAN: "ssdp:discover"`; anything else on the port is nothing to answer.
        static func parse(_ data: Data) -> Search? {
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            let lines = text.components(separatedBy: "\r\n")
            guard let first = lines.first, first.uppercased().hasPrefix("M-SEARCH * HTTP/1.") else { return nil }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard headers["man"]?.replacingOccurrences(of: "\"", with: "").lowercased() == "ssdp:discover",
                  let target = headers["st"], !target.isEmpty, target.utf8.count <= 256 else { return nil }
            return Search(target: target, mx: min(max(Int(headers["mx"] ?? "") ?? 1, 1), 5))
        }
    }

    private static func text(of address: sockaddr_in) -> String {
        var copy = address.sin_addr
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &copy, &text, socklen_t(text.count)) != nil else { return "" }
        return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func send(fd: Int32, to: sockaddr_in, text: String) {
        var to = to
        let bytes = [UInt8](text.utf8)
        _ = withUnsafePointer(to: &to) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }

    private static func address(host: String, port: UInt16) -> sockaddr_in? {
        var to = sockaddr_in()
        to.sin_family = sa_family_t(AF_INET)
        to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        to.sin_port = port.bigEndian
        return inet_pton(AF_INET, host, &to.sin_addr) == 1 ? to : nil
    }

    /// Joins the multicast group on every IPv4 network the Mac is on now (again before each announcement: a network joined
    /// later, such as Wi-Fi coming back, is then covered too).
    private func joinGroup(fd: Int32) {
        guard configuration.listenOn == nil else { return }
        for network in configuration.networks() where network.isIPv4 && network.supportsMulticast && !network.isLoopback {
            let key = network.interface + "/" + network.addressText
            guard !lock.withLock({ joined.contains(key) }) else { continue }
            var request = ip_mreq()
            inet_pton(AF_INET, SSDP.multicastHost, &request.imr_multiaddr)
            inet_pton(AF_INET, network.addressText, &request.imr_interface)
            if setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &request, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 || errno == EADDRINUSE {
                lock.withLock { _ = joined.insert(key) }
            }
        }
    }

    /// Announces every type (ssdp:alive) or takes them back (ssdp:byebye), on each network, twice (UDP may drop one).
    private func announce(fd: Int32, alive: Bool) {
        let items = ReceiverDescription.advertisements(udn: configuration.udn)
        if let test = configuration.announceTo {
            guard let to = Self.address(host: test.host, port: test.port) else { return }
            let location = "http://\(configuration.listenOn?.host ?? test.host):\(configuration.httpPort)\(ReceiverDescription.descriptionPath)"
            for item in items { send(fd: fd, to: to, text: notification(type: item.type, usn: item.usn, location: location, alive: alive)) }
            return
        }
        guard configuration.listenOn == nil, let group = Self.address(host: SSDP.multicastHost, port: SSDP.port) else { return }
        for network in configuration.networks() where network.isIPv4 && network.supportsMulticast && !network.isLoopback {
            var interface = in_addr()
            guard inet_pton(AF_INET, network.addressText, &interface) == 1,
                  setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &interface, socklen_t(MemoryLayout<in_addr>.size)) == 0 else { continue }
            let location = "http://\(network.addressText):\(configuration.httpPort)\(ReceiverDescription.descriptionPath)"
            for _ in 0..<2 {
                for item in items { send(fd: fd, to: group, text: notification(type: item.type, usn: item.usn, location: location, alive: alive)) }
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    func searchResponse(type: String, usn: String, location: String) -> String {
        ["HTTP/1.1 200 OK",
         "CACHE-CONTROL: max-age=\(configuration.maxAge)",
         "DATE: \(Self.dateFormatter.string(from: Date()))",
         "EXT:",
         "LOCATION: \(location)",
         "SERVER: \(configuration.server)",
         "ST: \(type)",
         "USN: \(usn)",
         "BOOTID.UPNP.ORG: 1",
         "CONFIGID.UPNP.ORG: 1"].joined(separator: "\r\n") + "\r\n\r\n"
    }

    func notification(type: String, usn: String, location: String, alive: Bool) -> String {
        var lines = ["NOTIFY * HTTP/1.1", "HOST: \(SSDP.multicastHost):\(SSDP.port)"]
        if alive { lines += ["CACHE-CONTROL: max-age=\(configuration.maxAge)", "LOCATION: \(location)", "SERVER: \(configuration.server)"] }
        lines += ["NT: \(type)", "NTS: \(alive ? "ssdp:alive" : "ssdp:byebye")", "USN: \(usn)", "BOOTID.UPNP.ORG: 1", "CONFIGID.UPNP.ORG: 1"]
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }
}
