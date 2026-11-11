//
// Vespertine: Mac Sound Output (beta): the layouts a group's output shows, how what other apps play is put on the speakers, how a
// stereo source is told from a surround one, and what the app hands the helper. No device needed.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreAudio
import Foundation
import Testing
@testable import VespertineAudio

@Suite("Mac Sound Output")
struct SystemOutputTests {
    /// A group whose speakers stand at these angles, 2 m from the seat, over as many two-channel DACs as it takes.
    private func group(_ speakers: [(SpeakerRole, Double)], stereo: StereoPolicy = .frontOnly, name: String = "Living room") -> SpeakerGroup {
        let dacs = (speakers.count + 1) / 2
        let members = (0..<dacs).map { SpeakerGroup.Member(deviceUID: "dac\($0)", name: "DAC \($0)", channelCount: 2) }
        let placed = speakers.enumerated().map { i, entry in
            SpeakerGroup.Speaker(role: entry.0, deviceUID: "dac\(i / 2)", channel: i % 2,
                                 position: Point2D(x: 2 * sin(entry.1 * .pi / 180), y: 2 * cos(entry.1 * .pi / 180)))
        }
        return SpeakerGroup(name: name, members: members, clockLeaderUID: "dac0", speakers: placed, stereoPolicy: stereo)
    }

    private func quad(_ stereo: StereoPolicy = .frontOnly) -> SpeakerGroup {
        group([(.frontLeft, -45), (.frontRight, 45), (.backLeft, -135), (.backRight, 135)], stereo: stereo)
    }

    private let five1 = SystemOutputLayout.surround51.labels!

    // MARK: Layouts

    @Test("Automatic layout: two speakers are stereo, a quad and a 5.1 are 5.1, side plus back is 7.1, heights 7.1.4, wides 9.1.6")
    func automaticLayouts() {
        #expect(SystemOutputLayout.automatic(for: group([(.frontLeft, -30), (.frontRight, 30)])) == .stereo)
        #expect(SystemOutputLayout.automatic(for: quad()) == .surround51)
        #expect(SystemOutputLayout.automatic(for: group([(.frontLeft, -30), (.frontRight, 30), (.center, 0), (.lfe, 0),
                                                         (.sideLeft, -110), (.sideRight, 110)])) == .surround51)
        #expect(SystemOutputLayout.automatic(for: group([(.frontLeft, -30), (.frontRight, 30), (.sideLeft, -90), (.sideRight, 90),
                                                         (.backLeft, -150), (.backRight, 150)])) == .surround71)
        #expect(SystemOutputLayout.automatic(for: group([(.frontLeft, -30), (.frontRight, 30), (.sideLeft, -110), (.sideRight, 110),
                                                         (.topFrontLeft, -45), (.topFrontRight, 45)])) == .surround714)
        #expect(SystemOutputLayout.automatic(for: group([(.frontLeft, -30), (.frontRight, 30), (.wideLeft, -60), (.wideRight, 60)])) == .surround916)
    }

    @Test("Every fixed layout has distinct labels, as many as its name says, and none past the engine's 16 channels")
    func layoutLabels() {
        let counts: [SystemOutputLayout: Int] = [.stereo: 2, .quad: 4, .surround51: 6, .surround71: 8, .surround714: 12, .surround916: 16]
        for (layout, count) in counts {
            let labels = layout.labels ?? []
            #expect(labels.count == count, "\(layout)")
            #expect(Set(labels).count == labels.count, "\(layout)")
            #expect(labels.count <= SystemOutput.maxChannels)
        }
        #expect(SystemOutputLayout.automatic.labels == nil)
    }

    // MARK: Routing

    @Test("A 5.1 film on a quad: L R and the surrounds on their own speakers at 1.0, the centre split between the front pair")
    func filmOnQuad() throws {
        let gains = try #require(SystemOutputRouting.matrix(input: five1, group: quad(), content: .multichannel, stereo: .asGroup))
        #expect(gains.count == 4 * 6)
        func g(_ out: Int, _ input: Int) -> Float { gains[out * 6 + input] }
        #expect(g(0, 0) == 1 && g(1, 1) == 1 && g(2, 4) == 1 && g(3, 5) == 1)
        #expect(g(0, 2) > 0.5 && g(1, 2) > 0.5 && abs(g(0, 2) - g(1, 2)) < 1e-6)
        #expect(g(2, 2) == 0 && g(3, 2) == 0)
    }

    @Test("Stereo as the group plays it: the group's front-only policy leaves the back pair silent")
    func stereoAsGroup() throws {
        let gains = try #require(SystemOutputRouting.matrix(input: five1, group: quad(), content: .stereo, stereo: .asGroup))
        func g(_ out: Int, _ input: Int) -> Float { gains[out * 6 + input] }
        #expect(g(0, 0) == 1 && g(1, 1) == 1)
        #expect((0..<6).allSatisfy { g(2, $0) == 0 && g(3, $0) == 0 })
    }

    @Test("Extended stereo: left on both left speakers, right on both right ones, whatever the group's own policy")
    func extendedStereo() throws {
        let gains = try #require(SystemOutputRouting.matrix(input: five1, group: quad(.frontOnly), content: .stereo, stereo: .extended))
        func g(_ out: Int, _ input: Int) -> Float { gains[out * 6 + input] }
        #expect(g(0, 0) > 0 && g(2, 0) > 0 && g(0, 1) == 0 && g(2, 1) == 0)
        #expect(g(1, 1) > 0 && g(3, 1) > 0 && g(1, 0) == 0 && g(3, 0) == 0)
        // The other inputs (silent under stereo) are not read.
        #expect((0..<4).allSatisfy { out in (2..<6).allSatisfy { g(out, $0) == 0 } })
    }

    @Test("Upmix: the matrix is the upmixer's 5.1 onto the group (six inputs, the surrounds on the back pair)")
    func upmixMatrix() throws {
        let gains = try #require(SystemOutputRouting.matrix(input: [kAudioChannelLabel_Left, kAudioChannelLabel_Right], group: quad(),
                                                            content: .stereo, stereo: .upmix))
        #expect(gains.count == 4 * StereoUpmixer.outputChannels)
        #expect(gains[2 * 6 + 4] == 1 && gains[3 * 6 + 5] == 1)
    }

    @Test("A stereo output reads its own pair: front pair found by label, not position")
    func frontPair() {
        #expect(SystemOutputRouting.frontPair([kAudioChannelLabel_Center, kAudioChannelLabel_Left, kAudioChannelLabel_Right]) == (1, 2))
        #expect(SystemOutputRouting.frontPair([kAudioChannelLabel_Mono]) == (0, 0))
    }

    // MARK: Telling stereo from surround

    @Test("Surround is taken at once; stereo after the other channels stay silent long enough, longer once surround was heard")
    func detector() {
        var d = SystemOutputContentDetector(input: five1)
        #expect(d.content == .stereo)
        let front: [Float] = [0.5, 0.5, 0, 0, 0, 0]
        let film: [Float] = [0.5, 0.5, 0.2, 0, 0.01, 0.01]
        #expect(d.update(peaks: film, seconds: 0.05))
        #expect(d.content == .multichannel)
        // A quiet stretch of the film: still surround after a few seconds.
        for _ in 0..<100 { _ = d.update(peaks: front, seconds: 0.05) }
        #expect(d.content == .multichannel)
        for _ in 0..<70 { _ = d.update(peaks: front, seconds: 0.05) }
        #expect(d.content == .stereo)
        // Silence everywhere changes nothing.
        _ = d.update(peaks: film, seconds: 0.05)
        for _ in 0..<1000 { _ = d.update(peaks: [0, 0, 0, 0, 0, 0], seconds: 0.05) }
        #expect(d.content == .multichannel)
    }

    @Test("A two-channel output is always stereo")
    func stereoOutputDetector() {
        var d = SystemOutputContentDetector(input: [kAudioChannelLabel_Left, kAudioChannelLabel_Right])
        #expect(!d.update(peaks: [1, 1], seconds: 1))
        #expect(d.content == .stereo)
    }

    // MARK: What the app hands the helper

    @Test("The snapshot round-trips through its file, and each group's output is named after the group with a stable UID")
    func snapshot() throws {
        let g = quad()
        let entry = SystemOutputEntry(group: g, choice: SystemOutputChoice(published: true, layout: .automatic, stereo: .upmix))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = SystemOutputSnapshot.url(in: directory)
        try SystemOutputSnapshot(entries: [entry]).write(to: url)
        let read = try #require(SystemOutputSnapshot.read(from: url))
        #expect(read.entries == [entry])
        #expect(entry.deviceUID == SystemOutput.deviceUID(groupID: g.id) && SystemOutput.isSystemOutputUID(entry.deviceUID))
        #expect(entry.captureUID == entry.deviceUID + ".capture")

        let config = SystemOutput.driverConfiguration([entry], latency: [entry.deviceUID: 1234])
        #expect(config.count == 1)
        #expect(config[0]["name"] as? String == "Living room")
        #expect(config[0]["channels"] as? Int == 6)
        #expect(config[0]["latency"] as? Int == 1234)
        #expect((config[0]["labels"] as? [Int])?.count == 6)
    }

    @Test("Off by default, and a snapshot from another version is not read")
    func defaults() throws {
        #expect(!SystemOutputChoice().published)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = SystemOutputSnapshot.url(in: directory)
        var snapshot = SystemOutputSnapshot(entries: [])
        snapshot.version = 99
        try snapshot.write(to: url)
        #expect(SystemOutputSnapshot.read(from: url) == nil)
    }

    @Test("The capture device goes first in the aggregate, records only, and follows the group's clock leader")
    func capturePlan() throws {
        let plan = try GroupAggregate.plan(for: quad(), capture: "cap", clockDomain: { _ in 0 })
        #expect(plan.members.first?.uid == "cap" && plan.members.first?.inputOnly == true)
        #expect(plan.leaderUID == "dac0")
        #expect(plan.drift.first == true)
        #expect(plan.outputMemberCount == 2)
    }

    // MARK: Upmix routing

    @Test("Upmix routing: a surround source comes out exactly as the direct path would, held back by the upmixer's latency")
    func upmixSurroundAligned() throws {
        let g = quad()
        var routing = try #require(UpmixRouting(input: five1, group: g, rate: 48_000, settings: UpmixSettings()))
        let hop = routing.hop
        let latency = routing.latency
        #expect(latency == UpmixRouting.latency(rate: 48_000))
        let router = try #require(PositionRouter(source: five1, group: g))
        let hops = latency / hop + 4
        // A surround signal: a ramp on every channel, the surrounds never silent.
        let frames = hops * hop
        var input = [Float](repeating: 0, count: frames * 6)
        for f in 0..<frames { for c in 0..<6 { input[f * 6 + c] = Float((f * 7 + c * 13) % 101) / 101 - 0.5 + (c >= 4 ? 0.01 : 0) } }
        var output = [Float](repeating: 0, count: frames * 4)
        for h in 0..<hops {
            input.withUnsafeBufferPointer { i in output.withUnsafeMutableBufferPointer { o in
                _ = routing.process(i.baseAddress! + h * hop * 6, into: o.baseAddress! + h * hop * 4)
            } }
        }
        #expect(routing.content == .multichannel)
        // Past the switch from stereo (the first hop crossfades), every frame is the direct route of the input `latency` frames back.
        var direct = [Float](repeating: 0, count: frames * 4)
        input.withUnsafeBufferPointer { i in direct.withUnsafeMutableBufferPointer { o in router.route(i.baseAddress!, into: o.baseAddress!, frames: frames) } }
        for f in max(latency, 2 * hop)..<frames {
            for o in 0..<4 { #expect(abs(output[f * 4 + o] - direct[(f - latency) * 4 + o]) < 1e-5) }
        }
    }

    @Test("Upmix routing: a stereo source plays on every speaker of a quad once the upmixer has filled")
    func upmixStereo() throws {
        var routing = try #require(UpmixRouting(input: five1, group: quad(), rate: 48_000, settings: UpmixSettings()))
        let hop = routing.hop
        let hops = routing.latency / hop + 8
        var output = [Float](repeating: 0, count: hop * 4)
        var energy = [Float](repeating: 0, count: 4)
        var phase = 0.0
        for h in 0..<hops {
            var input = [Float](repeating: 0, count: hop * 6)
            for f in 0..<hop {
                // Different on each side: ambience for the surrounds.
                input[f * 6] = Float(sin(phase) * 0.5)
                input[f * 6 + 1] = Float(sin(phase * 1.31 + 1) * 0.5)
                phase += 2 * .pi * 440 / 48_000
            }
            input.withUnsafeBufferPointer { i in output.withUnsafeMutableBufferPointer { o in _ = routing.process(i.baseAddress!, into: o.baseAddress!) } }
            if h >= hops - 2 { for f in 0..<hop { for o in 0..<4 { energy[o] += output[f * 4 + o] * output[f * 4 + o] } } }
        }
        #expect(routing.content == .stereo)
        #expect(energy.allSatisfy { $0 > 0 })
    }
}
