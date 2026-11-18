//
// Vespertine: the audio an AirPlay stream can carry as Apple Lossless, as a value: 44.1 or 48 kHz, 16 or 24 bits, stereo.
//
// AirPlay 1 is 16-bit at 44.1 kHz and nothing else. An AirPlay 2 receiver names each format it takes by one bit of a
// number (the `audioFormat` of a stream, and the `audioInputFormats` its /info answer lists by stream type); the four
// ALAC ones are here, with the choice of the one that keeps most of a song. Nothing here sends anything: 16-bit at
// 44.1 kHz stays what is sent until a receiver has said it takes more.
//
// The bits are the ones AirPlay 2 senders use, as OwnTone (GPL-2.0-or-later) records them. None of its code is included.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public struct AirPlayFormat: Sendable, Equatable, Hashable {
    public var sampleRate: Int
    public var bitDepth: Int

    public init(sampleRate: Int, bitDepth: Int) {
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
    }

    /// What every AirPlay receiver takes.
    public static let cd = AirPlayFormat(sampleRate: 44_100, bitDepth: 16)

    /// Every ALAC format a stream can name, the one that holds most first.
    public static let all = [
        AirPlayFormat(sampleRate: 48_000, bitDepth: 24), AirPlayFormat(sampleRate: 44_100, bitDepth: 24),
        AirPlayFormat(sampleRate: 48_000, bitDepth: 16), cd,
    ]

    /// The bit that names this format in `audioFormat` and `audioInputFormats`; nil for a format AirPlay has no name for.
    public var streamFormat: Int? {
        switch (sampleRate, bitDepth) {
        case (44_100, 16): 0x40000
        case (44_100, 24): 0x80000
        case (48_000, 16): 0x100000
        case (48_000, 24): 0x200000
        default: nil
        }
    }

    /// The formats of `all` that `mask` (a receiver's `audioInputFormats`) has the bit of.
    public static func accepted(mask: Int) -> [AirPlayFormat] {
        all.filter { format in format.streamFormat.map { mask & $0 != 0 } ?? false }
    }

    /// The format to send a song in. `sourceRate`: the song's own rate. `wantsDepth`: more than 16 bits would be lost
    /// at 16 (a deeper source, or samples the chain has changed). `accepted`: what the receiver takes; 16-bit at
    /// 44.1 kHz is always taken, listed or not.
    ///
    /// The rate first, so that a song at 48 kHz or a multiple of it isn't resampled when it needn't be, and nothing at
    /// 44.1 kHz or a multiple of it ever is; then 24 bits where they hold something 16 would lose (which they do when
    /// a 48 kHz song has to go at 44.1 kHz after all).
    public static func choose(sourceRate: Double, wantsDepth: Bool, accepted: [AirPlayFormat]) -> AirPlayFormat {
        let taken = all.filter { $0 == cd || accepted.contains($0) }
        let rate = isMultiple(sourceRate, of: 44_100) || !isMultiple(sourceRate, of: 48_000) ? 44_100 : 48_000
        let atRate = taken.filter { $0.sampleRate == rate }
        let pool = atRate.isEmpty ? taken.filter { $0.sampleRate == 44_100 } : atRate
        // A song that has to move to the other rate is resampled, and what that makes is worth 24 bits too.
        if wantsDepth || atRate.isEmpty, let deep = pool.first(where: { $0.bitDepth == 24 }) { return deep }
        return pool.first { $0.bitDepth == 16 } ?? pool.first ?? cd
    }

    private static func isMultiple(_ rate: Double, of base: Double) -> Bool {
        guard rate >= base - 0.5 else { return false }
        let times = (rate / base).rounded()
        return abs(rate - times * base) <= 0.5
    }

    /// What the receiver plays behind real time, in frames: two seconds, as at 44.1 kHz (`RAOPTiming.latencyFrames`).
    public var latencyFrames: UInt32 { UInt32(sampleRate) * 2 }
    /// What a sync packet says of it: the quarter second receivers always add taken off.
    var syncLatencyFrames: UInt32 { UInt32(sampleRate) * 7 / 4 }
    /// The least a receiver may hold before it plays, in frames: a quarter second.
    var latencyMin: Int { sampleRate / 4 }

    /// The ALAC configuration of 352-frame packets in this format.
    public var alac: ALACConfig {
        var config = ALACConfig()
        config.bitDepth = UInt8(bitDepth)
        config.sampleRate = UInt32(sampleRate)
        return config
    }
}

/// What a session would send if the receiver takes it: enough of the first song to choose a format by.
public struct AirPlayWish: Sendable, Equatable {
    /// The song's own rate.
    public var sourceRate: Double
    /// 16 bits would lose something (a deeper source, or samples the chain changes).
    public var wantsDepth: Bool

    public init(sourceRate: Double, wantsDepth: Bool) {
        self.sourceRate = sourceRate
        self.wantsDepth = wantsDepth
    }

    /// The format for a receiver that takes `accepted`.
    public func format(accepted: [AirPlayFormat]) -> AirPlayFormat {
        AirPlayFormat.choose(sourceRate: sourceRate, wantsDepth: wantsDepth, accepted: accepted)
    }

    /// Nothing but 16-bit at 44.1 kHz would be chosen whatever the receiver takes: there is nothing to ask it.
    public var isPlain: Bool { format(accepted: AirPlayFormat.all) == .cd }
}

extension AirPlay2Message {
    /// What a receiver's /info answer says it takes on a realtime stream: the formats of `AirPlayFormat.all` it has the
    /// bits of. Receivers say it in one of two ways: an `audioFormats` list with an entry per stream type
    /// (`audioInputFormats`), or `supportedFormats` with one mask per kind of stream (`audioStream` is the realtime
    /// one; an Apple TV 4K answers this way, and what its `bufferStream` takes is not offered here). nil when the answer
    /// says neither (a Roku's doesn't), which is not the same as taking none.
    static func acceptedFormats(info: Data) -> [AirPlayFormat]? {
        guard let said = decode(info) else { return nil }
        if let entries = said["audioFormats"] as? [[String: Any]] {
            for entry in entries where entry["type"] as? Int == realtime {
                guard let mask = entry["audioInputFormats"] as? Int else { return nil }
                return AirPlayFormat.accepted(mask: mask)
            }
        }
        if let mask = (said["supportedFormats"] as? [String: Any])?["audioStream"] as? Int {
            return AirPlayFormat.accepted(mask: mask)
        }
        return nil
    }

    /// Whether a receiver's /info answer says its buffered streams take 24-bit ALAC at 48 kHz (`supportedFormats`,
    /// `bufferStream`): the one buffered stream Vespertine makes. An Apple TV 4K's does.
    static func takesBuffered(info: Data) -> Bool {
        guard let mask = (decode(info)?["supportedFormats"] as? [String: Any])?["bufferStream"] as? Int else { return false }
        return mask & bufferedFormat != 0
    }
}
