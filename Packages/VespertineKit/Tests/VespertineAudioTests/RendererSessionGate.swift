//
// Vespertine: tests that run a `SystemRendererSession` (macOS's Atmos renderer, with its own file reader) take turns.
// On a CI runner (macOS 26 VM) two sessions at once, in two suites, each stopped inside `copyNextSampleBuffer` for the nine
// minutes it took the watchdog to print the stacks; one at a time they never did. The wait is `await`ed, so a test that is
// waiting its turn holds no thread of the cooperative pool (a test blocked on one starves every other test that needs it).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

actor RendererSessionGate {
    static let shared = RendererSessionGate()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Runs `body` alone among the tests that use the gate.
    func exclusive<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        if busy { await withCheckedContinuation { waiting.append($0) } } else { busy = true }
        let result = await body()
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }   // handed on, still busy
        return result
    }
}

private final class BoundedSlot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ v: T) { lock.lock(); stored = v; lock.unlock() }
}

/// Runs `body` on a thread of its own and waits for it by `await`ing (no pool thread is held), giving up after `patience`
/// seconds: nil then. A body that never returns (a read stuck in the system's media framework) leaves its thread behind, and
/// the test fails with a message instead of the whole run stalling.
func runBounded<T: Sendable>(patience: TimeInterval, _ body: @escaping @Sendable () -> T) async -> T? {
    let slot = BoundedSlot<T>()
    Thread.detachNewThread { slot.set(body()) }
    let deadline = Date().addingTimeInterval(patience)
    while slot.value == nil, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    return slot.value
}
