//
// Vespertine — speaker groups: from where the speakers and the seat stand to each speaker's distance, angle, delay and level.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("Speaker geometry")
struct SpeakerGeometryTests {
    /// The plan's example room: one pair 1.5 m from the seat, the other pair 2.5 m.
    private func downstairs() -> SpeakerGroup {
        var group = GroupFixtures.quad()
        group.speakers[0].position = Point2D(x: -1.2, y: 0.9)       // 1.5 m: a 3-4-5 triangle
        group.speakers[1].position = Point2D(x: 1.2, y: 0.9)
        group.speakers[2].position = Point2D(x: -2, y: -1.5)        // 2.5 m
        group.speakers[3].position = Point2D(x: 2, y: -1.5)
        return group
    }

    private func entry(_ alignment: [SpeakerAlignment], _ role: SpeakerRole) -> SpeakerAlignment {
        alignment.first { $0.role == role }!
    }

    @Test("Distance and angle from the seat: straight ahead is 0°, to the right is positive")
    func distanceAndAzimuth() {
        let seat = Listener()
        #expect(abs(SpeakerGeometry.distance(from: seat, to: Point2D(x: 3, y: 4)) - 5) < 1e-12)
        #expect(SpeakerGeometry.azimuth(from: seat, to: Point2D(x: 0, y: 2)) == 0)
        #expect(abs(SpeakerGeometry.azimuth(from: seat, to: Point2D(x: 2, y: 0)) - 90) < 1e-12)
        #expect(abs(SpeakerGeometry.azimuth(from: seat, to: Point2D(x: -1, y: 0)) + 90) < 1e-12)
        #expect(abs(abs(SpeakerGeometry.azimuth(from: seat, to: Point2D(x: 0, y: -1))) - 180) < 1e-12)
        #expect(abs(SpeakerGeometry.azimuth(from: seat, to: Point2D(x: 1, y: 1)) - 45) < 1e-12)
    }

    @Test("The angle is measured from where the listener faces, and wraps at ±180°")
    func facing() {
        let right = Listener(position: Point2D(), facingDegrees: 90)
        #expect(abs(SpeakerGeometry.azimuth(from: right, to: Point2D(x: 2, y: 0))) < 1e-12)
        #expect(abs(SpeakerGeometry.azimuth(from: right, to: Point2D(x: 0, y: 2)) + 90) < 1e-12)
        let back = Listener(position: Point2D(x: 1, y: 1), facingDegrees: 170)
        // The speaker is at a bearing of -170° from the seat; 20° clockwise of where the listener faces, past the back.
        let bearing = SpeakerGeometry.azimuth(from: back, to: Point2D(x: 1 + sin(-170 * .pi / 180), y: 1 + cos(-170 * .pi / 180)))
        #expect(abs(bearing - 20) < 1e-9)
        #expect(abs(SpeakerGeometry.azimuth(from: Listener(facingDegrees: 360), to: Point2D(x: 0, y: 1))) < 1e-9)
    }

    @Test("The plan's two-pair example: pairs at 1.5 m and 2.5 m, so the near pair waits 2.92 ms (140 frames at 48 kHz) and is 4.4 dB down")
    func downstairsExample() {
        let alignment = SpeakerGeometry.alignment(for: downstairs(), sampleRate: 48_000)
        let near = entry(alignment, .frontLeft), far = entry(alignment, .backLeft)
        #expect(abs(near.distance - 1.5) < 1e-12 && abs(far.distance - 2.5) < 1e-12)
        #expect(abs(near.delayMs - 1000 / 343) < 1e-9)
        #expect(abs(near.delayFrames - 139.9) < 0.1 && near.roundedDelayFrames == 140)
        #expect(abs(near.geometryGainDB - 20 * log10(1.5 / 2.5)) < 1e-12)
        #expect(abs(near.geometryGainDB + 4.437) < 0.001)
        #expect(far.delayMs == 0 && far.geometryGainDB == 0)
    }

    @Test("The farthest speaker is the reference: no delay, no cut; every other one is delayed and cut, never boosted")
    func referenceAndNeverBoost() {
        var group = GroupFixtures.quad()
        let distances: [Double] = [1.0, 1.7, 2.2, 3.1]
        for (i, d) in distances.enumerated() { group.speakers[i].position = Point2D(x: d * 0.6, y: d * 0.8) }
        let alignment = SpeakerGeometry.alignment(for: group, sampleRate: 96_000)
        #expect(alignment.allSatisfy { $0.geometryGainDB <= 0 && $0.delayMs >= 0 })
        let far = alignment.max { $0.distance < $1.distance }!
        #expect(far.delayMs == 0 && far.geometryGainDB == 0)
        // Delay and level follow distance from the farthest: a nearer speaker waits longer and is quieter.
        let sorted = alignment.sorted { $0.distance < $1.distance }
        for (a, b) in zip(sorted, sorted.dropFirst()) { #expect(a.delayMs > b.delayMs && a.geometryGainDB < b.geometryGainDB) }
    }

    @Test("Speakers all as far as each other need nothing")
    func equidistant() {
        var group = GroupFixtures.quad()
        let corners = [(-1.0, 1.0), (1, 1), (-1, -1), (1, -1)]
        for (i, c) in corners.enumerated() { group.speakers[i].position = Point2D(x: c.0, y: c.1) }
        let alignment = SpeakerGeometry.alignment(for: group, sampleRate: 48_000)
        #expect(alignment.allSatisfy { $0.delayMs == 0 && $0.geometryGainDB == 0 && $0.roundedDelayFrames == 0 })
    }

    @Test("The seat can move: the same speakers are aligned to wherever the listener sits")
    func movedSeat() {
        var group = GroupFixtures.quad()
        group.listener.position = Point2D(x: 0, y: 1.5)             // level with the front pair: they are 1 m away
        let alignment = SpeakerGeometry.alignment(for: group, sampleRate: 48_000)
        #expect(abs(entry(alignment, .frontLeft).distance - 1) < 1e-12)
        let back = entry(alignment, .backLeft)
        #expect(abs(back.distance - hypot(1, 3)) < 1e-12 && back.delayMs == 0)
        #expect(abs(entry(alignment, .frontLeft).azimuth + 90) < 1e-12)
    }

    @Test("A ceiling speaker is farther than its place on the floor by the height it is at")
    func heights() {
        var group = GroupFixtures.quad()
        group.speakers[0].position = Point2D(x: 0, y: 1)
        group.speakers[0].height = 2
        let alignment = SpeakerGeometry.alignment(for: group, sampleRate: 48_000)
        #expect(abs(entry(alignment, .frontLeft).distance - 5.0.squareRoot()) < 1e-12)
        #expect(entry(alignment, .frontLeft).azimuth == 0)
    }

    @Test("A speaker's own trims are added on top: its delay trim to the delay, its level trim to the level (kept apart from the geometry's)")
    func trims() {
        var group = downstairs()
        group.speakers[0].delayTrimMs = 0.5
        group.speakers[0].trimDB = -1.5
        group.speakers[3].trimDB = 2
        let alignment = SpeakerGeometry.alignment(for: group, sampleRate: 48_000)
        let near = entry(alignment, .frontLeft)
        #expect(abs(near.delayMs - (1000 / 343 + 0.5)) < 1e-9)
        #expect(abs(near.geometryGainDB + 4.437) < 0.001 && abs(near.gainDB - (near.geometryGainDB - 1.5)) < 1e-12)
        #expect(entry(alignment, .backRight).geometryGainDB == 0 && entry(alignment, .backRight).gainDB == 2)
    }

    @Test("A speaker that can't be placed (at the seat, or not a number) is left out and doesn't set the reference")
    func unplaceable() {
        var group = downstairs()
        group.speakers[0].position = group.listener.position
        group.speakers[1].position = Point2D(x: .nan, y: 1)
        let alignment = SpeakerGeometry.alignment(for: group, sampleRate: 48_000)
        #expect(Set(alignment.map(\.role)) == [.backLeft, .backRight])
        #expect(alignment.allSatisfy { $0.delayMs == 0 && $0.geometryGainDB == 0 })
        #expect(SpeakerGeometry.alignment(for: GroupFixtures.quad(name: "None").withoutSpeakers(), sampleRate: 48_000).isEmpty)
    }

    @Test("Delay in frames follows the sample rate, and is held to what the room correction chain can delay")
    func frames() {
        let low = SpeakerGeometry.alignment(for: downstairs(), sampleRate: 48_000)
        let high = SpeakerGeometry.alignment(for: downstairs(), sampleRate: 192_000)
        #expect(abs(entry(high, .frontLeft).delayFrames - 4 * entry(low, .frontLeft).delayFrames) < 1e-9)
        var far = downstairs()
        far.speakers[2].position = Point2D(x: 0, y: -90)            // 90 m away: 262 ms
        let limited = SpeakerGeometry.alignment(for: far, sampleRate: 192_000)
        let near = entry(limited, .frontLeft)
        #expect(near.delayLimited && near.roundedDelayFrames == SpeakerGeometry.maxDelayFrames)
        #expect(!entry(low, .frontLeft).delayLimited)
    }

    @Test("A warmer room carries sound faster: the speed of sound can be given, 343 m/s by default")
    func speedOfSound() {
        let slow = SpeakerGeometry.alignment(for: downstairs(), sampleRate: 48_000)
        let fast = SpeakerGeometry.alignment(for: downstairs(), sampleRate: 48_000, speedOfSound: 346)
        #expect(entry(fast, .frontLeft).delayMs < entry(slow, .frontLeft).delayMs)
        #expect(abs(entry(fast, .frontLeft).delayMs - 1000 / 346) < 1e-9)
        #expect(abs(SpeakerGeometry.speedOfSound(celsius: 20) - 343.2) < 0.1)
    }
}

extension SpeakerGroup {
    func withoutSpeakers() -> SpeakerGroup { var copy = self; copy.speakers = []; return copy }
}
