import Foundation
import Testing
@testable import VespertineAudio

@Suite("Output status while an output opens")
struct OutputStatusTests {
    @Test("Opening a new output drops the wait, the stand-in and the old output's path")
    func openingDropsWhatWasPublishedForTheOldOutput() {
        var snapshot = EngineSnapshot()
        snapshot.waitingForDevice = "Alex’s AirPods Max"
        snapshot.standingInFor = "Alex’s AirPods Max"
        snapshot.isBuffering = true
        snapshot.bufferFill = 0.5
        snapshot.beginOpeningOutput(keepingSession: false)
        #expect(snapshot.waitingForDevice == nil && snapshot.standingInFor == nil)
        #expect(snapshot.outputDevice == nil && snapshot.signalPath == nil && snapshot.bufferFill == 0)
        #expect(snapshot.isBuffering, "buffering is the engine's to say; opening doesn't clear it")
    }
}
