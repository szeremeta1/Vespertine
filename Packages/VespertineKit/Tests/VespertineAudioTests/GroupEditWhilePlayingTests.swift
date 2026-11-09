//
// Vespertine: speaker groups edited while they play. The aggregate's channels stay in the order it was made with until the output opens
// again, so what the chain and the router use keeps that order: the leader DAC's speakers stay on the leader DAC. Trims and the rest of an
// edit apply at once. Pure; no device.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group edited while playing")
struct GroupEditWhilePlayingTests {
    private let front = "test-front-dac", back = "test-back-dac"

    /// Front DAC (leader): front pair. Back DAC: back pair. As the session opened it.
    private func playing() -> SpeakerGroup {
        SpeakerGroup(id: UUID(uuidString: "0A1B2C3D-0000-4000-8000-0000000000E1")!, name: "Downstairs quad",
                     members: [SpeakerGroup.Member(deviceUID: front, name: "Front DAC", channelCount: 2),
                               SpeakerGroup.Member(deviceUID: back, name: "Back DAC", channelCount: 2, skewMs: 4)],
                     clockLeaderUID: front,
                     speakers: [SpeakerGroup.Speaker(role: .frontLeft, deviceUID: front, channel: 0, position: Point2D(x: -1, y: 1.5)),
                                SpeakerGroup.Speaker(role: .frontRight, deviceUID: front, channel: 1, position: Point2D(x: 1, y: 1.5)),
                                SpeakerGroup.Speaker(role: .backLeft, deviceUID: back, channel: 0, position: Point2D(x: -1, y: -1.5)),
                                SpeakerGroup.Speaker(role: .backRight, deviceUID: back, channel: 1, position: Point2D(x: 1, y: -1.5))])
    }

    @Test("Members put in another order while the group plays keep the open aggregate's order: the front pair stays on the front DAC")
    func reorderedKeepsTheAggregateOrder() {
        var edited = playing()
        edited.members.reverse()
        edited.clockLeaderUID = back
        edited.speakers[2].trimDB = -3
        let played = playing().asPlayed(chosen: edited)
        #expect(played.members.map(\.deviceUID) == [front, back])
        #expect(played.clockLeaderUID == front, "the aggregate's clock leader until it is made again")
        #expect(played.rolesByAggregateChannel == [.frontLeft, .frontRight, .backLeft, .backRight])
        #expect(GroupDelay.perChannelLevelDB(played) == [0, 0, -3, 0], "the trim applies at once, on the back DAC")
        #expect(GroupDelay.perChannelMs(played) == [4, 4, 0, 0], "the front DAC still waits for the back one")
    }

    @Test("A speaker moved to the other channel of its DAC applies at once: the aggregate has the same channels")
    func rewiredOnTheSameDAC() {
        var edited = playing()
        edited.speakers[2].channel = 1
        edited.speakers[3].channel = 0
        #expect(playing().asPlayed(chosen: edited).rolesByAggregateChannel == [.frontLeft, .frontRight, .backRight, .backLeft])
    }

    @Test("A member taken out of the group or given another channel count while it plays keeps the channels it has in the aggregate")
    func reshapedMemberKeepsItsChannels() {
        var removed = playing()
        removed.members.removeLast()
        removed.speakers.removeLast(2)
        let kept = playing().asPlayed(chosen: removed)
        #expect(kept.members.map(\.deviceUID) == [front, back] && kept.totalChannels == 4)
        #expect(kept.rolesByAggregateChannel == [.frontLeft, .frontRight, .backLeft, .backRight])
        var wider = playing()
        wider.members[1].channelCount = 4
        let shaped = playing().asPlayed(chosen: wider)
        #expect(shaped.totalChannels == 4)
    }

    @Test("A member lost while playing stays out, as before")
    func lostStaysOut() {
        var rest = playing()
        rest.members.removeLast()
        rest.speakers.removeLast(2)
        let played = rest.asPlayed(chosen: playing())
        #expect(played.members.map(\.deviceUID) == [front] && played.speakers.count == 2)
    }
}
