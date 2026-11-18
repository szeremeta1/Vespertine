//
// Vespertine Remote: the position slider on Now Playing. Letting go of it seeks, whether or not the slider says the
// finger lifted; the knob stays where it was put until the player says it is there; and the clock never pulls it back
// while it is held.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
@testable import VespertineRemote

@MainActor
@Suite struct ScrubberTests {
    private func made() -> (Scrubber, () -> [Double]) {
        let scrubber = Scrubber()
        // Long enough that no timer fires inside a test: the tests call what the timers call.
        scrubber.quiet = .seconds(600)
        scrubber.settle = .seconds(600)
        var sent: [Double] = []
        scrubber.commit = { sent.append($0) }
        return (scrubber, { sent })
    }

    // TestFlight AGWqTwVAvOJJl42tjue-P-M: "scrubbing to a point mid-song appears to be utterly nonfunctional".
    @Test func lettingGoMidSongSeeksThereOnce() {
        let (scrubber, sent) = made()
        scrubber.drag(to: 40)
        scrubber.drag(to: 120)
        scrubber.drag(to: 167)
        #expect(sent().isEmpty, "nothing is sought while the finger still moves")
        scrubber.end()
        #expect(sent() == [167])
        scrubber.end()
        #expect(sent() == [167])
    }

    @Test func aSliderThatNeverSaysTheFingerLiftedStillSeeks() {
        // A tap on the track, a VoiceOver swipe on the slider, or a slider that doesn't report the end of a drag: the
        // value is set and nothing more is heard.
        let (scrubber, sent) = made()
        scrubber.drag(to: 167)
        scrubber.stillness()
        #expect(sent() == [167])
        // Told late that the finger lifted: not sought a second time.
        scrubber.end()
        #expect(sent() == [167])
    }

    @Test func aFingerThatRestsAndMovesOnSeeksAgainWhereItEnds() {
        let (scrubber, sent) = made()
        scrubber.drag(to: 60)
        scrubber.stillness()
        scrubber.drag(to: 200)
        scrubber.end()
        #expect(sent() == [60, 200])
    }

    @Test func theClockDoesNotMoveTheKnobWhileItIsHeld() {
        let (scrubber, _) = made()
        #expect(scrubber.shown(position: 12) == 12)
        scrubber.drag(to: 167)
        for position in [12.5, 13, 13.5] {
            scrubber.reported(position: position)
            #expect(scrubber.shown(position: position) == 167)
        }
    }

    @Test func theKnobStaysAtTheTargetUntilThePlayerIsThere() {
        let (scrubber, _) = made()
        scrubber.drag(to: 167)
        scrubber.end()
        // The player's old place, still on its way in.
        scrubber.reported(position: 14)
        #expect(scrubber.shown(position: 14) == 167)
        scrubber.reported(position: 167.4)
        #expect(scrubber.held == nil)
        #expect(scrubber.shown(position: 168) == 168)
    }

    @Test func aPlayerThatNeverGetsThereGetsTheKnobBackAfterAMoment() {
        let (scrubber, _) = made()
        scrubber.drag(to: 167)
        scrubber.end()
        scrubber.expire()
        #expect(scrubber.held == nil)
        #expect(scrubber.shown(position: 14) == 14)
    }

    @Test func theTimersDoWhatTheTestsCallByHand() async throws {
        let scrubber = Scrubber()
        scrubber.quiet = .milliseconds(1)
        scrubber.settle = .milliseconds(1)
        var sent: [Double] = []
        scrubber.commit = { sent.append($0) }
        scrubber.drag(to: 90)
        for _ in 0..<400 where sent.isEmpty || scrubber.held != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(sent == [90])
        #expect(scrubber.held == nil)
    }

    @Test func aNewDragTakesOverFromOneThatEnded() {
        let (scrubber, sent) = made()
        scrubber.drag(to: 50)
        scrubber.end()
        scrubber.drag(to: 80)
        scrubber.reported(position: 50)
        #expect(scrubber.held == 80, "the first seek arriving doesn't let go of the second drag")
        scrubber.end()
        #expect(sent() == [50, 80])
    }

    @Test func targetsStayInsideTheSong() {
        let (scrubber, sent) = made()
        scrubber.drag(to: -4)
        scrubber.end()
        scrubber.drag(to: .nan)
        scrubber.end()
        #expect(sent() == [0, 0])
    }
}
