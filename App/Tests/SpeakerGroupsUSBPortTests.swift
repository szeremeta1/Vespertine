import Foundation
import Testing
import VespertineAudio
@testable import Vespertine

/// A DAC plugged into another USB port has another UID. The groups model saves the group with the UIDs of the ports it is on now,
/// so the group is found again after a restart, and tells the engine at once.
@Suite("Speaker Groups on another USB port", .serialized) @MainActor
struct SpeakerGroupsUSBPortTests {
    private let zd3Old = "AppleUSBAudioEngine:Fosi Audio:Fosi Audio ZD3:1100000:1", zd3New = "AppleUSBAudioEngine:Fosi Audio:Fosi Audio ZD3:2142200:1"
    private let k11Old = "AppleUSBAudioEngine:FIIO:FiiO K11:140000:2", k11New = "AppleUSBAudioEngine:FIIO:FiiO K11:2144400:2"

    @Test("The group is saved with the new UIDs, written to its file, and the engine is told once")
    func savedAndTold() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-usbport-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SpeakerGroupsModel(directory: root)
        let group = SpeakerGroup(name: "Bar 118", members: [SpeakerGroup.Member(deviceUID: zd3Old, name: "Fosi ZD3", channelCount: 2),
                                                          SpeakerGroup.Member(deviceUID: k11Old, name: "FiiO K11", channelCount: 2)],
                                 clockLeaderUID: k11Old)
        model.upsert(group)
        var told = 0
        model.onChange = { told += 1 }
        let present = [zd3New, k11New]
        model.followUSBPorts(amongUIDs: present)
        #expect(model.groups.first?.members.map(\.deviceUID) == [zd3New, k11New])
        #expect(model.groups.first?.clockLeaderUID == k11New)
        #expect(model.groups.first?.id == group.id)
        #expect(told == 1)
        model.followUSBPorts(amongUIDs: present)
        #expect(told == 1, "nothing changed the second time: nothing written, nobody told")
        #expect(SpeakerGroupsModel(directory: root).groups.first?.members.map(\.deviceUID) == [zd3New, k11New], "it is in the file")
    }
}
