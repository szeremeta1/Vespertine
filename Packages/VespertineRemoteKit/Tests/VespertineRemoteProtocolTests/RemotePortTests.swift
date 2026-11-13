//
// Vespertine: the Mac's fixed remote port: which ports it tries, in which order, and how a phone uses what the Mac
// says about its port (Bonjour TXT) and what it knows without it.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineRemoteProtocol

@Suite struct RemotePortChoice {
    @Test func theDefaultIsOutsideTheEphemeralRangeAndNextToTheWebRemote() {
        // 49152...65535 is where the system hands out ports on its own, so the Mac's fixed one stays below it, and
        // beside the web remote's (47820) so the two are easy to remember together.
        #expect(RemotePort.preferred == 47_821)
        #expect(RemotePort.preferred < 49_152)
        #expect(RemotePort.preferred != RemotePort.webRemote)
        #expect(RemotePort.webRemote == 47_820)
    }

    @Test func triesTheSavedPortFirstThenTheDefaultThenTheNextOnes() {
        let plain = RemotePort.candidates(saved: nil)
        #expect(plain.first == RemotePort.preferred)
        #expect(plain.count == RemotePort.fallbackCount)
        #expect(plain == (0..<RemotePort.fallbackCount).map { RemotePort.preferred + UInt16($0) })

        // A port saved from an earlier run (the default was busy then) comes first; the default stays a candidate.
        let saved = RemotePort.candidates(saved: RemotePort.preferred + 3)
        #expect(saved.first == RemotePort.preferred + 3)
        #expect(saved.contains(RemotePort.preferred))
        #expect(Set(saved).count == saved.count)
        #expect(saved.count == RemotePort.fallbackCount)
    }

    @Test func neverOffersThePortsItMustNotUse() {
        // The web remote's port, port 0 ("any") and a saved port from some other build are not offered.
        #expect(!RemotePort.candidates(saved: RemotePort.webRemote).contains(RemotePort.webRemote))
        #expect(RemotePort.candidates(saved: RemotePort.webRemote).first == RemotePort.preferred)
        #expect(RemotePort.candidates(saved: 0).first == RemotePort.preferred)
        #expect(RemotePort.candidates(saved: 80).first == RemotePort.preferred)
        #expect(RemotePort.candidates(saved: 60_000).first == RemotePort.preferred)
    }

    @Test func aDifferentBaseMovesTheWholeRange() {
        let range = RemotePort.candidates(saved: nil, preferred: 41_000, count: 5)
        #expect(range == [41_000, 41_001, 41_002, 41_003, 41_004])
    }

    @Test func theMacSaysItsPortInTheTXTRecord() {
        #expect(RemoteProtocol.TXTKey.port == "port")
        #expect(RemotePort.advertised(txt: ["port": "47822"]) == 47_822)
        #expect(RemotePort.advertised(txt: [:]) == nil)
        #expect(RemotePort.advertised(txt: ["port": "0"]) == nil)
        #expect(RemotePort.advertised(txt: ["port": "70000"]) == nil)
        #expect(RemotePort.advertised(txt: ["port": "abc"]) == nil)
    }
}
