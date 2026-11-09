//
// Vespertine: speaker groups: what a stereo song or a lost output does to a group's routing. The listener's choices (stereo
// on more than two speakers, the LFE, a DAC that goes away) and their consequences for what each output carries.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group content policies")
struct GroupContentPolicyTests {
    private let stereo: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right]
    private let surround51: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
                                                    kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]
    private let quadFile: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]

    private func quad(_ policy: StereoPolicy) -> SpeakerGroup {
        var group = GroupFixtures.quad()
        group.stereoPolicy = policy
        return group
    }

    private func taps(_ router: PositionRouter, _ output: Int) -> [Int: Float] {
        Dictionary(uniqueKeysWithValues: router.matrixRow(output).map { ($0.source, $0.gain) })
    }

    private func expect(_ actual: [Int: Float], _ wanted: [Int: Float], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(Set(actual.keys) == Set(wanted.keys), sourceLocation: sourceLocation)
        for (source, gain) in wanted { #expect(abs((actual[source] ?? -9) - gain) < 1e-6, sourceLocation: sourceLocation) }
    }

    /// A group of one DAC per row: the roles given, each on its own channel of one eight-channel output.
    private func wide(_ roles: [(SpeakerRole, Double)], policy: StereoPolicy) -> SpeakerGroup {
        let members = [SpeakerGroup.Member(deviceUID: "a", name: "A", channelCount: roles.count), SpeakerGroup.Member(deviceUID: "b", name: "B", channelCount: 2)]
        let speakers = roles.enumerated().map { i, entry in
            SpeakerGroup.Speaker(role: entry.0, deviceUID: "a", channel: i,
                                 position: Point2D(x: 2 * sin(entry.1 * .pi / 180), y: 2 * cos(entry.1 * .pi / 180)))
        }
        return SpeakerGroup(name: "Wide", members: members, clockLeaderUID: "a", speakers: speakers, stereoPolicy: policy)
    }

    // MARK: Stereo

    @Test("Front only: left and right play on the front pair, and the back pair stays quiet")
    func frontOnly() throws {
        let router = try #require(PositionRouter(source: stereo, group: quad(.frontOnly)))
        expect(taps(router, 0), [0: 1]); expect(taps(router, 1), [1: 1])
        #expect(router.matrixRow(2).isEmpty && router.matrixRow(3).isEmpty)
    }

    @Test("Mirror: the back pair repeats the front at the chosen level, left on the left and right on the right; the front stays the file's")
    func mirror() throws {
        let router = try #require(PositionRouter(source: stereo, group: quad(.mirror(trimDB: -3))))
        let g = Float(pow(10, -3.0 / 20))
        expect(taps(router, 0), [0: 1]); expect(taps(router, 1), [1: 1])
        expect(taps(router, 2), [0: g]); expect(taps(router, 3), [1: g])
        #expect(router.untouchedOutputs == [0, 1])
    }

    @Test("Mirror never boosts: a level above 0 dB is read as 0 dB")
    func mirrorNeverBoosts() throws {
        let router = try #require(PositionRouter(source: stereo, group: quad(.mirror(trimDB: 6))))
        expect(taps(router, 2), [0: 1])
        let nan = try #require(PositionRouter(source: stereo, group: quad(.mirror(trimDB: .nan))))
        #expect(nan.matrixRow(2).isEmpty)
    }

    @Test("Each pair its own stereo: every left-right pair plays the song at full level; a speaker with no partner, and the centre, stay quiet")
    func eachPair() throws {
        let group = wide([(.frontLeft, -30), (.frontRight, 30), (.center, 0), (.sideLeft, -90), (.backLeft, -135), (.backRight, 135)], policy: .eachPairStereo)
        let router = try #require(PositionRouter(source: stereo, group: group))
        expect(taps(router, 2), [:])                                  // centre
        expect(taps(router, 3), [:])                                  // side left has no side right
        expect(taps(router, 4), [0: 1]); expect(taps(router, 5), [1: 1])
    }

    @Test("All speakers: also the unpaired side speakers, and the centre plays the mono sum, half of each")
    func allSpeakers() throws {
        let group = wide([(.frontLeft, -30), (.frontRight, 30), (.center, 0), (.sideLeft, -90), (.backLeft, -135), (.backRight, 135)], policy: .allSpeakers)
        let router = try #require(PositionRouter(source: stereo, group: group))
        expect(taps(router, 2), [0: 0.5, 1: 0.5])
        expect(taps(router, 3), [0: 1])
        expect(taps(router, 4), [0: 1]); expect(taps(router, 5), [1: 1])
    }

    @Test("Ceiling speakers and the subwoofer never get a stereo song's channels, whatever the policy")
    func heightsAndSubStayQuiet() throws {
        for policy in [StereoPolicy.mirror(trimDB: 0), .eachPairStereo, .allSpeakers] {
            let group = wide([(.frontLeft, -30), (.frontRight, 30), (.topFrontLeft, -45), (.topFrontRight, 45), (.lfe, 0)], policy: policy)
            let router = try #require(PositionRouter(source: stereo, group: group))
            for output in 2...4 { #expect(router.matrixRow(output).isEmpty) }
        }
    }

    @Test("The policy is for stereo: a 5.1 song, a quad file or a mono one are routed as they were")
    func onlyStereo() throws {
        let plain = try #require(PositionRouter(source: surround51, group: quad(.frontOnly)))
        let withPolicy = try #require(PositionRouter(source: surround51, group: quad(.allSpeakers)))
        #expect(plain == withPolicy)
        let quadPlain = try #require(PositionRouter(source: quadFile, group: quad(.frontOnly)))
        #expect(quadPlain == PositionRouter(source: quadFile, group: quad(.mirror(trimDB: -6))))
        let mono = try #require(PositionRouter(source: [kAudioChannelLabel_Mono], group: quad(.frontOnly)))
        #expect(mono == PositionRouter(source: [kAudioChannelLabel_Mono], group: quad(.eachPairStereo)))
    }

    // MARK: What each output carries

    @Test("The content plan names, per member, the channels that carry music and the ones that carry it untouched")
    func contentPlan() throws {
        let plan = try #require(GroupContentPlan(source: quadFile, group: GroupFixtures.quad()))
        #expect(plan.usedChannels(ofMember: GroupFixtures.fosi) == [0, 1] && plan.untouchedChannels(ofMember: GroupFixtures.fosi) == [0, 1])
        #expect(plan.usedChannels(ofMember: GroupFixtures.fiio) == [0, 1])
        #expect(plan.membersCarryingMusic == [GroupFixtures.fosi, GroupFixtures.fiio])
        #expect(plan.carriesOnlyUntouchedChannels(ofMember: GroupFixtures.fosi))
    }

    @Test("A stereo song with front only leaves the second DAC with nothing to play; mirrored, it has something, at a changed level")
    func contentPlanStereo() throws {
        let frontOnly = try #require(GroupContentPlan(source: stereo, group: quad(.frontOnly)))
        #expect(frontOnly.membersCarryingMusic == [GroupFixtures.fosi])
        let mirrored = try #require(GroupContentPlan(source: stereo, group: quad(.mirror(trimDB: -3))))
        #expect(mirrored.membersCarryingMusic == [GroupFixtures.fosi, GroupFixtures.fiio])
        #expect(mirrored.carriesOnlyUntouchedChannels(ofMember: GroupFixtures.fosi))
        #expect(!mirrored.carriesOnlyUntouchedChannels(ofMember: GroupFixtures.fiio))
    }

    @Test("A fold mixes into the leader's channels too: its channels are no longer the file's")
    func foldReachesLeader() throws {
        let plan = try #require(GroupContentPlan(source: surround51, group: GroupFixtures.quad()))
        #expect(!plan.carriesOnlyUntouchedChannels(ofMember: GroupFixtures.fosi))
        #expect(plan.carriesOnlyUntouchedChannels(ofMember: GroupFixtures.fiio))
    }

    // MARK: A lost output

    private func trio() -> SpeakerGroup {
        let members = ["a", "b", "c"].map { SpeakerGroup.Member(deviceUID: $0, name: $0.uppercased(), channelCount: 2) }
        let speakers: [SpeakerGroup.Speaker] = [
            .init(role: .frontLeft, deviceUID: "a", channel: 0, position: Point2D(x: -1, y: 1.5)),
            .init(role: .frontRight, deviceUID: "a", channel: 1, position: Point2D(x: 1, y: 1.5)),
            .init(role: .sideLeft, deviceUID: "b", channel: 0, position: Point2D(x: -2, y: 0)),
            .init(role: .sideRight, deviceUID: "b", channel: 1, position: Point2D(x: 2, y: 0)),
            .init(role: .backLeft, deviceUID: "c", channel: 0, position: Point2D(x: -1, y: -1.5)),
            .init(role: .backRight, deviceUID: "c", channel: 1, position: Point2D(x: 1, y: -1.5)),
        ]
        return SpeakerGroup(name: "Trio", members: members, clockLeaderUID: "a", speakers: speakers, onMemberLoss: .continueOnRemaining)
    }

    @Test("Nothing lost, or something that was never in the group: nothing changes")
    func unaffected() {
        #expect(trio().outcome(losing: []) == .unaffected)
        #expect(trio().outcome(losing: ["z"]) == .unaffected)
    }

    @Test("Pause is the default: any lost output pauses, for that reason")
    func pausePolicy() {
        var group = trio()
        group.onMemberLoss = .pause
        #expect(group.outcome(losing: ["b"]) == .pause(.byPolicy(lost: ["b"])))
    }

    @Test("Continue: the group goes on with the outputs left, their channels counted again from the first, the speakers of the lost one gone")
    func continuing() throws {
        let original = trio()
        guard case .continueOn(let reduced) = original.outcome(losing: ["b"]) else { Issue.record("should continue"); return }
        #expect(reduced.members.map(\.deviceUID) == ["a", "c"] && reduced.clockLeaderUID == "a")
        #expect(Set(reduced.speakers.map(\.role)) == [.frontLeft, .frontRight, .backLeft, .backRight])
        #expect(reduced.aggregateChannels[.backLeft] == 2)
        #expect(reduced.id == original.id)
        #expect(reduced.name == "Trio")
    }

    @Test("Continuing folds the music onto what is left: a 5.1 song on a group that lost its back DAC becomes the ITU stereo fold")
    func continuingFolds() throws {
        var group = GroupFixtures.quad()
        group.onMemberLoss = .continueOnRemaining
        guard case .continueOn(let reduced) = group.outcome(losing: [GroupFixtures.fiio]) else { Issue.record("should continue"); return }
        let router = try #require(PositionRouter(source: surround51, group: reduced))
        #expect(router.outputChannels == 2)
        let r = Float(0.5.squareRoot())
        expect(taps(router, 0), [0: 1, 2: r, 4: r])
        expect(taps(router, 1), [1: 1, 2: r, 5: r])
    }

    @Test("The leader is never replaced silently: losing it pauses, with the outputs left as the ones to choose a new leader from")
    func leaderLost() {
        #expect(trio().outcome(losing: ["a"]) == .pause(.leaderLost(candidates: ["b", "c"])))
        var group = trio()
        group.onMemberLoss = .pause
        #expect(group.outcome(losing: ["a", "c"]) == .pause(.leaderLost(candidates: ["b"])))
    }

    @Test("Everything lost, or nothing left to play on, pauses")
    func nothingLeft() {
        #expect(trio().outcome(losing: ["a", "b", "c"]) == .pause(.nothingLeft))
        var group = GroupFixtures.quad()
        group.onMemberLoss = .continueOnRemaining
        group.speakers.removeAll { $0.deviceUID == GroupFixtures.fosi }          // only the FiiO has speakers
        #expect(group.outcome(losing: [GroupFixtures.fiio]) == .pause(.nothingLeft))
    }
}
