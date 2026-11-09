//
// Vespertine: speaker groups: a group as an output the engine can choose. Finding its members among the connected outputs,
// the output it presents (a UID of its own, the members' channels and common rates), when it counts as connected, and which
// rules decide whether it is held exclusively. Pure; no device.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group output")
struct GroupOutputTests {
    private func caps(_ rates: [Double], channels: Int = 2) -> DeviceCapabilities {
        DeviceCapabilities(sampleRates: rates,
                           physicalFormats: [PhysicalFormat(minRate: rates.min() ?? 0, maxRate: rates.max() ?? 0, bitDepth: 32, isInteger: true, isMixable: false, channels: channels)],
                           outputChannels: channels, supportsDoP: false)
    }

    private func device(_ uid: String, _ name: String, id: AudioObjectID, rates: [Double] = [44_100, 48_000, 96_000], channels: Int = 2,
                        transport: Transport = .usb) -> OutputDevice {
        OutputDevice(id: id, uid: uid, name: name, manufacturer: "", modelUID: nil, transport: transport, nominalSampleRate: 48_000,
                     capabilities: caps(rates, channels: channels), hasHardwareVolume: true, isDefault: false)
    }

    private let fosi = "fosi-uid", fiio = "fiio-uid"

    private func group() -> SpeakerGroup {
        SpeakerGroup(id: UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000001")!, name: "Downstairs quad",
                     members: [SpeakerGroup.Member(deviceUID: fosi, name: "Fosi ZD3", channelCount: 2),
                               SpeakerGroup.Member(deviceUID: fiio, name: "FiiO K11", channelCount: 2)],
                     clockLeaderUID: fosi)
    }

    // MARK: Finding the members

    @Test("With every member connected the group is an output of its own: the group's UID and name, all the channels, the common rates")
    func ready() throws {
        let zd3 = device(fosi, "Fosi ZD3", id: 10, rates: [44_100, 48_000, 96_000, 192_000])
        let k11 = device(fiio, "FiiO K11", id: 11, rates: [44_100, 48_000, 96_000])
        let other = device("other", "Speakers", id: 12)
        guard case .ready(let output, let members) = GroupOutput.resolve(group(), among: [other, k11, zd3]) else {
            Issue.record("not ready"); return
        }
        #expect(members.map(\.uid) == [fosi, fiio], "in the group's order, whatever the order of the list")
        #expect(output.uid == group().outputUID && output.uid.hasPrefix(SpeakerGroup.outputUIDPrefix))
        #expect(output.name == "Downstairs quad")
        #expect(output.capabilities.outputChannels == 4)
        #expect(output.capabilities.sampleRates == [44_100, 48_000, 96_000])
        #expect(!output.capabilities.supportsDoP)
        #expect(output.id == AudioObjectID(kAudioObjectUnknown), "it has no device of its own until its aggregate is made")
        #expect(output.transport == .aggregate)
        #expect(output.profile.kind == .speakerGroup)
        #expect(!output.hasHardwareVolume)
    }

    @Test("Members that aren't connected are named, in the group's order, and nothing is made")
    func missing() {
        let zd3 = device(fosi, "Fosi ZD3", id: 10)
        #expect(GroupOutput.resolve(group(), among: [zd3]) == .missing(["FiiO K11"]))
        #expect(GroupOutput.resolve(group(), among: []) == .missing(["Fosi ZD3", "FiiO K11"]))
    }

    @Test("A member that has fewer channels than the group was set up with is not usable, and is named")
    func fewerChannels() {
        let zd3 = device(fosi, "Fosi ZD3", id: 10)
        let k11 = device(fiio, "FiiO K11", id: 11, channels: 1)
        #expect(GroupOutput.resolve(group(), among: [zd3, k11]) == .missing(["FiiO K11"]))
    }

    @Test("Members with no rate in common can't play together")
    func noCommonRate() {
        let zd3 = device(fosi, "Fosi ZD3", id: 10, rates: [44_100, 88_200])
        let k11 = device(fiio, "FiiO K11", id: 11, rates: [48_000, 96_000])
        #expect(GroupOutput.resolve(group(), among: [zd3, k11]) == .noCommonRate)
    }

    @Test("A group that isn't valid isn't played")
    func invalid() {
        var g = group()
        g.clockLeaderUID = "nobody"
        let zd3 = device(fosi, "Fosi ZD3", id: 10), k11 = device(fiio, "FiiO K11", id: 11)
        #expect(GroupOutput.resolve(g, among: [zd3, k11]) == .invalid)
    }

    // MARK: Connected

    @Test("A group counts as a connected output exactly when all of its members are")
    func connected() {
        let g = group()
        #expect(GroupOutput.connectedUIDs(of: [g], connected: [fosi, fiio, "x"]) == [g.outputUID])
        #expect(GroupOutput.connectedUIDs(of: [g], connected: [fosi]).isEmpty)
        #expect(GroupOutput.connectedUIDs(of: [], connected: [fosi, fiio]).isEmpty)
    }

    // MARK: Settings

    @Test("The engine finds the group of a chosen output UID, and a single device's UID is no group")
    func settingsLookup() {
        var settings = EngineSettings()
        #expect(settings.group(forOutputUID: group().outputUID) == nil, "no groups known: the engine behaves as before")
        settings.speakerGroups = [group()]
        #expect(settings.group(forOutputUID: group().outputUID)?.name == "Downstairs quad")
        #expect(settings.group(forOutputUID: fosi) == nil)
        #expect(settings.group(forOutputUID: nil) == nil)
        #expect(settings != EngineSettings(), "a change of groups is a change of settings")
    }

    // MARK: The same output

    @Test("A group's output is the same output while its UID is; a single device by its ID")
    func sameOutput() {
        let a = device(fosi, "Fosi", id: 10), b = device(fosi, "Fosi", id: 10), c = device(fiio, "FiiO", id: 11)
        #expect(GroupOutput.isSameOutput(a, b) && !GroupOutput.isSameOutput(a, c) && !GroupOutput.isSameOutput(nil, a))
        let g = group()
        let output = GroupOutput.presented(g, members: [a, c])
        let withAggregate = output.with(id: 99)
        #expect(GroupOutput.isSameOutput(withAggregate, output), "the same group, now with its aggregate's ID")
        #expect(GroupOutput.isSameOutput(withAggregate, GroupOutput.presented(g, members: [a, c])))
        var other = group()
        other = SpeakerGroup(id: UUID(), name: "Other", members: other.members, clockLeaderUID: fosi)
        #expect(!GroupOutput.isSameOutput(withAggregate, GroupOutput.presented(other, members: [a, c])))
    }

    // MARK: Exclusive access

    @Test("A group is held exclusively when the setting says so, unless a member is one that always plays shared")
    func exclusive() {
        let usb = device(fosi, "Fosi", id: 10), builtIn = device(fiio, "Speakers", id: 11, transport: .builtIn)
        #expect(GroupOutput.exclusive(setting: true, members: [usb, usb]))
        #expect(!GroupOutput.exclusive(setting: false, members: [usb, usb]))
        #expect(!GroupOutput.exclusive(setting: true, members: [usb, builtIn]))
    }
}
