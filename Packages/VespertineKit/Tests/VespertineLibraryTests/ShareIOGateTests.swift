//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineLibrary

@Suite("Scans make way for a song streaming from a share")
struct ShareIOGateTests {
    /// Starts `count` scan requests; each keeps its turn until the test calls `leave()`.
    private func start(_ count: Int, on gate: ShareIOGate, entered: Counter) -> [Task<Void, Never>] {
        (0..<count).map { _ in
            Task {
                await gate.enter()
                entered.increment()
            }
        }
    }

    private func settle(_ until: () -> Bool) async {
        for _ in 0..<200 where !until() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("Nothing streaming: every request goes at once")
    func unlimited() async {
        let gate = ShareIOGate(), entered = Counter()
        let tasks = start(12, on: gate, entered: entered)
        for task in tasks { await task.value }
        #expect(entered.value == 12)
        #expect(gate.running == 12)
        for _ in 0..<12 { gate.leave() }
        #expect(gate.running == 0)
    }

    @Test("While a song streams, one request at a time, and the rest go in turn")
    func oneAtATime() async {
        let gate = ShareIOGate(), entered = Counter()
        gate.maxInFlight = ShareIOGate.whileStreaming
        _ = start(3, on: gate, entered: entered)
        await settle { entered.value >= 1 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(entered.value == 1)
        gate.leave()
        await settle { entered.value >= 2 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(entered.value == 2)
        #expect(gate.running == 1)
        gate.leave()
        await settle { entered.value >= 3 }
        #expect(entered.value == 3)
        gate.leave()
        #expect(gate.running == 0)
    }

    @Test("When the song stops streaming, waiting requests all go")
    func lifted() async {
        let gate = ShareIOGate(), entered = Counter()
        gate.maxInFlight = 1
        _ = start(5, on: gate, entered: entered)
        await settle { entered.value >= 1 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(entered.value == 1)
        gate.maxInFlight = nil
        await settle { entered.value >= 5 }
        #expect(entered.value == 5)
        #expect(gate.running == 5)
    }

    @Test("Requests already in flight finish; new ones wait until there's room under the limit")
    func narrowedWhileBusy() async {
        let gate = ShareIOGate(), entered = Counter()
        for task in start(4, on: gate, entered: entered) { await task.value }
        gate.maxInFlight = 1
        _ = start(1, on: gate, entered: entered)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(entered.value == 4)
        for _ in 0..<3 { gate.leave() }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(entered.value == 4)   // still one in flight: the limit
        gate.leave()
        await settle { entered.value >= 5 }
        #expect(entered.value == 5)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
