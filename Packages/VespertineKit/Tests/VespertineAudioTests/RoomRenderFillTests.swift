//
// Vespertine: speaker groups: Fill the room, measured. The switch was reported to do nothing. On the group it was reported on
// (stereo songs already on every speaker) it did three things: it turned the back pair of a stereo song DOWN by 9 dB, it changed
// no sample of a surround song (bass management aside), and it changed nothing of what other apps play (Mac Sound Output). These
// hold the opposite: with it on, every speaker plays the whole song or film, a speaker never plays a channel twice, the fill has
// no bass when the bass is managed, nothing passes full scale, and Mac Sound Output follows the switch.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Speaker groups: Fill the room fills the room")
struct RoomRenderFillTests {
    typealias T = RoomRenderTests
    static let frames = 96_000
    /// Past the upmixer's and the delays' start.
    static let settled = 24_000..<frames

    /// The default fill: 3 dB down.
    static let fill = Float(pow(10, -3.0 / 20))
    static let fold = Float(0.5.squareRoot())

    static func dB(_ a: Double, over b: Double) -> Double { 20 * log10(max(a, 1e-12) / max(b, 1e-12)) }

    /// The group the report came from, as it is saved: stereo on every speaker, the back DAC first (BL 0, BR 1, FL 2, FR 3).
    static func reported(_ settings: RoomRenderSettings? = RoomRenderSettings(crossoverHz: 0)) -> SpeakerGroup { T.misdrawn(settings) }

    /// `input` as the group plays it with the switch off.
    static func plain(_ input: [Float], source: [AudioChannelLabel], group: SpeakerGroup) throws -> [Float] {
        let router = try #require(PositionRouter(source: source, group: group))
        let frames = input.count / source.count
        var out = [Float](repeating: 0, count: frames * router.outputChannels)
        input.withUnsafeBufferPointer { i in out.withUnsafeMutableBufferPointer { router.route(i.baseAddress!, into: $0.baseAddress!, frames: frames) } }
        return out
    }

    static func level(_ x: [Float], _ channel: Int) -> Double { T.rms(T.channel(x, channel, of: 4)[settled]) }

    // MARK: Stereo

    @Test("A stereo song: the back pair plays the whole song 3 dB under the fronts, where the old switch left it 9 dB under")
    func stereoFillsTheBack() throws {
        let x = T.noise(Self.frames, seed: 1)
        // A voice in the middle of the image: nothing of it is ambience, so all the back pair has of it is the fill.
        let (out, width) = try T.render(T.interleave([x, x]), plan: T.plan(T.stereo, Self.reported()))
        #expect(width == 4)
        for back in [0, 1] { #expect(abs(Self.dB(Self.level(out, back), over: Self.level(out, 2)) + 3) < 0.5) }
        // The fronts are the song's own samples.
        #expect(T.channel(out, 2, of: 4) == x)
        #expect(T.channel(out, 3, of: 4) == x)
        // A group saved with the old default takes the new one; a level chosen under the new one is kept.
        #expect(try JSONDecoder().decode(RoomRenderSettings.self, from: Data("{\"fillDB\": -9}".utf8)).fillDB == -3)
        #expect(try JSONDecoder().decode(RoomRenderSettings.self, from: Data("{\"fillDB\": -9, \"revision\": 2}".utf8)).fillDB == -9)
        #expect(try JSONDecoder().decode(RoomRenderSettings.self, from: JSONEncoder().encode(RoomRenderSettings(fillDB: -9))).fillDB == -9)
    }

    @Test("Each back speaker plays its own side of the song, and a speaker never plays a channel twice")
    func sidesAndNoDoubles() throws {
        let l = T.noise(Self.frames, seed: 2)
        let silent = [Float](repeating: 0, count: Self.frames)
        let (out, _) = try T.render(T.interleave([l, silent]), plan: T.plan(T.stereo, Self.reported()))
        // Left only: the left back speaker has it, the right one has nothing; the front left is the channel alone (no late copy).
        #expect(Self.level(out, 0) > 0.5 * Self.level(out, 2))
        #expect(Self.level(out, 1) < 0.001)
        #expect(T.channel(out, 2, of: 4) == l)
        #expect(T.channel(out, 3, of: 4) == silent)
        let plan = try T.plan(T.surround51, Self.reported())
        let router = try #require(PositionRouter(source: plan.routeLabels, group: plan.group))
        let taps = RoomRender.fillTaps(for: plan, router: router)
        for (output, list) in taps.enumerated() {
            let direct = Set(router.matrixRow(output).map(\.source))
            #expect(direct.isDisjoint(with: list.map(\.source)))
            #expect(!list.contains { $0.source == 3 }, "the subwoofer channel is never part of the fill")
        }
    }

    // MARK: Surround

    @Test("A film: the dialogue (the centre channel) plays on every speaker, where the old switch left the back pair silent")
    func dialogueEverywhere() throws {
        var chans = [[Float]](repeating: [Float](repeating: 0, count: Self.frames), count: 6)
        chans[2] = T.noise(Self.frames, seed: 3)
        let x = T.interleave(chans)
        let source = T.rms(chans[2][Self.settled])
        let before = try Self.plain(x, source: T.surround51, group: Self.reported(nil))
        #expect(Self.level(before, 0) == 0 && Self.level(before, 1) == 0)
        let (out, _) = try T.render(x, plan: T.plan(T.surround51, Self.reported()))
        // Fronts: the centre folded at -3 dB, as without the switch. Backs: the centre's share of a side (-3 dB), 3 dB down.
        for front in [2, 3] { #expect(abs(Self.dB(Self.level(out, front), over: source) + 3) < 0.1) }
        for back in [0, 1] { #expect(abs(Self.dB(Self.level(out, back), over: source) + 6) < 0.5) }
    }

    @Test("A film: a surround channel also plays on the front speaker of its side, and not on the other side")
    func surroundsReachTheFront() throws {
        var chans = [[Float]](repeating: [Float](repeating: 0, count: Self.frames), count: 6)
        chans[4] = T.noise(Self.frames, seed: 4)
        let (out, _) = try T.render(T.interleave(chans), plan: T.plan(T.surround51, Self.reported()))
        #expect(T.channel(out, 0, of: 4) == chans[4])
        #expect(abs(Self.dB(Self.level(out, 2), over: Self.level(out, 0)) + 6) < 0.5)
        #expect(Self.level(out, 1) == 0 && Self.level(out, 3) == 0)
    }

    // MARK: Bass and full scale

    @Test("With the bass managed the fill has none: a late copy of the bass would cancel it")
    func fillHasNoBass() throws {
        // The same tone on both channels: none of it is ambience, so the back pair has only the fill.
        func back(_ hz: Double) throws -> Double {
            let tone = T.sine(Self.frames, hz).map { $0 * 0.5 }
            let (out, _) = try T.render(T.interleave([tone, tone]), plan: T.plan(T.stereo, Self.reported(RoomRenderSettings())))
            return T.amplitude(T.channel(out, 0, of: 4), hz: hz, from: 24_000)
        }
        #expect(try back(30) < 0.01)
        #expect(try abs(back(2_000) - 0.5 * Double(Self.fill)) < 0.02)
    }

    @Test("Nothing passes full scale, a speaker within it is left exactly as it was, and the song keeps its length")
    func limited() throws {
        // A full-scale square on both channels, the fill at the fronts' level: the all-passed fill overshoots.
        let square = (0..<30_000).map { Float(($0 / 37) % 2 == 0 ? 1 : -1) }
        let (out, _) = try T.render(T.interleave([square, square]), plan: T.plan(T.stereo, Self.reported(RoomRenderSettings(fillDB: 0, crossoverHz: 0))))
        #expect(out.count == square.count * 4)
        #expect(out.allSatisfy { abs($0) <= 1 })
        #expect(T.channel(out, 2, of: 4) == square)
        #expect(T.rms(T.channel(out, 0, of: 4)[10_000...]) > 0.2)

        // The limiter alone: one channel twice too loud, one within full scale.
        var limiter = RenderLimiter(channels: 2, sampleRate: T.rate)
        let loud = T.sine(9_000, 440).map { $0 * 2 }, quiet = T.sine(9_000, 1_000).map { $0 * 0.9 }
        var result: [Float] = []
        var x = T.interleave([loud, quiet])
        var f = 0
        while f < 9_000 {
            let take = min(701, 9_000 - f)
            x.withUnsafeMutableBufferPointer { limiter.process($0.baseAddress! + f * 2, frames: take, into: &result) }
            f += take
        }
        limiter.finish(into: &result)
        #expect(result.count == 18_000)
        #expect(T.channel(result, 1, of: 2) == quiet)
        let peak = T.channel(result, 0, of: 2).map(abs).max() ?? 0
        #expect(peak <= 1 && peak > 0.95)
        // A speaker turned down 6 dB later in the chain may be driven 6 dB harder here.
        var trimmed = RenderLimiter(channels: 1, sampleRate: T.rate, thresholds: [2])
        var y = loud.map { $0 * 0.99 }, kept: [Float] = []
        y.withUnsafeMutableBufferPointer { trimmed.process($0.baseAddress!, frames: 9_000, into: &kept) }
        trimmed.finish(into: &kept)
        #expect(kept == loud.map { $0 * 0.99 })
    }

    // MARK: Mac Sound Output

    @Test("Mac Sound Output follows the switch: what other apps play reaches every speaker too; off, its routing is as it was")
    func systemOutput() throws {
        let group = Self.reported(nil), on = Self.reported()
        let wired = group.aggregateChannels
        let bl = try #require(wired[.backLeft]), br = try #require(wired[.backRight]), fl = try #require(wired[.frontLeft])
        // A film in 5.1: the centre (input 2) on the back pair, the left surround (input 4) on the front left.
        let off = try #require(SystemOutputRouting.matrix(input: T.surround51, group: group, content: .multichannel, stereo: .upmix))
        let film = try #require(SystemOutputRouting.matrix(input: T.surround51, group: on, content: .multichannel, stereo: .upmix))
        #expect(off[bl * 6 + 2] == 0 && off[br * 6 + 2] == 0)
        #expect(abs(film[bl * 6 + 2] - Self.fold * Self.fill) < 1e-5 && abs(film[br * 6 + 2] - Self.fold * Self.fill) < 1e-5)
        #expect(abs(film[fl * 6 + 4] - Self.fold * Self.fill) < 1e-5)
        #expect(film[bl * 6 + 4] == 1 && film[bl * 6 + 3] == off[bl * 6 + 3])
        // Stereo upmixed (six channels from the upmixer): the back pair gets the left and the centre besides its ambience.
        let upmixed = try #require(SystemOutputRouting.matrix(input: T.surround51, group: on, content: .stereo, stereo: .upmix))
        #expect(abs(upmixed[bl * 6 + 0] - Self.fill) < 1e-5 && abs(upmixed[bl * 6 + 2] - Self.fold * Self.fill) < 1e-5 && upmixed[bl * 6 + 1] == 0)
        // Stereo as the group plays it: this group has it on every speaker already, so there is nothing to add.
        #expect(SystemOutputRouting.matrix(input: T.surround51, group: on, content: .stereo, stereo: .asGroup)
            == SystemOutputRouting.matrix(input: T.surround51, group: group, content: .stereo, stereo: .asGroup))
        // On a group with stereo on the front pair only, the switch brings it to the back pair.
        var frontOnly = on
        frontOnly.stereoPolicy = .frontOnly
        let stereo = try #require(SystemOutputRouting.matrix(input: T.stereo, group: frontOnly, content: .stereo, stereo: .asGroup))
        #expect(abs(stereo[bl * 2 + 0] - Self.fill) < 1e-5 && stereo[bl * 2 + 1] == 0 && stereo[fl * 2 + 0] == 1)
    }
}
