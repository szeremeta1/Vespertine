import Foundation
import Testing
import VespertineAudio
@testable import Vespertine

/// The Identify buttons of a speaker group's channel map: no tone while the group's own output is in use, and a DAC that is not
/// connected says so instead of playing anywhere.
@Suite("Group identify buttons") @MainActor
struct GroupIdentifierTests {
    private func group() -> SpeakerGroup {
        let a = SpeakerGroup.Member(deviceUID: "no-such-dac-a-\(UUID())", name: "Fosi ZD3", channelCount: 2)
        let b = SpeakerGroup.Member(deviceUID: "no-such-dac-b-\(UUID())", name: "FiiO K11", channelCount: 2)
        return SpeakerGroup(name: "Dorm", members: [a, b], clockLeaderUID: a.deviceUID)
    }

    @Test("While the group's output is in use nothing plays and the reason is given")
    func refused() throws {
        let g = group()
        let row = try #require(GroupChannelMap.rows(g).first)
        let identifier = GroupIdentifier()
        identifier.identify(row, in: g, outputInUseUID: g.outputUID)
        #expect(identifier.playing == nil && identifier.problem?.contains("Stop playback") == true)
    }

    @Test("A DAC that is not connected plays nothing and is named")
    func notConnected() throws {
        let g = group()
        let row = try #require(GroupChannelMap.rows(g).last)
        let identifier = GroupIdentifier()
        identifier.identify(row, in: g, outputInUseUID: nil)
        #expect(identifier.playing == nil && identifier.problem?.contains("FiiO K11") == true)
        identifier.stop()
        #expect(identifier.problem == nil)
    }
}
