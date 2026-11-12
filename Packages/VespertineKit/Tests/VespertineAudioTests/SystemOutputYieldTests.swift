//
// Vespertine: Mac Sound Output (beta): the helper gives the group's DACs up (never holds them against the Mac's own choices), and
// the group's volume survives a layout change. Regression tests for two bugs found live on a laptop with a FiiO K11 and a Fosi ZD3:
//   1. with a group on, choosing one of its DACs alone in the Sound menu spun forever: the helper held the DAC (hog mode), and macOS
//      never makes a hogged device the Mac's output;
//   2. changing the group's layout put the group's volume back to 100%.
// No device needed.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Mac Sound Output: members and volume")
struct SystemOutputYieldTests {
    private let me: pid_t = 4242
    private let a = "AppleUSBAudioEngine:FIIO:FiiO K11:2144400:2"
    private let b = "AppleUSBAudioEngine:XMOS:Fosi Audio ZD3:2142200:1"
    private let groupOutput = SystemOutput.deviceUID(groupID: UUID())

    private func group() -> SpeakerGroup {
        let members = [SpeakerGroup.Member(deviceUID: a, name: "FiiO K11", channelCount: 2),
                       SpeakerGroup.Member(deviceUID: b, name: "Fosi Audio ZD3", channelCount: 2)]
        let speakers = [SpeakerGroup.Speaker(role: .frontLeft, deviceUID: a, channel: 0, position: Point2D(x: -1, y: 1)),
                        SpeakerGroup.Speaker(role: .frontRight, deviceUID: a, channel: 1, position: Point2D(x: 1, y: 1)),
                        SpeakerGroup.Speaker(role: .backLeft, deviceUID: b, channel: 0, position: Point2D(x: -1, y: -1)),
                        SpeakerGroup.Speaker(role: .backRight, deviceUID: b, channel: 1, position: Point2D(x: 1, y: -1))]
        return SpeakerGroup(name: "bar 118 test", members: members, clockLeaderUID: a, speakers: speakers)
    }

    // MARK: 1. The helper never holds the DACs

    @Test("The helper plays the group without exclusive access, whatever the app's Exclusive Mode says")
    func helperNeverHogs() {
        for exclusive in [false, true] {
            let entry = SystemOutputEntry(group: group(), choice: SystemOutputChoice(published: true), exclusive: exclusive)
            #expect(SystemOutputPolicy.holdsMembers(entry) == false, "exclusive \(exclusive)")
        }
    }

    @Test("Nothing in the way: the group may play")
    func freeToPlay() {
        let claim = SystemOutputPolicy.memberClaim(group: group(), defaultOutputUID: "BuiltInSpeakerDevice", hogOwners: [a: -1, b: -1], me: me)
        #expect(claim == .none)
        // The group's own output being the default is the normal way to use it.
        #expect(SystemOutputPolicy.memberClaim(group: group(), defaultOutputUID: groupOutput, hogOwners: [a: -1, b: -1], me: me) == .none)
        // Unknown owners (the device can't be read) don't stop the group.
        #expect(SystemOutputPolicy.memberClaim(group: group(), defaultOutputUID: nil, hogOwners: [:], me: me) == .none)
    }

    @Test("A member chosen as the Mac's output is let go: the group stops using it")
    func memberBecomesDefault() {
        #expect(SystemOutputPolicy.memberClaim(group: group(), defaultOutputUID: b, hogOwners: [a: -1, b: -1], me: me) == .isDefaultOutput(uid: b))
        #expect(SystemOutputPolicy.memberClaim(group: group(), defaultOutputUID: a, hogOwners: [a: -1, b: -1], me: me) == .isDefaultOutput(uid: a))
    }

    @Test("Another app holding a member exclusively is let be")
    func memberHeldByOther() {
        #expect(SystemOutputPolicy.memberClaim(group: group(), defaultOutputUID: groupOutput, hogOwners: [a: -1, b: 777], me: me)
                == .heldByOther(uid: b, pid: 777))
        // A hold of our own (this process) is not someone else's.
        #expect(SystemOutputPolicy.memberClaim(group: group(), defaultOutputUID: groupOutput, hogOwners: [a: me, b: -1], me: me) == .none)
    }

    @Test("The default output wins over a hold: the user's choice is named first")
    func defaultBeatsHold() {
        #expect(SystemOutputPolicy.memberClaim(group: group(), defaultOutputUID: a, hogOwners: [a: 777, b: -1], me: me) == .isDefaultOutput(uid: a))
    }

    // MARK: 2. The group's volume survives a layout change

    private func level(_ v: Float, muted: Bool = false) -> SystemOutputLevel { SystemOutputLevel(volume: v, muted: muted) }

    @Test("After a layout change macOS puts the volume back to 100%: it is put back to what it was")
    func volumeSurvivesLayoutChange() {
        var keeper = SystemOutputLevelKeeper()
        let t0 = Date(timeIntervalSince1970: 1_000)
        // Settled, at 10%, 8 channels (Automatic on a quad).
        keeper.beforePublish(layouts: [groupOutput: [1, 2, 3, 4, 5, 6, 33, 34]], levels: [groupOutput: level(0.1)], now: t0)
        #expect(keeper.restores(devices: [groupOutput: .init(level: level(0.1), channels: 8)], now: t0).isEmpty)
        // The user picks 5.1: the layout changes, and the device is read before it is published (still 10%).
        keeper.beforePublish(layouts: [groupOutput: [1, 2, 3, 4, 5, 6]], levels: [groupOutput: level(0.1)], now: t0 + 1)
        // Still the old 8 channels (the host hasn't reconfigured yet): nothing to do yet.
        #expect(keeper.restores(devices: [groupOutput: .init(level: level(0.1), channels: 8)], now: t0 + 1.5).isEmpty)
        // Reconfigured: 6 channels, and the volume is 100%.
        let restores = keeper.restores(devices: [groupOutput: .init(level: level(1.0), channels: 6)], now: t0 + 2)
        #expect(restores == [groupOutput: level(0.1)])
        // Once put back, nothing more is asked.
        #expect(keeper.restores(devices: [groupOutput: .init(level: level(0.1), channels: 6)], now: t0 + 3).isEmpty)
    }

    @Test("A mute is kept the same way")
    func muteSurvivesLayoutChange() {
        var keeper = SystemOutputLevelKeeper()
        let t0 = Date(timeIntervalSince1970: 1_000)
        keeper.beforePublish(layouts: [groupOutput: [1, 2]], levels: [groupOutput: level(0.3, muted: true)], now: t0)
        keeper.beforePublish(layouts: [groupOutput: [1, 2, 3, 4]], levels: [groupOutput: level(0.3, muted: true)], now: t0 + 1)
        let restores = keeper.restores(devices: [groupOutput: .init(level: level(1.0), channels: 4)], now: t0 + 2)
        #expect(restores == [groupOutput: level(0.3, muted: true)])
    }

    @Test("Without a layout change the volume is the user's: never written")
    func noChangeNoRestore() {
        var keeper = SystemOutputLevelKeeper()
        let t0 = Date(timeIntervalSince1970: 1_000)
        keeper.beforePublish(layouts: [groupOutput: [1, 2, 3, 4]], levels: [groupOutput: level(0.1)], now: t0)
        // The user turns it up with the keys; a refresh with the same layout follows.
        keeper.beforePublish(layouts: [groupOutput: [1, 2, 3, 4]], levels: [groupOutput: level(0.5)], now: t0 + 5)
        #expect(keeper.restores(devices: [groupOutput: .init(level: level(0.5), channels: 4)], now: t0 + 5).isEmpty)
        // Even when it reads differently later.
        #expect(keeper.restores(devices: [groupOutput: .init(level: level(0.9), channels: 4)], now: t0 + 6).isEmpty)
    }

    @Test("A group published for the first time has nothing to restore")
    func firstPublishNothing() {
        var keeper = SystemOutputLevelKeeper()
        let t0 = Date(timeIntervalSince1970: 1_000)
        keeper.beforePublish(layouts: [groupOutput: [1, 2]], levels: [groupOutput: nil], now: t0)
        #expect(keeper.restores(devices: [groupOutput: .init(level: level(1.0), channels: 2)], now: t0 + 1).isEmpty)
    }

    @Test("A restore that never comes (the host never reconfigures) is given up after a while, not written late")
    func restoreExpires() {
        var keeper = SystemOutputLevelKeeper()
        let t0 = Date(timeIntervalSince1970: 1_000)
        keeper.beforePublish(layouts: [groupOutput: [1, 2]], levels: [groupOutput: level(0.2)], now: t0)
        keeper.beforePublish(layouts: [groupOutput: [1, 2, 3, 4]], levels: [groupOutput: level(0.2)], now: t0 + 1)
        #expect(keeper.restores(devices: [groupOutput: .init(level: level(0.4), channels: 2)], now: t0 + 1 + SystemOutputLevelKeeper.patience + 1).isEmpty)
        #expect(keeper.restores(devices: [groupOutput: .init(level: level(0.4), channels: 4)], now: t0 + 100).isEmpty)
    }

    @Test("A layout change with the same channel count (same number, other labels) is checked at once")
    func sameChannelCount() {
        var keeper = SystemOutputLevelKeeper()
        let t0 = Date(timeIntervalSince1970: 1_000)
        keeper.beforePublish(layouts: [groupOutput: [1, 2, 3, 4]], levels: [groupOutput: level(0.1)], now: t0)
        keeper.beforePublish(layouts: [groupOutput: [1, 2, 5, 6]], levels: [groupOutput: level(0.1)], now: t0 + 1)
        #expect(keeper.restores(devices: [groupOutput: .init(level: level(1.0), channels: 4)], now: t0 + 2) == [groupOutput: level(0.1)])
    }

    @Test("Each output keeps its own level, and an output that goes away is forgotten")
    func perOutput() {
        var keeper = SystemOutputLevelKeeper()
        let other = SystemOutput.deviceUID(groupID: UUID())
        let t0 = Date(timeIntervalSince1970: 1_000)
        keeper.beforePublish(layouts: [groupOutput: [1, 2], other: [1, 2]], levels: [groupOutput: level(0.1), other: level(0.7)], now: t0)
        keeper.beforePublish(layouts: [groupOutput: [1, 2, 3, 4]], levels: [groupOutput: level(0.1)], now: t0 + 1)
        let restores = keeper.restores(devices: [groupOutput: .init(level: level(1.0), channels: 4)], now: t0 + 2)
        #expect(restores == [groupOutput: level(0.1)])
        // The other comes back later as a new output: nothing remembered.
        keeper.beforePublish(layouts: [groupOutput: [1, 2, 3, 4], other: [1, 2]], levels: [groupOutput: level(0.1), other: nil], now: t0 + 10)
        #expect(keeper.restores(devices: [other: .init(level: level(1.0), channels: 2)], now: t0 + 11).isEmpty)
    }
}
