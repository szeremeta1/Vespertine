//
// Vespertine: speaker groups: which speaker plays which channel of a song, from where the speakers really stand.
// Golden coefficients for the ITU-style folds, and the properties that make the panning safe.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Position router")
struct PositionRouterTests {
    private let r = Float(0.5.squareRoot())                          // 0.7071…, the ITU −3 dB

    // Source layouts, in file order.
    private let stereo: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right]
    private let quadFile: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]
    private let surround51: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
                                                    kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]
    private let surround71: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
                                                    kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
                                                    kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight]

    /// A group whose speakers stand at these angles, 2 m from the seat. Outputs are numbered in the order given, over as many
    /// two-channel DACs as it takes.
    private func group(_ speakers: [(SpeakerRole, Double)]) -> SpeakerGroup {
        let dacs = (speakers.count + 1) / 2
        let members = (0..<dacs).map { SpeakerGroup.Member(deviceUID: "dac\($0)", name: "DAC \($0)", channelCount: 2) }
        let placed = speakers.enumerated().map { i, entry in
            SpeakerGroup.Speaker(role: entry.0, deviceUID: "dac\(i / 2)", channel: i % 2,
                                 position: Point2D(x: 2 * sin(entry.1 * .pi / 180), y: 2 * cos(entry.1 * .pi / 180)))
        }
        return SpeakerGroup(name: "Test", members: members, clockLeaderUID: "dac0", speakers: placed)
    }

    private func quadGroup() -> SpeakerGroup { group([(.frontLeft, -45), (.frontRight, 45), (.backLeft, -135), (.backRight, 135)]) }

    private func makeRouter(_ source: [AudioChannelLabel], _ group: SpeakerGroup) throws -> PositionRouter {
        try #require(PositionRouter(source: source, group: group))
    }

    /// The matrix as rows of (source, gain) to compare with a hand-written table; rows are the group's output channels.
    private func gains(_ router: PositionRouter, output: Int) -> [Int: Float] {
        Dictionary(uniqueKeysWithValues: router.matrixRow(output).map { ($0.source, $0.gain) })
    }

    private func expect(_ actual: [Int: Float], _ wanted: [Int: Float], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(Set(actual.keys) == Set(wanted.keys), sourceLocation: sourceLocation)
        for (source, gain) in wanted { #expect(abs((actual[source] ?? -9) - gain) < 1e-6, sourceLocation: sourceLocation) }
    }

    // MARK: Channels with a speaker of their own

    @Test("A quad file on a quad group goes channel for channel, each at exactly 1.0, nothing mixed: the leader's pair can stay bit-perfect")
    func quadOnQuad() throws {
        let router = try makeRouter(quadFile, quadGroup())
        for output in 0..<4 { #expect(router.matrixRow(output).count == 1 && router.matrixRow(output)[0] == .init(source: output, gain: 1)) }
        #expect(router.isUnmixed && router.dropped.isEmpty)
        #expect(router.untouchedOutputs == [0, 1, 2, 3])
    }

    @Test("Rendered, an unmixed channel is the file's sample to the bit, silence and negative zero included")
    func bitExact() throws {
        let router = try makeRouter(quadFile, quadGroup())
        let input: [Float] = [0.25, -0.5, -0.0, 1e-30,   0, 0.125, -1, 0.999_999_9]
        var output = [Float](repeating: 7, count: 8)
        input.withUnsafeBufferPointer { i in output.withUnsafeMutableBufferPointer { o in router.route(i.baseAddress!, into: o.baseAddress!, frames: 2) } }
        #expect(zip(input, output).allSatisfy { $0.bitPattern == $1.bitPattern })
    }

    @Test("Stereo on a quad group: the front pair gets its own channels at 1.0; the back pair is for the stereo policy to decide")
    func stereoOnQuad() throws {
        let router = try makeRouter(stereo, quadGroup())
        expect(gains(router, output: 0), [0: 1])
        expect(gains(router, output: 1), [1: 1])
        #expect(router.matrixRow(2).isEmpty && router.matrixRow(3).isEmpty)
        #expect(router.isUnmixed)
    }

    @Test("A surround pair with no speakers of that name takes the nearest single free speaker, unmixed: the quad file's Ls/Rs on the back pair")
    func nearestSingle() throws {
        let router = try makeRouter(quadFile, group([(.frontLeft, -30), (.frontRight, 30), (.backLeft, -120), (.backRight, 120)]))
        #expect(router.isUnmixed)
        expect(gains(router, output: 2), [2: 1])
    }

    // MARK: Folds

    @Test("5.1 on a quad: L + 0.707·C, R + 0.707·C, Ls and Rs alone; the LFE is left out")
    func fiveOneOnQuad() throws {
        let router = try makeRouter(surround51, quadGroup())
        expect(gains(router, output: 0), [0: 1, 2: r])
        expect(gains(router, output: 1), [1: 1, 2: r])
        expect(gains(router, output: 2), [4: 1])
        expect(gains(router, output: 3), [5: 1])
        #expect(router.dropped == [3] && !router.isUnmixed)
        #expect(router.untouchedOutputs == [2, 3])
    }

    @Test("7.1 on a quad: the sides at ±90° fall halfway between the pairs, 0.707 on each; the backs stay on the back pair")
    func sevenOneOnQuad() throws {
        let router = try makeRouter(surround71, quadGroup())
        expect(gains(router, output: 0), [0: 1, 2: r, 4: r])
        expect(gains(router, output: 1), [1: 1, 2: r, 5: r])
        expect(gains(router, output: 2), [6: 1, 4: r])
        expect(gains(router, output: 3), [7: 1, 5: r])
    }

    @Test("5.1 to two speakers at ±30°, the ITU fold: L + 0.707·C + 0.707·Ls, R + 0.707·C + 0.707·Rs; LFE out")
    func fiveOneToStereo() throws {
        let router = try makeRouter(surround51, group([(.frontLeft, -30), (.frontRight, 30)]))
        expect(gains(router, output: 0), [0: 1, 2: r, 4: r])
        expect(gains(router, output: 1), [1: 1, 2: r, 5: r])
        // Exactly the ITU number, not just near it.
        #expect(router.matrixRow(0).first { $0.source == 2 }!.gain == Float(0.5.squareRoot()))
        #expect(router.dropped == [3])
    }

    @Test("The worst case a speaker can receive is its row's sum of gains: 1 + 0.707 + 0.707 = 2.414 for the 5.1 fold (+7.7 dB), the shared preamp's measure")
    func worstCase() throws {
        let router = try makeRouter(surround51, group([(.frontLeft, -30), (.frontRight, 30)]))
        #expect(abs(router.worstCaseGain - (1 + 2 * r)) < 1e-6)
        #expect(abs(20 * log10(Double(router.worstCaseGain)) - 7.65) < 0.01)
        let unmixed = try self.makeRouter(quadFile, quadGroup())
        #expect(unmixed.worstCaseGain == 1)
    }

    @Test("A mono song is a centre: between the front pair, 0.707 on each")
    func mono() throws {
        let router = try makeRouter([kAudioChannelLabel_Mono], quadGroup())
        expect(gains(router, output: 0), [0: r])
        expect(gains(router, output: 1), [0: r])
    }

    // MARK: Ceiling speakers

    @Test("7.1.4 tops fold to the ear-level speaker under them at 0.707: Tfl → L, Tfr → R, Tbl → back left, Tbr → back right")
    func topsOnQuad() throws {
        let tops: [AudioChannelLabel] = [kAudioChannelLabel_VerticalHeightLeft, kAudioChannelLabel_VerticalHeightRight,
                                         kAudioChannelLabel_TopBackLeft, kAudioChannelLabel_TopBackRight]
        let router = try makeRouter(tops, quadGroup())
        expect(gains(router, output: 0), [0: r])
        expect(gains(router, output: 1), [1: r])
        expect(gains(router, output: 2), [2: r])
        expect(gains(router, output: 3), [3: r])
        #expect(!router.isUnmixed)
    }

    @Test("A group with its own ceiling speakers plays the tops on them, at 1.0")
    func topsOnTops() throws {
        let g = group([(.frontLeft, -30), (.frontRight, 30), (.topFrontLeft, -45), (.topFrontRight, 45)])
        let tops: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_VerticalHeightLeft, kAudioChannelLabel_VerticalHeightRight]
        let router = try makeRouter(tops, g)
        #expect(router.isUnmixed)
        expect(gains(router, output: 2), [2: 1])
    }

    @Test("Ceiling speakers in a group are not pan targets for ear-level channels")
    func heightsNotPanTargets() throws {
        let g = group([(.frontLeft, -30), (.frontRight, 30), (.topFrontLeft, 0), (.topFrontRight, 0)])
        let router = try makeRouter([kAudioChannelLabel_Center], g)
        expect(gains(router, output: 0), [0: r])
        #expect(router.matrixRow(2).isEmpty && router.matrixRow(3).isEmpty)
    }

    // MARK: LFE

    @Test("A group with a subwoofer plays the LFE on it at 1.0")
    func lfeOnSub() throws {
        let g = group([(.frontLeft, -30), (.frontRight, 30), (.lfe, 0)])
        let router = try makeRouter(surround51, g)
        expect(gains(router, output: 2), [3: 1])
    }

    @Test("With no subwoofer the LFE policy decides: dropped, added to every speaker at a level, or to one speaker")
    func lfePolicies() throws {
        var g = quadGroup()
        #expect(try makeRouter(surround51, g).dropped == [3])
        g.lfePolicy = .toAll(dB: -6)
        let all = try makeRouter(surround51, g)
        for output in 0..<4 { #expect(abs((gains(all, output: output)[3] ?? 0) - Float(pow(10, -6.0 / 20))) < 1e-6) }
        #expect(all.dropped.isEmpty)
        g.lfePolicy = .toSpeaker(g.speakers[2].id)
        let one = try makeRouter(surround51, g)
        expect(gains(one, output: 2), [3: 1, 4: 1])
        #expect((gains(one, output: 0)[3]) == nil)
    }

    // MARK: Where the speakers really stand

    @Test("Panning follows the angles drawn: a centre between speakers at -20° and +40° leans to the nearer one")
    func oddAngles() throws {
        let g = group([(.frontLeft, -20), (.frontRight, 40)])
        let router = try makeRouter([kAudioChannelLabel_Center], g)
        let left = gains(router, output: 0)[0]!, right = gains(router, output: 1)[0]!
        // The tangent law: (gR − gL) / (gR + gL) = tan(θ) / tan(θ0), θ the centre's offset from the pair's middle, θ0 half the gap.
        let theta = (0.0 - 10.0) * Double.pi / 180, theta0 = 30.0 * Double.pi / 180
        #expect(abs(Double(right - left) / Double(right + left) - tan(theta) / tan(theta0)) < 1e-6)
        #expect(left > right)
        #expect(abs(left * left + right * right - 1) < 1e-6)
    }

    @Test("Turning the listener changes the panning: facing 15° right puts the centre's source dead between a pair at ±15°")
    func facingChangesAngles() throws {
        var g = group([(.frontLeft, 0), (.frontRight, 30)])
        let before = try makeRouter([kAudioChannelLabel_Center], g)
        #expect(gains(before, output: 0)[0]! > (gains(before, output: 1)[0] ?? 0))        // the centre (0°) is on the left speaker
        g.listener.facingDegrees = 15
        let after = try makeRouter([kAudioChannelLabel_Center], g)
        // Now the speakers are at -15° and +15°, and the centre is where the listener faces.
        expect(gains(after, output: 0), [0: r])
        expect(gains(after, output: 1), [0: r])
    }

    @Test("A channel outside every pair's arc goes to the nearest speaker alone, at 0.707")
    func outsideTheArc() throws {
        let g = group([(.frontLeft, -90), (.sideLeft, -30)])
        let router = try makeRouter([kAudioChannelLabel_Right], g)
        expect(gains(router, output: 1), [0: r])
        #expect(router.matrixRow(0).isEmpty)
    }

    @Test("Equal power: wherever a panned channel falls, its gains square-sum to 1, for any placement of the speakers")
    func equalPower() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let count = Int.random(in: 3...6, using: &generator)
            // Speakers spread around the seat with no gap of 180° or more, so every direction has a pair.
            var angles = (0..<count).map { Double($0) * 360 / Double(count) + Double.random(in: -20...20, using: &generator) }
            angles = angles.map { $0 > 180 ? $0 - 360 : $0 }
            let roles: [SpeakerRole] = [.frontLeft, .frontRight, .center, .sideLeft, .sideRight, .backLeft]
            let g = group(Array(zip(roles.prefix(count), angles)))
            guard let router = PositionRouter(source: surround51, group: g) else { continue }
            for (s, routes) in router.routes.enumerated() where s != 3 && routes.count == 2 {
                #expect(abs(routes.reduce(Float(0)) { $0 + $1.gain * $1.gain } - 1) < 1e-5)
            }
        }
    }

    // MARK: Output channels follow the group's member order

    @Test("Rows are the aggregate's channels: reversing the members moves the rows, not the speakers")
    func memberOrder() throws {
        var g = quadGroup()
        g.members.reverse()                                          // the back pair's DAC now comes first
        let router = try makeRouter(quadFile, g)
        expect(gains(router, output: 0), [2: 1])                     // back left
        expect(gains(router, output: 2), [0: 1])                     // front left
        #expect(router.outputChannels == 4)
    }

    @Test("Channels no speaker is wired to stay silent")
    func unusedChannels() throws {
        var g = quadGroup()
        g.members[1].channelCount = 4                                // the second DAC has two outputs nobody uses
        let router = try makeRouter(quadFile, g)
        #expect(router.outputChannels == 6 && router.matrixRow(4).isEmpty && router.matrixRow(5).isEmpty)
    }

    // MARK: Refusals and rendering

    @Test("No router when there is nothing to play on or nothing to play")
    func refusals() {
        #expect(PositionRouter(source: [], group: quadGroup()) == nil)
        #expect(PositionRouter(source: quadFile, group: quadGroup().withoutSpeakers()) == nil)
        let onlyHeights = group([(.topFrontLeft, -45), (.topFrontRight, 45)])
        #expect(PositionRouter(source: [kAudioChannelLabel_Center], group: onlyHeights) != nil)       // no ear-level speaker: nothing to pan across, dropped
        #expect(PositionRouter(source: [kAudioChannelLabel_Center], group: onlyHeights)?.dropped == [0])
    }

    @Test("Channels with no label that names a speaker are dropped, not guessed")
    func unnamedChannels() throws {
        let router = try makeRouter([kAudioChannelLabel_Left, kAudioChannelLabel_Unknown, kAudioChannelLabel_Right], quadGroup())
        #expect(router.dropped == [1])
        expect(gains(router, output: 1), [2: 1])
    }

    @Test("A speaker that can't be placed (at the seat, or not a number) is never a pan target, and no gain is ever not a number")
    func unplaceableSpeakers() throws {
        var g = quadGroup()
        g.speakers[0].position = g.listener.position
        g.speakers[3].position = Point2D(x: .nan, y: 1)
        let router = try makeRouter(surround51, g)
        #expect(router.routes.joined().allSatisfy { $0.gain.isFinite && $0.gain >= 0 && $0.gain <= 1 })
        // The centre is panned across what is left: the front right (45°) and the back left (-135°), a gap of 180° that no pair spans, so it folds.
        #expect(router.routes[2].count == 1 && router.routes[2][0].kind == .folded)
        // A channel with a speaker of its own still plays on it, wherever that stands.
        #expect(router.routes[0] == [.init(output: 0, gain: 1, kind: .own)])
    }

    @Test("Rendering a 5.1 frame to two speakers gives the hand-computed sums")
    func render() throws {
        let router = try makeRouter(surround51, group([(.frontLeft, -30), (.frontRight, 30)]))
        let frame: [Float] = [0.5, -0.25, 0.4, 0.9, 0.2, -0.1]       // L R C LFE Ls Rs
        var out = [Float](repeating: 0, count: 2)
        frame.withUnsafeBufferPointer { i in out.withUnsafeMutableBufferPointer { o in router.route(i.baseAddress!, into: o.baseAddress!, frames: 1) } }
        #expect(abs(out[0] - (0.5 + r * 0.4 + r * 0.2)) < 1e-6)
        #expect(abs(out[1] - (-0.25 + r * 0.4 + r * -0.1)) < 1e-6)
    }
}
