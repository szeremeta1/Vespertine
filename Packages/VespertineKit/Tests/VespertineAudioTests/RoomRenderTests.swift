//
// Vespertine: speaker groups: room render. Off unless chosen; the fronts keep the song's own samples; only what is not dry and
// easy to place reaches the surrounds, later than the fronts and decorrelated; bass moves to the bass speakers at the level it
// had at the seat; a drawing that contradicts the speakers' names is overruled; the low room correction keeps to what holds
// across the room; and the signal path says the song was rendered.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Speaker groups: room render")
struct RoomRenderTests {
    static let rate = 48_000.0
    static let stereo: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right]
    static let surround51: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                                                  kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]
    static let surround71: [AudioChannelLabel] = surround51 + [kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight]

    // The fixture quad: FL 0, FR 1, BL 2, BR 3.
    static func quad(_ settings: RoomRenderSettings? = RoomRenderSettings()) -> SpeakerGroup {
        var group = GroupFixtures.quad()
        group.roomRender = settings
        return group
    }

    /// A quad drawn as a real one was: the seat off-centre, both back speakers drawn left of it (the right one by mistake), and the
    /// back DAC listed first (BL 0, BR 1, FL 2, FR 3).
    static func misdrawn(_ settings: RoomRenderSettings? = RoomRenderSettings()) -> SpeakerGroup {
        let fosi = GroupFixtures.fosi, fiio = GroupFixtures.fiio
        return SpeakerGroup(
            name: "Misdrawn", members: [.init(deviceUID: fiio, name: "FiiO K11", channelCount: 2), .init(deviceUID: fosi, name: "Fosi Audio ZD3", channelCount: 2)],
            clockLeaderUID: fosi,
            speakers: [.init(role: .frontLeft, deviceUID: fosi, channel: 0, position: Point2D(x: 0.03, y: 0.82)),
                       .init(role: .frontRight, deviceUID: fosi, channel: 1, position: Point2D(x: 0.97, y: 0.82)),
                       .init(role: .backLeft, deviceUID: fiio, channel: 0, position: Point2D(x: -2, y: -1)),
                       .init(role: .backRight, deviceUID: fiio, channel: 1, position: Point2D(x: -1.1, y: -1))],
            listener: Listener(position: Point2D(x: 0.5, y: 0)), stereoPolicy: .allSpeakers, lfePolicy: .toAll(dB: -10), roomRender: settings)
    }

    static func plan(_ source: [AudioChannelLabel], _ group: SpeakerGroup, levels: [Double] = []) throws -> RoomRenderPlan {
        var plan = try #require(RoomRender.plan(source: source, group: group))
        plan.levelsDB = levels
        return plan
    }

    /// Runs interleaved `input` through a fresh renderer, in uneven blocks as decoding hands them over.
    static func render(_ input: [Float], plan: RoomRenderPlan) throws -> (out: [Float], width: Int) {
        let renderer = try #require(RoomRenderer(plan: plan, sampleRate: rate))
        let n = renderer.sourceChannels
        var out: [Float] = []
        let frames = input.count / n
        var f = 0, block = 997
        while f < frames {
            let take = min(block, frames - f)
            input.withUnsafeBufferPointer { renderer.process($0.baseAddress! + f * n, frames: take, into: &out) }
            f += take
            block = block == 997 ? 4096 : 997
        }
        renderer.finish(into: &out)
        return (out, renderer.outputChannels)
    }

    /// Deterministic white noise in -1…1.
    static func noise(_ count: Int, seed: UInt64) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Double(state >> 11) / Double(1 << 53) * 2 - 1) * 0.5
        }
    }

    static func channel(_ x: [Float], _ c: Int, of n: Int) -> [Float] { stride(from: c, to: x.count, by: n).map { x[$0] } }

    static func interleave(_ channels: [[Float]]) -> [Float] {
        let frames = channels[0].count
        var x = [Float](repeating: 0, count: frames * channels.count)
        for (c, ch) in channels.enumerated() { for f in 0..<frames { x[f * channels.count + c] = ch[f] } }
        return x
    }

    static func rms(_ x: ArraySlice<Float>) -> Double { (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(x.count, 1))).squareRoot() }

    /// Normalized correlation of `a` with `b` delayed by `lag` frames, over `range` of `a`.
    static func correlation(_ a: [Float], _ b: [Float], lag: Int, range: Range<Int>) -> Double {
        var ab = 0.0, aa = 0.0, bb = 0.0
        for i in range where i + lag < b.count && i + lag >= 0 {
            let x = Double(a[i]), y = Double(b[i + lag])
            ab += x * y; aa += x * x; bb += y * y
        }
        return aa > 0 && bb > 0 ? ab / (aa * bb).squareRoot() : 0
    }

    /// The amplitude of the `hz` sine in `x` (from frame `from` on).
    static func amplitude(_ x: [Float], hz: Double, from: Int) -> Double {
        var s = 0.0, c = 0.0
        let count = x.count - from
        for i in from..<x.count {
            let p = 2 * Double.pi * hz * Double(i) / rate
            s += Double(x[i]) * sin(p); c += Double(x[i]) * cos(p)
        }
        return 2 * (s * s + c * c).squareRoot() / Double(count)
    }

    static func sine(_ frames: Int, _ hz: Double) -> [Float] { (0..<frames).map { Float(sin(2 * .pi * hz * Double($0) / rate)) } }

    // MARK: Off

    @Test("Off unless chosen: a group without it routes as before, and a group saved before it existed reads as off")
    func offByDefault() throws {
        let plain = GroupFixtures.quad()
        #expect(plain.roomRender == nil)
        #expect(RoomRender.plan(source: Self.stereo, group: plain) == nil)
        let content = try #require(GroupContentPlan(source: Self.stereo, group: plain))
        #expect(content.render == nil)
        #expect(content.router == PositionRouter(source: Self.stereo, group: plain))
        #expect(content.untouchedChannels(ofMember: GroupFixtures.fosi) == [0, 1])

        let data = try SpeakerGroupCoding.encode(plain)
        #expect(!String(decoding: data, as: UTF8.self).contains("roomRender"))
        #expect(try SpeakerGroupCoding.decode(data).roomRender == nil)

        var on = plain
        on.roomRender = RoomRenderSettings(fillDB: -12, bassSpeakers: .all)
        #expect(try SpeakerGroupCoding.decode(SpeakerGroupCoding.encode(on)) == on)
        // A saved setting missing later fields takes their defaults.
        #expect(try JSONDecoder().decode(RoomRenderSettings.self, from: Data("{\"fillDB\": -3}".utf8)) == RoomRenderSettings(fillDB: -3))
    }

    @Test("Settings are held to their ranges; a number that isn't one takes the default")
    func clamped() {
        let wild = RoomRenderSettings(ambienceDB: 9, fillDB: -.infinity, surroundDelayMs: 2, crossoverHz: .nan, lowCorrectionDepth: 3, lowCorrectionBelowHz: -1)
        let held = wild.clamped
        #expect(held.ambienceDB == 0)
        #expect(held.fillDB == RoomRenderSettings().fillDB)
        #expect(held.surroundDelayMs == 12)
        #expect(held.crossoverHz == 90)
        #expect(held.lowCorrectionDepth == 1)
        #expect(held.lowCorrectionBelowHz == 0)
        #expect(RoomRenderSettings(crossoverHz: 0).clamped.crossoverHz == 0)
        #expect(RoomRenderSettings(crossoverHz: 500).clamped.crossoverHz == 200)
        #expect(RoomRenderSettings(fillDB: -40).fillGain == 0)
    }

    @Test("It needs a front pair; a group with no surround pair isn't upmixed")
    func applies() throws {
        var frontOnly = Self.quad()
        frontOnly.speakers.removeAll { $0.role == .backLeft || $0.role == .backRight }
        #expect(try Self.plan(Self.stereo, frontOnly).upmixes == false)
        var noFront = Self.quad()
        noFront.speakers.removeAll { $0.role == .frontLeft }
        #expect(RoomRender.plan(source: Self.stereo, group: noFront) == nil)
        #expect(try Self.plan(Self.stereo, Self.quad()).upmixes)
        #expect(try Self.plan([kAudioChannelLabel_Center], Self.quad()).upmixes)
        #expect(try Self.plan(Self.surround51, Self.quad()).upmixes == false)
    }

    // MARK: Stereo

    @Test("Stereo: the fronts play the song's own samples, and the song comes out exactly as long as it went in")
    func frontsUntouched() throws {
        let frames = 30_000
        let l = Self.noise(frames, seed: 1), r = Self.noise(frames, seed: 2)
        let (out, width) = try Self.render(Self.interleave([l, r]), plan: Self.plan(Self.stereo, Self.quad(RoomRenderSettings(crossoverHz: 0))))
        #expect(width == 4)
        #expect(out.count == frames * 4)
        #expect(Self.channel(out, 0, of: 4) == l)
        #expect(Self.channel(out, 1, of: 4) == r)
        #expect(Self.rms(Self.channel(out, 2, of: 4)[10_000...]) > 0.01)
    }

    @Test("A dry sound in the middle of the image reaches the surrounds only as the fill; with no fill, hardly at all")
    func dryCentreStaysFront() throws {
        let frames = 48_000
        let x = Self.noise(frames, seed: 3)
        let (out, _) = try Self.render(Self.interleave([x, x]), plan: Self.plan(Self.stereo, Self.quad(RoomRenderSettings(fillDB: -40, crossoverHz: 0))))
        let front = Self.rms(Self.channel(out, 0, of: 4)[8_000...])
        let back = max(Self.rms(Self.channel(out, 2, of: 4)[8_000...]), Self.rms(Self.channel(out, 3, of: 4)[8_000...]))
        #expect(20 * log10(back / front) < -30)
        // With the default fill it is there, 9 dB down (the all-passes keep the level).
        let (filled, _) = try Self.render(Self.interleave([x, x]), plan: Self.plan(Self.stereo, Self.quad(RoomRenderSettings(crossoverHz: 0))))
        let level = 20 * log10(Self.rms(Self.channel(filled, 2, of: 4)[8_000...]) / front)
        #expect(abs(level + 9) < 1)
    }

    @Test("The surrounds arrive after the fronts by the delay, and the two sides hardly correlate")
    func precedenceAndDecorrelation() throws {
        let frames = 24_000
        let x = Self.noise(frames, seed: 4)
        // Mono: both surrounds are made of one signal, which is the hardest case for decorrelation.
        let (out, _) = try Self.render(x, plan: Self.plan([kAudioChannelLabel_Center], Self.quad(RoomRenderSettings(crossoverHz: 0))))
        let fl = Self.channel(out, 0, of: 4), bl = Self.channel(out, 2, of: 4), br = Self.channel(out, 3, of: 4)
        let range = 2_000..<20_000
        let delay = Int(0.015 * Self.rate)
        // Nothing of the front reaches a surround before the delay.
        let early = (0..<(delay - 8)).map { abs(Self.correlation(fl, bl, lag: $0, range: range)) }.max() ?? 1
        #expect(early < 0.05)
        let late = (delay..<(delay + 400)).map { abs(Self.correlation(fl, bl, lag: $0, range: range)) }.max() ?? 0
        #expect(late > 0.1)
        // The two surrounds against each other, at any lag within 5 ms.
        let between = (-240...240).map { abs(Self.correlation(bl, br, lag: $0, range: range)) }.max() ?? 1
        #expect(between < 0.3)
    }

    @Test("Mono plays on the fronts at a centre's level, as it does without room render")
    func monoLevel() throws {
        let x = Self.noise(10_000, seed: 5)
        let (out, _) = try Self.render(x, plan: Self.plan([kAudioChannelLabel_Center], Self.quad(RoomRenderSettings(crossoverHz: 0))))
        let fl = Self.channel(out, 0, of: 4)
        for i in stride(from: 0, to: x.count, by: 37) { #expect(abs(fl[i] - x[i] * Float(0.5.squareRoot())) < 1e-6) }
    }

    // MARK: Surround songs

    @Test("Surround songs: every channel stays on its speaker, at its time and level")
    func surroundUnchanged() throws {
        let frames = 8_000
        let chans = (0..<6).map { Self.noise(frames, seed: UInt64(10 + $0)) }
        let (out, _) = try Self.render(Self.interleave(chans), plan: Self.plan(Self.surround51, Self.quad(RoomRenderSettings(crossoverHz: 0))))
        let half = Float(0.5.squareRoot())
        #expect(Self.channel(out, 2, of: 4) == chans[4])
        #expect(Self.channel(out, 3, of: 4) == chans[5])
        let fl = Self.channel(out, 0, of: 4)
        for i in stride(from: 0, to: frames, by: 13) { #expect(abs(fl[i] - (chans[0][i] + half * chans[2][i])) < 1e-6) }
    }

    @Test("A drawing with the right back speaker on the left is overruled: 7.1's right channels reach it, not the front right")
    func placement() throws {
        let (fixed, replaced) = RoomRender.placement(Self.misdrawn())
        #expect(replaced == [.backRight])
        let br = try #require(fixed.speakers.first { $0.role == .backRight })
        let drawn = try #require(Self.misdrawn().speakers.first { $0.role == .backRight })
        #expect(SpeakerGeometry.azimuth(from: fixed.listener, to: br.position) > 100)
        #expect(abs(SpeakerGeometry.distance(from: fixed.listener, to: br.position) - SpeakerGeometry.distance(from: fixed.listener, to: drawn.position)) < 1e-9)
        #expect(RoomRender.placement(GroupFixtures.quad()).replaced.isEmpty)

        // A front speaker drawn behind the seat goes to its usual angle.
        var behind = GroupFixtures.quad()
        behind.speakers[0].position = Point2D(x: -1, y: -0.5)
        let moved = RoomRender.placement(behind)
        #expect(moved.replaced == [.frontLeft])
        #expect(abs(SpeakerGeometry.azimuth(from: behind.listener, to: moved.group.speakers[0].position) + 30) < 1e-9)

        // 7.1 (sides at index 4 and 5, backs at 6 and 7) on the misdrawn group: BL is 0, BR 1, FL 2, FR 3.
        let before = try #require(PositionRouter(source: Self.surround71, group: Self.misdrawn(nil)))
        #expect(!before.routes[5].contains { $0.output == 1 })
        let after = try #require(GroupContentPlan(source: Self.surround71, group: Self.misdrawn()))
        #expect(after.router.routes[5].contains { $0.output == 1 })
        #expect(after.router.routes[7].map(\.output) == [1])
        #expect(after.render?.replaced == [.backRight])
    }

    // MARK: Bass

    @Test("Bass management: a surround channel's bass moves to the fronts, at the level it had at the seat; its treble stays")
    func bassMoves() throws {
        let frames = 48_000
        func run(_ hz: Double, levels: [Double]) throws -> [[Float]] {
            var chans = [[Float]](repeating: [Float](repeating: 0, count: frames), count: 6)
            chans[4] = Self.sine(frames, hz)
            let (out, _) = try Self.render(Self.interleave(chans), plan: Self.plan(Self.surround51, Self.quad(), levels: levels))
            return (0..<4).map { Self.channel(out, $0, of: 4) }
        }
        for levels in [[Double](), [-11, -10.7, -2.3, 0]] {
            let gain = (0..<4).map { Float(pow(10, ($0 < levels.count ? levels[$0] : 0) / 20)) }
            for hz in [40.0, 90.0] {
                let y = try run(hz, levels: levels)
                // What reaches the seat: each speaker at its level in the chain, summed (the bass adds in phase there).
                let seat = (0..<frames).map { i in (0..<4).reduce(Float(0)) { $0 + gain[$1] * y[$1][i] } }
                #expect(abs(Self.amplitude(seat, hz: hz, from: 12_000) - Double(gain[2])) < 0.03 * Double(gain[2]))
            }
            let low = try run(40, levels: levels)
            #expect(Self.amplitude(low[2], hz: 40, from: 12_000) < 0.05)
            #expect(Self.amplitude(low[0], hz: 40, from: 12_000) > 0.3)
            let high = try run(2_000, levels: levels)
            #expect(abs(Self.amplitude(high[2], hz: 2_000, from: 12_000) - 1) < 0.01)
            #expect(Self.amplitude(high[0], hz: 2_000, from: 12_000) < 0.01)
        }
    }

    @Test("Bass goes to the subwoofer when there is one, or to every speaker when chosen")
    func bassTargets() throws {
        let all = try #require(BassManager(plan: Self.plan(Self.surround51, Self.quad(RoomRenderSettings(bassSpeakers: .all))),
                                           settings: RoomRenderSettings(bassSpeakers: .all), outputChannels: 4, sampleRate: Self.rate))
        #expect(all.targets.map(\.output) == [0, 1, 2, 3])
        #expect(all.targets.allSatisfy { abs($0.gain - 0.25) < 1e-6 })
        var withSub = Self.quad()
        withSub.members[1].channelCount = 3
        withSub.speakers.append(.init(role: .lfe, deviceUID: GroupFixtures.fiio, channel: 2, position: Point2D(x: 0, y: 1.5)))
        let sub = try #require(BassManager(plan: Self.plan(Self.surround51, withSub), settings: RoomRenderSettings(), outputChannels: 5, sampleRate: Self.rate))
        #expect(sub.targets.map(\.output) == [4])
        #expect(!sub.sources.contains(4))
        // A bass speaker far down in the chain is turned up at most 12 dB.
        let quiet = try #require(BassManager(plan: Self.plan(Self.surround51, Self.quad(), levels: [-30, -30, 0, 0]), settings: RoomRenderSettings(), outputChannels: 4, sampleRate: Self.rate))
        #expect(quiet.targets.allSatisfy { abs($0.gain - 2) < 1e-6 })
    }

    // MARK: Room correction

    @Test("Room correction across the room: low cuts keep 75 %, low boosts are left out, the rest is as measured")
    func roomWideCorrection() {
        let bands = [EQBand(kind: .peak, frequency: 125, gainDB: -9.2, q: 6), EQBand(kind: .peak, frequency: 456, gainDB: -6.6, q: 5.7),
                     EQBand(kind: .peak, frequency: 60, gainDB: 3, q: 2), EQBand(kind: .highPass, frequency: 20, gainDB: 0, q: 0.7)]
        let room = RoomCorrectionPlayback(profileID: UUID(), name: "Room", preampDB: -1,
                                          channels: [RoomChannelPlayback(delayMs: 13.8, levelDB: -11, bands: bands)])
        let wide = RoomRender.roomWide(room, settings: RoomRenderSettings())
        let out = wide.channels[0].bands
        #expect(out.count == 3)
        #expect(abs(out[0].gainDB - -6.9) < 1e-9 && out[0].frequency == 125 && out[0].q == 6)
        #expect(out[1] == bands[1])
        #expect(out[2] == bands[3])
        #expect(wide.channels[0].delayMs == 13.8 && wide.channels[0].levelDB == -11 && wide.preampDB == -1)
        #expect(RoomRender.roomWide(room, settings: RoomRenderSettings(lowCorrectionDepth: 1, lowCorrectionBelowHz: 0)) == room)
    }

    // MARK: What the listener is told

    @Test("A rendered song is never bit-perfect, and the signal path says ROOM RENDER and what it did")
    func signalPath() throws {
        let content = try #require(GroupContentPlan(source: Self.stereo, group: Self.quad()))
        #expect(content.render != nil)
        #expect(content.untouchedChannels(ofMember: GroupFixtures.fosi).isEmpty)
        #expect(content.usedChannels(ofMember: GroupFixtures.fosi) == [0, 1])
        #expect(content.usedChannels(ofMember: GroupFixtures.fiio) == [0, 1])
        #expect(!content.carriesOnlyUntouchedChannels(ofMember: GroupFixtures.fosi))

        let source = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 48_000, bitDepth: 16, channels: 2)
        let plan = OutputPlan(mode: .pcm, deviceSampleRate: 48_000, decodedSampleRate: 48_000, physicalBitDepth: 32, channels: 4,
                              dsdConvertedToPCM: false, reason: "")
        let applied = AppliedFormat(sampleRate: 48_000, physicalBitDepth: 32, physicalIsInteger: false, virtualChannels: 4, exclusive: true, bufferFrames: 512)
        let path = GroupSignalPath.make(group: Self.quad(), applied: applied, source: source, plan: plan, stage: .none, content: content)
        #expect(path.folds && path.render != nil && !path.isBitPerfect)
        #expect(path.badges.contains("ROOM RENDER"))
        #expect(path.rows.last == "Room render: ambience and a decorrelated fill on the surrounds, 15 ms after the fronts; bass below 90 Hz on the front pair")

        let routed = GroupRouting.routed(plan, content: content, group: Self.quad(), source: source)
        #expect(routed.reason.contains("rendered for the room"))
    }
}
