//
// Vespertine — speaker groups: the Identify button. The tone for a channel is played on that channel of the DAC that has it (not
// through the group, which exists only while music plays), quietly, and not while the group's own output is in use.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group identify")
struct GroupIdentifyTests {
    @Test("A channel of the group is a channel of one DAC: the second DAC's first channel is aggregate channel 2")
    func rightSpeaker() throws {
        let group = GroupFixtures.quad()
        let first = try #require(GroupIdentify.plan(group: group, aggregateChannel: 1))
        #expect(first.deviceUID == GroupFixtures.fosi && first.channelOnDevice == 1)
        let third = try #require(GroupIdentify.plan(group: group, aggregateChannel: 2))
        #expect(third.deviceUID == GroupFixtures.fiio && third.channelOnDevice == 0)
        #expect(third.stimulus.tracks.map(\.channel) == [0], "one track, on that channel of that DAC")
    }

    @Test("A channel the group does not have is not played anywhere")
    func notAChannel() {
        let group = GroupFixtures.quad()
        #expect(GroupIdentify.plan(group: group, aggregateChannel: 4) == nil)
        #expect(GroupIdentify.plan(group: group, aggregateChannel: -1) == nil)
    }

    @Test("The same quiet tone as IdentifyTone: its length, three bursts, a peak at -30 dBFS, never louder")
    func tone() throws {
        let plan = try #require(GroupIdentify.plan(group: GroupFixtures.quad(), aggregateChannel: 0, rate: 96_000))
        let samples = try #require(plan.stimulus.tracks.first?.samples)
        #expect(samples == IdentifyTone.samples(channel: 0, channels: 1, rate: 96_000))
        #expect(samples.count == Int(96_000 * IdentifyTone.seconds))
        let peak = samples.map { abs($0) }.max() ?? 0
        #expect(abs(20 * log10(Double(peak)) - IdentifyTone.levelDB) < 0.1)
    }

    @Test("It is refused while the group's own output is in use (its DACs are held), and not for another output or when nothing plays")
    func refusal() {
        let group = GroupFixtures.quad()
        #expect(GroupIdentify.refusal(for: group, outputInUseUID: group.outputUID)?.contains("Stop") == true)
        #expect(GroupIdentify.refusal(for: group, outputInUseUID: "some-other-dac") == nil)
        #expect(GroupIdentify.refusal(for: group, outputInUseUID: nil) == nil)
    }

    @Test("A DAC that is not connected says so, in words, and nothing plays")
    func notConnected() throws {
        var group = GroupFixtures.quad()
        group.members[0].deviceUID = "no-such-dac-\(UUID())"
        group.speakers[0].deviceUID = group.members[0].deviceUID
        let plan = try #require(GroupIdentify.plan(group: group, aggregateChannel: 0))
        #expect(throws: RoomHardwareError.self) { _ = try GroupIdentifyPlayer(plan: plan, deviceName: "Fosi Audio ZD3") }
    }
}
