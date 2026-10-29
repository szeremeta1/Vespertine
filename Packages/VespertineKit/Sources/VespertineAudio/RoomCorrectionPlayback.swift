//
// Vespertine — room correction as the engine plays it: one bank of parametric bands per output channel and a shared
// preamp, built for the device's actual sample rate and run on the I/O thread ahead of the equalizer
// (`nrt_context_set_room`). Off unless chosen for an output; anything that changes nothing counts as off, so
// bit-perfect playback stays possible.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CVespertineRT
import Foundation

public struct RoomCorrectionPlayback: Codable, Hashable, Sendable {
    /// The profile the filters come from.
    public var profileID: UUID
    public var name: String
    public var preampDB: Double
    /// Bands per output channel: index 0 is the first output channel.
    public var channels: [[EQBand]]

    public static let maxChannels = Int(NRT_ROOM_MAX_CHANNELS)
    public static let maxBandsPerChannel = Int(NRT_ROOM_MAX_SECTIONS)

    public init(profileID: UUID, name: String, preampDB: Double, channels: [[EQBand]]) {
        self.profileID = profileID
        self.name = name
        self.preampDB = preampDB
        self.channels = channels
    }

    /// The profile's filters in output-channel order (from its channel map).
    public init(profile: RoomProfile) {
        let outputs = (profile.channelMap.entries.map(\.output).max() ?? -1) + 1
        var channels = [[EQBand]](repeating: [], count: max(0, min(outputs, Self.maxChannels)))
        for entry in profile.channelMap.entries where entry.output >= 0 && entry.output < channels.count {
            channels[entry.output] = profile.filters.channels[entry.speaker] ?? []
        }
        self.init(profileID: profile.id, name: profile.name, preampDB: profile.filters.preampDB, channels: channels)
    }

    /// Changes nothing: no preamp and no band with an effect.
    public var isFlat: Bool { preampDB == 0 && !channels.contains { $0.contains(where: \.isActive) } }

    /// Measured per speaker of a stereo pair: it applies only where the music plays as two channels, unmixed.
    public func applies(channels count: Int) -> Bool { count == channels.count }

    public var preampGain: Double { pow(10, min(max(preampDB, EQPreset.preampRange.lowerBound), 0) / 20) }

    /// What `nrt_context_set_room` takes at `sampleRate`: sections laid out channel by channel, NRT_ROOM_MAX_SECTIONS
    /// apart, and the count of each.
    public struct Bank: Sendable {
        public var sections: [NRTBiquad]
        public var counts: [UInt32]
        public var preamp: Double
    }

    public func bank(sampleRate: Double) -> Bank {
        let used = Array(channels.prefix(Self.maxChannels))
        var sections = [NRTBiquad](repeating: NRTBiquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0), count: used.count * Self.maxBandsPerChannel)
        var counts = [UInt32](repeating: 0, count: used.count)
        for (c, bands) in used.enumerated() {
            let built = Array(bands.compactMap { $0.section(sampleRate: sampleRate) }.prefix(Self.maxBandsPerChannel))
            for (k, s) in built.enumerated() { sections[c * Self.maxBandsPerChannel + k] = s }
            counts[c] = UInt32(built.count)
        }
        return Bank(sections: sections, counts: counts, preamp: preampGain)
    }

    /// Channel `channel`'s response in dB, preamp included, at each of `frequencies`.
    public func responseDB(channel: Int, at frequencies: [Double], sampleRate: Double) -> [Double] {
        let bands = channel < channels.count ? channels[channel] : []
        return EQPreset(name: name, preampDB: preampDB, bands: Array(bands.prefix(Self.maxBandsPerChannel)))
            .responseDB(at: frequencies, sampleRate: sampleRate)
    }

    /// Installs this correction (nil: none) on `context` for `sampleRate`.
    static func install(_ correction: RoomCorrectionPlayback?, on context: OpaquePointer, sampleRate: Double) {
        guard let correction else { nrt_context_set_room(context, nil, nil, 0, 1); return }
        let bank = correction.bank(sampleRate: sampleRate)
        bank.sections.withUnsafeBufferPointer { s in
            bank.counts.withUnsafeBufferPointer { n in
                nrt_context_set_room(context, s.baseAddress, n.baseAddress, UInt32(bank.counts.count), bank.preamp)
            }
        }
    }
}
