//
// Vespertine — speaker groups: the choices for what a stereo song does on more than two speakers, what becomes of the subwoofer
// channel, and what happens when an output goes away. The options and the words for them, and how a choice is put in the group.
// Pure; no view.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group policies")
struct GroupPoliciesTests {
    private func group() -> SpeakerGroup {
        SpeakerGroup(name: "Dorm quad",
                     members: [SpeakerGroup.Member(deviceUID: "a", name: "A", channelCount: 2), SpeakerGroup.Member(deviceUID: "b", name: "B", channelCount: 2)],
                     clockLeaderUID: "a",
                     speakers: [SpeakerGroup.Speaker(role: .frontLeft, deviceUID: "a", channel: 0, position: Point2D(x: -1, y: 2)),
                                SpeakerGroup.Speaker(role: .lfe, deviceUID: "b", channel: 1, position: Point2D(x: 0, y: 1))])
    }

    // MARK: Stereo

    @Test("Four choices for stereo, each with a title and a sentence; the leader-only one says what it keeps")
    func stereoChoices() {
        #expect(GroupPolicies.StereoChoice.allCases.map(\.title) == ["Front pair only", "Mirror on the back pair", "Each pair its own stereo", "Every speaker"])
        #expect(GroupPolicies.StereoChoice.frontOnly.detail.contains("bit-perfect"))
        #expect(GroupPolicies.StereoChoice.allCases.allSatisfy { !$0.detail.isEmpty })
    }

    @Test("The choice a group has now, and putting another in: mirror keeps a level of its own")
    func stereoSelect() {
        var g = group()
        #expect(GroupPolicies.stereoChoice(g) == .frontOnly)
        g = GroupPolicies.setStereo(.mirror, in: g)
        #expect(g.stereoPolicy == .mirror(trimDB: GroupPolicies.defaultMirrorTrimDB) && GroupPolicies.stereoChoice(g) == .mirror)
        g = GroupPolicies.setMirrorTrim(-6, in: g)
        #expect(g.stereoPolicy == .mirror(trimDB: -6) && GroupPolicies.mirrorTrim(g) == -6)
        g = GroupPolicies.setStereo(.eachPairStereo, in: g)
        #expect(GroupPolicies.stereoChoice(g) == .eachPairStereo && GroupPolicies.mirrorTrim(g) == nil)
        g = GroupPolicies.setStereo(.mirror, in: g)
        #expect(GroupPolicies.mirrorTrim(g) == GroupPolicies.defaultMirrorTrimDB, "back to the default, not the old one")
        g = GroupPolicies.setStereo(.allSpeakers, in: g)
        #expect(g.stereoPolicy == .allSpeakers)
    }

    @Test("The mirror level is held between -20 dB and 0: never louder than the front, never nonsense")
    func mirrorRange() {
        var g = GroupPolicies.setStereo(.mirror, in: group())
        #expect(GroupPolicies.setMirrorTrim(6, in: g).stereoPolicy == .mirror(trimDB: 0))
        #expect(GroupPolicies.setMirrorTrim(-90, in: g).stereoPolicy == .mirror(trimDB: -20))
        g = GroupPolicies.setMirrorTrim(.nan, in: g)
        #expect(g.stereoPolicy == .mirror(trimDB: GroupPolicies.defaultMirrorTrimDB))
        #expect(GroupPolicies.setMirrorTrim(-3, in: group()).stereoPolicy == .frontOnly, "only where the mirror is the choice")
    }

    // MARK: Subwoofer

    @Test("Three choices for the LFE channel, the speaker one only if the group has a speaker to put it on")
    func lfeChoices() {
        #expect(GroupPolicies.LFEChoice.allCases.map(\.title) == ["Leave it out", "Add it to every speaker", "Add it to one speaker"])
        #expect(GroupPolicies.lfeChoice(group()) == .drop)
        var g = GroupPolicies.setLFE(.toAll, in: group())
        #expect(g.lfePolicy == .toAll(dB: GroupPolicies.defaultLFEToAllDB) && GroupPolicies.lfeChoice(g) == .toAll)
        g = GroupPolicies.setLFELevel(-9, in: g)
        #expect(g.lfePolicy == .toAll(dB: -9) && GroupPolicies.lfeLevel(g) == -9)
        let speaker = g.speakers[1].id
        g = GroupPolicies.setLFE(.toSpeaker, in: g)
        #expect(g.lfePolicy == .toSpeaker(g.speakers.first { $0.role == .lfe }?.id ?? speaker), "the subwoofer speaker if there is one")
        var none = group()
        none.speakers.removeAll { $0.role == .lfe }
        #expect(GroupPolicies.setLFE(.toSpeaker, in: none).lfePolicy == .toSpeaker(none.speakers[0].id), "else the first speaker")
        #expect(GroupPolicies.setLFE(.toSpeaker, in: SpeakerGroup(name: "x", members: [], clockLeaderUID: "")).lfePolicy == .drop, "no speaker: stays dropped")
        #expect(GroupPolicies.setLFE(.drop, in: g).lfePolicy == .drop)
    }

    @Test("The LFE level is held between -20 and +0 dB")
    func lfeRange() {
        let g = GroupPolicies.setLFE(.toAll, in: group())
        #expect(GroupPolicies.setLFELevel(5, in: g).lfePolicy == .toAll(dB: 0))
        #expect(GroupPolicies.setLFELevel(-80, in: g).lfePolicy == .toAll(dB: -20))
    }

    @Test("Choosing a speaker for the LFE that isn't in the group is ignored")
    func lfeSpeaker() {
        let g = group()
        #expect(GroupPolicies.setLFESpeaker(UUID(), in: g) == g)
        let set = GroupPolicies.setLFESpeaker(g.speakers[0].id, in: g)
        #expect(set.lfePolicy == .toSpeaker(g.speakers[0].id))
    }

    // MARK: Loss

    @Test("When an output goes away: pause, or carry on with the rest; the leader always pauses, and the sentence says so")
    func loss() {
        #expect(GroupPolicies.LossChoice.allCases.map(\.title) == ["Pause", "Carry on with the rest"])
        #expect(GroupPolicies.LossChoice.pause.detail.contains("comes back"))
        #expect(GroupPolicies.LossChoice.continueOnRemaining.detail.contains("clock leader") && GroupPolicies.LossChoice.continueOnRemaining.detail.contains("pauses"))
        var g = group()
        #expect(GroupPolicies.lossChoice(g) == .pause)
        g = GroupPolicies.setLoss(.continueOnRemaining, in: g)
        #expect(g.onMemberLoss == .continueOnRemaining && GroupPolicies.lossChoice(g) == .continueOnRemaining)
    }

    // MARK: What plays today

    @Test("The notes say what works now: the stereo and LFE choices are played by speaker position, carry-on and pause by the engine; level trims and polarity are not applied yet")
    func notes() {
        #expect(!GroupPolicies.stereoNote.contains("first two channels") && !GroupPolicies.stereoNote.contains("saved"))
        #expect(GroupPolicies.stereoNote.contains("where the speakers stand"))
        #expect(!GroupPolicies.lfeNote.contains("not played") && GroupPolicies.lfeNote.contains("LFE"))
        #expect(!GroupPolicies.lossNote.contains("not played"))
        #expect(GroupPolicies.playedToday.contains("delays") && GroupPolicies.playedToday.contains("not applied"))
        #expect(GroupPolicies.playedToday.contains("where the speakers stand"))
    }
}
