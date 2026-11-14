//
// Vespertine: the Mac's listener is reachable from wherever the Mac is (a tailnet, a forwarded port), so a host that keeps
// failing the handshake is shut out for a while, and strangers can't hold every connection open at once.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineStreamServer

@Suite struct ConnectionThrottleTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aHostThatKeepsFailingIsShutOutForAWhileThenLetBackIn() {
        var throttle = ConnectionThrottle(allowedFailures: 3, window: 60, lockout: 300, maximumPending: 8)
        for i in 0..<3 {
            #expect(throttle.admits(host: "100.64.0.9", pending: 0, now: start.addingTimeInterval(Double(i))))
            throttle.failed(host: "100.64.0.9", now: start.addingTimeInterval(Double(i)))
        }
        #expect(!throttle.admits(host: "100.64.0.9", pending: 0, now: start.addingTimeInterval(5)))
        #expect(!throttle.admits(host: "100.64.0.9", pending: 0, now: start.addingTimeInterval(299)))
        // Somebody else is not affected.
        #expect(throttle.admits(host: "192.168.1.20", pending: 0, now: start.addingTimeInterval(5)))
        #expect(throttle.admits(host: "100.64.0.9", pending: 0, now: start.addingTimeInterval(303)))
    }

    @Test func failuresSpreadOverALongTimeNeverAddUp() {
        var throttle = ConnectionThrottle(allowedFailures: 3, window: 60, lockout: 300, maximumPending: 8)
        for i in 0..<10 {
            let now = start.addingTimeInterval(Double(i) * 45)
            #expect(throttle.admits(host: "h", pending: 0, now: now))
            throttle.failed(host: "h", now: now)
        }
    }

    @Test func aPhoneThatGetsInIsForgiven() {
        var throttle = ConnectionThrottle(allowedFailures: 3, window: 60, lockout: 300, maximumPending: 8)
        throttle.failed(host: "h", now: start)
        throttle.failed(host: "h", now: start)
        throttle.succeeded(host: "h")
        throttle.failed(host: "h", now: start)
        throttle.failed(host: "h", now: start)
        #expect(throttle.admits(host: "h", pending: 0, now: start))
    }

    @Test func onlySoManyConnectionsMayWaitUnsignedAtOnce() {
        var throttle = ConnectionThrottle(allowedFailures: 3, window: 60, lockout: 300, maximumPending: 8)
        #expect(throttle.admits(host: "h", pending: 7, now: start))
        #expect(!throttle.admits(host: "h", pending: 8, now: start))
    }

    @Test func theListOfHostsDoesNotGrowForEver() {
        var throttle = ConnectionThrottle(allowedFailures: 3, window: 60, lockout: 300, maximumPending: 8)
        for i in 0..<5000 { throttle.failed(host: "host-\(i)", now: start) }
        _ = throttle.admits(host: "x", pending: 0, now: start.addingTimeInterval(1000))
        #expect(throttle.trackedHosts < 100)
    }

    @Test func anAddressIsTheSameHostWhateverItsPortOrScope() {
        #expect(ConnectionThrottle.host(of: "192.168.1.20:51234") == "192.168.1.20")
        #expect(ConnectionThrottle.host(of: "fe80::1%en0.51234") == "fe80::1")
        #expect(ConnectionThrottle.host(of: "[fd7a:115c:a1e0::1]:47821") == "fd7a:115c:a1e0::1")
        #expect(ConnectionThrottle.host(of: "100.101.102.103") == "100.101.102.103")
    }
}
