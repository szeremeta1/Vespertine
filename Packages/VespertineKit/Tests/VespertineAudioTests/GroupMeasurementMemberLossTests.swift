//
// Vespertine: a DAC of a speaker group unplugged while the group is being measured. The aggregate the sweeps play on stays alive
// without it, so the capture checks the members themselves and stops with "went away" instead of recording silence. Pure; no device.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group measurement member loss")
struct GroupMeasurementMemberLossTests {
    private let leader = "test-leader-uid", follower = "test-follower-uid"

    @Test("Every member still in the aggregate and connected: the output is there")
    func allThere() {
        #expect(GroupAggregateDevice.membersPresent(atStart: [leader, follower], now: [leader, follower], connected: { _ in true }))
        #expect(GroupAggregateDevice.membersPresent(atStart: [], now: [], connected: { _ in false }), "not an aggregate: nothing to check")
    }

    @Test("A member gone from the aggregate's active list, or no longer connected, means the output went away")
    func memberGone() {
        #expect(!GroupAggregateDevice.membersPresent(atStart: [leader, follower], now: [leader], connected: { _ in true }))
        #expect(!GroupAggregateDevice.membersPresent(atStart: [leader, follower], now: [leader, follower], connected: { $0 != follower }))
    }
}
