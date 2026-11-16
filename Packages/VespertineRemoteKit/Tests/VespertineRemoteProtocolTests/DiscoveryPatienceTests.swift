//
// Vespertine Remote: "Looking for Macs" stops turning after a while and says what to try.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if canImport(Observation)
import Foundation
import Testing
import VespertineRemoteClient

/// A wait the test ends by hand, so nothing here depends on how fast the machine is.
private final class HandClock: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var asked: [Duration] = []
    private var over = 0

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                asked.append(duration)
                waiting.append(continuation)
            }
        }
        lock.withLock { over += 1 }
    }

    /// Every wait asked for so far, in order.
    var waits: [Duration] { lock.withLock { asked } }

    /// How many waits have ended.
    var ended: Int { lock.withLock { over } }

    /// Ends every wait that is running.
    func ring() {
        let all = lock.withLock {
            let all = waiting
            waiting = []
            return all
        }
        for continuation in all { continuation.resume() }
    }
}

@MainActor
struct DiscoveryPatienceTests {
    /// Lets other work run until `condition` holds. Counted in looks, not against a deadline, so a machine that
    /// stalls for a few seconds can't fail it.
    private func settle(until condition: () -> Bool) async -> Bool {
        var looks = 0
        while !condition(), looks < 1000 {
            looks += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// After waits were ended by hand that should change nothing: lets them all come back and be ignored.
    private func idle(_ clock: HandClock) async {
        let running = clock.waits.count
        _ = await settle { clock.ended == running }
        for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func patience(_ clock: HandClock) -> DiscoveryPatience {
        DiscoveryPatience(wait: .seconds(10)) { await clock.sleep($0) }
    }

    @Test func theSpinnerGivesWayToAdviceWhenTheWaitRunsOut() async {
        let clock = HandClock()
        let search = patience(clock)
        #expect(search.stage == .looking)
        search.update(looking: true, found: 0)
        #expect(await settle { clock.waits.count == 1 })
        #expect(clock.waits == [.seconds(10)])
        #expect(search.stage == .looking)
        clock.ring()
        #expect(await settle { search.stage == .nothingFound })
        // More news of an empty search doesn't bring the spinner back or start another wait.
        search.update(looking: true, found: 0)
        await idle(clock)
        #expect(search.stage == .nothingFound)
        #expect(clock.waits.count == 1)
    }

    @Test func aMacFoundInTimeStopsTheWait() async {
        let clock = HandClock()
        let search = patience(clock)
        search.update(looking: true, found: 0)
        #expect(await settle { clock.waits.count == 1 })
        search.update(looking: true, found: 1)
        // The old wait ends late: it must not turn a list with a Mac in it into "nothing found".
        clock.ring()
        await idle(clock)
        #expect(search.stage == .looking)
        // The Mac goes away again: a fresh spinner and a full wait.
        search.update(looking: true, found: 0)
        #expect(await settle { clock.waits.count == 2 })
        #expect(search.stage == .looking)
        clock.ring()
        #expect(await settle { search.stage == .nothingFound })
    }

    @Test func aMacFoundAfterTheAdviceClearsIt() async {
        let clock = HandClock()
        let search = patience(clock)
        search.update(looking: true, found: 0)
        #expect(await settle { clock.waits.count == 1 })
        clock.ring()
        #expect(await settle { search.stage == .nothingFound })
        search.update(looking: true, found: 2)
        #expect(search.stage == .looking)
    }

    @Test func lookingAgainStartsOver() async {
        let clock = HandClock()
        let search = patience(clock)
        search.update(looking: true, found: 0)
        #expect(await settle { clock.waits.count == 1 })
        clock.ring()
        #expect(await settle { search.stage == .nothingFound })
        search.lookAgain()
        #expect(search.stage == .looking)
        #expect(await settle { clock.waits.count == 2 })
        // Asked twice in a row: only the last wait counts.
        search.lookAgain()
        #expect(await settle { clock.waits.count == 3 })
        clock.ring()
        #expect(await settle { search.stage == .nothingFound })
        #expect(clock.waits.count == 3)
    }

    @Test func nothingIsCountedWhileTheAppIsNotLooking() async {
        let clock = HandClock()
        let search = patience(clock)
        // In the background the search is stopped: no wait runs.
        search.update(looking: false, found: 0)
        await idle(clock)
        #expect(clock.waits.isEmpty)
        // A wait that was running when the app left doesn't count against the next search.
        search.update(looking: true, found: 0)
        #expect(await settle { clock.waits.count == 1 })
        search.update(looking: false, found: 0)
        clock.ring()
        await idle(clock)
        #expect(search.stage == .looking)
        // Back in front: the spinner turns for a full wait again, also after the advice was showing.
        search.update(looking: true, found: 0)
        #expect(await settle { clock.waits.count == 2 })
        clock.ring()
        #expect(await settle { search.stage == .nothingFound })
        search.update(looking: false, found: 0)
        #expect(search.stage == .looking)
    }

    @Test func theRowSaysWhatTheListShows() {
        typealias P = DiscoveryPatience
        // A Mac to pair with: the list shows it and nothing else.
        #expect(P.row(stage: .looking, unpaired: 1, discovered: 1, blocked: false) == .none)
        #expect(P.row(stage: .nothingFound, unpaired: 1, discovered: 2, blocked: false) == .none)
        // Nothing yet: the spinner, then the advice.
        #expect(P.row(stage: .looking, unpaired: 0, discovered: 0, blocked: false) == .spinner)
        #expect(P.row(stage: .nothingFound, unpaired: 0, discovered: 0, blocked: false) == .advice)
        // Every Mac found is paired already: the search works, so no advice about fixing it.
        #expect(P.row(stage: .looking, unpaired: 0, discovered: 1, blocked: false) == .spinner)
        #expect(P.row(stage: .nothingFound, unpaired: 0, discovered: 1, blocked: false) == .none)
        // Local Network access is off: the list says that in its own place, with no spinner beside it.
        #expect(P.row(stage: .looking, unpaired: 0, discovered: 0, blocked: true) == .none)
        #expect(P.row(stage: .nothingFound, unpaired: 0, discovered: 0, blocked: true) == .none)
    }

    @Test func theStandardWaitIsTenSeconds() {
        #expect(DiscoveryPatience.standardWait == .seconds(10))
    }
}
#endif
