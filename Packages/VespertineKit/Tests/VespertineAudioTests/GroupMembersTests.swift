//
// Vespertine — speaker groups: configuring the members of a group before they play together. What the group can do as one
// device (the rates every member takes), which rate it runs at, and who may be held exclusively. Without touching a device.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group members")
struct GroupMembersTests {
    private func caps(_ rates: [Double], channels: Int = 2) -> DeviceCapabilities {
        DeviceCapabilities(sampleRates: rates,
                           physicalFormats: [PhysicalFormat(minRate: rates.min() ?? 0, maxRate: rates.max() ?? 0, bitDepth: 32, isInteger: true, isMixable: false, channels: channels)],
                           outputChannels: channels, supportsDoP: true, speakerLayoutChannels: channels)
    }

    private let zd3 = [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let k11 = [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000]

    // MARK: The group as one device

    @Test("As one device the group can run at the rates every member takes, and has all the members' channels")
    func combined() {
        let group = GroupCapabilities.combined([caps(zd3), caps(k11, channels: 2)])
        #expect(group.sampleRates == k11)
        #expect(group.outputChannels == 4)
        #expect(!group.supportsDoP, "DSD over PCM can't pass through drift correction")
        #expect(group.speakerLayoutChannels == nil)
    }

    @Test("The aggregate carries Float32 on every stream, so that is the group's format, mixable, at the common rates")
    func combinedFormat() throws {
        let group = GroupCapabilities.combined([caps(zd3), caps(k11)])
        let format = try #require(group.physicalFormats.first)
        #expect(group.physicalFormats.count == 1 && format.bitDepth == 32 && !format.isInteger && format.isMixable && format.channels == 4)
        #expect(format.minRate == 44_100 && format.maxRate == 192_000)
    }

    @Test("Rates are compared as rates, not as bit patterns: 44100.0 and 44100.4 are the same rate")
    func ratesCompared() {
        let group = GroupCapabilities.combined([caps([44_100, 48_000]), caps([44_100.4, 96_000])])
        #expect(group.sampleRates.count == 1 && abs(group.sampleRates[0] - 44_100) < 0.5)
    }

    @Test("Members with no rate in common can't be a group")
    func noCommonRate() {
        let group = GroupCapabilities.combined([caps([44_100]), caps([48_000])])
        #expect(group.sampleRates.isEmpty && group.physicalFormats.isEmpty)
        #expect(GroupMemberPlanner.rate(for: 44_100, members: [caps([44_100]), caps([48_000])], policy: .matchSource) == nil)
        #expect(GroupMemberPlanner.rate(for: 44_100, members: [], policy: .matchSource) == nil)
    }

    // MARK: Which rate

    @Test("A rate every member has is the song's own: exact, nothing resampled")
    func exactRate() {
        let plan = GroupMemberPlanner.rate(for: 96_000, members: [caps(zd3), caps(k11)], policy: .matchSource)
        #expect(plan == GroupMemberPlanner.RatePlan(rate: 96_000, exact: true))
    }

    @Test("A rate one member lacks is converted the way a single device would: to the integer divisor when the top rate is near")
    func convertedRate() {
        let plan = GroupMemberPlanner.rate(for: 352_800, members: [caps(zd3), caps(k11)], policy: .matchSource)
        #expect(plan == GroupMemberPlanner.RatePlan(rate: 176_400, exact: false))
        // 384 kHz on a 192 kHz-capped DAC: half.
        #expect(GroupMemberPlanner.rate(for: 384_000, members: [caps(zd3), caps(k11)], policy: .matchSource)?.rate == 192_000)
    }

    @Test("The device's own rate policies apply to the group's common rates: fixed and maximum")
    func policies() {
        let members = [caps(zd3), caps(k11)]
        #expect(GroupMemberPlanner.rate(for: 44_100, members: members, policy: .fixed(96_000))?.rate == 96_000)
        #expect(GroupMemberPlanner.rate(for: 44_100, members: members, policy: .maximum)?.rate == 192_000)
        // A fixed rate that one member lacks falls back to matching the song.
        #expect(GroupMemberPlanner.rate(for: 44_100, members: members, policy: .fixed(384_000)) == GroupMemberPlanner.RatePlan(rate: 44_100, exact: true))
    }

    // MARK: Who may be held

    @Test("Exclusive access per member: free ones are taken, ours are ours, another app's are refused with who holds them")
    func access() {
        let me: pid_t = 4242
        #expect(GroupMemberPlanner.access(owners: [-1, me, 777], me: me) == [.take, .alreadyHeld, .heldByOther(777)])
        #expect(GroupMemberPlanner.access(owners: [], me: me).isEmpty)
    }

    @Test("A member in agreement is at the wanted rate on the device and on every one of its own streams")
    func agreement() {
        let ok = GroupMemberSession.Member(uid: "a", deviceID: 1, rateBefore: 44_100, rate: 96_000, streamRates: [96_000, 96_000], exclusive: true)
        #expect(ok.isAt(96_000))
        var slow = ok
        slow.streamRates = [96_000, 48_000]
        #expect(!slow.isAt(96_000), "a stream still at another rate means the device resamples silently")
        var empty = ok
        empty.streamRates = []
        #expect(!empty.isAt(96_000), "no stream could be read: not confirmed")
        var off = ok
        off.rate = 48_000
        #expect(!off.isAt(96_000))
    }
}
