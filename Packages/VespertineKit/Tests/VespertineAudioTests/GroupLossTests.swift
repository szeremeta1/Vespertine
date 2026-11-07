//
// Vespertine — speaker groups: a member that goes away while the group plays, and comes back. Who is gone decides what
// happens: a follower lost pauses the group or lets it carry on with the rest, as the group says; the leader lost always
// pauses (the group never carries on silently on another clock). Pure; no device.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group member loss")
struct GroupLossTests {
    private let fosi = "fosi-uid", fiio = "fiio-uid", dac3 = "dac3-uid"

    private func caps(_ rates: [Double] = [44_100, 48_000, 96_000], channels: Int = 2) -> DeviceCapabilities {
        DeviceCapabilities(sampleRates: rates,
                           physicalFormats: [PhysicalFormat(minRate: rates.min() ?? 0, maxRate: rates.max() ?? 0, bitDepth: 32, isInteger: true, isMixable: false, channels: channels)],
                           outputChannels: channels, supportsDoP: false)
    }

    private func device(_ uid: String, _ name: String, id: AudioObjectID) -> OutputDevice {
        OutputDevice(id: id, uid: uid, name: name, manufacturer: "", modelUID: nil, transport: .usb, nominalSampleRate: 48_000,
                     capabilities: caps(), hasHardwareVolume: true, isDefault: false)
    }

    private func group(loss: LossPolicy = .pause, three: Bool = false) -> SpeakerGroup {
        var members = [SpeakerGroup.Member(deviceUID: fosi, name: "Fosi ZD3", channelCount: 2),
                       SpeakerGroup.Member(deviceUID: fiio, name: "FiiO K11", channelCount: 2)]
        var speakers = [SpeakerGroup.Speaker(role: .frontLeft, deviceUID: fosi, channel: 0, position: Point2D(x: -1, y: 1.5)),
                        SpeakerGroup.Speaker(role: .frontRight, deviceUID: fosi, channel: 1, position: Point2D(x: 1, y: 1.5)),
                        SpeakerGroup.Speaker(role: .backLeft, deviceUID: fiio, channel: 0, position: Point2D(x: -1, y: -1.5)),
                        SpeakerGroup.Speaker(role: .backRight, deviceUID: fiio, channel: 1, position: Point2D(x: 1, y: -1.5))]
        if three {
            members.append(SpeakerGroup.Member(deviceUID: dac3, name: "Third DAC", channelCount: 2))
            speakers.append(SpeakerGroup.Speaker(role: .sideLeft, deviceUID: dac3, channel: 0, position: Point2D(x: -2, y: 0)))
            speakers.append(SpeakerGroup.Speaker(role: .sideRight, deviceUID: dac3, channel: 1, position: Point2D(x: 2, y: 0)))
        }
        return SpeakerGroup(id: UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000002")!, name: "Dorm quad", members: members,
                            clockLeaderUID: fosi, speakers: speakers, onMemberLoss: loss)
    }

    // MARK: Who is gone

    @Test("Everyone connected: nothing lost")
    func nobody() {
        #expect(GroupLoss.assess(group(), connected: [fosi, fiio, "x"]) == .intact)
    }

    @Test("A follower that went away is named, in the group's order")
    func followerGone() {
        #expect(GroupLoss.assess(group(), connected: [fosi]) == .followersLost(["FiiO K11"]))
        #expect(GroupLoss.assess(group(three: true), connected: [fosi]) == .followersLost(["FiiO K11", "Third DAC"]))
    }

    @Test("The leader gone is the leader gone, even when followers are too")
    func leaderGone() {
        #expect(GroupLoss.assess(group(), connected: [fiio]) == .leaderLost("Fosi ZD3"))
        #expect(GroupLoss.assess(group(), connected: []) == .leaderLost("Fosi ZD3"))
    }

    // MARK: What happens

    @Test("Pause policy: any loss pauses; continue policy: only a follower lost carries on; the leader lost always pauses")
    func actions() {
        #expect(GroupLoss.action(for: .intact, policy: .pause) == .none)
        #expect(GroupLoss.action(for: .intact, policy: .continueOnRemaining) == .none)
        #expect(GroupLoss.action(for: .followersLost(["FiiO K11"]), policy: .pause) == .pause)
        #expect(GroupLoss.action(for: .followersLost(["FiiO K11"]), policy: .continueOnRemaining) == .continueOnRest)
        #expect(GroupLoss.action(for: .leaderLost("Fosi ZD3"), policy: .pause) == .pause)
        #expect(GroupLoss.action(for: .leaderLost("Fosi ZD3"), policy: .continueOnRemaining) == .pause, "never silently on another clock")
    }

    // MARK: Carrying on with the rest

    @Test("Carrying on: the group with the members that are left, same name and UID, speakers of the lost ones dropped, still valid")
    func withoutLost() {
        let rest = group(three: true).without(memberUIDs: [dac3])
        #expect(rest.members.map(\.deviceUID) == [fosi, fiio])
        #expect(rest.speakers.map(\.deviceUID).allSatisfy { $0 != dac3 } && rest.speakers.count == 4)
        #expect(rest.outputUID == group().outputUID && rest.name == "Dorm quad" && rest.clockLeaderUID == fosi)
        #expect(rest.isValid, "\(rest.issues)")
    }

    @Test("Resolving a group with a follower missing: continue policy gives the rest as a group when two or more are left")
    func degradedGroup() {
        let all = [device(fosi, "Fosi ZD3", id: 10), device(dac3, "Third DAC", id: 12)]
        guard case .ready(let output, let members) = GroupOutput.resolveDegraded(group(loss: .continueOnRemaining, three: true), among: all) else {
            Issue.record("not ready"); return
        }
        #expect(members.map(\.uid) == [fosi, dac3])
        #expect(output.uid == group().outputUID)
        #expect(output.capabilities.outputChannels == 4)
    }

    @Test("Only the leader left: its own device plays, as a single output")
    func degradedSingle() {
        let leader = device(fosi, "Fosi ZD3", id: 10)
        #expect(GroupOutput.resolveDegraded(group(loss: .continueOnRemaining), among: [leader]) == .single(leader))
    }

    @Test("The leader missing, or the pause policy: nothing to carry on with")
    func degradedNothing() {
        let fiioOnly = [device(fiio, "FiiO K11", id: 11)]
        #expect(GroupOutput.resolveDegraded(group(loss: .continueOnRemaining), among: fiioOnly) == .missing(["Fosi ZD3"]))
        #expect(GroupOutput.resolveDegraded(group(loss: .pause), among: [device(fosi, "Fosi ZD3", id: 10)]) == .missing(["FiiO K11"]))
    }
}
