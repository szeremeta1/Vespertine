//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

/// CI also runs on Macs that are in use: one may be playing music, another carrying a call. A runner there starts
/// every test process with no way to reach macOS's audio system, and says so with VESPERTINE_CI_NO_AUDIO=1. This is
/// the check from inside the test process that the promise holds, so a runner that has lost that protection turns
/// its job red instead of going unnoticed. Anywhere else the variable is not set and the test is skipped.
@Suite("CI on a Mac in use")
struct CIAudioIsolationTests {
    @Test("A test process that was promised no audio sees no output device",
          .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_CI_NO_AUDIO"] == "1"))
    func noOutputDeviceIsVisible() {
        #expect(OutputDevices.list().isEmpty)
        #expect(DeviceQuery.outputUIDs().isEmpty)
    }
}
