//
// Vespertine: speaker groups: presets that lay out the speakers (stereo up to 9.1.6), and the readout of where each
// speaker stands and what that asks of it (distance, angle, delay, level). Pure; no view.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Group presets and readout")
struct GroupPresetsTests {
    private let fosi = "fosi-uid", fiio = "fiio-uid", third = "third-uid"

    private func quadGroup(facing: Double = 0, room: RoomOutline? = RoomOutline(width: 8, depth: 8)) -> SpeakerGroup {
        SpeakerGroup(name: "Downstairs quad",
                     members: [SpeakerGroup.Member(deviceUID: fosi, name: "Fosi ZD3", channelCount: 2),
                               SpeakerGroup.Member(deviceUID: fiio, name: "FiiO K11", channelCount: 2)],
                     clockLeaderUID: fosi, listener: Listener(position: Point2D(), facingDegrees: facing), room: room)
    }

    private func sixChannel() -> SpeakerGroup {
        var g = quadGroup()
        g.members.append(SpeakerGroup.Member(deviceUID: third, name: "Third DAC", channelCount: 2))
        return g
    }

    private func place(_ g: SpeakerGroup, _ role: SpeakerRole) -> (distance: Double, azimuth: Double)? {
        guard let s = g.speakers.first(where: { $0.role == role }) else { return nil }
        return (SpeakerGeometry.distance(from: g.listener, to: s.position), SpeakerGeometry.azimuth(from: g.listener, to: s.position))
    }

    // MARK: Presets

    @Test("Quad: front left and right at 45° either side, back left and right at 135°, 2 m away, on the channels in order")
    func quad() throws {
        let g = try #require(GroupPresets.apply(.quad, to: quadGroup()))
        #expect(GroupChannelMap.rows(g).map(\.role) == [.frontLeft, .frontRight, .backLeft, .backRight])
        for (role, azimuth) in [(SpeakerRole.frontLeft, -45.0), (.frontRight, 45), (.backLeft, -135), (.backRight, 135)] {
            let p = try #require(place(g, role))
            #expect(abs(p.distance - 2) < 1e-9 && abs(p.azimuth - azimuth) < 1e-9, "\(role): \(p)")
        }
        #expect(g.isValid, "\(g.issues)")
    }

    @Test("ITU 5.1: front pair at 30°, centre ahead, surrounds at 110°, the subwoofer in front; it needs six channels")
    func itu51() throws {
        #expect(GroupPresets.apply(.itu51, to: quadGroup()) == nil, "four channels are too few")
        let g = try #require(GroupPresets.apply(.itu51, to: sixChannel()))
        #expect(GroupChannelMap.rows(g).map(\.role) == [.frontLeft, .frontRight, .center, .lfe, .sideLeft, .sideRight])
        let frontLeft = try #require(place(g, .frontLeft)), centre = try #require(place(g, .center)), surround = try #require(place(g, .sideRight))
        #expect(abs(frontLeft.azimuth - -30) < 1e-9 && abs(centre.azimuth) < 1e-9)
        #expect(abs(surround.azimuth - 110) < 1e-9)
        #expect(g.isValid, "\(g.issues)")
    }

    @Test("Two pairs facing: the leader's pair 1.5 m ahead at 30°, the other pair 2.5 m behind at 150°")
    func twoPairsFacing() throws {
        let g = try #require(GroupPresets.apply(.twoPairsFacing, to: quadGroup()))
        #expect(GroupChannelMap.rows(g).map(\.role) == [.frontLeft, .frontRight, .backLeft, .backRight])
        let front = try #require(place(g, .frontRight)), back = try #require(place(g, .backLeft))
        #expect(abs(front.distance - 1.5) < 1e-9 && abs(front.azimuth - 30) < 1e-9)
        #expect(abs(back.distance - 2.5) < 1e-9 && abs(back.azimuth - -150) < 1e-9)
    }

    @Test("A preset follows where the seat faces and stands where the seat is")
    func followsSeat() throws {
        var base = quadGroup(facing: 90)
        base.listener.position = Point2D(x: 0.5, y: 0)
        let g = try #require(GroupPresets.apply(.quad, to: base))
        let fl = try #require(place(g, .frontLeft))
        #expect(abs(fl.azimuth - -45) < 1e-9 && abs(fl.distance - 2) < 1e-9, "relative to the seat: \(fl)")
        let s = try #require(g.speakers.first { $0.role == .frontLeft })
        #expect(s.position.x > 0.5 && s.position.y > 0, "facing right, front left is up and to the right of the seat")
    }

    @Test("A preset replaces the speakers but keeps the group's other settings; extra channels stay free; the room is not left")
    func keeps() throws {
        var base = quadGroup(room: RoomOutline(width: 3, depth: 3))
        base.stereoPolicy = .mirror(trimDB: -3)
        base.onMemberLoss = .continueOnRemaining
        base.speakers = [SpeakerGroup.Speaker(role: .center, deviceUID: fosi, channel: 0, position: Point2D(x: 0, y: 1))]
        let g = try #require(GroupPresets.apply(.quad, to: base))
        #expect(g.stereoPolicy == base.stereoPolicy && g.onMemberLoss == .continueOnRemaining && g.name == base.name && g.id == base.id)
        #expect(g.speakers.count == 4 && !g.speakers.contains { $0.role == .center })
        #expect(g.speakers.allSatisfy { abs($0.position.x) <= 1.5 && abs($0.position.y) <= 1.5 }, "held inside a 3 m room")
        let six = try #require(GroupPresets.apply(.quad, to: sixChannel()))
        #expect(GroupChannelMap.unassigned(six).count == 2)
    }

    @Test("Which presets fit a group: by its channels")
    func available() {
        #expect(GroupPresets.available(for: quadGroup()) == [.stereo, .stereoSub, .frontThreeSub, .quad, .twoPairsFacing])
        #expect(GroupPresets.available(for: sixChannel()) == [.stereo, .stereoSub, .frontThreeSub, .quad, .twoPairsFacing, .itu51])
        #expect(GroupPresets.available(for: channels(16)) == GroupPresets.Preset.allCases)
        #expect(GroupPresets.Preset.quad.title == "Quad" && GroupPresets.Preset.itu51.title == "ITU 5.1" && GroupPresets.Preset.twoPairsFacing.title == "Two pairs facing")
        #expect(GroupPresets.Preset.surround714.title == "7.1.4" && GroupPresets.Preset.stereoSub.title == "2.1")
    }

    /// A group of two-channel DACs with that many channels, in a 6 by 6 m room with a 2.6 m ceiling and ears at 1.1 m.
    private func channels(_ count: Int) -> SpeakerGroup {
        SpeakerGroup(name: "Cinema",
                     members: (0..<(count / 2)).map { SpeakerGroup.Member(deviceUID: "dac\($0)", name: "DAC \($0)", channelCount: 2) },
                     clockLeaderUID: "dac0", listener: Listener(position: Point2D(), facingDegrees: 0, earHeight: 1.1),
                     room: RoomOutline(width: 6, depth: 6, height: 2.6))
    }

    @Test("Every preset: as many speakers as its name counts, no place twice, each on a channel of its own, and a group that is valid",
          arguments: GroupPresets.Preset.allCases)
    func everyPreset(_ preset: GroupPresets.Preset) throws {
        let g = try #require(GroupPresets.apply(preset, to: channels(16)))
        let counted: [GroupPresets.Preset: Int] = [.stereo: 2, .stereoSub: 3, .frontThreeSub: 4, .quad: 4, .twoPairsFacing: 4, .itu51: 6, .surround71: 8,
                                                   .surround512: 8, .surround514: 10, .surround712: 10, .surround714: 12, .surround916: 16]
        #expect(g.speakers.count == counted[preset])
        #expect(Set(g.speakers.map(\.role)).count == g.speakers.count, "no place twice")
        #expect(Set(g.speakers.map { "\($0.deviceUID)/\($0.channel)" }).count == g.speakers.count, "a channel each")
        #expect(g.isValid, "\(g.issues)")
        #expect(GroupPresets.apply(preset, to: channels(g.speakers.count + (g.speakers.count % 2))) != nil, "it fits on just enough channels")
        if g.speakers.count >= 4 { #expect(GroupPresets.apply(preset, to: channels(2)) == nil) }
        // Left and right are mirrored about where the seat faces.
        for s in g.speakers where s.position.x < -1e-9 {
            #expect(g.speakers.contains { abs($0.position.x + s.position.x) < 1e-9 && abs($0.position.y - s.position.y) < 1e-9 && $0.height == s.height },
                    "\(s.role) has no mirror")
        }
    }

    @Test("Ceiling speakers go on the ceiling: 1.5 m above ears at 1.1 m under a 2.6 m ceiling, the front and back pairs 45° up, the middle pair steeper")
    func ceilingSpeakers() throws {
        let g = try #require(GroupPresets.apply(.surround916, to: channels(16)))
        let tops = g.speakers.filter { $0.role.rawValue.hasPrefix("T") }
        #expect(tops.count == 6 && tops.allSatisfy { abs(($0.height ?? 0) - 1.5) < 1e-9 })
        #expect(g.speakers.filter { !$0.role.rawValue.hasPrefix("T") }.allSatisfy { $0.height == nil }, "the rest at the ears")
        #expect(tops.allSatisfy { abs(g.heightAboveFloor(of: $0) - 2.6) < 1e-9 })
        let front = try #require(place(g, .topFrontLeft)), middle = try #require(place(g, .topMiddleRight)), back = try #require(place(g, .topBackRight))
        #expect(abs(front.distance - 1.5) < 1e-9 && abs(front.azimuth - -45) < 1e-9)
        #expect(abs(middle.distance - 0.75) < 1e-9 && abs(middle.azimuth - 90) < 1e-9)
        #expect(abs(back.distance - 1.5) < 1e-9 && abs(back.azimuth - 135) < 1e-9)
        #expect(GroupPresets.Preset.surround512.hasCeilingSpeakers && !GroupPresets.Preset.surround71.hasCeilingSpeakers)
        // With no ceiling height or ear height set, the usual ones: 2.4 m and 1.2 m.
        var plain = channels(16)
        plain.room = RoomOutline(width: 6, depth: 6)
        plain.listener = Listener(position: Point2D(), facingDegrees: 0)
        let usual = try #require(GroupPresets.apply(.surround514, to: plain))
        #expect(usual.speakers.filter { $0.height != nil }.allSatisfy { abs(($0.height ?? 0) - 1.2) < 1e-9 })
    }

    @Test("7.1 puts the side pair beside the seat and the back pair at 150°; 9.1.6 adds the wide pair at 60°; each fills its Mac layout")
    func larger() throws {
        let seven = try #require(GroupPresets.apply(.surround71, to: channels(8)))
        #expect(GroupChannelMap.rows(seven).map(\.role) == [.frontLeft, .frontRight, .center, .lfe, .sideLeft, .sideRight, .backLeft, .backRight])
        let side = try #require(place(seven, .sideLeft)), back = try #require(place(seven, .backRight))
        #expect(abs(side.azimuth - -90) < 1e-9 && abs(back.azimuth - 150) < 1e-9)
        let nine = try #require(GroupPresets.apply(.surround916, to: channels(16)))
        let wide = try #require(place(nine, .wideRight))
        #expect(abs(wide.azimuth - 60) < 1e-9)
        #expect(SystemOutputLayout.automatic(for: seven) == .surround71)
        #expect(SystemOutputLayout.automatic(for: try #require(GroupPresets.apply(.surround714, to: channels(12)))) == .surround714)
        #expect(SystemOutputLayout.automatic(for: nine) == .surround916)
    }

    // MARK: Readout

    @Test("The two-pair example: the near pair 1.5 m away waits 2.9 ms (140 frames at 48 kHz) and is 4.4 dB down; the pair at 2.5 m waits for nothing")
    func downstairs() throws {
        let g = try #require(GroupPresets.apply(.twoPairsFacing, to: quadGroup()))
        let rows = GroupReadout.rows(g, sampleRate: 48_000, unit: .metres)
        #expect(rows.map(\.role) == [.frontLeft, .frontRight, .backLeft, .backRight])
        let front = rows[0], back = rows[2]
        #expect(front.distance == "1.5 m" && back.distance == "2.5 m")
        #expect(front.angle == "30° left")
        #expect(front.delay == "2.9 ms · 140 frames" && back.delay == "0 ms")
        #expect(front.level == "-4.4 dB" && back.level == "0 dB")
        #expect(rows.allSatisfy { !$0.delayLimited })
    }

    @Test("Feet, the angle the other way, and a speaker that isn't placed isn't in the readout")
    func units() throws {
        var g = try #require(GroupPresets.apply(.twoPairsFacing, to: quadGroup()))
        let rows = GroupReadout.rows(g, sampleRate: 96_000, unit: .feet)
        #expect(rows[0].distance == "4.9 ft" && rows[1].angle == "30° right")
        #expect(rows[0].delay == "2.9 ms · 280 frames")
        g.speakers[0].position = g.listener.position
        #expect(GroupReadout.rows(g, sampleRate: 48_000, unit: .metres).count == 3)
        #expect(GroupReadout.rows(g, sampleRate: 48_000, unit: .metres).first?.role == .frontRight)
    }
}
