//
// Vespertine: what discovery is willing to fetch. A reply's description must be on the host that sent the reply, a
// description's services on the host of the description, and a description can't be bigger than 1 MiB.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineUPnP

@Suite("Discovery trust", .serialized)
struct DiscoveryTrustTests {
    @Test("A search records which host answered")
    func responderRecorded() async throws {
        let responder = try FakeSSDPResponder(replies: [SSDPTests.upmpdcliReply])
        defer { responder.close() }
        let replies = await SSDPSearcher(host: "127.0.0.1", port: responder.port).search(targets: [SSDP.rendererTargets[0]], mx: 1, wait: 0.5)
        #expect(replies.first?.responder == "127.0.0.1")
    }

    @Test("A reply pointing at another host's description isn't followed")
    func otherHostIgnored() async throws {
        let fake = try await FakeRenderer(kind: .openHome)
        defer { fake.stop() }
        var reply = SSDPResponse(location: fake.location, st: SSDP.rendererTargets[0], usn: "uuid:x::y", udn: "uuid:x")
        reply.responder = "192.0.2.7"   // someone else on the network naming 127.0.0.1
        let discovery = RendererDiscovery(searcher: CountingSearcher(replies: [reply]))
        discovery.start()
        defer { discovery.stop() }
        try await Task.sleep(for: .milliseconds(300))
        await discovery.searchOnce()
        #expect(discovery.renderers.isEmpty)
        #expect(!fake.calls.contains { $0.action == "GetProtocolInfo" })
        reply.responder = "127.0.0.1"
        let trusted = RendererDiscovery(searcher: CountingSearcher(replies: [reply]))
        trusted.start()
        defer { trusted.stop() }
        try await Task.sleep(for: .milliseconds(300))
        await trusted.searchOnce()
        #expect(trusted.renderers.count == 1)
    }

    @Test("Services on another host are left out; a description over 1 MiB isn't read")
    func servicesAndSize() async throws {
        let big = Data(repeating: 0x20, count: 2 << 20)
        let description = """
        <?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device>
        <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><friendlyName>Odd</friendlyName><UDN>uuid:odd</UDN><serviceList>
        <service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><serviceId>a</serviceId><SCPDURL>/scpd.xml</SCPDURL><controlURL>http://192.0.2.9/ctl</controlURL></service>
        <service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><serviceId>c</serviceId><SCPDURL>/scpd.xml</SCPDURL><controlURL>/cm</controlURL></service>
        </serviceList></device></root>
        """
        let server = HTTPServer { request in
            switch request.path {
            case "/big.xml": HTTPResponse(status: 200, headers: [("Content-Length", "\(big.count)")], body: .data(big))
            case "/odd.xml": HTTPResponse(status: 200, headers: [("Content-Length", "\(description.utf8.count)")], body: .data(Data(description.utf8)))
            default: .status(404)
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        await #expect(throws: (any Error).self) { try await RendererDevice.load(location: URL(string: "http://127.0.0.1:\(port)/big.xml")!) }
        // Its AVTransport is on another host: it goes, and without it this isn't a renderer.
        await #expect(throws: (any Error).self) { try await RendererDevice.load(location: URL(string: "http://127.0.0.1:\(port)/odd.xml")!) }
        let parsed = try DeviceDescription.parse(Data(description.utf8), location: URL(string: "http://127.0.0.1:\(port)/odd.xml")!)
        #expect(parsed.confined().service(.avTransport) == nil)
        #expect(parsed.confined().service(.connectionManager) != nil)
    }
}
