import Foundation
import Testing
import VespertineAudio
@testable import Vespertine

/// The Room Correction window for a speaker group's output: what it says about the profile made from the drawing, and when it
/// offers it.
@Suite("Speaker group alignment card")
struct SpeakerGroupAlignmentCardTests {
    @Test("The offer is there until the group plays with the drawing, and never when there is no drawing to make")
    func offers() {
        #expect(SpeakerGroupAlignmentCard.buttonTitle(.notMade) == "Use the Drawing")
        #expect(SpeakerGroupAlignmentCard.buttonTitle(.available) == "Use the Drawing Instead")
        #expect(SpeakerGroupAlignmentCard.buttonTitle(.inUse) == nil)
        #expect(SpeakerGroupAlignmentCard.buttonTitle(.unavailable) == nil)
    }

    @Test("Every state says something, and only the made ones say the profile follows the drawing")
    func words() {
        let states: [GroupDrawingState] = [.unavailable, .notMade, .available, .inUse]
        #expect(states.allSatisfy { !SpeakerGroupAlignmentCard.explanation($0).isEmpty })
        #expect(SpeakerGroupAlignmentCard.explanation(.available).contains("follows the drawing"))
        #expect(SpeakerGroupAlignmentCard.explanation(.inUse).contains("follows the drawing"))
        #expect(!SpeakerGroupAlignmentCard.explanation(.notMade).contains("follows the drawing"))
    }
}
