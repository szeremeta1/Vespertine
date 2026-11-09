//
// Vespertine: running a play/pause rig scenario on a thread of its own. A test task that times presses or waits with `Task.sleep`
// resumes on one of Swift's few cooperative threads; when other tests hold all of them (a whole package run on a small machine),
// it resumes late, after the song it was timing has moved on. A script on a plain thread is never held that way: it records what
// it saw, and the test judges it afterwards. Waits are on conditions with generous patience, never on a window of time.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
@testable import VespertineAudio

extension PlayPauseRig {
    /// Runs `script` on a thread of its own and returns what it returns, without holding a cooperative thread meanwhile.
    func runScript<T: Sendable>(_ script: @escaping @Sendable (PlayPauseRig) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread { continuation.resume(with: Result { try script(self) }) }
            thread.name = "Rig script"
            thread.start()
        }
    }

    /// For a script: waits until `condition` holds of the snapshot (false after `timeout`).
    func scriptWait(timeout: Double, _ condition: (EngineSnapshot) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition(engine.snapshot) { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition(engine.snapshot)
    }

    /// For a script: waits until at least `seconds` more of sound has come out (false after `timeout`).
    func scriptHears(_ seconds: Double, timeout: Double) -> Bool {
        let target = audibleFrames + Int(seconds * Self.rate)
        return scriptWait(timeout: timeout) { _ in self.audibleFrames >= target }
    }

    func scriptSleep(ms: Int) { Thread.sleep(forTimeInterval: Double(ms) / 1000) }
}
