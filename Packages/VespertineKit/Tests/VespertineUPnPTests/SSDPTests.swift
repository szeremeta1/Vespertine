//
// Vespertine: SSDP search messages, replies, and a search against a fake responder on 127.0.0.1.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Darwin
import Foundation
import Testing
@testable import VespertineUPnP

@Suite("SSDP")
struct SSDPTests {
    static let upmpdcliReply = """
    HTTP/1.1 200 OK\r
    Cache-Control: max-age=1800\r
    DATE: Thu, 13 Nov 2026 10:00:00 GMT\r
    EXT:\r
    location: http://192.168.1.20:49152/uuid-5f8e/description.xml\r
    SERVER: Linux/6.1 UPnP/1.0 libupnpp/0.21\r
    ST: urn:schemas-upnp-org:device:MediaRenderer:1\r
    USN: uuid:5f8e1c2a-0000-1111-2222-b827eb000001::urn:schemas-upnp-org:device:MediaRenderer:1\r
    \r

    """

    @Test("A renderer's reply is parsed, headers in any case")
    func parsesReply() throws {
        let reply = try #require(SSDPResponse.parse(Data(Self.upmpdcliReply.utf8)))
        #expect(reply.location == URL(string: "http://192.168.1.20:49152/uuid-5f8e/description.xml"))
        #expect(reply.st == "urn:schemas-upnp-org:device:MediaRenderer:1")
        #expect(reply.udn == "uuid:5f8e1c2a-0000-1111-2222-b827eb000001")
        #expect(reply.maxAge == 1800)
        #expect(reply.server?.contains("libupnpp") == true)
    }

    @Test("A NOTIFY, a search or garbage is not a reply")
    func rejectsOthers() {
        #expect(SSDPResponse.parse(Data("NOTIFY * HTTP/1.1\r\nLOCATION: http://a/b\r\nUSN: uuid:x\r\n\r\n".utf8)) == nil)
        #expect(SSDPResponse.parse(Data("HTTP/1.1 200 OK\r\nUSN: uuid:x\r\n\r\n".utf8)) == nil)   // no location
        #expect(SSDPResponse.parse(Data([0xFF, 0x00, 0x13])) == nil)
    }

    @Test("A USN without a type is its own UDN")
    func bareUSN() throws {
        let text = "HTTP/1.1 200 OK\r\nLOCATION: http://10.0.0.2:8080/d.xml\r\nST: upnp:rootdevice\r\nUSN: uuid:abc\r\n\r\n"
        #expect(try #require(SSDPResponse.parse(Data(text.utf8))).udn == "uuid:abc")
    }

    @Test("The search message is what the UPnP Device Architecture asks for")
    func searchMessage() {
        let text = String(decoding: SSDP.searchMessage(target: "urn:schemas-upnp-org:device:MediaRenderer:1", mx: 2), as: UTF8.self)
        #expect(text.hasPrefix("M-SEARCH * HTTP/1.1\r\n"))
        #expect(text.contains("HOST: 239.255.255.250:1900\r\n"))
        #expect(text.contains("MAN: \"ssdp:discover\"\r\n"))
        #expect(text.contains("MX: 2\r\n"))
        #expect(text.contains("ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test("A search collects the replies of a responder, once per USN")
    func searchAgainstFakeResponder() async throws {
        let responder = try FakeSSDPResponder(replies: [
            Self.upmpdcliReply,
            Self.upmpdcliReply,   // a duplicate (renderers answer each search once per target)
            "HTTP/1.1 200 OK\r\nLOCATION: http://127.0.0.1:9/oh.xml\r\nST: urn:av-openhome-org:service:Product:1\r\nUSN: uuid:5f8e1c2a-0000-1111-2222-b827eb000001::urn:av-openhome-org:service:Product:1\r\n\r\n",
        ])
        defer { responder.close() }
        let searcher = SSDPSearcher(host: "127.0.0.1", port: responder.port)
        let replies = await searcher.search(targets: SSDP.rendererTargets, mx: 1, wait: 0.6)
        #expect(responder.searchesReceived >= 1)
        #expect(Set(replies.map(\.usn)).count == replies.count)
        #expect(replies.count == 2)
        #expect(Set(replies.map(\.udn)) == ["uuid:5f8e1c2a-0000-1111-2222-b827eb000001"])
    }
}

/// Answers every M-SEARCH it receives on 127.0.0.1 with the given replies, sent back to the searcher's port.
final class FakeSSDPResponder: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var searches = 0
    private var closed = false

    var searchesReceived: Int { lock.withLock { searches } }

    init(replies: [String]) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = UInt16(bigEndian: addr.sin_port)
        self.fd = fd
        serve(replies: replies)
    }

    private func serve(replies: [String]) {
        let fd = self.fd
        Thread.detachNewThread { [self] in
            var buffer = [UInt8](repeating: 0, count: 2048)
            while true {
                var from = sockaddr_in()
                var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&pfd, 1, 100) <= 0 {
                    if lock.withLock({ closed }) { return }
                    continue
                }
                let n = withUnsafeMutablePointer(to: &from) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLen) }
                }
                guard n > 0 else { return }
                let text = String(decoding: buffer[0..<n], as: UTF8.self)
                guard text.hasPrefix("M-SEARCH") else { continue }
                lock.withLock { searches += 1 }
                for reply in replies {
                    let bytes = Array(reply.utf8)
                    _ = withUnsafePointer(to: &from) { p in
                        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes, bytes.count, 0, $0, fromLen) }
                    }
                }
            }
        }
    }

    func close() {
        lock.withLock { closed = true }
        Thread.sleep(forTimeInterval: 0.15)
        Darwin.close(fd)
    }
}
