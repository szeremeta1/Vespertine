//
// Vespertine: the decisions behind the phone's system manners, apart from iOS so they can be tested anywhere: what a call or
// an alarm does to the music, what unplugging headphones does, and which outputs are asked to run at a song's own rate.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

/// A call, Siri or an alarm takes the sound: music that was playing pauses, and comes back when iOS says it may, unless
/// you paused or played it yourself in between.
public struct InterruptionPolicy: Sendable, Equatable {
    public enum Action: Sendable, Equatable { case pause, resume, nothing }

    private var resumesAfter = false

    public init() {}

    public mutating func began(isPlaying: Bool) -> Action {
        resumesAfter = isPlaying
        return isPlaying ? .pause : .nothing
    }

    public mutating func ended(shouldResume: Bool) -> Action {
        defer { resumesAfter = false }
        return resumesAfter && shouldResume ? .resume : .nothing
    }

    /// You pressed play or pause yourself: what the interruption remembered no longer counts.
    public mutating func userActed() { resumesAfter = false }
}

public enum RouteChangePolicy {
    public enum Reason: Sendable, Equatable { case oldDeviceUnavailable, newDeviceAvailable, other }

    /// Headphones unplugged or a Bluetooth device gone: pause, so the music doesn't carry on from the speaker.
    public static func pauses(reason: Reason) -> Bool { reason == .oldDeviceUnavailable }
}

extension PhoneRoute {
    /// The rate to ask iOS for so `streamRate` isn't resampled: only on outputs that can change rate (a USB DAC, the
    /// headphone adapter), and only when they aren't there already. iOS may still decline: the app reads back what it got.
    public func rateToAsk(for streamRate: Double) -> Double? {
        guard !hasFixedRate, streamRate > 0, abs(streamRate - sampleRate) > 0.5 else { return nil }
        return streamRate
    }
}
