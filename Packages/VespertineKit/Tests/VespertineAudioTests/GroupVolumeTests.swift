//
// Vespertine — speaker groups: volume. A group's output is a private aggregate that has no volume of its own, so the volume keys
// relay and the "make it the Mac's sound output" step must never be pointed at it; each DAC's own volume is set once, by hand.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group volume")
struct GroupVolumeTests {
    private func device(uid: String, id: UInt32 = 77) -> OutputDevice {
        OutputDevice(id: id, uid: uid, name: uid, manufacturer: "", modelUID: nil, transport: .usb, nominalSampleRate: 48_000,
                     capabilities: DeviceCapabilities(sampleRates: [48_000], physicalFormats: [], outputChannels: 2, supportsDoP: false),
                     hasHardwareVolume: true, isDefault: false)
    }

    @Test("The volume-key relay follows an ordinary output when it is on, never a group's aggregate, never when off")
    func relay() {
        let dac = device(uid: "AppleUSBAudioEngine:Fosi:ZD3:1", id: 41)
        let group = device(uid: SpeakerGroup.outputUIDPrefix + "abc", id: 99)
        #expect(GroupVolume.relayTarget(for: dac, enabled: true) == 41)
        #expect(GroupVolume.relayTarget(for: group, enabled: true) == nil)
        #expect(GroupVolume.relayTarget(for: dac, enabled: false) == nil)
        #expect(GroupVolume.relayTarget(for: nil, enabled: true) == nil)
    }

    @Test("A group's aggregate is never made the Mac's sound output: it exists only in this app")
    func systemOutput() {
        #expect(GroupVolume.mayBecomeSystemOutput(device(uid: "some-dac")))
        #expect(!GroupVolume.mayBecomeSystemOutput(device(uid: SpeakerGroup.outputUIDPrefix + "abc")))
    }

    @Test("A level is held to 0...1, and a number that isn't one is none")
    func clamp() {
        #expect(GroupVolume.clamped(0.4) == 0.4 && GroupVolume.clamped(-1) == 0 && GroupVolume.clamped(7) == 1)
        #expect(GroupVolume.clamped(.nan) == nil && GroupVolume.clamped(.infinity) == nil)
    }

    @Test("A DAC that is not connected has no volume to read and none to set")
    func notConnected() {
        let uid = "no-such-dac-\(UUID())"
        #expect(GroupVolume.level(ofDeviceUID: uid) == nil)
        #expect(GroupVolume.setLevel(0.5, ofDeviceUID: uid) == false)
        var group = GroupFixtures.quad()
        group.members[0].deviceUID = uid
        group.members[1].deviceUID = "also-not-here-\(UUID())"
        let rows = GroupVolume.members(of: group)
        #expect(rows.map(\.name) == ["Fosi Audio ZD3", "FiiO K11"] && rows.allSatisfy { $0.level == nil })
    }

    @Test("What the editor says: the DACs' own volumes are set by hand, the trims and a master are digital")
    func note() {
        #expect(GroupVolume.note.contains("set once") && GroupVolume.note.contains("digital") && GroupVolume.note.contains("bit-perfect"))
    }
}
