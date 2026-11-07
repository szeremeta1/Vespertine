//
// Vespertine — speaker groups: from where the speakers and the seat stand to each speaker's distance, angle, delay and
// level, so a group can be aligned without a microphone. The sound of every speaker is made to reach the seat together:
// the farthest speaker is the reference, and each nearer one waits for it and is turned down to match. Nothing is ever
// boosted, so the alignment can't clip. (The rule room correction already uses; a measurement replaces this.)
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// What the geometry asks of one speaker.
public struct SpeakerAlignment: Equatable, Sendable {
    public var speakerID: UUID
    public var role: SpeakerRole
    /// From the listener's ears to the speaker, in metres (the height counted when the speaker has one).
    public var distance: Double
    /// Degrees from where the listener faces, positive to the right, in -180…180.
    public var azimuth: Double
    /// Milliseconds the speaker waits for the farthest one, plus its own delay trim.
    public var delayMs: Double
    /// The same in sample frames, held to what the room correction chain can delay.
    public var delayFrames: Double
    /// The delay was longer than the chain takes and has been cut to it.
    public var delayLimited: Bool
    /// dB from the distance alone: 0 for the farthest speaker, below 0 for the rest.
    public var geometryGainDB: Double
    /// The distance's dB plus the speaker's own level trim.
    public var gainDB: Double

    /// The delay as whole frames: a delay with no fraction only shifts the samples, it doesn't change them.
    public var roundedDelayFrames: Int { Int(delayFrames.rounded()) }
}

public enum SpeakerGeometry {
    /// Metres per second in air at about 20 °C.
    public static let defaultSpeedOfSound = 343.0
    /// The longest delay the room correction chain takes, in frames (`NRT_ROOM_MAX_DELAY` is one more).
    public static let maxDelayFrames = 32767

    /// The speed of sound in dry air at this temperature.
    public static func speedOfSound(celsius: Double) -> Double { 331.3 * (1 + celsius / 273.15).squareRoot() }

    /// Distance across the floor from the seat to a point, in metres.
    public static func distance(from listener: Listener, to point: Point2D) -> Double {
        hypot(point.x - listener.position.x, point.y - listener.position.y)
    }

    /// The angle to a point from where the listener faces: 0° straight ahead, positive to the right, -180…180.
    public static func azimuth(from listener: Listener, to point: Point2D) -> Double {
        let bearing = atan2(point.x - listener.position.x, point.y - listener.position.y) * 180 / .pi
        return wrap(bearing - listener.facingDegrees)
    }

    /// Every speaker that can be placed, in the group's order. A speaker at the seat or at a position that isn't a number is
    /// left out, and doesn't count as the reference.
    public static func alignment(for group: SpeakerGroup, sampleRate: Double, speedOfSound: Double = defaultSpeedOfSound) -> [SpeakerAlignment] {
        let placed: [(speaker: SpeakerGroup.Speaker, distance: Double)] = group.speakers.compactMap { speaker in
            guard speaker.position.isFinite, speaker.height?.isFinite ?? true else { return nil }
            let floor = distance(from: group.listener, to: speaker.position)
            let d = hypot(floor, speaker.height ?? 0)
            return d > 0 && d.isFinite ? (speaker, d) : nil
        }
        guard let farthest = placed.map(\.distance).max() else { return [] }
        return placed.map { speaker, d in
            let delayMs = (farthest - d) / speedOfSound * 1000 + speaker.delayTrimMs
            let frames = delayMs * sampleRate / 1000
            let limited = frames > Double(maxDelayFrames)
            let gain = 20 * log10(d / farthest)
            return SpeakerAlignment(
                speakerID: speaker.id, role: speaker.role, distance: d, azimuth: azimuth(from: group.listener, to: speaker.position),
                delayMs: delayMs, delayFrames: limited ? Double(maxDelayFrames) : frames, delayLimited: limited,
                geometryGainDB: gain, gainDB: gain + speaker.trimDB)
        }
    }

    private static func wrap(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        return d
    }
}
