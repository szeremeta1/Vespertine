//
// Vespertine: speaker groups: polarity played. A speaker marked inverted has its signal turned over (every sample's sign flipped) in the
// room correction chain the I/O thread already runs, so it lands once whichever profile the group plays with.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CVespertineRT
import Foundation
import Testing
@testable import VespertineAudio

private func render(_ input: [Float], channels: UInt32 = 2, setUp: (OpaquePointer) -> Void) -> [Float] {
    let frames = UInt32(input.count) / channels
    let ring = nrt_ring_create(UInt32(max(16_384, 2 * Int(frames))), channels)!
    let context = nrt_context_create(ring, 512)!
    defer { nrt_context_destroy(context); nrt_ring_destroy(ring) }
    nrt_context_set_gain(context, 1, 32)
    setUp(context)
    #expect(nrt_ring_write(ring, input, frames) == frames)
    var out = [Float](repeating: 0, count: input.count)
    nrt_context_render_interleaved(context, &out, frames, channels)
    return out
}

@Suite("Group polarity")
struct GroupPolarityTests {
    private func inverted(_ flags: [Bool]) -> SpeakerGroup {
        var group = GroupFixtures.quad()
        for (i, flag) in flags.enumerated() { group.speakers[i].invertPolarity = flag }
        return group
    }

    @Test("Through the real I/O-thread code: the inverted channel's samples change sign, the other's are bit for bit the same")
    func signFlip() {
        let chain = RoomCorrectionPlayback(profileID: UUID(), name: "x", preampDB: 0,
                                           channels: [RoomChannelPlayback(inverted: true), RoomChannelPlayback()])
        let input: [Float] = (0..<256).flatMap { i -> [Float] in [Float(sin(Double(i) * 0.3)) * 0.5, Float(cos(Double(i) * 0.2)) * 0.25] }
        let out = render(input) { RoomCorrectionPlayback.install(chain, on: $0, sampleRate: 48_000, channelCount: 2) }
        for f in 0..<256 {
            #expect(out[2 * f] == -input[2 * f], "frame \(f)")
            #expect(out[2 * f + 1] == input[2 * f + 1])
        }
    }

    @Test("With a level and a delay the flip is the same turned-over signal: -6 dB and 1 ms late, upside down")
    func withLevelAndDelay() {
        let chain = RoomCorrectionPlayback(profileID: UUID(), name: "x", preampDB: 0,
                                           channels: [RoomChannelPlayback(delayMs: 1, levelDB: -6.020599913279624, inverted: true), RoomChannelPlayback()])
        var input = [Float](repeating: 0, count: 2 * 256)
        input[0] = 1; input[1] = 1
        let out = render(input) { RoomCorrectionPlayback.install(chain, on: $0, sampleRate: 48_000, channelCount: 2) }
        #expect(abs(out[2 * 48] - -0.5) < 1e-6 && out[0] == 0)
        #expect(out[1] == 1)
    }

    @Test("With bands the response is the same turned over: the output is minus what it would have been")
    func withBands() {
        let band = EQBand(kind: .peak, frequency: 1_000, gainDB: -6, q: 1)
        func chain(_ flip: Bool) -> RoomCorrectionPlayback {
            RoomCorrectionPlayback(profileID: UUID(), name: "x", preampDB: 0, channels: [RoomChannelPlayback(bands: [band], inverted: flip)])
        }
        let input: [Float] = (0..<4096).map { Float(0.25 * sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
        let plain = render(input, channels: 1) { RoomCorrectionPlayback.install(chain(false), on: $0, sampleRate: 48_000, channelCount: 1) }
        let flipped = render(input, channels: 1) { RoomCorrectionPlayback.install(chain(true), on: $0, sampleRate: 48_000, channelCount: 1) }
        #expect(zip(plain, flipped).allSatisfy { $0 == -$1 })
    }

    @Test("A flipped channel is a change to the samples: not just timing, and not a flat chain")
    func notTimingOnly() {
        let chain = RoomCorrectionPlayback(profileID: UUID(), name: "x", preampDB: 0, channels: [RoomChannelPlayback(inverted: true), RoomChannelPlayback()])
        #expect(!chain.isFlat)
        #expect(!chain.changesOnlyTiming(channels: [0, 1]))
        #expect(chain.changesOnlyTiming(channels: [1]), "an output that stays as the file has it is still bit-perfect")
        #expect(RoomChannelPlayback(inverted: true).isActive)
    }

    @Test("Each aggregate channel's polarity is that of the speaker on it; a channel with no speaker is not flipped")
    func perChannel() {
        #expect(GroupDelay.perChannelInverted(inverted([false, true, false, true])) == [false, true, false, true])
        var group = inverted([true, true, true, true])
        group.members[1].channelCount = 3
        #expect(GroupDelay.perChannelInverted(group) == [true, true, true, true, false])
    }

    @Test("The group's chain carries the flips alone, or on top of a room correction, whose own channels are not turned back")
    func composed() throws {
        let alone = try #require(GroupDelay.chain(nil, group: inverted([false, true, false, false])))
        #expect(alone.channels.map(\.inverted) == [false, true, false, false] && alone.preampDB == 0)
        let room = RoomCorrectionPlayback(profileID: UUID(), name: "Room", preampDB: -2, channels: [RoomChannelPlayback(levelDB: -1), RoomChannelPlayback(delayMs: 3)])
        let both = try #require(GroupDelay.chain(room, group: inverted([true, false, false, false])))
        #expect(both.channels.map(\.inverted) == [true, false, false, false] && both.preampDB == -2)
        #expect(both.channels[0].levelDB == -1 && both.channels[1].delayMs == 3)
        #expect(GroupDelay.chain(nil, group: inverted([false, false, false, false])) == nil)
    }

    @Test("In the signal path: a flip on an output that carries music changes the samples; on one that stays silent it does not")
    func stage() {
        let chain = GroupDelay.chain(nil, group: inverted([false, true, false, false]))
        #expect(GroupSignalPath.stage(room: chain, used: [0, 1], equalizer: false, digitalVolumeDB: nil, replayGainDB: nil) == .roomCorrection)
        #expect(GroupSignalPath.stage(room: chain, used: [0], equalizer: false, digitalVolumeDB: nil, replayGainDB: nil) == .none)
    }

    @Test("The editor says polarity is played")
    func note() {
        #expect(GroupPolicies.playedToday.contains("polarity") && !GroupPolicies.playedToday.contains("not applied"))
    }
}
