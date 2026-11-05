import Testing
@testable import Vespertine

/// Flipping Room Correction from Guided to Advanced looks like nothing happened when every Advanced section is below
/// the fold, so the window scrolls to the first one and says where the controls are.
@Suite("Room correction mode switch")
struct RoomModeRevealTests {
    @Test("Guided to Advanced with a profile scrolls to the first Advanced section and shows a hint")
    func advancedScrolls() throws {
        let reaction = try #require(RoomModeReveal.reaction(from: false, to: true, hasProfile: true))
        #expect(reaction.scrollTo == RoomModeReveal.advancedAnchor)
        #expect(!reaction.hint.isEmpty)
    }

    @Test("Back to Guided, no change, or no profile to show controls for: nothing scrolls and no hint")
    func otherwiseNothing() {
        #expect(RoomModeReveal.reaction(from: true, to: false, hasProfile: true) == nil)
        #expect(RoomModeReveal.reaction(from: true, to: true, hasProfile: true) == nil)
        #expect(RoomModeReveal.reaction(from: false, to: false, hasProfile: true) == nil)
        #expect(RoomModeReveal.reaction(from: false, to: true, hasProfile: false) == nil)
    }
}
