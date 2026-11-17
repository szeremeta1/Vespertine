//
// Vespertine: speaker groups: presets that lay out the speakers (stereo up to 9.1.6, with the ceiling speakers on the ceiling), and
// the readout of where each speaker stands and what that asks of it. Plain data; the panel is a thin layer.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum GroupPresets {
    public enum Preset: String, CaseIterable, Sendable, Identifiable {
        case stereo, stereoSub, frontThreeSub, quad, twoPairsFacing, itu51, surround71, surround512, surround514, surround712, surround714, surround916
        public var id: String { rawValue }

        /// The layouts that are only a count of speakers are named by it, the same in every language.
        public var title: String {
            switch self {
            case .stereo: String(localized: "Stereo")
            case .stereoSub: "2.1"
            case .frontThreeSub: "3.1"
            case .quad: String(localized: "Quad")
            case .twoPairsFacing: String(localized: "Two pairs facing")
            case .itu51: String(localized: "ITU 5.1")
            case .surround71: "7.1"
            case .surround512: "5.1.2"
            case .surround514: "5.1.4"
            case .surround712: "7.1.2"
            case .surround714: "7.1.4"
            case .surround916: "9.1.6"
            }
        }

        /// How many channels it takes.
        public var speakerCount: Int { layout.count }

        /// Whether any of its speakers hang from the ceiling.
        public var hasCeilingSpeakers: Bool { layout.contains { $0.overhead != nil } }

        /// One speaker of a preset: its role, degrees from where the seat faces, and metres from the seat across the floor. A ceiling
        /// speaker has `overhead` instead of a distance: how far out it hangs for each metre the ceiling is above the ears (1 is 45° up).
        struct Place {
            var role: SpeakerRole
            var azimuth: Double
            var distance: Double
            var overhead: Double?

            init(_ role: SpeakerRole, _ azimuth: Double, _ distance: Double = 2) {
                self.role = role
                self.azimuth = azimuth
                self.distance = distance
            }

            static func ceiling(_ role: SpeakerRole, _ azimuth: Double, out overhead: Double) -> Place {
                var place = Place(role, azimuth, 0)
                place.overhead = overhead
                return place
            }
        }

        private static let front: [Place] = [Place(.frontLeft, -30), Place(.frontRight, 30)]
        /// The subwoofer stands in front, a little right of the centre so it is not hidden behind it.
        private static let sub = Place(.lfe, 15)
        private static let bed51: [Place] = front + [Place(.center, 0), sub, Place(.sideLeft, -110), Place(.sideRight, 110)]
        /// With a back pair the side pair stands beside the seat.
        private static let bed71: [Place] = front + [Place(.center, 0), sub, Place(.sideLeft, -90), Place(.sideRight, 90),
                                                     Place(.backLeft, -150), Place(.backRight, 150)]
        private static let topMiddle: [Place] = [.ceiling(.topMiddleLeft, -90, out: 0.5), .ceiling(.topMiddleRight, 90, out: 0.5)]
        private static let topFront: [Place] = [.ceiling(.topFrontLeft, -45, out: 1), .ceiling(.topFrontRight, 45, out: 1)]
        private static let topBack: [Place] = [.ceiling(.topBackLeft, -135, out: 1), .ceiling(.topBackRight, 135, out: 1)]

        /// The speakers in the order of the channels they go on.
        var layout: [Place] {
            switch self {
            case .stereo: Self.front
            case .stereoSub: Self.front + [Self.sub]
            case .frontThreeSub: Self.front + [Place(.center, 0), Self.sub]
            case .quad: [Place(.frontLeft, -45), Place(.frontRight, 45), Place(.backLeft, -135), Place(.backRight, 135)]
            case .twoPairsFacing: [Place(.frontLeft, -30, 1.5), Place(.frontRight, 30, 1.5), Place(.backLeft, -150, 2.5), Place(.backRight, 150, 2.5)]
            case .itu51: Self.bed51
            case .surround71: Self.bed71
            case .surround512: Self.bed51 + Self.topMiddle
            case .surround514: Self.bed51 + Self.topFront + Self.topBack
            case .surround712: Self.bed71 + Self.topMiddle
            case .surround714: Self.bed71 + Self.topFront + Self.topBack
            case .surround916: Self.bed71 + [Place(.wideLeft, -60), Place(.wideRight, 60)] + Self.topFront + Self.topMiddle + Self.topBack
            }
        }
    }

    /// The layout a new group starts with, so it plays (and can be a Mac sound output) before anyone opens the editor: the largest
    /// usual one its channels hold. Stereo on two or three, a quad on four or five (two stereo DACs are most often two pairs), 5.1 from
    /// six, 7.1 from eight, 5.1.4 from ten, 7.1.4 from twelve, 9.1.6 on sixteen. Each output's channels are taken in order.
    public static func startingPreset(for group: SpeakerGroup) -> Preset? {
        switch group.totalChannels {
        case 16...: .surround916
        case 12...: .surround714
        case 10...: .surround514
        case 8...: .surround71
        case 6...: .itu51
        case 4...: .quad
        case 2...: .stereo
        default: nil
        }
    }

    /// The presets that fit the group's channels.
    public static func available(for group: SpeakerGroup) -> [Preset] {
        Preset.allCases.filter { $0.speakerCount <= group.totalChannels }
    }

    /// The group with its speakers laid out by `preset`, on the channels in order (a channel past the preset's is left free), around the
    /// seat and facing where it faces, held inside the room; its ceiling speakers on the ceiling. Everything else about the group
    /// stays. nil when the group has too few channels.
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
        // How far the ceiling is above the ears: what a ceiling speaker's height is counted in.
        let overhead = max(RoomCanvas.ceiling(of: group) - group.listener.ears, 0)
        for place in layout {
            let target = targets[channel]
            channel += 1
            let bearing = (group.listener.facingDegrees + place.azimuth) * .pi / 180
            let distance = place.overhead.map { $0 * overhead } ?? place.distance
            var x = seat.x + distance * sin(bearing), y = seat.y + distance * cos(bearing)
            x = min(max(x, -room.width / 2), room.width / 2)
            y = min(max(y, -room.depth / 2), room.depth / 2)
            result.speakers.append(SpeakerGroup.Speaker(role: place.role, deviceUID: target.uid, channel: target.channel, position: Point2D(x: x, y: y),
                                                        height: place.overhead == nil ? nil : overhead))
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
