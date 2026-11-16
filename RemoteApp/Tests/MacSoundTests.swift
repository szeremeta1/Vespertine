//
// Vespertine Remote: the Mac's sound settings on the Output screen: a choice the Mac no longer lists reads as Off, and
// the balance is worded as on the Mac.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import Testing
import VespertineRemoteProtocol
@testable import VespertineRemote

@MainActor @Suite struct MacSound {
    private let presets = [SoundChoice(id: "P1", name: "Warm"), SoundChoice(id: "P2", name: "Late Night")]

    @Test func aChoiceTheListNoLongerHasReadsAsOff() {
        #expect(MacSoundSection.listed("P2", in: presets) == "P2")
        #expect(MacSoundSection.listed(nil, in: presets) == nil)
        // A preset deleted on the Mac between two messages: the picker shows Off instead of an empty row.
        #expect(MacSoundSection.listed("gone", in: presets) == nil)
        #expect(MacSoundSection.listed("P1", in: []) == nil)
    }

    @Test func theBalanceIsWordedInWholePointsWithItsSide() {
        let center = MacSoundSection.caption(0), left = MacSoundSection.caption(-0.2), right = MacSoundSection.caption(0.354)
        #expect(left.contains("20") && right.contains("35"))
        #expect(!center.contains("0") && Set([center, left, right]).count == 3)
        // A hair off the middle still rounds to the center's own word.
        #expect(MacSoundSection.caption(0.004) == center)
    }
}
