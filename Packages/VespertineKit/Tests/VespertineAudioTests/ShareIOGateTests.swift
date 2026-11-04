//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

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

@Suite("Scans pause while the song needs the link")
struct ShareIOGatePauseTests {
    private func settle(_ until: () -> Bool) async {
        for _ in 0..<400 where !until() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("Paused: nothing new starts, a request on the wire finishes, and waiting ones go after the grace period")
    func pausedThenResumed() async {
        let gate = ShareIOGate(healthyGrace: 0.2), entered = Counter()
        await gate.enter()   // already in flight when the song asks
        gate.setPlaybackDemand(true, from: "song")
        #expect(gate.isPaused)
        for _ in 0..<3 { Task { await gate.enter(); entered.increment() } }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(entered.value == 0)
        gate.leave()
        gate.setPlaybackDemand(false, from: "song")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(entered.value == 0)   // inside the grace period
        await settle { entered.value == 3 }
        #expect(entered.value == 3)
        #expect(!gate.isPaused)
    }

    @Test("Demand again inside the grace period keeps scans held; repeated polls don't postpone the resume")
    func graceIsOneWindow() async {
        let gate = ShareIOGate(healthyGrace: 0.2)
        gate.setPlaybackDemand(true, from: "song")
        gate.setPlaybackDemand(false, from: "song")
        try? await Task.sleep(for: .milliseconds(100))
        gate.setPlaybackDemand(true, from: "song")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(gate.isPaused)
        gate.setPlaybackDemand(false, from: "song")
        // A player polling "no demand" every 66 ms must not keep the hold from expiring.
        let polled = Task { for _ in 0..<12 { gate.setPlaybackDemand(false, from: "player"); try? await Task.sleep(for: .milliseconds(66)) } }
        let entered = Counter()
        Task { await gate.enter(); entered.increment() }
        await settle { entered.value == 1 }
        #expect(entered.value == 1)
        await polled.value
    }

    @Test("Two songs (current and one being skipped to) both have to let go")
    func severalOwners() {
        let gate = ShareIOGate(healthyGrace: 0)
        gate.setPlaybackDemand(true, from: "a")
        gate.setPlaybackDemand(true, from: "b")
        gate.setPlaybackDemand(false, from: "a")
        #expect(gate.isPaused)
        gate.setPlaybackDemand(false, from: "b")
        #expect(!gate.isPaused)
    }

    @Test("Player: a requested song holds scans; a live stream does while its buffer is under a third, until two thirds")
    func playerPolicy() {
        let gate = ShareIOGate(healthyGrace: 0)
        gate.playerState(pending: true, streaming: true, buffering: false, bufferFill: 1)
        #expect(gate.isPaused)
        #expect(gate.maxInFlight == ShareIOGate.whileStreaming)
        gate.playerState(pending: false, streaming: true, buffering: false, bufferFill: 0.9)
        #expect(!gate.isPaused)   // healthy
        #expect(gate.maxInFlight == ShareIOGate.whileStreaming)
        gate.playerState(pending: false, streaming: true, buffering: false, bufferFill: 0.2)
        #expect(gate.isPaused)
        gate.playerState(pending: false, streaming: true, buffering: false, bufferFill: 0.5)
        #expect(gate.isPaused)    // refilling: not healthy yet
        gate.playerState(pending: false, streaming: true, buffering: true, bufferFill: 0.9)
        #expect(gate.isPaused)    // output held for the network
        gate.playerState(pending: false, streaming: true, buffering: false, bufferFill: 0.7)
        #expect(!gate.isPaused)
        gate.playerState(pending: false, streaming: false, buffering: false, bufferFill: 1)
        #expect(gate.maxInFlight == nil)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
