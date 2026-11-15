//
// Vespertine: the request gate, judged by the events it reports and a clock the test moves. Nothing here waits for time to pass.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio
@testable import VespertineStreaming

@Suite("Request gate")
struct RequestGateTests {
    /// A gate with a clock the test moves and its events kept.
    private func gate(slots: Int = 1) -> (RequestGate, Locked<Date>, Locked<[RequestGate.Event]>) {
        let now = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let events = Locked([RequestGate.Event]())
        let gate = RequestGate(maxInFlight: slots, clock: { now.withLock { $0 } }, onEvent: { event in events.withLock { $0.append(event) } })
        return (gate, now, events)
    }

    /// Holds a slot until `release` is called.
    private func hold(_ gate: RequestGate, _ priority: RequestPriority, events: Locked<[RequestGate.Event]>) async -> (task: Task<Void, Error>, release: @Sendable () -> Void) {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let already = events.withLock { $0.filter { $0 == .started(priority) }.count }
        let task = Task { try await gate.run(priority) { for await _ in stream { break } } }
        _ = await Patience.until { events.withLock { $0.filter { $0 == .started(priority) }.count } > already }
        return (task, { continuation.yield() })
    }

    @Test("Playback goes ahead of browsing, and browsing ahead of sync, whatever order they arrived in")
    func priorities() async throws {
        let (gate, _, events) = gate(slots: 1)
        let (blocker, release) = await hold(gate, .sync, events: events)
        let order = Locked([String]())
        var waiting: [Task<Void, Error>] = []
        for (index, (priority, name)) in [(RequestPriority.sync, "sync"), (.browsing, "browsing"), (.sync, "sync 2"), (.playback, "playback")].enumerated() {
            waiting.append(Task { try await gate.run(priority) { order.withLock { $0.append(name) } } })
            #expect(await Patience.until { await gate.queuedCount == index + 1 })
        }
        #expect(order.withLock { $0 }.isEmpty, "one slot, and it is taken")
        release()
        try await blocker.value
        for task in waiting { try await task.value }
        #expect(order.withLock { $0 } == ["playback", "browsing", "sync", "sync 2"])
        #expect(await gate.queuedCount == 0)
        let started = events.withLock { $0.compactMap { event -> RequestPriority? in if case .started(let p) = event { p } else { nil } } }
        #expect(started == [.sync, .playback, .browsing, .sync, .sync])
        #expect(events.withLock { $0.filter { if case .queued = $0 { true } else { false } }.count } == 4)
    }

    @Test("No more requests are in flight than there are slots")
    func slots() async throws {
        let (gate, _, events) = gate(slots: 2)
        let (first, releaseFirst) = await hold(gate, .browsing, events: events)
        let (second, releaseSecond) = await hold(gate, .browsing, events: events)
        let ran = Locked(false)
        let third = Task { try await gate.run(.playback) { ran.withLock { $0 = true } } }
        #expect(await Patience.until { await gate.queuedCount == 1 })
        #expect(!ran.withLock { $0 })
        releaseFirst()
        try await first.value
        try await third.value
        #expect(ran.withLock { $0 })
        releaseSecond()
        try await second.value
    }

    @Test("When the server asks to wait, nothing is sent until it said, and then requests flow again")
    func backoff() async throws {
        let (gate, now, events) = gate()
        #expect(gate.waitingUntil == nil)
        gate.askedToWait(retryAfter: 30)
        #expect(gate.waitingUntil == now.withLock { $0 }.addingTimeInterval(30))
        let sent = Locked(0)
        await #expect(throws: StreamingError.askedToWait(seconds: 30)) { try await gate.run(.playback) { sent.withLock { $0 += 1 } } }
        now.withLock { $0 += 29 }
        await #expect(throws: StreamingError.askedToWait(seconds: 1)) { try await gate.run(.browsing) { sent.withLock { $0 += 1 } } }
        #expect(sent.withLock { $0 } == 0)
        now.withLock { $0 += 1 }
        #expect(gate.waitingUntil == nil)
        try await gate.run(.sync) { sent.withLock { $0 += 1 } }
        #expect(sent.withLock { $0 } == 1)
        #expect(events.withLock { $0 } == [.waitBegan(seconds: 30), .refused, .refused, .started(.sync), .finished(.sync)])
    }

    @Test("A wait is extended, never shortened, and is a minute when the server doesn't say how long")
    func waitsOnlyGrow() {
        let (gate, now, events) = gate()
        let start = now.withLock { $0 }
        gate.askedToWait(retryAfter: nil)
        #expect(gate.waitingUntil == start.addingTimeInterval(60))
        gate.askedToWait(retryAfter: 10)
        #expect(gate.waitingUntil == start.addingTimeInterval(60))
        gate.askedToWait(retryAfter: 0)
        gate.askedToWait(retryAfter: -5)
        #expect(gate.waitingUntil == start.addingTimeInterval(60))
        gate.askedToWait(retryAfter: 120)
        #expect(gate.waitingUntil == start.addingTimeInterval(120))
        #expect(events.withLock { $0 } == [.waitBegan(seconds: 60), .waitBegan(seconds: 120)])
    }

    @Test("A request that stood in line when the wait began is refused when its turn comes")
    func queuedWhenWaitBegins() async throws {
        let (gate, _, events) = gate()
        let (blocker, release) = await hold(gate, .sync, events: events)
        let sent = Locked(false)
        let queued = Task { try await gate.run(.playback) { sent.withLock { $0 = true } } }
        #expect(await Patience.until { await gate.queuedCount == 1 })
        gate.askedToWait(retryAfter: 45)
        release()
        try await blocker.value
        await #expect(throws: StreamingError.askedToWait(seconds: 45)) { try await queued.value }
        #expect(!sent.withLock { $0 })
        // Its slot was given back.
        #expect(await gate.queuedCount == 0)
    }

    @Test("A cancelled request leaves the line")
    func cancelledLeavesTheLine() async throws {
        let (gate, _, events) = gate()
        let (blocker, release) = await hold(gate, .sync, events: events)
        let queued = Task { try await gate.run(.browsing) {} }
        #expect(await Patience.until { await gate.queuedCount == 1 })
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(await gate.queuedCount == 0)
        release()
        try await blocker.value
        try await gate.run(.playback) {}
    }

    @Test("Retry-After is read when it gives seconds")
    func retryAfter() throws {
        func response(_ value: String?) throws -> HTTPURLResponse {
            try #require(HTTPURLResponse(url: URL(string: "https://music.example/rest/ping")!, statusCode: 429, httpVersion: nil,
                                         headerFields: value.map { ["Retry-After": $0] }))
        }
        #expect(RequestGate.retryAfter(try response("120")) == 120)
        #expect(RequestGate.retryAfter(try response(" 7 ")) == 7)
        #expect(RequestGate.retryAfter(try response("0")) == nil)
        #expect(RequestGate.retryAfter(try response("Wed, 21 Oct 2026 07:28:00 GMT")) == nil)
        #expect(RequestGate.retryAfter(try response(nil)) == nil)
    }

    @Test("The sentence a wait is told in gives its length in plain units")
    func waitWording() {
        #expect(StreamingError.wait(45) == "45 seconds")
        #expect(StreamingError.wait(60) == "1 minute")
        #expect(StreamingError.wait(3600) == "1 hour")
    }
}
