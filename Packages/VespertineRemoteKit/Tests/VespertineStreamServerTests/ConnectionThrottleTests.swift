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
            let admitted1 = throttle.admits(host: "100.64.0.9", pending: 0, now: start.addingTimeInterval(Double(i)))
            #expect(admitted1)
            throttle.failed(host: "100.64.0.9", now: start.addingTimeInterval(Double(i)))
        }
        let admitted2 = throttle.admits(host: "100.64.0.9", pending: 0, now: start.addingTimeInterval(5))
        #expect(!admitted2)
        let admitted3 = throttle.admits(host: "100.64.0.9", pending: 0, now: start.addingTimeInterval(299))
        #expect(!admitted3)
        // Somebody else is not affected.
        let admitted4 = throttle.admits(host: "192.168.1.20", pending: 0, now: start.addingTimeInterval(5))
        #expect(admitted4)
        let admitted5 = throttle.admits(host: "100.64.0.9", pending: 0, now: start.addingTimeInterval(303))
        #expect(admitted5)
    }

    @Test func hangingUpOnTheSlowerRoutesAfterSigningInIsNotCountedAsGuessing() {
        // A phone tries every way to the Mac at once; the ones it didn't use end without a handshake.
        var throttle = ConnectionThrottle(allowedFailures: 3, window: 60, lockout: 300, maximumPending: 8)
        throttle.succeeded(host: "100.64.0.9", now: start)
        for i in 0..<6 { throttle.failed(host: "100.64.0.9", now: start.addingTimeInterval(Double(i))) }
        let admitted = throttle.admits(host: "100.64.0.9", pending: 0, now: start.addingTimeInterval(7))
        #expect(admitted)
        // Long after the sign-in, failures count again.
        for i in 0..<3 { throttle.failed(host: "100.64.0.9", now: start.addingTimeInterval(30 + Double(i))) }
        let shutOut = throttle.admits(host: "100.64.0.9", pending: 0, now: start.addingTimeInterval(34))
        #expect(!shutOut)
    }

    @Test func failuresSpreadOverALongTimeNeverAddUp() {
        var throttle = ConnectionThrottle(allowedFailures: 3, window: 60, lockout: 300, maximumPending: 8)
        for i in 0..<10 {
            let now = start.addingTimeInterval(Double(i) * 45)
            let admitted6 = throttle.admits(host: "h", pending: 0, now: now)
            #expect(admitted6)
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
        let admitted7 = throttle.admits(host: "h", pending: 0, now: start)
        #expect(admitted7)
    }

    @Test func onlySoManyConnectionsMayWaitUnsignedAtOnce() {
        var throttle = ConnectionThrottle(allowedFailures: 3, window: 60, lockout: 300, maximumPending: 8)
        let admitted8 = throttle.admits(host: "h", pending: 7, now: start)
        #expect(admitted8)
        let admitted9 = throttle.admits(host: "h", pending: 8, now: start)
        #expect(!admitted9)
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
