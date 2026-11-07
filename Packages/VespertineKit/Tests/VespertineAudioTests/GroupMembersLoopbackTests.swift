//
// Vespertine — speaker groups: configuring two real (virtual) devices as the members of a group: exclusive access per
// member, each member's own rate set and read back from the member, everything put back.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Opt-in: VESPERTINE_GROUP_LOOPBACK=1 swift test --filter GroupMembersLoopback
// Needs "Vespertine Loopback" and a second virtual device ("BlackHole 2ch" unless VESPERTINE_GROUP_FOLLOWER names another),
// both unused by other processes. Nothing is played. The members' rates are put back afterwards.
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group members loopback", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VESPERTINE_GROUP_LOOPBACK"] == "1"))
struct GroupMembersLoopbackTests {
    static let leaderName = "Vespertine Loopback"
    static let followerName = ProcessInfo.processInfo.environment["VESPERTINE_GROUP_FOLLOWER"] ?? "BlackHole 2ch"
    static let rate = 96_000.0

    private func devices() throws -> [OutputDevice] {
        let all = OutputDevices.list()
        let leader = try #require(all.first { $0.name == Self.leaderName && $0.transport == .virtual }, "no \(Self.leaderName)")
        let follower = try #require(all.first { $0.name == Self.followerName && $0.transport == .virtual }, "no \(Self.followerName)")
        try #require(!LoopbackGuard.inUseByOthers(leader.id) && !LoopbackGuard.inUseByOthers(follower.id), "a device is in use by another process; left alone")
        try #require(leader.capabilities.supports(rate: Self.rate) && follower.capabilities.supports(rate: Self.rate), "a device lacks \(Self.rate) Hz")
        return [leader, follower]
    }

    private func nominal(_ device: OutputDevice) -> Double {
        (try? HAL.get(device.id, .global(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0
    }

    @Test("Each member is held, set to the group's rate and read back from the member itself; releasing frees them; the rates are put back")
    func configureAndRelease() throws {
        let members = try devices()
        let found = members.map(nominal)
        defer { for (d, r) in zip(members, found) { try? DeviceControl.setNominalRate(r, on: d.id) } }

        let session = try GroupMemberSession.begin(devices: members, rate: Self.rate, exclusive: true)
        defer { session.release() }
        #expect(session.members.map(\.uid) == members.map(\.uid))
        #expect(session.members.allSatisfy { $0.isAt(Self.rate) && $0.exclusive }, "\(session.members)")
        #expect(session.members.map(\.rateBefore) == found)
        // The OS agrees: each member runs at the rate and is held by this process.
        for d in members {
            #expect(abs(nominal(d) - Self.rate) < 0.5)
            #expect(DeviceControl.hogOwner(d.id) == getpid())
        }
        #expect(Set(DeviceRestore.changedDevices).isSuperset(of: members.map(\.uid)), "the quit-time restore knows these devices")

        session.release()
        for d in members { #expect(DeviceControl.hogOwner(d.id) == -1) }
        session.release()          // twice is harmless
    }

    @Test("Shared, not exclusive: nothing is held, and the rates are still set and read back")
    func shared() throws {
        let members = try devices()
        let found = members.map(nominal)
        defer { for (d, r) in zip(members, found) { try? DeviceControl.setNominalRate(r, on: d.id) } }
        let session = try GroupMemberSession.begin(devices: members, rate: Self.rate, exclusive: false)
        defer { session.release() }
        #expect(session.members.allSatisfy { $0.isAt(Self.rate) && !$0.exclusive })
        for d in members { #expect(DeviceControl.hogOwner(d.id) == -1) }
    }

    @Test("A rate a member lacks is refused, and nothing is left held or changed")
    func refusedRate() throws {
        let members = try devices()
        let found = members.map(nominal)
        defer { for (d, r) in zip(members, found) { try? DeviceControl.setNominalRate(r, on: d.id) } }
        #expect(throws: (any Error).self) { try GroupMemberSession.begin(devices: members, rate: 12_345, exclusive: true) }
        for d in members { #expect(DeviceControl.hogOwner(d.id) == -1) }
        #expect(members.map(nominal) == found)
    }
}
