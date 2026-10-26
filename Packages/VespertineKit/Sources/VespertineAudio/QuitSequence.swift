//
// Vespertine — the work done when the app quits, kept from holding the app up.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Runs the quit-time steps (stop the volume relay, clear the Discord status, stop the engine and release the DAC, put
/// the DAC's format back) in order on a thread of their own, and waits for them at most `budget` seconds in all.
///
/// Every step is a blocking Core Audio call or a wait for another thread, and they take as long as the device does: with
/// the engine thread still failing to switch AirPods Max to 48 kHz, Cmd-Q spent 4.75 s on the main thread before the Dock
/// offered Force Quit. Past the budget the caller carries on and the app ends: the steps still running die with the
/// process, which lets go of any device it holds, and a format that wasn't put back stays as it was (as with
/// "Leave it as it is").
public enum QuitSequence {
    /// How long Cmd-Q waits for the steps. A normal quit takes under half a second.
    public static let defaultBudget: TimeInterval = 2.5

    /// True when every step finished within the budget.
    @discardableResult
    public static func run(budget: TimeInterval = defaultBudget, steps: [@Sendable () -> Void]) -> Bool {
        guard !steps.isEmpty else { return true }
        let finished = DispatchSemaphore(value: 0)
        // A thread of its own, not GCD: a step stuck in the HAL must not be able to starve the pool.
        let thread = Thread {
            for step in steps { step() }
            finished.signal()
        }
        thread.name = "Vespertine Quit"
        thread.qualityOfService = .userInitiated
        thread.start()
        return finished.wait(timeout: .now() + budget) == .success
    }
}
