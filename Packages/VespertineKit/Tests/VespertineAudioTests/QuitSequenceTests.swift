//
// Vespertine — quitting never waits on a stuck device.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

/// Cmd-Q ran the quit-time work (volume relay, Discord, the engine, handing the DAC back) on the main thread, each
/// step waiting as long as Core Audio took. With the engine thread still failing to switch AirPods Max to 48 kHz,
/// that was 4.75 s of beach ball before the Dock offered Force Quit (and it was used).
@Suite("Quitting")
struct QuitSequenceTests {
    /// Records which steps ran, in order, from whichever thread they run on.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func add(_ name: String) { lock.withLock { names.append(name) } }
        var all: [String] { lock.withLock { names } }
    }

    @Test("steps run in order, and the caller gets true when they all finish in time")
    func finishesInOrder() {
        let log = Log()
        let finished = QuitSequence.run(budget: 5, steps: [{ log.add("relay") }, { log.add("engine") }, { log.add("restore") }])
        #expect(finished)
        #expect(log.all == ["relay", "engine", "restore"])
    }

    @Test("a step stuck on a device doesn't hold the caller past the budget")
    func stuckStepIsAbandoned() {
        let log = Log()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }   // lets the abandoned thread finish when the test is over
        let started = Date()
        let finished = QuitSequence.run(budget: 0.3, steps: [
            { log.add("relay") },
            { _ = release.wait(timeout: .now() + 30) },   // the HAL never answers
            { log.add("restore") },
        ])
        let took = Date().timeIntervalSince(started)
        #expect(!finished)
        #expect(took < 1.5, "returned after \(took) s")
        #expect(log.all == ["relay"])   // the step after the stuck one never starts: the process ends first
    }

    @Test("the budget covers the whole sequence, not each step")
    func budgetIsForTheWholeSequence() {
        let started = Date()
        let finished = QuitSequence.run(budget: 0.4, steps: (0..<10).map { _ in { Thread.sleep(forTimeInterval: 0.2) } })
        let took = Date().timeIntervalSince(started)
        #expect(!finished)
        #expect(took < 1.5, "returned after \(took) s")
    }

    @Test("an empty sequence returns at once")
    func emptySequence() {
        let started = Date()
        #expect(QuitSequence.run(budget: 5, steps: []))
        #expect(Date().timeIntervalSince(started) < 1)
    }
}
