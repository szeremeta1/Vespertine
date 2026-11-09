//
// Vespertine — speaker groups: the delay of each speaker in the room correction chain. macOS 27 takes a sub-device's extra output
// latency without error and reads 0 back, so a measured skew between the DACs is held back in Vespertine instead: the members that
// are ahead wait for the one that is latest, and a speaker's own delay trim adds to its channel. Pure; no device.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group delay")
struct GroupDelayTests {
    private let fosi = "fosi-uid", fiio = "fiio-uid"

    private func group(leaderSkew: Double = 0, followerSkew: Double = 0, trims: [Double] = [0, 0, 0, 0]) -> SpeakerGroup {
        func speaker(_ role: SpeakerRole, _ uid: String, _ channel: Int, _ x: Double, _ y: Double, _ trim: Double) -> SpeakerGroup.Speaker {
            SpeakerGroup.Speaker(role: role, deviceUID: uid, channel: channel, position: Point2D(x: x, y: y), delayTrimMs: trim)
        }
        return SpeakerGroup(name: "Downstairs quad",
                            members: [SpeakerGroup.Member(deviceUID: fosi, name: "Fosi ZD3", channelCount: 2, skewMs: leaderSkew),
                                      SpeakerGroup.Member(deviceUID: fiio, name: "FiiO K11", channelCount: 2, skewMs: followerSkew)],
                            clockLeaderUID: fosi,
                            speakers: [speaker(.frontLeft, fosi, 0, -1, 1.5, trims[0]), speaker(.frontRight, fosi, 1, 1, 1.5, trims[1]),
                                       speaker(.sideLeft, fiio, 0, -2, 0, trims[2]), speaker(.sideRight, fiio, 1, 2, 0, trims[3])])
    }

    // MARK: The measured skew in the model

    @Test("A member's measured skew is saved with the group; a group saved before it was there has none")
    func skewCoding() throws {
        let saved = try SpeakerGroupCoding.decode(SpeakerGroupCoding.encode(group(followerSkew: 12.95)))
        #expect(saved.members[1].skewMs == 12.95 && saved.members[0].skewMs == 0)
        var json = try #require(JSONSerialization.jsonObject(with: SpeakerGroupCoding.encode(group(followerSkew: 5))) as? [String: Any])
        var members = try #require(json["members"] as? [[String: Any]])
        for i in members.indices { members[i].removeValue(forKey: "skewMs") }
        json["members"] = members
        let old = try SpeakerGroupCoding.decode(JSONSerialization.data(withJSONObject: json))
        #expect(old.members.allSatisfy { $0.skewMs == 0 })
    }

    @Test("A skew must be a delay the chain can hold: 0 to 40 ms, and a number")
    func skewValidation() {
        #expect(group(followerSkew: 12.95).isValid && group(followerSkew: 40).isValid)
        #expect(group(followerSkew: -1).issues == [.skewInvalid(fiio)])
        #expect(group(followerSkew: 41).issues == [.skewInvalid(fiio)])
        #expect(group(leaderSkew: .nan).issues == [.skewInvalid(fosi)])
        #expect(group(followerSkew: 5).issues.isEmpty)
    }

    // MARK: Per channel

    @Test("No skew and no trims: no delay anywhere")
    func none() {
        #expect(GroupDelay.perChannelMs(group()) == [0, 0, 0, 0])
        #expect(!GroupDelay.isNeeded(group()))
    }

    @Test("The follower sounds 5 ms late: the leader's pair waits 5 ms, the follower's none")
    func followerLate() {
        #expect(GroupDelay.perChannelMs(group(followerSkew: 5)) == [5, 5, 0, 0])
        #expect(GroupDelay.isNeeded(group(followerSkew: 5)))
    }

    @Test("Skews are against each other: the latest member waits for nobody")
    func latestWaitsForNobody() {
        #expect(GroupDelay.perChannelMs(group(leaderSkew: 3, followerSkew: 5)) == [2, 2, 0, 0])
        #expect(GroupDelay.perChannelMs(group(leaderSkew: 5, followerSkew: 3)) == [0, 0, 2, 2])
    }

    @Test("A speaker's own delay trim adds to its channel, on top of the skew")
    func trims() {
        #expect(GroupDelay.perChannelMs(group(followerSkew: 5, trims: [1.5, 0, 0, 2])) == [6.5, 5, 0, 2])
    }

    @Test("Never more than the chain holds: 40 ms a channel")
    func clamped() {
        #expect(GroupDelay.perChannelMs(group(followerSkew: 40, trims: [10, 0, 0, 0])) == [40, 40, 0, 0])
    }

    @Test("A channel with no speaker still gets its member's skew; the list covers every channel of the group")
    func unassigned() {
        var bare = group(followerSkew: 5)
        bare.speakers = []
        #expect(GroupDelay.perChannelMs(bare) == [5, 5, 0, 0])
    }

    // MARK: In the room chain

    @Test("With no room correction the delays are a chain of their own, timing only; with none to hold back, no chain")
    func chainOfItsOwn() {
        #expect(GroupDelay.composing(nil, delaysMs: [0, 0, 0, 0], name: "x") == nil)
        let chain = GroupDelay.composing(nil, delaysMs: [5, 5, 0, 0], name: "Downstairs quad")
        #expect(chain?.channels.map(\.delayMs) == [5, 5, 0, 0])
        #expect(chain?.changesOnlyTiming(channels: 0..<4) == true)
        #expect(chain?.preampDB == 0)
    }

    @Test("With a room correction the delays add to its own, and its levels, bands and preamp stay")
    func addedToRoom() {
        let band = EQBand(kind: .peak, frequency: 100, gainDB: -3, q: 1)
        let room = RoomCorrectionPlayback(profileID: UUID(), name: "Room", preampDB: -2,
                                          channels: [RoomChannelPlayback(delayMs: 3, levelDB: -1, bands: [band]), RoomChannelPlayback(delayMs: 0)])
        let chain = GroupDelay.composing(room, delaysMs: [5, 5, 0, 0], name: "Downstairs quad")
        #expect(chain?.name == "Room" && chain?.preampDB == -2 && chain?.profileID == room.profileID)
        #expect(chain?.channels.map(\.delayMs) == [8, 5, 0, 0], "extended to the group's channels")
        #expect(chain?.channels[0].levelDB == -1 && chain?.channels[0].bands == [band])
        #expect(chain?.channels[2].levelDB == 0)
    }

    @Test("A measured skew like 12.95 ms is whole frames in the chain: 622 at 48 kHz, 1243 at 96 kHz")
    func wholeFrames() throws {
        let chain = try #require(GroupDelay.composing(nil, delaysMs: [12.95, 12.95, 0, 0], name: "Downstairs quad"))
        #expect(chain.renderChannels(sampleRate: 48_000, channelCount: 4).map(\.delayFrames) == [622, 622, 0, 0])
        #expect(chain.renderChannels(sampleRate: 96_000, channelCount: 4).map(\.delayFrames) == [1243, 1243, 0, 0])
        // The chain's delay is held at the end of the queue: what the engine plays out.
        #expect(abs(chain.maxDelaySeconds - 0.01295) < 1e-9)
    }
}
