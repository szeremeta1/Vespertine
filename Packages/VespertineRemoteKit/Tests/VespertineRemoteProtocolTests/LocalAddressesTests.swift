//
// Vespertine: tests for which of a Mac's addresses a phone is told, and how a phone knows Tailscale is on.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineRemoteProtocol

@Suite struct LocalAddressesTests {
    private typealias Entry = LocalAddresses.Entry

    @Test func aMacTellsItsHomeAndTailscaleAddressesWithItsPort() {
        let entries = [
            Entry(interface: "lo0", host: "127.0.0.1", isLoopback: true),
            Entry(interface: "lo0", host: "::1", isLoopback: true),
            Entry(interface: "en0", host: "fe80::1c2d:3e4f:5a6b:7c8d"),
            Entry(interface: "en0", host: "192.168.1.24"),
            Entry(interface: "en0", host: "2a01:4f8:1:2::3"),
            Entry(interface: "utun4", host: "100.101.102.103"),
            Entry(interface: "utun4", host: "fd7a:115c:a1e0::1234"),
            Entry(interface: "en5", host: "169.254.10.20"),
            Entry(interface: "en7", host: "10.0.0.9", isUp: false),
        ]
        let told = LocalAddresses.advertised(from: entries, port: 52718, names: ["Studio-Mac.tail1a2b3.ts.net."])
        #expect(told.map(\.text) == ["192.168.1.24:52718", "100.101.102.103:52718", "[fd7a:115c:a1e0::1234]:52718", "studio-mac.tail1a2b3.ts.net:52718"])
        #expect(told.map(\.kind) == [.localNetwork, .tailscale, .tailscale, .tailscale])
    }

    @Test func theListIsShortAndHasNoDoubles() {
        let many = (1...20).map { Entry(interface: "en\($0)", host: "10.0.0.\($0)") } + [Entry(interface: "en0", host: "10.0.0.1")]
        let told = LocalAddresses.advertised(from: many, port: 1)
        #expect(told.count == LocalAddresses.maximumAdvertised)
        #expect(Set(told).count == told.count)
    }

    @Test func anotherVPNsAddressIsToldToo() {
        // WireGuard and the like hand out private addresses on a tunnel interface: a phone on the same VPN reaches them.
        let told = LocalAddresses.advertised(from: [Entry(interface: "utun6", host: "10.8.0.2")], port: 7)
        #expect(told == [RemoteAddress(host: "10.8.0.2", port: 7)])
    }

    @Test func tailscaleIsOnWhenAnInterfaceHasItsAddress() {
        #expect(LocalAddresses.hasTailscale([Entry(interface: "utun3", host: "100.90.1.2")]))
        #expect(LocalAddresses.hasTailscale([Entry(interface: "utun3", host: "fd7a:115c:a1e0:ab12::1")]))
        #expect(!LocalAddresses.hasTailscale([Entry(interface: "utun3", host: "100.90.1.2", isUp: false)]))
        #expect(!LocalAddresses.hasTailscale([Entry(interface: "en0", host: "192.168.1.5"), Entry(interface: "pdp_ip0", host: "10.20.30.40")]))
    }

    #if canImport(Darwin)
    @Test func thisMachineListsItsLoopback() {
        #expect(LocalAddresses.current().contains { $0.isLoopback && $0.host == "127.0.0.1" })
    }
    #endif

    @Test func aWelcomeWithoutAddressesStillReads() throws {
        // An older Mac's welcome has no addresses; a newer one's are read back as they were sent.
        let old = #"{"name":"Mac","serverID":"S","appVersion":"1.1.4","protocolVersion":2}"#
        #expect(try RemoteProtocol.decoder().decode(ServerInfo.self, from: Data(old.utf8)).addresses == nil)
        let info = ServerInfo(name: "Mac", serverID: "S", appVersion: "1.2", addresses: [RemoteAddress(host: "100.64.0.1", port: 9)])
        let data = try RemoteProtocol.encoder().encode(info)
        #expect(try RemoteProtocol.decoder().decode(ServerInfo.self, from: data) == info)
    }

    @Test func pingAndTheLanguageKeepTheirShape() throws {
        func json(_ command: RemoteCommand) throws -> String {
            String(decoding: try RemoteProtocol.encoder().encode(ClientMessage(id: 1, command: command)), as: UTF8.self)
        }
        #expect(try json(.ping) == #"{"command":{"ping":{}},"id":1}"#)
        #expect(try json(.setLanguage(code: "pt-BR")) == #"{"command":{"setLanguage":{"code":"pt-BR"}},"id":1}"#)
    }
}
