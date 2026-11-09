//
// Vespertine — speaker groups: making one. Which outputs may join and why the others may not, the order and the clock leader of the
// ones chosen, and the group that comes out. Pure; no device.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("New speaker group")
struct SpeakerGroupDraftTests {
    private func device(_ uid: String, _ name: String, channels: Int = 2, transport: Transport = .usb, id: AudioObjectID = 1) -> OutputDevice {
        OutputDevice(id: id, uid: uid, name: name, manufacturer: "", modelUID: nil, transport: transport, nominalSampleRate: 48_000,
                     capabilities: DeviceCapabilities(sampleRates: [48_000, 96_000],
                                                      physicalFormats: [PhysicalFormat(minRate: 48_000, maxRate: 96_000, bitDepth: 32, isInteger: true, isMixable: true, channels: channels)],
                                                      outputChannels: channels, supportsDoP: false),
                     hasHardwareVolume: true, isDefault: false)
    }

    private func candidate(_ uid: String, _ name: String, channels: Int = 2, transport: Transport = .usb) -> GroupCandidate {
        GroupCandidates.candidate(for: device(uid, name, channels: channels, transport: transport))
    }

    // MARK: Who may join

    @Test("Wired outputs may join; Bluetooth and AirPlay may not, with the reason; the Mac's own output joins with a warning")
    func eligibility() {
        #expect(candidate("a", "Fosi ZD3").eligibility == .ok)
        for transport in [Transport.hdmi, .displayPort, .thunderbolt, .pci, .fireWire] { #expect(candidate("a", "x", transport: transport).eligibility == .ok) }
        for transport in [Transport.bluetooth, .bluetoothLE, .airPlay] {
            guard case .refused(let reason) = candidate("a", "x", transport: transport).eligibility else { Issue.record("\(transport) allowed"); continue }
            #expect(reason.contains("100"))
        }
        guard case .warning(let note) = candidate("a", "MacBook Pro Speakers", transport: .builtIn).eligibility else { Issue.record("no warning"); return }
        #expect(note.contains("never bit-perfect"))
    }

    @Test("Combined and software outputs may not join, and an output with no channels may not")
    func notOutputs() {
        guard case .refused = candidate("a", "Aggregate", transport: .aggregate).eligibility else { Issue.record("aggregate allowed"); return }
        guard case .refused = candidate("a", "BlackHole", transport: .virtual).eligibility else { Issue.record("virtual allowed"); return }
        guard case .refused = candidate("a", "Nothing", channels: 0).eligibility else { Issue.record("no channels allowed"); return }
    }

    @Test("The list leaves out the groups themselves, and puts what may join first")
    func list() {
        let group = SpeakerGroup(name: "G", members: [], clockLeaderUID: "")
        let devices = [device("bt", "AirPods", transport: .bluetooth), device("z", "Zeta DAC"), device("a", "Alpha DAC"),
                       device(group.outputUID, "G", transport: .aggregate)]
        let candidates = GroupCandidates.list(from: devices)
        #expect(candidates.map(\.name) == ["Alpha DAC", "Zeta DAC", "AirPods"])
    }

    // MARK: Choosing

    @Test("Outputs are chosen in an order, the first is the clock leader, and a refused one cannot be chosen")
    func choosing() {
        var draft = SpeakerGroupDraft()
        draft.toggle(candidate("fiio", "FiiO K11"))
        draft.toggle(candidate("fosi", "Fosi ZD3"))
        draft.toggle(candidate("bt", "AirPods", transport: .bluetooth))
        #expect(draft.chosen.map(\.uid) == ["fiio", "fosi"])
        #expect(draft.leaderUID == "fiio")
        draft.setLeader("fosi")
        #expect(draft.leaderUID == "fosi")
        draft.setLeader("nobody")
        #expect(draft.leaderUID == "fosi", "only a chosen output can lead")
        draft.toggle(candidate("fosi", "Fosi ZD3"))
        #expect(draft.chosen.map(\.uid) == ["fiio"] && draft.leaderUID == "fiio", "the leader left: the first one left leads")
        draft.toggle(candidate("fiio", "FiiO K11"))
        #expect(draft.chosen.isEmpty && draft.leaderUID == nil)
    }

    @Test("The order is the order of the streams, and can be changed")
    func order() {
        var draft = SpeakerGroupDraft()
        for (uid, name) in [("a", "A"), ("b", "B"), ("c", "C")] { draft.toggle(candidate(uid, name)) }
        draft.move("c", by: -1)
        #expect(draft.chosen.map(\.uid) == ["a", "c", "b"])
        draft.move("a", by: -1)
        #expect(draft.chosen.map(\.uid) == ["a", "c", "b"], "not past the start")
        draft.move("b", by: 1)
        #expect(draft.chosen.map(\.uid) == ["a", "c", "b"], "not past the end")
        draft.move("a", by: 1)
        #expect(draft.chosen.map(\.uid) == ["c", "a", "b"])
    }

    // MARK: Ready or not

    @Test("Two outputs and a name make a group; fewer, or more than 16 channels, do not, and the problem is said")
    func problems() {
        var draft = SpeakerGroupDraft(name: "Downstairs quad")
        #expect(!draft.canCreate && draft.problems == ["Choose at least two outputs."])
        draft.toggle(candidate("a", "A"))
        #expect(!draft.canCreate)
        draft.toggle(candidate("b", "B"))
        #expect(draft.canCreate && draft.problems.isEmpty)
        var big = SpeakerGroupDraft(name: "Big")
        big.toggle(candidate("a", "A", channels: 8))
        big.toggle(candidate("b", "B", channels: 8))
        big.toggle(candidate("c", "C", channels: 2))
        #expect(!big.canCreate && big.problems == ["The outputs add up to 18 channels; a group can have 16."])
    }

    @Test("The group that comes out: members in order with their channels, the leader, the name (a default when empty), valid")
    func makeGroup() throws {
        var draft = SpeakerGroupDraft(name: "  Downstairs quad ")
        draft.toggle(candidate("fosi", "Fosi ZD3"))
        draft.toggle(candidate("fiio", "FiiO K11", channels: 4))
        draft.setLeader("fiio")
        let id = UUID()
        let group = try #require(draft.makeGroup(id: id))
        #expect(group.id == id && group.name == "Downstairs quad")
        #expect(group.members.map(\.deviceUID) == ["fosi", "fiio"] && group.members.map(\.channelCount) == [2, 4])
        #expect(group.members.map(\.name) == ["Fosi ZD3", "FiiO K11"])
        #expect(group.clockLeaderUID == "fiio")
        #expect(group.isValid, "\(group.issues)")
        var unnamed = draft
        unnamed.name = "   "
        #expect(unnamed.makeGroup()?.name == "Speaker group")
        #expect(SpeakerGroupDraft(name: "x").makeGroup() == nil)
    }

    @Test("The sentence that says what the clock leader is, for the picker")
    func leaderSentence() {
        #expect(SpeakerGroupDraft.leaderExplanation.contains("follow") && SpeakerGroupDraft.leaderExplanation.contains("bit-perfect"))
    }
}
