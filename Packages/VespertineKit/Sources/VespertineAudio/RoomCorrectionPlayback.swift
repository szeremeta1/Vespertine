//
// Vespertine — room correction as the engine plays it: per output channel a delay, a level, parametric bands and,
// optionally, a measured filter (impulse response), plus a preamp shared by every channel. Built for the device's
// actual sample rate and run on the I/O thread ahead of the equalizer (`nrt_context_set_room`, then
// `nrt_context_set_fir`). Off unless chosen for an output; anything that changes nothing counts as off, so bit-perfect
// playback stays possible.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CVespertineRT
import Foundation

/// One output channel's correction.
public struct RoomChannelPlayback: Hashable, Sendable {
    public var delayMs: Double
    public var levelDB: Double
    public var bands: [EQBand]
    public var impulse: RoomImpulse?

    public init(delayMs: Double = 0, levelDB: Double = 0, bands: [EQBand] = [], impulse: RoomImpulse? = nil) {
        self.delayMs = delayMs
        self.levelDB = levelDB
        self.bands = bands
        self.impulse = impulse
    }

    /// Whether the channel's correction does anything at all.
    public var isActive: Bool { delayMs > 0 || levelDB != 0 || bands.contains(where: \.isActive) || impulse != nil }
}

public struct RoomCorrectionPlayback: Hashable, Sendable {
    /// The profile the filters come from.
    public var profileID: UUID
    public var name: String
    public var preampDB: Double
    /// Index 0 is the first output channel.
    public var channels: [RoomChannelPlayback]
    /// Where the impulse responses' files are.
    public var impulseDirectory: URL

    public static let maxChannels = Int(NRT_ROOM_MAX_CHANNELS)
    public static let maxBandsPerChannel = Int(NRT_ROOM_MAX_SECTIONS)

    public init(profileID: UUID, name: String, preampDB: Double, channels: [RoomChannelPlayback],
                impulseDirectory: URL = RoomImpulse.defaultDirectory) {
        self.profileID = profileID
        self.name = name
        self.preampDB = preampDB
        self.channels = channels
        self.impulseDirectory = impulseDirectory
    }

    /// Bands only, one list per output channel.
    public init(profileID: UUID, name: String, preampDB: Double, bands: [[EQBand]]) {
        self.init(profileID: profileID, name: name, preampDB: preampDB, channels: bands.map { RoomChannelPlayback(bands: $0) })
    }

    /// The profile's correction in output-channel order (from its channel map).
    public init(profile: RoomProfile, impulseDirectory: URL = RoomImpulse.defaultDirectory) {
        let outputs = (profile.channelMap.entries.map(\.output).max() ?? -1) + 1
        var channels = [RoomChannelPlayback](repeating: RoomChannelPlayback(), count: max(0, min(outputs, Self.maxChannels)))
        for entry in profile.channelMap.entries where entry.output >= 0 && entry.output < channels.count {
            let alignment = profile.alignment(for: entry.speaker).clamped
            channels[entry.output] = RoomChannelPlayback(delayMs: alignment.delayMs, levelDB: alignment.levelDB,
                                                         bands: profile.filters.channels[entry.speaker] ?? [],
                                                         impulse: profile.impulses?[entry.speaker])
        }
        self.init(profileID: profile.id, name: profile.name, preampDB: profile.filters.preampDB, channels: channels,
                  impulseDirectory: impulseDirectory)
    }

    /// Changes nothing: no preamp and no channel with an effect.
    public var isFlat: Bool { preampDB == 0 && !channels.contains(where: \.isActive) }

    /// The stream's channels line up with the speakers it was made for: the same layout, or the front left and right
    /// of a surround profile for stereo music. Anything else (mono, a surround stream on a stereo profile) bypasses it.
    public func applies(channels count: Int) -> Bool { count == channels.count || (count == 2 && channels.count > 2) }

    public var preampGain: Double { pow(10, min(max(preampDB, EQPreset.preampRange.lowerBound), 0) / 20) }

    /// The longest delay any channel holds sound back, in seconds (what the end of the queue has to play out).
    public var maxDelaySeconds: Double {
        (channels.map(\.delayMs).max() ?? 0).clamped(to: RoomSpeakerAlignment.delayRange) / 1000
    }

    /// What `nrt_context_set_room` takes for a stream of `channelCount` channels at `sampleRate`: each channel's delay
    /// in frames, the preamp and its level as one gain, and its bands designed for the rate. Channels past the profile
    /// get the preamp only, so the balance holds.
    public func renderChannels(sampleRate: Double, channelCount: Int) -> [NRTRoomChannel] {
        let count = min(max(channelCount, 0), Self.maxChannels)
        let preamp = preampGain
        return (0..<count).map { c in
            let correction = c < channels.count ? channels[c] : RoomChannelPlayback()
            let alignment = RoomSpeakerAlignment(delayMs: correction.delayMs, levelDB: correction.levelDB).clamped
            var out = NRTRoomChannel()
            let frames: Double = (alignment.delayMs * sampleRate / 1000).rounded()
            out.delayFrames = UInt32(min(max(frames, 0), Double(NRT_ROOM_MAX_DELAY - 1)))
            out.gain = preamp * pow(10, alignment.levelDB / 20)
            let sections = Array(correction.bands.compactMap { $0.section(sampleRate: sampleRate) }.prefix(Self.maxBandsPerChannel))
            withUnsafeMutableBytes(of: &out.sections) { raw in
                let slots = raw.bindMemory(to: NRTBiquad.self)
                for (i, section) in sections.enumerated() { slots[i] = section }
            }
            out.count = UInt32(sections.count)
            return out
        }
    }

    /// What identifies the measured filters for a stream of `channelCount` channels at `sampleRate`: the same key, the
    /// same taps, so they're only loaded, resampled and transformed again when it changes.
    public func impulseKey(sampleRate: Double, channelCount: Int) -> String {
        let count = min(max(channelCount, 0), Self.maxChannels)
        let files = (0..<count).map { c in c < channels.count ? channels[c].impulse?.file ?? "" : "" }
        return files.joined(separator: "|") + "@\(sampleRate)"
    }

    /// Each channel's filter taps at `sampleRate` (nil: unfiltered), or nil if no channel has a filter. A filter that
    /// can't be read, or is too long for the I/O thread at this rate, leaves its channel unfiltered.
    public func impulseTaps(sampleRate: Double, channelCount: Int) -> [[Float]?]? {
        let count = min(max(channelCount, 0), Self.maxChannels)
        let taps = (0..<count).map { c -> [Float]? in
            guard c < channels.count, let impulse = channels[c].impulse else { return nil }
            return impulse.taps(at: sampleRate, in: impulseDirectory)
        }
        return taps.contains { $0 != nil } ? taps : nil
    }

    /// Some channel's measured filter is too long to run at `sampleRate`, so it's left out there.
    public func filtersTooLong(sampleRate: Double, channelCount: Int) -> Bool {
        channels.prefix(min(max(channelCount, 0), Self.maxChannels)).contains { channel in
            channel.impulse.map { !$0.fits(at: sampleRate) } ?? false
        }
    }

    /// Channel `channel`'s response in dB from its bands, preamp and level (the delay doesn't change it; a measured
    /// filter isn't included), at each of `frequencies`.
    public func responseDB(channel: Int, at frequencies: [Double], sampleRate: Double) -> [Double] {
        let correction = channel < channels.count ? channels[channel] : RoomChannelPlayback()
        let bands = Array(correction.bands.prefix(Self.maxBandsPerChannel))
        let offset: Double = 20 * log10(preampGain) + correction.levelDB
        return EQPreset(name: name, preampDB: 0, bands: bands).responseDB(at: frequencies, sampleRate: sampleRate).map { $0 + offset }
    }

    /// Installs the delay, level and bands of `correction` (nil: none) on `context` for a stream of `channelCount`
    /// channels at `sampleRate`.
    static func install(_ correction: RoomCorrectionPlayback?, on context: OpaquePointer, sampleRate: Double, channelCount: Int) {
        let channels = correction?.renderChannels(sampleRate: sampleRate, channelCount: channelCount) ?? []
        channels.withUnsafeBufferPointer { nrt_context_set_room(context, $0.baseAddress, UInt32($0.count)) }
    }

    /// Hands each channel's taps (nil: unfiltered) to the I/O thread; nil, no filters at all. False if out of memory.
    @discardableResult
    static func installFilters(_ taps: [[Float]?]?, on context: OpaquePointer) -> Bool {
        guard let taps else { return nrt_context_set_fir(context, nil, 0, 0) }
        let length = taps.map { $0?.count ?? 0 }.max() ?? 0
        var flat = [Float](repeating: 0, count: taps.count * length)
        for (c, channel) in taps.enumerated() {
            if let channel { flat.replaceSubrange(c * length ..< c * length + channel.count, with: channel) }
        }
        return flat.withUnsafeBufferPointer { buffer in
            let pointers: [UnsafePointer<Float>?] = taps.indices.map { c in
                taps[c] == nil ? nil : buffer.baseAddress.map { $0 + c * length }
            }
            return pointers.withUnsafeBufferPointer { nrt_context_set_fir(context, $0.baseAddress, UInt32(taps.count), UInt32(length)) }
        }
    }
}

extension Double {
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
