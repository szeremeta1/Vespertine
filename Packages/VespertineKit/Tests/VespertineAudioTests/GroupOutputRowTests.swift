//
// Vespertine: speaker groups in the output list: a row for each saved group saying whether it can play and what it is made of or
// what is missing, and the lines of the signal path for its DACs. Pure; no view.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group output rows")
struct GroupOutputRowTests {
    private func device(_ uid: String, _ name: String, id: AudioObjectID) -> OutputDevice {
        OutputDevice(id: id, uid: uid, name: name, manufacturer: "", modelUID: nil, transport: .usb, nominalSampleRate: 48_000,
                     capabilities: DeviceCapabilities(sampleRates: [48_000, 96_000],
                                                      physicalFormats: [PhysicalFormat(minRate: 48_000, maxRate: 96_000, bitDepth: 32, isInteger: true, isMixable: false, channels: 2)],
                                                      outputChannels: 2, supportsDoP: false),
                     hasHardwareVolume: true, isDefault: false)
    }

    private func group(_ name: String = "Downstairs quad") -> SpeakerGroup {
        SpeakerGroup(name: name,
                     members: [SpeakerGroup.Member(deviceUID: "fosi", name: "Fosi ZD3", channelCount: 2),
                               SpeakerGroup.Member(deviceUID: "fiio", name: "FiiO K11", channelCount: 2)],
                     clockLeaderUID: "fosi")
    }

    @Test("A group whose outputs are all connected is ready, and its row says what it is made of")
    func ready() {
        let g = group()
        let rows = GroupOutputRows.rows(groups: [g], devices: [device("fosi", "Fosi ZD3", id: 1), device("fiio", "FiiO K11", id: 2)])
        #expect(rows.count == 1)
        #expect(rows[0].name == "Downstairs quad" && rows[0].isReady && rows[0].uid == g.outputUID)
        #expect(rows[0].detail == "SPEAKER GROUP · 4 CH · FOSI ZD3 + FIIO K11")
    }

    @Test("A group with an output missing says which, and can't play")
    func missing() {
        let rows = GroupOutputRows.rows(groups: [group()], devices: [device("fosi", "Fosi ZD3", id: 1)])
        #expect(!rows[0].isReady && rows[0].detail == "NOT CONNECTED · FIIO K11 MISSING")
        let none = GroupOutputRows.rows(groups: [group()], devices: [])
        #expect(none[0].detail == "NOT CONNECTED · FOSI ZD3, FIIO K11 MISSING")
    }

    @Test("A group that isn't valid says so, and the members that have no rate in common too")
    func notValid() {
        var g = group()
        g.clockLeaderUID = "nobody"
        let rows = GroupOutputRows.rows(groups: [g], devices: [device("fosi", "Fosi ZD3", id: 1), device("fiio", "FiiO K11", id: 2)])
        #expect(!rows[0].isReady && rows[0].detail.hasPrefix("NEEDS ATTENTION · "))
    }

    @Test("The rows keep the groups' order, and the UID is the one the engine chooses by")
    func uids() {
        let a = group("A"), b = group("B")
        let rows = GroupOutputRows.rows(groups: [a, b], devices: [])
        #expect(rows.map(\.name) == ["A", "B"] && rows.map(\.uid) == [a.outputUID, b.outputUID])
    }

    @Test("The signal path lists every DAC of the group with what reaches it")
    func memberLines() {
        let source = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 96_000, bitDepth: 24, channels: 4)
        func member(_ name: String, leader: Bool, resampled: Bool, _ roles: [SpeakerRole]) -> GroupSignalPath.Member {
            GroupSignalPath.Member(deviceUID: name, name: name, isLeader: leader, resampled: resampled, speakers: roles, sampleRate: 96_000,
                                   physicalBitDepth: 32, physicalIsInteger: true, physicalFormatKnown: true, exclusive: true, otherAppsPlaying: false)
        }
        let path = GroupSignalPath(groupName: "Downstairs quad", source: source, folds: false, dsdConvertedToPCM: false, stage: .none,
                                   members: [member("Fosi ZD3", leader: true, resampled: false, [.frontLeft, .frontRight]),
                                             member("FiiO K11", leader: false, resampled: true, [.backLeft, .backRight])])
        let lines = GroupOutputRows.signalPathLines(path)
        #expect(lines.map(\.title) == ["Fosi ZD3", "FiiO K11"])
        #expect(lines[0].value == "bit-perfect" && lines[0].isUntouched)
        #expect(lines[1].value == "resampled" && !lines[1].isUntouched)
        #expect(lines[0].detail == "FL FR · clock leader" && lines[1].detail == "BL BR · follows Fosi ZD3, resampled to stay in step")
    }
}
