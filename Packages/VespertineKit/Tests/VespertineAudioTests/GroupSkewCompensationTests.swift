//
// Vespertine — speaker groups: per-member compensation from a measured skew. The numbers are the hardware session of 2026-11-07 (Fosi ZD3
// leader, FiiO K11 follower, drift correction at quality 127, 48 kHz): the resampler adds 53.5 frames, and the follower falls behind the
// leader at +13.47 ppm. Pure; no device.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CVespertineRT
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group skew compensation")
struct GroupSkewCompensationTests {
    private let fosi = "fosi-uid", fiio = "fiio-uid"
    private let leaderSpeaker = UUID(), followerSpeaker = UUID()

    /// Fosi front pair, FiiO side pair. The seat is at the origin: front left at 1.803 m, side left at 2.000 m.
    private func group(followerSkew: Double = 0, context: SpeakerGroup.Member.SkewContext? = nil, rateTrim: Double = 0, quality: Int = 127,
                       sideLeft: Point2D = Point2D(x: -2, y: 0)) -> SpeakerGroup {
        SpeakerGroup(name: "Dorm quad",
                     members: [SpeakerGroup.Member(deviceUID: fosi, name: "Fosi ZD3", channelCount: 2),
                               SpeakerGroup.Member(deviceUID: fiio, name: "FiiO K11", channelCount: 2, skewMs: followerSkew, skewContext: context, rateTrimPPM: rateTrim, driftQuality: quality)],
                     clockLeaderUID: fosi,
                     speakers: [SpeakerGroup.Speaker(id: leaderSpeaker, role: .frontLeft, deviceUID: fosi, channel: 0, position: Point2D(x: -1, y: 1.5)),
                                SpeakerGroup.Speaker(role: .frontRight, deviceUID: fosi, channel: 1, position: Point2D(x: 1, y: 1.5)),
                                SpeakerGroup.Speaker(id: followerSpeaker, role: .sideLeft, deviceUID: fiio, channel: 0, position: sideLeft),
                                SpeakerGroup.Speaker(role: .sideRight, deviceUID: fiio, channel: 1, position: Point2D(x: 2, y: 0))])
    }

    private var resampledFiio: Set<String> { [fiio] }

    // MARK: The resampler's delay, which is certain

    @Test("A drift-corrected follower with no measurement is held back by the resampler's measured 53.5 frames: the leader waits 1.115 ms")
    func resamplerDelay() {
        let delays = GroupDelay.perChannelMs(group(), resampled: resampledFiio)
        #expect(delays.count == 4)
        #expect(abs(delays[0] - 53.5 / 48) < 1e-9 && abs(delays[1] - 53.5 / 48) < 1e-9)
        #expect(delays[2] == 0 && delays[3] == 0)
        #expect(abs(53.5 / 48 - 1.1146) < 1e-4)
    }

    @Test("Nothing is guessed: no drift correction, an unknown plan or another quality add no delay")
    func nothingGuessed() {
        #expect(GroupDelay.perChannelMs(group(), resampled: []) == [0, 0, 0, 0])
        #expect(GroupDelay.perChannelMs(group()) == [0, 0, 0, 0])
        #expect(GroupDelay.perChannelMs(group(quality: 64), resampled: resampledFiio) == [0, 0, 0, 0])
    }

    @Test("The resampler's delay is a number of frames: half as long in ms at 96 kHz (unverified there)")
    func resamplerAtOtherRates() {
        #expect(abs(GroupSkewCompensation.resamplerDelayMs(driftQuality: 127, rate: 96_000) - 53.5 / 96) < 1e-9)
        #expect(GroupSkewCompensation.resamplerDelayMs(driftQuality: 127, rate: 0) == 0)
    }

    @Test("A skew typed in without a context keeps its number and gets the resampler's delay on top")
    func typedInSkew() {
        let delays = GroupDelay.perChannelMs(group(followerSkew: 5), resampled: resampledFiio)
        #expect(abs(delays[0] - (5 + 53.5 / 48)) < 1e-9)
        #expect(GroupDelay.perChannelMs(group(followerSkew: 5)) == [5, 5, 0, 0])
    }

    // MARK: A measured skew and the settings it was measured under

    private let ctx = SpeakerGroup.Member.SkewContext(driftCorrected: true, driftQuality: 127, sampleRate: 48_000)

    @Test("A skew measured with drift correction on already holds the resampler's delay: it is used as it is, not added to")
    func measuredHoldsResampler() {
        #expect(GroupDelay.perChannelMs(group(followerSkew: 12.5, context: ctx), resampled: resampledFiio) == [12.5, 12.5, 0, 0])
    }

    @Test("A skew measured under other settings is not used: only the certain part is")
    func staleSkew() {
        let off = SpeakerGroup.Member.SkewContext(driftCorrected: false, driftQuality: 127, sampleRate: 48_000)
        let delays = GroupDelay.perChannelMs(group(followerSkew: 12.0, context: off), resampled: resampledFiio)
        #expect(abs(delays[0] - 53.5 / 48) < 1e-9)
        var other = ctx; other.driftQuality = 64
        #expect(abs(GroupDelay.perChannelMs(group(followerSkew: 12.5, context: other), resampled: resampledFiio)[0] - 53.5 / 48) < 1e-9)
        var rate = ctx; rate.sampleRate = 96_000
        #expect(abs(GroupDelay.perChannelMs(group(followerSkew: 12.5, context: rate), resampled: resampledFiio)[0] - 53.5 / 48) < 1e-9)
        // Measured corrected, now run uncorrected (the DACs share a clock): the measured number includes a resampler that is gone.
        #expect(GroupDelay.perChannelMs(group(followerSkew: 12.5, context: ctx), resampled: []) == [0, 0, 0, 0])
        // Plan not known: the saved number stands.
        #expect(GroupDelay.perChannelMs(group(followerSkew: 12.5, context: ctx)) == [12.5, 12.5, 0, 0])
    }

    @Test("The context and the rate trim are saved with the group; a group saved before has neither")
    func coding() throws {
        let saved = try SpeakerGroupCoding.decode(SpeakerGroupCoding.encode(group(followerSkew: 12.5, context: ctx, rateTrim: 13.5)))
        #expect(saved.members[1].skewContext == ctx && saved.members[1].rateTrimPPM == 13.5)
        #expect(saved.members[0].skewContext == nil && saved.members[0].rateTrimPPM == 0)
        var json = try #require(JSONSerialization.jsonObject(with: SpeakerGroupCoding.encode(group(followerSkew: 5, context: ctx, rateTrim: 3))) as? [String: Any])
        var members = try #require(json["members"] as? [[String: Any]])
        for i in members.indices { members[i].removeValue(forKey: "skewContext"); members[i].removeValue(forKey: "rateTrimPPM") }
        json["members"] = members
        let old = try SpeakerGroupCoding.decode(JSONSerialization.data(withJSONObject: json))
        #expect(old.members.allSatisfy { $0.skewContext == nil && $0.rateTrimPPM == 0 })
    }

    @Test("A rate trim must be a number within ±200 ppm")
    func rateTrimValidation() {
        #expect(group(rateTrim: 13.5).isValid && group(rateTrim: -200).isValid)
        #expect(group(rateTrim: 201).issues == [.rateTrimInvalid(fiio)])
        #expect(group(rateTrim: .nan).issues == [.rateTrimInvalid(fiio)])
    }

    // MARK: From a measurement to the member

    @Test("The wizard's number: 628.6 frames at 48 kHz is 13.10 ms at the mic; the speakers' 0.575 ms of extra path is taken off, 12.52 ms is kept")
    func applyTakesTheAcousticTermOff() throws {
        let result = try #require(GroupSkewCompensation.apply(measuredFrames: 628.56, rate: 48_000, to: group(), followerUID: fiio,
                                                              leaderSpeaker: leaderSpeaker, followerSpeaker: followerSpeaker, corrected: true))
        #expect(abs(result.measuredMs - 13.095) < 1e-3)
        let acoustic = try #require(result.acousticMs)
        let farther: Double = 2.0 - (1.0 + 2.25).squareRoot()
        #expect(abs(acoustic - farther / 343 * 1000) < 1e-9)
        #expect(abs(acoustic - 0.575) < 1e-3)
        let follower = result.group.members[1]
        #expect(abs(follower.skewMs - 12.520) < 1e-3)
        #expect(follower.skewContext == ctx)
        #expect(result.group.members[0].skewMs == 0)
        // And that is exactly what the chain then holds: the leader waits the electronic skew, the geometry is not in it twice.
        #expect(abs(GroupDelay.perChannelMs(result.group, resampled: resampledFiio)[0] - 12.520) < 1e-3)
    }

    @Test("Without distances in the drawing (a speaker at the seat) the whole number is kept, and the result says it was not subtracted")
    func applyWithoutDistances() throws {
        let result = try #require(GroupSkewCompensation.apply(measuredFrames: 628.56, rate: 48_000, to: group(sideLeft: Point2D(x: 0, y: 0)), followerUID: fiio,
                                                              leaderSpeaker: leaderSpeaker, followerSpeaker: followerSpeaker, corrected: true))
        #expect(result.acousticMs == nil)
        #expect(abs(result.group.members[1].skewMs - 13.095) < 1e-3)
    }

    @Test("A follower that sounds earlier than the leader (after the path) makes the leader the later one: nobody is advanced")
    func applyNegative() throws {
        let result = try #require(GroupSkewCompensation.apply(measuredFrames: 10, rate: 48_000, to: group(), followerUID: fiio,
                                                              leaderSpeaker: leaderSpeaker, followerSpeaker: followerSpeaker, corrected: true))
        // 0.208 ms measured, 0.575 ms of it path: the follower is 0.367 ms early electronically.
        #expect(result.group.members[1].skewMs == 0)
        #expect(abs(result.group.members[0].skewMs - 0.367) < 1e-3)
    }

    @Test("A follower measured earlier than the leader is held back by that much when it plays, as the leader never is resampled")
    func applyNegativePlays() throws {
        let result = try #require(GroupSkewCompensation.apply(measuredFrames: 10, rate: 48_000, to: group(), followerUID: fiio,
                                                              leaderSpeaker: leaderSpeaker, followerSpeaker: followerSpeaker, corrected: true))
        let delays = GroupDelay.perChannelMs(result.group, resampled: resampledFiio, rate: 48_000)
        #expect(delays[0] == 0 && delays[1] == 0, "the leader waits for nobody")
        #expect(abs(delays[2] - 0.367) < 1e-3 && abs(delays[3] - 0.367) < 1e-3, "the follower waits for the leader: \(delays)")
        // At another rate the measurement doesn't hold: only the certain part (the resampler's delay on the follower) is left.
        let other = GroupDelay.perChannelMs(result.group, resampled: resampledFiio, rate: 96_000)
        #expect(abs(other[0] - 53.5 / 96) < 1e-9 && other[2] == 0, "\(other)")
    }

    @Test("Only a follower can be measured, and the measurement must be a number")
    func applyRefusals() {
        #expect(GroupSkewCompensation.apply(measuredFrames: 600, rate: 48_000, to: group(), followerUID: fosi, leaderSpeaker: leaderSpeaker, followerSpeaker: followerSpeaker, corrected: true) == nil)
        #expect(GroupSkewCompensation.apply(measuredFrames: .nan, rate: 48_000, to: group(), followerUID: fiio, leaderSpeaker: leaderSpeaker, followerSpeaker: followerSpeaker, corrected: true) == nil)
        #expect(GroupSkewCompensation.apply(measuredFrames: 600, rate: 48_000, to: group(), followerUID: "nobody", leaderSpeaker: leaderSpeaker, followerSpeaker: followerSpeaker, corrected: true) == nil)
    }

    @Test("The measured rate trim is stored with the skew, within the range")
    func applyStoresRateTrim() throws {
        let result = try #require(GroupSkewCompensation.apply(measuredFrames: 628.56, rate: 48_000, to: group(), followerUID: fiio, leaderSpeaker: leaderSpeaker,
                                                              followerSpeaker: followerSpeaker, corrected: true, rateTrimPPM: 13.47))
        #expect(result.group.members[1].rateTrimPPM == 13.47)
        let wild = try #require(GroupSkewCompensation.apply(measuredFrames: 628.56, rate: 48_000, to: group(), followerUID: fiio, leaderSpeaker: leaderSpeaker,
                                                            followerSpeaker: followerSpeaker, corrected: true, rateTrimPPM: 900))
        #expect(wild.group.isValid && wild.group.members[1].rateTrimPPM == 200)
    }

    // MARK: The rate trim in the chain

    @Test("A follower creeping +13.5 ppm is brought forward at 13.5 ppm; every channel is held back 8.1 ms (+8 frames) at the start to give it room")
    func rateTrimInTheChain() {
        let g = group(followerSkew: 12.5, context: ctx, rateTrim: 13.5)
        #expect(GroupDelay.advancePPM(g, resampled: resampledFiio) == [0, 13.5])
        #expect(GroupDelay.perChannelAdvancePPM(g, resampled: resampledFiio) == [0, 0, 13.5, 13.5])
        let headroom = 13.5e-6 * 600 * 1000 + 8.0 / 48
        #expect(abs(GroupDelay.rateHeadroomMs(g, resampled: resampledFiio) - headroom) < 1e-9)
        let delays = GroupDelay.perChannelMs(g, resampled: resampledFiio)
        #expect(abs(delays[0] - (12.5 + headroom)) < 1e-9 && abs(delays[2] - headroom) < 1e-9)
        let chain = GroupDelay.chain(nil, group: g, resampled: resampledFiio)
        #expect(chain?.channels.map(\.advancePPM) == [0, 0, 13.5, 13.5])
        // What the real-time chain gets: the follower gives back 13.5 ppm × 600 s × 48 kHz = 388.8 frames of its 397.
        let rt = chain!.renderChannels(sampleRate: 48_000, channelCount: 4)
        #expect(rt[0].advancePPM == 0 && rt[0].advanceLimitFrames == 0)
        #expect(rt[2].advancePPM == 13.5 && abs(rt[2].advanceLimitFrames - 388.8) < 1e-6 && rt[2].delayFrames >= 389 + 8)
    }

    @Test("No trim, no headroom: a group without a measured rate holds nothing back for it")
    func noRateTrim() {
        let g = group(followerSkew: 12.5, context: ctx)
        #expect(GroupDelay.rateHeadroomMs(g, resampled: resampledFiio) == 0)
        #expect(GroupDelay.perChannelAdvancePPM(g, resampled: resampledFiio) == [0, 0, 0, 0])
        #expect(GroupDelay.chain(nil, group: g, resampled: resampledFiio)?.channels.allSatisfy { $0.advancePPM == 0 } == true)
    }

    @Test("A trim measured with drift correction on is not applied to a member that is not corrected now, or measured at another quality")
    func rateTrimOnlyWhereMeasured() {
        #expect(GroupDelay.advancePPM(group(context: ctx, rateTrim: 13.5), resampled: []) == [0, 0])
        var other = ctx; other.driftQuality = 64
        #expect(GroupDelay.advancePPM(group(context: other, rateTrim: 13.5), resampled: resampledFiio) == [0, 0])
        // Typed in without a context: it applies while the member is corrected, or when the plan is not known.
        #expect(GroupDelay.advancePPM(group(rateTrim: 13.5), resampled: resampledFiio) == [0, 13.5])
        #expect(GroupDelay.advancePPM(group(rateTrim: 13.5)) == [0, 13.5])
    }

    @Test("Two trimmed members are advanced against the slower one; a member that creeps the other way gets the headroom, not a ramp")
    func rateTrimRelative() {
        var g = group(rateTrim: 13.5)
        g.members[0].rateTrimPPM = 5     // the leader, never resampled, is not trimmed by itself
        #expect(GroupDelay.advancePPM(g, resampled: resampledFiio) == [0, 13.5])
        g.members[0].rateTrimPPM = 0
        g.members[1].rateTrimPPM = -4    // a follower that gets ahead of the leader: the leader is the one that creeps (relatively)
        #expect(GroupDelay.advancePPM(g, resampled: resampledFiio) == [4, 0])
    }

    // MARK: In the real-time chain

    private func render(_ input: [Float], channels: UInt32, setUp: (OpaquePointer) -> Void) -> [Float] {
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

    /// A 1 kHz tone on both channels, 0.25 peak.
    private func tone(frames: Int) -> [Float] {
        (0..<frames).flatMap { i -> [Float] in let v = Float(0.25 * sin(2 * Double.pi * 1_000 * Double(i) / 48_000)); return [v, v] }
    }

    @Test("A channel with a rate trim is read faster than it is written: its delay shrinks by the ppm, the other channel is a whole-frame copy")
    func realTimeRamp() {
        let frames = 40_000
        let ppm = 10_000.0                  // 1%: 400 frames over this render, large enough to see
        var left = NRTRoomChannel(), right = NRTRoomChannel()
        left.delayFrames = 1_000; left.gain = 1; left.advancePPM = ppm; left.advanceLimitFrames = 392
        right.delayFrames = 1_000; right.gain = 1
        let input = tone(frames: frames)
        let out = render(input, channels: 2) { context in
            var channels = [left, right]
            nrt_context_set_room(context, &channels, 2)
        }
        func delayAt(_ n: Int) -> Double { 1_000 - min(ppm * 1e-6 * Double(n), 392) }
        var worst = 0.0, worstRight = 0.0
        for n in 3_000..<(frames - 100) {
            let expected = 0.25 * sin(2 * Double.pi * 1_000 * (Double(n) - delayAt(n)) / 48_000)
            worst = max(worst, abs(Double(out[2 * n]) - expected))
            worstRight = max(worstRight, abs(Double(out[2 * n + 1]) - Double(input[2 * (n - 1_000)])))
        }
        #expect(worst < 2e-3, "interpolated channel off by \(worst)")
        #expect(worstRight == 0, "whole-frame channel off by \(worstRight)")
    }

    @Test("The ramp stops at its limit: after 392 frames given back the delay holds at 608")
    func realTimeLimit() {
        let frames = 60_000
        var channel = NRTRoomChannel()
        channel.delayFrames = 1_000; channel.gain = 1; channel.advancePPM = 10_000; channel.advanceLimitFrames = 392
        let input = tone(frames: frames)
        let out = render(input, channels: 2) { context in var c = [channel, channel]; nrt_context_set_room(context, &c, 2) }
        var worst = 0.0
        for n in 45_000..<(frames - 10) {   // the ramp ends at frame 39,200
            let expected = 0.25 * sin(2 * Double.pi * 1_000 * (Double(n) - 608) / 48_000)
            worst = max(worst, abs(Double(out[2 * n]) - expected))
        }
        #expect(worst < 2e-3, "off by \(worst)")
    }
}
