//
// Vespertine: speaker groups and a room profile measured on the group. The sweeps were timed against the leader, so the profile's own
// delays already hold how much later the follower DAC sounds; the chain adds the measured skew only when the profile can't hold it
// (another rate, another drift setting, a drawn or imported profile). The numbers are the hardware session's: the follower 12.5 ms late.
// Pure; no device.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group measured profile")
struct GroupMeasuredProfileTests {
    private let leader = "test-leader-uid", follower = "test-follower-uid"
    private let skewContext = SpeakerGroup.Member.SkewContext(driftCorrected: true, driftQuality: 127, sampleRate: 48_000)
    private var resampled: Set<String> { [follower] }

    /// Leader: front pair. Follower: back pair, measured 12.5 ms late (electronic) with drift correction on at 48 kHz.
    private func quad(followerQuality: Int = 127) -> SpeakerGroup {
        SpeakerGroup(name: "Downstairs quad",
                     members: [SpeakerGroup.Member(deviceUID: leader, name: "Leader DAC", channelCount: 2),
                               SpeakerGroup.Member(deviceUID: follower, name: "Follower DAC", channelCount: 2, skewMs: 12.5,
                                                   skewContext: skewContext, driftQuality: followerQuality)],
                     clockLeaderUID: leader,
                     speakers: [SpeakerGroup.Speaker(role: .frontLeft, deviceUID: leader, channel: 0, position: Point2D(x: -1, y: 1.5)),
                                SpeakerGroup.Speaker(role: .frontRight, deviceUID: leader, channel: 1, position: Point2D(x: 1, y: 1.5)),
                                SpeakerGroup.Speaker(role: .backLeft, deviceUID: follower, channel: 0, position: Point2D(x: -1, y: -1.5)),
                                SpeakerGroup.Speaker(role: .backRight, deviceUID: follower, channel: 1, position: Point2D(x: 1, y: -1.5))])
    }

    private var clockThen: GroupClockContext {
        GroupClockContext(sampleRate: 48_000, members: [.init(uid: leader, driftCorrected: false, driftQuality: 0),
                                                        .init(uid: follower, driftCorrected: true, driftQuality: 127)])
    }

    /// What the wizard measures on that quad: the sweeps from the follower arrive 12.5 ms later, so the leader's pair waits 12.5 ms.
    private func measuredProfile(group: SpeakerGroup, clock: GroupClockContext?, origin: RoomProfileSource = .measured) throws -> RoomProfile {
        let fit = try #require(RoomLayout.layout(for: group))
        var profile = RoomProfile(id: UUID(), name: "Measured", createdAt: Date(timeIntervalSince1970: 1_800_000_000), sessionID: UUID(),
                                  deviceUID: group.outputUID, layout: fit.layout, channelMap: fit.channelMap, micSerial: "7001",
                                  calibrationSHA256: nil, target: .flat, filters: RoomFilterSet(version: 1, channels: [:]))
        profile.alignment = RoomSpeakerAlignment.align(arrivalMs: [.left: 0, .right: 0, .leftSurround: 12.5, .rightSurround: 12.5], levelDB: [:])
        profile.source = origin
        profile.groupClock = clock
        return profile
    }

    @Test("A profile measured on the group, which still runs as it did, holds the follower's 12.5 ms itself: the leader waits 12.5 ms, not 25")
    func measuredHoldsTheSkew() throws {
        let group = quad()
        let room = RoomCorrectionPlayback(profile: try measuredProfile(group: group, clock: clockThen))
        let chain = try #require(GroupDelay.chain(room, group: group, resampled: resampled, rate: 48_000))
        #expect(chain.channels.map(\.delayMs) == [12.5, 12.5, 0, 0], "\(chain.channels.map(\.delayMs))")
    }

    @Test("A level or polarity trim still plays on a measured profile: only the wait for the latest DAC is left out")
    func trimsStay() throws {
        var group = quad()
        group.speakers[2].trimDB = -3
        group.speakers[3].invertPolarity = true
        group.speakers[0].delayTrimMs = 1
        let chain = try #require(GroupDelay.chain(RoomCorrectionPlayback(profile: try measuredProfile(group: group, clock: clockThen)),
                                                  group: group, resampled: resampled, rate: 48_000))
        #expect(chain.channels.map(\.delayMs) == [13.5, 12.5, 0, 0])
        #expect(chain.channels[2].levelDB == -3 && chain.channels[3].inverted)
    }

    @Test("Measured under other settings, at another rate, or not measured at all: the skew is added to the profile as before")
    func otherwiseAsBefore() throws {
        let group = quad()
        func leaderWait(_ profile: RoomProfile, group: SpeakerGroup = quad(), resampled: Set<String>? = [follower], rate: Double = 48_000) -> Double? {
            GroupDelay.chain(RoomCorrectionPlayback(profile: profile), group: group, resampled: resampled, rate: rate)?.channels[0].delayMs
        }
        #expect(leaderWait(try measuredProfile(group: group, clock: nil)) == 25, "no record of how it was measured")
        var other = clockThen; other.sampleRate = 96_000
        #expect(leaderWait(try measuredProfile(group: group, clock: other)) == 25, "measured at 96 kHz, playing at 48 kHz")
        #expect(leaderWait(try measuredProfile(group: group, clock: clockThen), resampled: []) == 0 + 12.5,
                "the follower isn't resampled now: its skew doesn't hold either, so only the profile's own delay is left")
        #expect(leaderWait(try measuredProfile(group: group, clock: clockThen), resampled: nil) == 25, "not known how the group runs")
        let lowQuality = quad(followerQuality: 64)
        #expect(leaderWait(try measuredProfile(group: lowQuality, clock: clockThen), group: lowQuality) == 12.5,
                "another quality: the profile's context doesn't hold, and neither does the skew's, so nothing is added")
        #expect(leaderWait(try measuredProfile(group: group, clock: clockThen, origin: .geometry)) == 25, "a drawn profile never holds it")
    }

    @Test("A measurement on a group keeps how the group was clocked, and a single output's measurement keeps nothing")
    func recordedWithTheProfile() throws {
        let group = quad()
        let profile = try measuredProfile(group: group, clock: clockThen)
        let decoded = try JSONDecoder().decode(RoomProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded.groupClock == clockThen)
        #expect(RoomCorrectionPlayback(profile: decoded).measuredGroupClock == clockThen)
        var older = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        older.removeValue(forKey: "groupClock")
        #expect(try JSONDecoder().decode(RoomProfile.self, from: JSONSerialization.data(withJSONObject: older)).groupClock == nil)
    }
}
