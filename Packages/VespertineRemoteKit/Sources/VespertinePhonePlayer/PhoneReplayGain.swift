//
// Vespertine: ReplayGain on the phone, worked out. A song's file may say how much quieter or louder to play it so that it
// sits level with other songs (its track gain) or so that its album does (its album gain), and how high its loudest
// sample goes (its peak). This turns those values and the listener's choice into the one number the player multiplies
// samples by. Off is the starting point: any gain changes the samples.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//
// The rules are the Mac player's: the gain of the kind chosen (the other kind when the file has only that one), held
// down so the peak never passes full scale, and kept within -30…+15 dB.
//

import Foundation
import VespertineRemoteProtocol

/// How songs are levelled on this device.
public enum ReplayGainChoice: String, Sendable, CaseIterable, Codable {
    /// Nothing is changed.
    case off
    /// Each song by its own gain.
    case track
    /// Each song by its album's gain, so an album keeps its quiet and loud songs.
    case album
}

/// What is done to a song's samples for ReplayGain.
public struct AppliedGain: Equatable, Sendable {
    /// The change in decibels, after the peak has had its say: what the Output screen shows.
    public var decibels: Double
    /// What each sample is multiplied by.
    public var scale: Float
    /// The file asked for more, and it was held down so the song's peak stays at or under full scale.
    public var heldByPeak: Bool

    public init(decibels: Double, scale: Float, heldByPeak: Bool) {
        self.decibels = decibels
        self.scale = scale
        self.heldByPeak = heldByPeak
    }
}

public enum PhoneReplayGain {
    /// The same limits the Mac player keeps a gain within.
    public static let range: ClosedRange<Double> = -30...15

    /// What to do to a song with these values, or nil when nothing is to be done: the choice is Off, the file says
    /// nothing usable, or what it asks for comes to no change at all.
    public static func applied(_ values: ReplayGain?, choice: ReplayGainChoice) -> AppliedGain? {
        guard let values else { return nil }
        let gain: Double?, peak: Double?
        switch choice {
        case .off: return nil
        case .track: gain = values.trackGain ?? values.albumGain; peak = values.trackPeak ?? values.albumPeak
        case .album: gain = values.albumGain ?? values.trackGain; peak = values.albumPeak ?? values.trackPeak
        }
        guard let gain, gain.isFinite else { return nil }
        var decibels = min(max(gain, range.lowerBound), range.upperBound)
        var held = false
        if let peak, peak.isFinite, peak > 0 {
            let room = -20 * log10(peak)
            if decibels > room {
                decibels = room
                held = true
            }
        }
        var scale = Float(pow(10, decibels / 20))
        // Rounding to a Float must not be what lets the peak through.
        if held, let peak { while Double(scale) * peak > 1 { scale = scale.nextDown } }
        guard scale != 1, scale > 0, scale.isFinite else { return nil }
        return AppliedGain(decibels: decibels, scale: scale, heldByPeak: held)
    }
}
