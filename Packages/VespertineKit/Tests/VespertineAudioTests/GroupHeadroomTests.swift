//
// Vespertine — speaker groups: the headroom guard. A positive level trim (up to +12 dB) on a speaker could push a loud song past full
// scale; the shared preamp of the group's chain is lowered so that no channel's peak (its level plus the top of its bands) can
// rise above 0 dB. The other channels come down with it, so the balance the trims ask for holds.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group headroom guard")
struct GroupHeadroomTests {
    /// The loudest any channel of `chain` can get when the input is at full scale, in dB (what its I/O gain is, plus the top of its bands).
    private func loudestDB(_ chain: RoomCorrectionPlayback, rate: Double = 48_000) -> Double {
        let gains = chain.renderChannels(sampleRate: rate, channelCount: chain.channels.count)
        return zip(gains, chain.channels).map { render, channel in
            20 * log10(Double(render.gain)) + EQPreset(name: "", bands: channel.bands).peakDB(sampleRate: rate)
        }.max() ?? 0
    }

    @Test("A positive trim lowers the shared preamp by that much, so the loudest channel peaks at 0 dB")
    func plusSix() throws {
        let chain = try #require(GroupDelay.composing(nil, delaysMs: [0, 0, 0, 0], levelsDB: [6, 0, 0, 0], name: "Dorm quad"))
        #expect(chain.preampDB == -6)
        #expect(chain.channels.map(\.levelDB) == [6, 0, 0, 0], "the trims themselves are as asked: the balance holds")
        #expect(loudestDB(chain) <= 0.0001)
    }

    @Test("The largest trim sets it: +12 and +3 on two speakers leave -12 dB, rounded so it is never short")
    func largestWins() throws {
        let chain = try #require(GroupDelay.composing(nil, delaysMs: [0, 0, 0, 0], levelsDB: [3.04, 0, 12, -4], name: "x"))
        #expect(chain.preampDB == -12)
        let rounded = try #require(GroupDelay.composing(nil, delaysMs: [0, 0, 0, 0], levelsDB: [3.04, 0, 0, 0], name: "x"))
        #expect(rounded.preampDB == -3.1)
    }

    @Test("Cuts and zero trims need no headroom: the preamp stays 0 and the chain is as before")
    func cutsAlone() throws {
        let chain = try #require(GroupDelay.composing(nil, delaysMs: [0, 0, 0, 0], levelsDB: [0, -3, -6, 0], name: "x"))
        #expect(chain.preampDB == 0)
    }

    @Test("A room correction that already leaves enough room keeps its preamp; one that does not is lowered further")
    func withRoom() throws {
        let cut = RoomCorrectionPlayback(profileID: UUID(), name: "Room", preampDB: -8, channels: [RoomChannelPlayback(), RoomChannelPlayback()])
        let kept = try #require(GroupDelay.composing(cut, delaysMs: [0, 0, 0, 0], levelsDB: [6, 0, 0, 0], name: "x"))
        #expect(kept.preampDB == -8, "-8 dB already covers +6")
        let lowered = try #require(GroupDelay.composing(cut, delaysMs: [0, 0, 0, 0], levelsDB: [10, 0, 0, 0], name: "x"))
        #expect(lowered.preampDB == -10)
    }

    @Test("The top of a channel's bands counts with its trim: +4 dB trim on a channel with a +3 dB boost needs 7 dB, plus the design margin")
    func bandsCount() throws {
        let boost = EQBand(kind: .peak, frequency: 1_000, gainDB: 3, q: 1)
        let room = RoomCorrectionPlayback(profileID: UUID(), name: "Room", preampDB: -3.5,
                                          channels: [RoomChannelPlayback(bands: [boost]), RoomChannelPlayback()])
        let chain = try #require(GroupDelay.composing(room, delaysMs: [0, 0, 0, 0], levelsDB: [4, 0, 0, 0], name: "x"))
        #expect(chain.preampDB < -7 && chain.preampDB >= -8)
        #expect(loudestDB(chain) <= 0.0001)
        let notLoud = try #require(GroupDelay.composing(room, delaysMs: [0, 0, 0, 0], levelsDB: [0, -2, 0, 0], name: "x"))
        #expect(notLoud.preampDB == -3.5, "no boost from a trim: the profile's own preamp stands")
    }

    @Test("A trim that is not a number or past the limit is held to what the chain takes before it is counted")
    func clampedBeforeCounting() throws {
        var rendered = RoomCorrectionPlayback(profileID: UUID(), name: "x", preampDB: 0, channels: [RoomChannelPlayback(levelDB: 40)])
        rendered = rendered.withHeadroom()
        #expect(rendered.preampDB == -12)
        let nan = RoomCorrectionPlayback(profileID: UUID(), name: "x", preampDB: 0, channels: [RoomChannelPlayback(levelDB: .nan)]).withHeadroom()
        #expect(nan.preampDB == 0)
    }

    @Test("Every chain the engine builds for a group goes through the guard, and a plain room correction is not touched")
    func engineEntry() {
        var group = GroupFixtures.quad()
        group.speakers[1].trimDB = 9
        let chain = GroupDelay.chain(nil, group: group)
        #expect(chain?.preampDB == -9)
        let room = RoomCorrectionPlayback(profileID: UUID(), name: "Room", preampDB: 0, channels: [RoomChannelPlayback(levelDB: 5)])
        group.speakers[1].trimDB = 0
        #expect(GroupDelay.chain(room, group: group) == room, "nothing to add: the profile as chosen, even with its own boost")
    }
}
