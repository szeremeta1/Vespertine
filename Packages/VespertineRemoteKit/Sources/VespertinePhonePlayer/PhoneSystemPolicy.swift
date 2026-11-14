//
// Vespertine: the decisions behind the phone's system manners, apart from iOS so they can be tested anywhere: what a call or
// an alarm does to the music, what unplugging headphones does, and which outputs are asked to run at a song's own rate.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

/// Off, Fixed or Head Tracked, as the Mac's Spatial Audio setting has them (`SpatialMode` where Core Audio exists).
public enum SpatialModeChoice: String, Sendable, Equatable, CaseIterable, Codable {
    case off, fixed, headTracked
}

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

/// Where the song is, told only when it's news. A song that plays moves by itself, and whoever shows it works out where
/// it has got to from where it was and when (`PlayerState.expectedPosition`); telling every reading afresh redrew the
/// whole player four times a second, in the background too.
public struct PositionAnchor: Sendable, Equatable {
    /// The reading may run this far from where the anchor expects it before the anchor moves.
    public static let tolerance = 0.25

    public private(set) var position: Double
    public private(set) var at: Date
    /// The song was advancing at `at`.
    public private(set) var moving: Bool

    public init(position: Double = 0, at: Date = Date(), moving: Bool = false) {
        self.position = position
        self.at = at
        self.moving = moving
    }

    public func expected(at date: Date) -> Double { moving ? position + date.timeIntervalSince(at) : position }

    /// Takes a reading. True when it is news: the song started or stopped moving, or isn't where it was expected.
    public mutating func read(_ now: Double, moving: Bool, at date: Date = Date()) -> Bool {
        guard moving != self.moving || abs(now - expected(at: date)) > Self.tolerance else { return false }
        place(now, moving: moving, at: date)
        return true
    }

    /// The song was put here (a seek, another song).
    public mutating func place(_ now: Double, moving: Bool, at date: Date = Date()) {
        position = now
        at = date
        self.moving = moving
    }
}

public enum RouteChangePolicy {
    public enum Reason: Sendable, Equatable { case oldDeviceUnavailable, newDeviceAvailable, other }

    /// Headphones unplugged or a Bluetooth device gone: pause, so the music doesn't carry on from the speaker.
    public static func pauses(reason: Reason) -> Bool { reason == .oldDeviceUnavailable }
}

extension PhoneRoute {
    /// Headphones of some kind: Bluetooth, the headphone jack or adapter, or a USB DAC (which usually feeds headphones from
    /// a phone).
    public var isHeadphones: Bool { isBluetooth || isUSB || portType == "Headphones" }

    /// How a surround song is played on this output when you asked for `wanted`: rendered for headphones only on
    /// headphones, head tracked only where the headphones follow your head, folded to stereo everywhere else.
    public func surroundMode(wanted: SpatialModeChoice) -> SpatialModeChoice {
        guard isHeadphones, wanted != .off else { return .off }
        return wanted == .headTracked && !spatial ? .fixed : wanted
    }

    /// The rate to ask iOS for so `streamRate` isn't resampled: only on outputs that can change rate (a USB DAC, the
    /// headphone adapter), and only when they aren't there already. iOS may still decline: the app reads back what it got.
    public func rateToAsk(for streamRate: Double) -> Double? {
        guard !hasFixedRate, streamRate > 0, abs(streamRate - sampleRate) > 0.5 else { return nil }
        return streamRate
    }
}
