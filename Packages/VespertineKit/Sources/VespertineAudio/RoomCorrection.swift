//
// Vespertine — room correction: each speaker's delay, level and filters, and Equalizer APO / REW import.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A room profile belongs to one output. Channel c of the profile corrects decoded channel c (L, R, then C, LFE and
// the surrounds in standard order), and the I/O thread runs it before the equalizer, digital volume and dither
// (`nrt_context_set_room`). Bands are the equalizer's own `EQBand`s, designed for the device's actual sample rate, so
// one profile works at every rate. Like the equalizer, a profile that changes nothing is treated as none, so
// bit-perfect playback stays possible.
//

import CVespertineRT
import Foundation

public struct RoomChannelCorrection: Codable, Hashable, Sendable {
    /// How long this speaker's sound is held back, in milliseconds (to line it up with a farther speaker).
    public var delayMs: Double
    /// Level trim in dB.
    public var levelDB: Double
    public var bands: [EQBand]
    /// A measured correction filter, convolved before the delay, level and bands.
    public var impulse: RoomImpulse?

    public static let delayRange: ClosedRange<Double> = 0...40
    public static let levelRange: ClosedRange<Double> = -30...12

    public init(delayMs: Double = 0, levelDB: Double = 0, bands: [EQBand] = [], impulse: RoomImpulse? = nil) {
        self.delayMs = delayMs
        self.levelDB = levelDB
        self.bands = bands
        self.impulse = impulse
    }

    /// Whether the channel's correction does anything at all.
    public var isActive: Bool { delayMs > 0 || levelDB != 0 || bands.contains { $0.isActive } || impulse != nil }
}

public struct RoomProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Off: kept, but not applied (the quick bypass).
    public var enabled: Bool
    /// Gain applied to every channel, so boosts can't clip.
    public var preampDB: Double
    /// One per decoded channel, in order. Channels the profile doesn't list get only the preamp.
    public var channels: [RoomChannelCorrection]

    /// As many bands per channel as the I/O thread runs.
    public static let maxBands = Int(NRT_ROOM_MAX_SECTIONS)
    /// As many channels as the I/O thread corrects.
    public static let maxChannels = Int(NRT_METER_CHANNELS)

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, preampDB: Double = 0, channels: [RoomChannelCorrection] = []) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.preampDB = preampDB
        self.channels = channels
    }

    /// Changes nothing: played as no correction, so bit-perfect stays possible.
    public var isFlat: Bool { preampDB == 0 && !channels.contains { $0.isActive } }

    private var preampGain: Double { pow(10, min(max(preampDB, EQPreset.preampRange.lowerBound), EQPreset.preampRange.upperBound) / 20) }

    /// What the I/O thread runs for a stream of `channelCount` channels at `sampleRate`.
    func renderChannels(sampleRate: Double, channelCount: Int) -> [NRTRoomChannel] {
        let count = min(max(channelCount, 0), Self.maxChannels)
        return (0..<count).map { c in
            let correction = c < channels.count ? channels[c] : RoomChannelCorrection()
            var out = NRTRoomChannel()
            let delay = min(max(correction.delayMs, RoomChannelCorrection.delayRange.lowerBound), RoomChannelCorrection.delayRange.upperBound)
            out.delayFrames = UInt32(min((delay * sampleRate / 1000).rounded(), Double(NRT_ROOM_MAX_DELAY - 1)))
            let level = min(max(correction.levelDB, RoomChannelCorrection.levelRange.lowerBound), RoomChannelCorrection.levelRange.upperBound)
            out.gain = preampGain * pow(10, level / 20)
            let sections = correction.bands.compactMap { $0.section(sampleRate: sampleRate) }.prefix(Self.maxBands)
            withUnsafeMutableBytes(of: &out.sections) { raw in
                let slots = raw.bindMemory(to: NRTBiquad.self)
                for (i, section) in sections.enumerated() { slots[i] = section }
            }
            out.count = UInt32(sections.count)
            return out
        }
    }

    /// What identifies the filters for a stream of `channelCount` channels: the same key, the same taps.
    func impulseKey(channelCount: Int) -> [String] {
        (0..<min(max(channelCount, 0), Self.maxChannels)).map { c in c < channels.count ? channels[c].impulse?.file ?? "" : "" }
    }

    /// Each channel's filter taps at `sampleRate` (nil: unfiltered), or nil if no channel has a filter. A filter that
    /// can't be read, or is too long for the I/O thread at this rate, leaves its channel unfiltered.
    func impulseTaps(sampleRate: Double, channelCount: Int) -> [[Float]?]? {
        let count = min(max(channelCount, 0), Self.maxChannels)
        let taps = (0..<count).map { c in c < channels.count ? channels[c].impulse?.taps(at: sampleRate) : nil }
        return taps.contains { $0 != nil } ? taps : nil
    }

    /// Some speaker's measured filter is too long to run at `sampleRate`, so it's left out there.
    public func filtersTooLong(sampleRate: Double, channelCount: Int) -> Bool {
        channels.prefix(min(max(channelCount, 0), Self.maxChannels)).contains { $0.impulse.map { !$0.fits(at: sampleRate) } ?? false }
    }

    /// Channel `c`'s response in dB (preamp and level included, delay doesn't change it), at each of `frequencies`.
    public func responseDB(channel c: Int, at frequencies: [Double], sampleRate: Double) -> [Double] {
        let correction = c < channels.count ? channels[c] : RoomChannelCorrection()
        return EQPreset(name: name, preampDB: 0, bands: correction.bands).responseDB(at: frequencies, sampleRate: sampleRate)
            .map { $0 + 20 * log10(preampGain) + correction.levelDB }
    }

    /// The preamp that brings the loudest channel's peak, from 20 Hz to 20 kHz, down to 0 dB (never above 0 dB).
    public func preampForNoClipping(sampleRate: Double = 48_000) -> Double {
        let peak = channels.map { channel in
            EQPreset(name: name, preampDB: 0, bands: channel.bands).peakDB(sampleRate: sampleRate) + channel.levelDB
        }.max() ?? 0
        return min(0, -(peak * 10).rounded(.up) / 10)
    }
}

// MARK: - Equalizer APO / REW text

extension RoomProfile {
    /// Channel names Equalizer APO uses, by the decoded channel they correct (L R C LFE, then the surrounds).
    static let apoChannels: [String: Int] = [
        "L": 0, "R": 1, "C": 2, "LFE": 3, "SUB": 3, "RL": 4, "BL": 4, "RR": 5, "BR": 5, "SL": 6, "SR": 7,
    ]

    /// Reads an Equalizer APO configuration (as REW and other room-measurement tools write it) with per-speaker
    /// sections:
    ///
    ///     Preamp: -4 dB
    ///     Channel: L
    ///     Delay: 1.2 ms
    ///     Filter 1: ON PK Fc 42 Hz Gain -9.5 dB Q 6.0
    ///     Channel: R
    ///     Preamp: -1.5 dB
    ///     Filter 1: ON PK Fc 45 Hz Gain -7 dB Q 5.2
    ///
    /// `Channel:` takes APO's names (L R C LFE/SUB RL RR SL SR), 1-based numbers, or ALL. Filters and delays before
    /// any `Channel:` apply to every channel. A `Preamp:` there is the profile's preamp; under `Channel:` it's that
    /// speaker's level. A file with no `Channel:` lines corrects left and right alike.
    public static func parseAPO(_ text: String, name: String) throws -> RoomProfile {
        var shared = RoomChannelCorrection()
        var own: [Int: RoomChannelCorrection] = [:]
        var scope: [Int]? = nil   // nil: every channel
        var profile = RoomProfile(name: name)
        var lineNumber = 0
        var anyFilter = false

        func update(_ change: (inout RoomChannelCorrection) -> Void) {
            if let scope { for c in scope { change(&own[c, default: RoomChannelCorrection()]) } } else { change(&shared) }
        }

        for raw in text.components(separatedBy: .newlines) {
            lineNumber += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let command = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let tokens = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace).map(String.init)
            switch command {
            case "channel":
                guard !tokens.isEmpty else { throw EQImportError.unreadable(line: lineNumber) }
                if tokens.contains(where: { $0.uppercased() == "ALL" }) { scope = nil; continue }
                scope = try tokens.map { token in
                    if let n = Int(token), n >= 1, n <= maxChannels { return n - 1 }
                    if let c = apoChannels[token.uppercased()] { return c }
                    throw EQImportError.unsupportedChannel(line: lineNumber, name: token)
                }
            case "preamp":
                guard let db = tokens.first.flatMap(EQPreset.number) else { throw EQImportError.unreadable(line: lineNumber) }
                if scope == nil { profile.preampDB += db } else { update { $0.levelDB += db } }
            case "delay":
                guard let value = tokens.first.flatMap(EQPreset.number), value >= 0 else { throw EQImportError.unreadable(line: lineNumber) }
                guard tokens.count < 2 || tokens[1].lowercased() == "ms" else { throw EQImportError.delayInSamples(line: lineNumber) }
                update { $0.delayMs += value }
            case "graphiceq":
                throw EQImportError.graphicEQ
            case "copy", "convolution":
                throw EQImportError.unsupportedCommand(line: lineNumber, command: String(line[..<colon]))
            default:
                guard command == "filter" || (command.hasPrefix("filter") && Int(command.dropFirst(6).trimmingCharacters(in: .whitespaces)) != nil)
                else { continue }   // Device:, Include:, Eval: … say nothing about the sound
                let band = try EQPreset.band(tokens, line: lineNumber)
                anyFilter = true
                update { $0.bands.append(band) }
            }
        }

        let count = max(2, (own.keys.max() ?? -1) + 1)
        profile.channels = (0..<count).map { c in
            let mine = own[c] ?? RoomChannelCorrection()
            return RoomChannelCorrection(delayMs: shared.delayMs + mine.delayMs, levelDB: shared.levelDB + mine.levelDB,
                                         bands: shared.bands + mine.bands)
        }
        guard anyFilter || profile.channels.contains(where: { $0.delayMs > 0 || $0.levelDB != 0 }) else { throw EQImportError.noFilters }
        if let crowded = profile.channels.first(where: { $0.bands.count > maxBands }) {
            throw EQImportError.tooManyRoomFilters(crowded.bands.count)
        }
        for c in profile.channels.indices {
            profile.channels[c].delayMs = min(profile.channels[c].delayMs, RoomChannelCorrection.delayRange.upperBound)
            profile.channels[c].levelDB = min(max(profile.channels[c].levelDB, RoomChannelCorrection.levelRange.lowerBound),
                                              RoomChannelCorrection.levelRange.upperBound)
        }
        profile.preampDB = min(max(profile.preampDB, EQPreset.preampRange.lowerBound), EQPreset.preampRange.upperBound)
        return profile
    }

    /// The profile as Equalizer APO text, which `parseAPO` reads back.
    public var apoText: String {
        var lines = [String(format: "Preamp: %.1f dB", preampDB)]
        let names = ["L", "R", "C", "LFE", "RL", "RR", "SL", "SR"]
        for (c, channel) in channels.enumerated() {
            lines.append("Channel: " + (c < names.count ? names[c] : String(c + 1)))
            if channel.levelDB != 0 { lines.append(String(format: "Preamp: %.1f dB", channel.levelDB)) }
            if channel.delayMs > 0 { lines.append(String(format: "Delay: %.2f ms", channel.delayMs)) }
            if let impulse = channel.impulse { lines.append("# Convolution: \(impulse.name) (impulse responses aren't exported)") }
            let filters = EQPreset(name: name, bands: channel.bands).apoText.components(separatedBy: "\n").dropFirst().filter { !$0.isEmpty }
            lines.append(contentsOf: filters)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
