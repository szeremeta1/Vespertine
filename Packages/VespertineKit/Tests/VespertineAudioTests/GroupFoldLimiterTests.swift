//
// Vespertine: speaker groups: a song folded onto fewer speakers cannot clip them. The speakers that get a sum of channels have a
// limiter; the others, and every speaker while the sum stays within full scale, get exactly what the router makes.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio
import VespertineTestSupport

@Suite("Group fold limiter")
struct GroupFoldLimiterTests {
    private static let rate = 48_000.0
    private static let stereo: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right]
    private static let quadFile: [AudioChannelLabel] = stereo + [kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]
    private static let surround51: [AudioChannelLabel] = stereo + [kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
                                                                   kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]
    private static let surround71: [AudioChannelLabel] = surround51 + [kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight]

    private func router(_ source: [AudioChannelLabel], _ group: SpeakerGroup = GroupFixtures.quad()) throws -> PositionRouter {
        try #require(PositionRouter(source: source, group: group))
    }

    /// Every channel the same sine at `level`, in phase: the worst a fold can be handed. Interleaved.
    private func song(channels: Int, frames: Int, level: (Int) -> Float) -> [Float] {
        var x = [Float](repeating: 0, count: frames * channels)
        for f in 0..<frames {
            let v = Float(sin(2 * Double.pi * 440 * Double(f) / Self.rate)) * level(f)
            for c in 0..<channels { x[f * channels + c] = v }
        }
        return x
    }

    /// The router alone: what reached the ring before.
    private func routed(_ router: PositionRouter, _ input: [Float]) -> [Float] {
        let frames = input.count / router.sourceChannels
        var out = [Float](repeating: 0, count: frames * router.outputChannels)
        input.withUnsafeBufferPointer { i in out.withUnsafeMutableBufferPointer { o in router.route(i.baseAddress!, into: o.baseAddress!, frames: frames) } }
        return out
    }

    /// The router with its limiter, fed in chunks of uneven size as the converter feeds it.
    private func limited(_ router: PositionRouter, _ input: [Float], gain: Float = 1) throws -> [Float] {
        let limiter = try #require(GroupFoldLimiter(router: router, sampleRate: Self.rate, gain: gain))
        let frames = input.count / router.sourceChannels
        var out: [Float] = []
        var f = 0
        input.withUnsafeBufferPointer { i in
            while f < frames {
                let take = min(1_013, frames - f)
                limiter.process(i.baseAddress! + f * router.sourceChannels, frames: take, into: &out)
                f += take
            }
        }
        limiter.finish(into: &out)
        return out
    }

    private func channel(_ x: [Float], _ c: Int, of n: Int) -> [Float] { stride(from: c, to: x.count, by: n).map { x[$0] } }
    private func peak(_ x: [Float]) -> Float { x.map(abs).max() ?? 0 }
    private func same(_ a: [Float], _ b: [Float]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern } }

    @Test("Only a fold that can pass full scale gets a limiter: stereo, a quad file and mono on the quad have none")
    func onlyWhereNeeded() throws {
        for policy in [StereoPolicy.frontOnly, .mirror(trimDB: -3), .eachPairStereo, .allSpeakers] {
            var group = GroupFixtures.quad()
            group.stereoPolicy = policy
            #expect(GroupFoldLimiter(router: try router(Self.stereo, group), sampleRate: Self.rate) == nil)
        }
        #expect(GroupFoldLimiter(router: try router(Self.quadFile), sampleRate: Self.rate) == nil)
        #expect(GroupFoldLimiter(router: try router([kAudioChannelLabel_Mono]), sampleRate: Self.rate) == nil)
        #expect(GroupFoldLimiter(router: try router(Self.surround51), sampleRate: Self.rate) != nil)
        #expect(GroupFoldLimiter(router: try router(Self.surround71), sampleRate: Self.rate) != nil)
        #expect(GroupFoldLimiter(router: try router(Self.surround51), sampleRate: 0) == nil)
    }

    @Test("5.1 on the quad, every channel at full scale together: the fronts reached 1.71 times full scale, and now stay within it; the back pair is the file's own samples, and the song keeps its length")
    func fiveOneCannotClip() throws {
        let r = try router(Self.surround51)
        let input = song(channels: 6, frames: 24_000) { _ in 1 }
        let before = routed(r, input), after = try limited(r, input)
        #expect(abs(peak(channel(before, 0, of: 4)) - 1.7071) < 0.001 && abs(peak(channel(before, 1, of: 4)) - 1.7071) < 0.001)
        #expect(after.count == before.count)
        for front in 0...1 {
            let p = peak(channel(after, front, of: 4))
            #expect(p <= 1 && p > 0.95)
        }
        for back in 2...3 { #expect(same(channel(after, back, of: 4), channel(before, back, of: 4))) }
    }

    @Test("7.1 on the quad: the fronts carry the centre and the back pair the side surrounds, 1.71 times full scale each at worst, and all four stay within it")
    func sevenOneCannotClip() throws {
        let r = try router(Self.surround71)
        #expect(abs(r.worstCaseGain - 1.7071) < 0.001)
        let input = song(channels: 8, frames: 24_000) { _ in 1 }
        let before = routed(r, input), after = try limited(r, input)
        #expect(after.count == before.count)
        for output in 0..<4 {
            #expect(abs(peak(channel(before, output, of: 4)) - 1.7071) < 0.001)
            let p = peak(channel(after, output, of: 4))
            #expect(p <= 1 && p > 0.95)
        }
    }

    @Test("A song whose sums stay within full scale comes out sample for sample as the router makes it, on every speaker")
    func quietIsUntouched() throws {
        for source in [Self.surround51, Self.surround71] {
            let r = try router(source)
            let input = song(channels: source.count, frames: 12_000) { _ in 0.58 }       // 0.58 × 1.7071 = 0.99
            #expect(same(try limited(r, input), routed(r, input)))
        }
    }

    @Test("Only the loud part is turned down: before it the speaker has the router's samples, and 300 ms after it again")
    func onlyWhileItWouldClip() throws {
        let r = try router(Self.surround51)
        // Quiet, loud for a quarter of a second, quiet again.
        let input = song(channels: 6, frames: 48_000) { (12_000..<24_000).contains($0) ? 1 : 0.5 }
        let before = routed(r, input), after = try limited(r, input)
        let was = channel(before, 0, of: 4), now = channel(after, 0, of: 4)
        #expect(peak(now) <= 1)
        #expect(same(Array(now[..<11_800]), Array(was[..<11_800])))
        #expect(same(Array(now[38_400...]), Array(was[38_400...])))
        // While it is loud the speaker is held at full scale, not far under it.
        #expect(peak(Array(now[14_000..<24_000])) > 0.95)
    }

    @Test("A speaker that plays one channel of the file at 1.0 is never changed, even by samples above full scale")
    func ownChannelIsNeverLimited() throws {
        let r = try router(Self.surround51)
        var input = song(channels: 6, frames: 9_600) { _ in 1 }
        for f in 0..<9_600 { input[f * 6 + 4] *= 1.5 }                                  // the left surround, over full scale in the file
        let before = routed(r, input), after = try limited(r, input)
        #expect(peak(channel(after, 2, of: 4)) > 1.4)
        #expect(same(channel(after, 2, of: 4), channel(before, 2, of: 4)))
    }

    @Test("ReplayGain comes after: a song it turns down 6 dB may sum to twice full scale here, and one it turns up 6 dB must stay under half")
    func allowsForReplayGain() throws {
        let r = try router(Self.surround51)
        let input = song(channels: 6, frames: 24_000) { _ in 1 }
        let plain = routed(r, input)
        // 1.71 × 0.5 = 0.85: nothing would clip, so nothing is limited and no limiter is made.
        #expect(GroupFoldLimiter(router: r, sampleRate: Self.rate, gain: 0.5) == nil)
        // 1.71 × 0.7 = 1.2: the fronts are held to 1 / 0.7 here, which is full scale after the gain.
        let down = try limited(r, input, gain: 0.7)
        #expect(peak(channel(down, 0, of: 4)) * 0.7 <= 1 && peak(channel(down, 0, of: 4)) * 0.7 > 0.95)
        let up = try limited(r, input, gain: 2)
        #expect(peak(channel(up, 0, of: 4)) * 2 <= 1 && peak(channel(up, 0, of: 4)) * 2 > 0.95)
        #expect(same(channel(up, 2, of: 4), channel(plain, 2, of: 4)))
        // A fold that fits only until the gain: 0.58 × 1.71 = 0.99, twice that is not.
        let quiet = song(channels: 6, frames: 24_000) { _ in 0.58 }
        #expect(peak(channel(try limited(r, quiet, gain: 2), 0, of: 4)) * 2 <= 1)
    }
}
