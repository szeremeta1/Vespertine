import Foundation
import Testing
import VespertineAudio
@testable import Vespertine

/// CI also runs on Macs that are in use: one may be playing music, another carrying a call. A runner there says so
/// with VESPERTINE_CI_NO_AUDIO=1, and the debug app that hosts these tests then shuts itself off from macOS's audio
/// system before anything else (CIQuiet). This is the check from inside the app that it did, so a change that breaks
/// that turns the job red instead of going unnoticed. Anywhere else the variable is not set and the test is skipped.
@Suite("CI on a Mac in use: the app")
struct CIAudioIsolationAppTests {
    @Test("An app that was promised no audio sees no output device",
          .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_CI_NO_AUDIO"] == "1"))
    func noOutputDeviceIsVisible() {
        #expect(CIQuiet.applied)
        #expect(OutputDevices.list().isEmpty)
    }
}
