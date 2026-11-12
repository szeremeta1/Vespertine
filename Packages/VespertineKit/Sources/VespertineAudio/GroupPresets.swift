//
// Vespertine: speaker groups: presets that lay out the speakers (Quad, ITU 5.1, Two pairs facing), and the readout of where each
// speaker stands and what that asks of it. Plain data; the panel is a thin layer.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum GroupPresets {
    public enum Preset: String, CaseIterable, Sendable, Identifiable {
        case quad, itu51, twoPairsFacing
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .quad: String(localized: "Quad")
            case .itu51: String(localized: "ITU 5.1")
            case .twoPairsFacing: String(localized: "Two pairs facing")
            }
        }

        public var detail: String {
            switch self {
            case .quad: String(localized: "Four speakers around the seat, 2 m away, at 45° and 135°.")
            case .itu51: String(localized: "The standard 5.1 room: 30° front pair, centre ahead, surrounds at 110°, the subwoofer in front.")
            case .twoPairsFacing: String(localized: "A pair 1.5 m ahead, and another pair 2.5 m behind facing it, as in a shared room.")
            }
        }

        /// The speakers in the order of the channels they go on: role, degrees from where the seat faces, metres from the seat.
        var layout: [(role: SpeakerRole, azimuth: Double, distance: Double)] {
            switch self {
            case .quad:
                [(.frontLeft, -45, 2), (.frontRight, 45, 2), (.backLeft, -135, 2), (.backRight, 135, 2)]
            case .itu51:
                [(.frontLeft, -30, 2), (.frontRight, 30, 2), (.center, 0, 2), (.lfe, 0, 1), (.sideLeft, -110, 2), (.sideRight, 110, 2)]
            case .twoPairsFacing:
                [(.frontLeft, -30, 1.5), (.frontRight, 30, 1.5), (.backLeft, -150, 2.5), (.backRight, 150, 2.5)]
            }
        }
    }

    /// The layout a new group starts with, so it plays (and can be a Mac sound output) before anyone opens the editor: ITU 5.1 on six
    /// channels or more, a quad on four or five, nothing on fewer. Each output's channels are taken in order.
    public static func startingPreset(for group: SpeakerGroup) -> Preset? {
        switch group.totalChannels {
        case 6...: .itu51
        case 4...: .quad
        default: nil
        }
    }

    /// The presets that fit the group's channels.
    public static func available(for group: SpeakerGroup) -> [Preset] {
        Preset.allCases.filter { $0.layout.count <= group.totalChannels }
    }

    /// The group with its speakers laid out by `preset`, on the channels in order (a channel past the preset's is left free), around the
    /// seat and facing where it faces, held inside the room. Everything else about the group stays. nil when the group has too few
    /// channels.
    public static func apply(_ preset: Preset, to group: SpeakerGroup) -> SpeakerGroup? {
        let layout = preset.layout
        guard layout.count <= group.totalChannels else { return nil }
        var result = group
        result.speakers = []
        var channel = 0
        var targets: [(uid: String, channel: Int)] = []
        for member in group.members { for c in 0..<max(member.channelCount, 0) { targets.append((member.deviceUID, c)) } }
        let seat = group.listener.position
        let room = RoomCanvas.room(of: group)
        for place in layout {
            let target = targets[channel]
            channel += 1
            let bearing = (group.listener.facingDegrees + place.azimuth) * .pi / 180
            var x = seat.x + place.distance * sin(bearing), y = seat.y + place.distance * cos(bearing)
            x = min(max(x, -room.width / 2), room.width / 2)
            y = min(max(y, -room.depth / 2), room.depth / 2)
            result.speakers.append(SpeakerGroup.Speaker(role: place.role, deviceUID: target.uid, channel: target.channel, position: Point2D(x: x, y: y)))
        }
        return result
    }
}

/// Where each placed speaker stands and what the geometry asks of it, as text for the panel.
public enum GroupReadout {
    public struct Row: Equatable, Sendable, Identifiable {
        public var speakerID: UUID
        public var role: SpeakerRole
        public var distance: String
        public var angle: String
        public var delay: String
        public var level: String
        /// The delay is longer than the room correction chain holds and has been cut to it.
        public var delayLimited: Bool
        public var id: UUID { speakerID }
    }

    /// One row per speaker that can be placed, in the group's order.
    public static func rows(_ group: SpeakerGroup, sampleRate: Double, unit: DistanceUnit) -> [Row] {
        SpeakerGeometry.alignment(for: group, sampleRate: sampleRate).map { a in
            Row(speakerID: a.speakerID, role: a.role, distance: unit.format(a.distance), angle: angle(a.azimuth),
                delay: a.delayMs < 0.05 ? "0 ms" : String(localized: "\(decimal(a.delayMs, places: 1)) ms · \(a.roundedDelayFrames) frames", comment: "Readout of a speaker's wait: milliseconds, a dot, then whole frames (plural by the frames)."),
                level: abs(a.gainDB) < 0.05 ? "0 dB" : "\(decimal(a.gainDB, places: 1)) dB", delayLimited: a.delayLimited)
        }
    }

    private static func decimal(_ v: Double, places: Int) -> String {
        let scale = pow(10, Double(places))
        let r = (v * scale).rounded() / scale
        return r == r.rounded() ? String(Int(r)) : String(r)
    }

    private static func angle(_ azimuth: Double) -> String {
        let a = abs(azimuth).rounded()
        if a < 1 { return String(localized: "ahead", comment: "A speaker's angle: straight ahead of where the seat faces.") }
        if a >= 180 { return String(localized: "behind", comment: "A speaker's angle: directly behind the seat.") }
        return azimuth < 0 ? String(localized: "\(Int(a))° left", comment: "A direction in degrees to the left of straight ahead (also read aloud by the screen reader).")
                           : String(localized: "\(Int(a))° right", comment: "A direction in degrees to the right of straight ahead (also read aloud by the screen reader).")
    }
}
