//
// Vespertine Remote: a Mac's typed address: what parses, how it prints, and which network it belongs to.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineRemoteProtocol

@Suite struct Address {
    @Test func parsesNamesAndPorts() {
        #expect(RemoteAddress(parsing: "mac-mini.tail1234.ts.net") == RemoteAddress(host: "mac-mini.tail1234.ts.net"))
        #expect(RemoteAddress(parsing: "  Mac-Mini.Tail1234.ts.net:51234 ") == RemoteAddress(host: "mac-mini.tail1234.ts.net", port: 51234))
        #expect(RemoteAddress(parsing: "100.101.102.103:7000") == RemoteAddress(host: "100.101.102.103", port: 7000))
        #expect(RemoteAddress(parsing: "studio.local.") == RemoteAddress(host: "studio.local"))
        #expect(RemoteAddress(parsing: "vespertine://studio:9000/anything") == RemoteAddress(host: "studio", port: 9000))
    }

    @Test func parsesIPv6() {
        #expect(RemoteAddress(parsing: "fd7a:115c:a1e0::1") == RemoteAddress(host: "fd7a:115c:a1e0::1"))
        #expect(RemoteAddress(parsing: "[fd7a:115c:a1e0::1]:443") == RemoteAddress(host: "fd7a:115c:a1e0::1", port: 443))
        #expect(RemoteAddress(parsing: "[fe80::1%en0]") == RemoteAddress(host: "fe80::1%en0"))
    }

    @Test func refusesWhatIsNotAnAddress() {
        for text in ["", "   ", "my mac", "host:0", "host:70000", "host:port", "[::1", "[::1]9", "[nocolon]:1", "héllo.local", ":8080"] {
            #expect(RemoteAddress(parsing: text) == nil, "\(text)")
        }
    }

    @Test func printsBackWhatItRead() {
        for text in ["studio.local", "studio.local:9000", "[fd7a:115c:a1e0::1]:443", "100.64.0.1:1"] {
            #expect(RemoteAddress(parsing: text)?.text == text)
        }
        #expect(RemoteAddress(host: "fd7a::1").text == "fd7a::1")
    }

    @Test func knowsTailscaleFromTheLocalNetwork() {
        #expect(RemoteAddress(host: "mac.tail1234.ts.net").kind == .tailscale)
        #expect(RemoteAddress(host: "100.64.0.1").kind == .tailscale)
        #expect(RemoteAddress(host: "100.127.255.254").kind == .tailscale)
        #expect(RemoteAddress(host: "fd7a:115c:a1e0::53").kind == .tailscale)
        #expect(RemoteAddress(host: "100.128.0.1").kind == .other)
        #expect(RemoteAddress(host: "100.63.0.1").kind == .other)
        #expect(RemoteAddress(host: "192.168.1.20").kind == .localNetwork)
        #expect(RemoteAddress(host: "10.0.0.5").kind == .localNetwork)
        #expect(RemoteAddress(host: "172.20.1.1").kind == .localNetwork)
        #expect(RemoteAddress(host: "172.32.1.1").kind == .other)
        #expect(RemoteAddress(host: "studio.local").kind == .localNetwork)
        #expect(RemoteAddress(host: "fe80::1%en0").kind == .localNetwork)
        #expect(RemoteAddress(host: "example.com").kind == .other)
        #expect(RemoteAddress(host: "mac-mini").kind == .other)
    }

    @Test func borrowsAPortOnlyWhenItHasNone() {
        let known = RemoteAddress(host: "192.168.1.20", port: 51000)
        #expect(RemoteAddress(host: "mac.ts.net").withPort(from: known) == RemoteAddress(host: "mac.ts.net", port: 51000))
        #expect(RemoteAddress(host: "mac.ts.net", port: 9).withPort(from: known).port == 9)
        #expect(RemoteAddress(host: "mac.ts.net").withPort(from: nil).port == nil)
    }
}
