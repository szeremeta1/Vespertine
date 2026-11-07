//
// Vespertine — speaker groups: a speaker's own level trim, played. Held in the same chain as the delays (a level per output
// channel ahead of the bands), so it lands once whether the group plays with a measured profile, the drawing's or none.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group level trims")
struct GroupLevelTrimTests {
    private func quad(trims: [Double]) -> SpeakerGroup {
        var group = GroupFixtures.quad()
        for (i, trim) in trims.enumerated() { group.speakers[i].trimDB = trim }
        return group
    }

    @Test("Each aggregate channel's level is the trim of the speaker on it; a channel with no speaker has none")
    func perChannel() {
        #expect(GroupDelay.perChannelLevelDB(quad(trims: [0, -2, -4, -6])) == [0, -2, -4, -6])
        var group = quad(trims: [-1, -1, -1, -1])
        group.members[1].channelCount = 3
        #expect(GroupDelay.perChannelLevelDB(group) == [-1, -1, -1, -1, 0])
    }

    @Test("Held to what the chain takes (-30 to +12 dB), and a number that isn't one is no trim")
    func clamped() {
        #expect(GroupDelay.perChannelLevelDB(quad(trims: [-40, 12, 20, .nan])) == [-30, 12, 12, 0])
    }

    @Test("No trims and no delays: no chain; trims alone make a chain of levels, with no timing")
    func chainOfItsOwn() {
        #expect(GroupDelay.composing(nil, delaysMs: [0, 0, 0, 0], levelsDB: [0, 0, 0, 0], name: "x") == nil)
        let chain = GroupDelay.composing(nil, delaysMs: [0, 0, 0, 0], levelsDB: [0, -3, 0, 0], name: "Dorm quad")
        #expect(chain?.channels.map(\.levelDB) == [0, -3, 0, 0] && chain?.channels.map(\.delayMs) == [0, 0, 0, 0])
        #expect(chain?.changesOnlyTiming(channels: 0..<4) == false)
        #expect(chain?.changesOnlyTiming(channels: [0, 2, 3]) == true, "an output with no trim on it is not changed")
    }

    @Test("With a room correction the trims add to its levels, and its delays, bands and preamp stay")
    func addedToRoom() {
        let band = EQBand(kind: .peak, frequency: 100, gainDB: -3, q: 1)
        let room = RoomCorrectionPlayback(profileID: UUID(), name: "Room", preampDB: -2,
                                          channels: [RoomChannelPlayback(delayMs: 3, levelDB: -1, bands: [band]), RoomChannelPlayback(delayMs: 0)])
        let chain = GroupDelay.composing(room, delaysMs: [0, 0, 0, 0], levelsDB: [-2, 0, -4, 0], name: "Dorm quad")
        #expect(chain?.name == "Room" && chain?.preampDB == -2)
        #expect(chain?.channels.map(\.levelDB) == [-3, 0, -4, 0])
        #expect(chain?.channels[0].delayMs == 3 && chain?.channels[0].bands == [band])
    }

    @Test("Delays alone still compose as before")
    func delaysAlone() {
        let chain = GroupDelay.composing(nil, delaysMs: [5, 5, 0, 0], name: "Dorm quad")
        #expect(chain?.channels.map(\.delayMs) == [5, 5, 0, 0] && chain?.channels.allSatisfy { $0.levelDB == 0 } == true)
    }

    @Test("In the signal path: a trim on an output that carries music changes the samples; on one that stays silent it does not")
    func stage() {
        let used = GroupDelay.composing(nil, delaysMs: [0, 0, 0, 0], levelsDB: [0, -3, 0, 0], name: "x")
        #expect(GroupSignalPath.stage(room: used, used: [0, 1], equalizer: false, digitalVolumeDB: nil, replayGainDB: nil) == .roomCorrection)
        let unused = GroupDelay.composing(nil, delaysMs: [0, 0, 0, 0], levelsDB: [0, 0, -3, -3], name: "x")
        #expect(GroupSignalPath.stage(room: unused, used: [0, 1], equalizer: false, digitalVolumeDB: nil, replayGainDB: nil) == .none)
    }

    @Test("The editor says the level trims are played")
    func note() {
        #expect(GroupPolicies.playedToday.contains("level trims"))
        #expect(!GroupPolicies.playedToday.contains("Level trims and polarity are saved"))
    }
}
