//
// Vespertine: the Mac noticing that Bonjour never announced it.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineStreamServer

@Suite struct AdvertisingWatchTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aListenerBonjourNeverAnnouncedIsSilentAfterAWhile() {
        var watch = AdvertisingWatch(patience: 8)
        // Not up yet: nothing to say.
        #expect(!watch.isSilent(at: start))
        watch.listening(at: start)
        #expect(!watch.isSilent(at: start.addingTimeInterval(3)))
        #expect(watch.isSilent(at: start.addingTimeInterval(8)))
    }

    @Test func anAnnouncedListenerIsNotSilent() {
        var watch = AdvertisingWatch(patience: 8)
        watch.listening(at: start)
        watch.announced(added: true)
        #expect(!watch.isSilent(at: start.addingTimeInterval(60)))
        // Wi-Fi and Ethernet both took it; one going away leaves the other.
        watch.announced(added: true)
        watch.announced(added: false)
        #expect(!watch.isSilent(at: start.addingTimeInterval(60)))
        watch.announced(added: false)
        #expect(watch.isSilent(at: start.addingTimeInterval(60)))
    }

    @Test func stoppingStartsTheWaitAgain() {
        var watch = AdvertisingWatch(patience: 8)
        watch.listening(at: start)
        watch.announced(added: true)
        watch.stopped()
        #expect(!watch.isSilent(at: start.addingTimeInterval(60)))
        watch.listening(at: start.addingTimeInterval(60))
        #expect(!watch.isSilent(at: start.addingTimeInterval(62)))
        #expect(watch.isSilent(at: start.addingTimeInterval(70)))
        // Being up twice over doesn't move the start.
        watch.listening(at: start.addingTimeInterval(69))
        #expect(watch.isSilent(at: start.addingTimeInterval(70)))
    }
}
