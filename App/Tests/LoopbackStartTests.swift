// Vespertine: tests for starting the loopback test while macOS's permission prompt is still unanswered.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import VespertineAudio
@testable import Vespertine

/// Stands in for macOS's "may Vespertine record?" prompt: every ask waits until the test answers.
@MainActor
private final class Prompt {
    private(set) var asked = 0
    private var waiting: [CheckedContinuation<LoopbackPermission.Answer, Never>] = []

    func ask() async -> LoopbackPermission.Answer {
        asked += 1
        return await withCheckedContinuation { waiting.append($0) }
    }

    func answer(_ answer: LoopbackPermission.Answer) {
        let waiting = waiting
        self.waiting = []
        for w in waiting { w.resume(returning: answer) }
    }

    /// Lets the tasks that were started run until the prompt has been put up `count` times.
    func shown(_ count: Int) async -> Bool {
        for _ in 0..<100_000 where asked < count { await Task.yield() }
        return asked == count
    }
}

@Suite("Starting the loopback test", .serialized) @MainActor
struct LoopbackStartTests {
    /// A loopback test with no saved results that asks `prompt` instead of macOS. No device is involved: these tests
    /// stop where the test would begin to play.
    private func fixture(_ body: @MainActor (LoopbackTest, Prompt) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-loopback-start-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let test = LoopbackTest(dataDirectory: root)
        let prompt = Prompt()
        test.permission = { await prompt.ask() }
        try await body(test, prompt)
    }

    @Test("A second Run Test while macOS's prompt is up starts nothing")
    func secondPressIsIgnored() async throws {
        try await fixture { test, prompt in
            let first = Task { await test.mayStart() }
            #expect(await prompt.shown(1))
            #expect(test.starting && test.phase == .setup)

            #expect(await test.mayStart() == false)
            #expect(prompt.asked == 1, "the second press didn't ask again")
            #expect(test.starting, "the first press is still waiting")

            prompt.answer(.granted)
            #expect(await first.value)
            #expect(!test.starting && test.error == nil)
        }
    }

    @Test("Cancel while macOS's prompt is up gives the start up, whatever the answer")
    func cancelStopsThePendingStart() async throws {
        try await fixture { test, prompt in
            let pending = Task { await test.mayStart() }
            #expect(await prompt.shown(1))

            test.reset()   // what closing the sheet does
            #expect(!test.starting)
            prompt.answer(.granted)
            #expect(await pending.value == false)
            #expect(test.phase == .setup && test.error == nil)
        }
    }

    @Test("A refusal that arrives after Cancel isn't shown as the next result")
    func refusalAfterCancelIsDropped() async throws {
        try await fixture { test, prompt in
            let pending = Task { await test.mayStart() }
            #expect(await prompt.shown(1))
            test.reset()
            prompt.answer(.denied)
            #expect(await pending.value == false)
            #expect(test.phase == .setup && test.error == nil)
        }
    }

    @Test("After Cancel the test can be started again, and only the new start goes ahead")
    func startAgainAfterCancel() async throws {
        try await fixture { test, prompt in
            let cancelled = Task { await test.mayStart() }
            #expect(await prompt.shown(1))
            test.reset()

            let again = Task { await test.mayStart() }
            #expect(await prompt.shown(2))
            #expect(test.starting)
            prompt.answer(.unanswered)   // not a refusal: the test goes ahead
            #expect(await cancelled.value == false)
            #expect(await again.value)
            #expect(!test.starting && test.phase == .setup)
        }
    }

    @Test("A refusal ends the start and says why")
    func refusalIsShown() async throws {
        try await fixture { test, prompt in
            let pending = Task { await test.mayStart() }
            #expect(await prompt.shown(1))
            prompt.answer(.denied)
            #expect(await pending.value == false)
            #expect(!test.starting && test.phase == .finished)
            #expect(test.error == LoopbackError.permissionDenied.localizedDescription)
        }
    }
}
