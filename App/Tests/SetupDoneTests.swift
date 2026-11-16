import Testing
@testable import Vespertine

/// The Done step ends on Start Listening. With no music added that opens an empty library, so the step offers the way
/// back to adding music beside it, and only then.
@Suite("Setup: the Done step")
struct SetupDoneTests {
    @Test("With nothing in the library and nothing being added, Add Music is offered")
    func emptyLibraryOffersAddMusic() {
        #expect(SetupDoneOffer.addMusic(tracks: 0, scanning: false))
    }

    @Test("While music is on its way in, or once there is some, only Start Listening is shown")
    func musicOnItsWayOrThere() {
        #expect(!SetupDoneOffer.addMusic(tracks: 0, scanning: true), "a scan that has found nothing yet is still adding")
        #expect(!SetupDoneOffer.addMusic(tracks: 1, scanning: false))
        #expect(!SetupDoneOffer.addMusic(tracks: 4_200, scanning: true))
    }

    @Test("Add Music goes back to the Music step, which is before Done, so the page slides back")
    func musicStepIsBeforeDone() {
        #expect(SetupStep.music < SetupStep.done)
        #expect(SetupStep.named.first == .music)
    }
}
