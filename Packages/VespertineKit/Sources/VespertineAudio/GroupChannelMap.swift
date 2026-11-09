//
// Vespertine: speaker groups: the channel map. Every channel of every output against the speaker role on it, edited one cell at a
// time, and the quiet tone that says which channel is which. Plain data; the grid is a thin layer over it.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum GroupChannelMap {
    public struct Row: Equatable, Sendable, Identifiable {
        /// The channel's place in the aggregate (all outputs' channels in the group's order, from 0).
        public var aggregateChannel: Int
        public var deviceUID: String
        public var deviceName: String
        /// From 0 on its own output.
        public var channelOnDevice: Int
        public var role: SpeakerRole?
        public var inverted: Bool
        public var id: Int { aggregateChannel }

        /// "Fosi ZD3 · channel 1"
        public var label: String { "\(deviceName) · channel \(channelOnDevice + 1)" }
    }

    public static func rows(_ group: SpeakerGroup) -> [Row] {
        var rows: [Row] = []
        for member in group.members {
            for channel in 0..<max(member.channelCount, 0) {
                let speaker = group.speakers.first { $0.deviceUID == member.deviceUID && $0.channel == channel }
                rows.append(Row(aggregateChannel: rows.count, deviceUID: member.deviceUID, deviceName: member.name, channelOnDevice: channel,
                                role: speaker?.role, inverted: speaker?.invertPolarity ?? false))
            }
        }
        return rows
    }

    /// Puts `role` on a channel of an output (nil: clears it). A role is in a group once, so it leaves any other channel it was on. A
    /// channel that already has a speaker keeps its place, trims and polarity and only changes role; a new one starts where its role
    /// usually stands, 2 m from the seat. A channel the output doesn't have, or an output not in the group, changes nothing.
    public static func assign(_ role: SpeakerRole?, toChannel channel: Int, of deviceUID: String, in group: SpeakerGroup) -> SpeakerGroup {
        guard let member = group.members.first(where: { $0.deviceUID == deviceUID }), channel >= 0, channel < member.channelCount else { return group }
        var result = group
        let existing = result.speakers.firstIndex { $0.deviceUID == deviceUID && $0.channel == channel }
        guard let role else {
            if let existing { result.speakers.remove(at: existing) }
            return result
        }
        result.speakers.removeAll { $0.role == role && !($0.deviceUID == deviceUID && $0.channel == channel) }
        if let index = result.speakers.firstIndex(where: { $0.deviceUID == deviceUID && $0.channel == channel }) {
            result.speakers[index].role = role
        } else {
            result.speakers.append(SpeakerGroup.Speaker(role: role, deviceUID: deviceUID, channel: channel, position: startingPlace(of: role)))
        }
        return result
    }

    public static func setInverted(_ inverted: Bool, channel: Int, of deviceUID: String, in group: SpeakerGroup) -> SpeakerGroup {
        guard let index = group.speakers.firstIndex(where: { $0.deviceUID == deviceUID && $0.channel == channel }) else { return group }
        var result = group
        result.speakers[index].invertPolarity = inverted
        return result
    }

    /// The channels with no speaker on them.
    public static func unassigned(_ group: SpeakerGroup) -> [Row] { rows(group).filter { $0.role == nil } }

    /// The roles not yet on any channel.
    public static func freeRoles(_ group: SpeakerGroup) -> [SpeakerRole] {
        let used = Set(group.speakers.map(\.role))
        return SpeakerRole.allCases.filter { !used.contains($0) }
    }

    /// Where a role usually stands, 2 m from the seat (metres, the seat at the origin facing +y); the LFE, which has no place, 1 m
    /// in front.
    static func startingPlace(of role: SpeakerRole) -> Point2D {
        guard let azimuth = role.defaultAzimuth else { return Point2D(x: 0, y: 1) }
        let radians = azimuth * .pi / 180
        return Point2D(x: 2 * sin(radians), y: 2 * cos(radians))
    }
}

/// The quiet sound that says which channel is which: three bursts of pink noise on the one channel and silence on the others, at
/// -30 dBFS, each burst faded in and out. The same every time.
public enum IdentifyTone {
    public static let seconds = 2.0
    public static let levelDB = -30.0

    /// Interleaved Float32 for `channels` channels at `rate`; all silence when `channel` is not one of them.
    public static func samples(channel: Int, channels: Int, rate: Double) -> [Float] {
        guard channels > 0, rate > 0 else { return [] }
        let frames = Int(rate * seconds)
        var out = [Float](repeating: 0, count: frames * channels)
        guard channel >= 0, channel < channels else { return out }
        let burst = Int(rate * 0.4), gap = Int(rate * 0.3), lead = Int(rate * 0.1), fade = max(1, Int(rate * 0.02))
        var noise = PinkNoise()
        var mono = [Float](repeating: 0, count: frames)
        var peak: Float = 0
        for b in 0..<3 {
            let start = lead + b * (burst + gap)
            for i in 0..<burst where start + i < frames {
                let edge = min(i, burst - 1 - i)
                let envelope = edge >= fade ? 1 : Float(0.5 - 0.5 * cos(Double.pi * Double(edge) / Double(fade)))
                let value = noise.next() * envelope
                mono[start + i] = value
                peak = max(peak, abs(value))
            }
        }
        let scale = peak > 0 ? Float(pow(10, levelDB / 20)) / peak : 0
        for f in 0..<frames { out[f * channels + channel] = mono[f] * scale }
        return out
    }

    /// Pink noise from white (Paul Kellet's filter), from a fixed seed.
    private struct PinkNoise {
        private var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        private var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0

        private mutating func white() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2_000_001 - 1_000_000) / 1_000_000
        }

        mutating func next() -> Float {
            let w = white()
            b0 = 0.99886 * b0 + w * 0.0555179
            b1 = 0.99332 * b1 + w * 0.0750759
            b2 = 0.96900 * b2 + w * 0.1538520
            b3 = 0.86650 * b3 + w * 0.3104856
            b4 = 0.55000 * b4 + w * 0.5329522
            b5 = -0.7616 * b5 - w * 0.0168980
            let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
            b6 = w * 0.115926
            return pink * 0.11
        }
    }
}
