//
// Vespertine: how the playback tests wait. They wait for what they are about to check (the queue's end, a request the
// receiver got) for as long as it takes, so a slow or busy Mac changes how long a test runs and never what it finds. A
// thing that never happens is a hang: the suite's time limit ends the test, and the checks after the wait say what is
// missing.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Returns once `condition` holds; early only when the test is being stopped (its time limit ran out).
@MainActor
func untilTrue(_ condition: @MainActor () -> Bool) async {
    while !condition() {
        do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
    }
}
