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

/// Where a surround song's channels go (`PhoneRoute.surroundPath`).
public enum SurroundPath: Equatable, Sendable {
    /// Folded to stereo by the app.
    case fold
    /// Handed to iOS with all its channels and their layout: iOS's Spatial Audio renders it.
    case system
    /// Rendered for headphones by the app (Apple's spatial mixer, fixed), for headphones iOS doesn't spatialize.
    case binaural
    /// A channel to each output of an interface.
    case discrete
}

/// What iOS says it does with the app's audio (`AVAudioSession.renderingMode`, iOS 17.2 and later), in the same order.
public enum SystemRenderingMode: Int, Equatable, Sendable {
    case notApplicable = 0, monoStereo, surround, spatialAudio, dolbyAudio, dolbyAtmos
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

/// What the lock screen and Control Center are told about the song: who, where in it, and where in the queue. Built here,
/// where it is tested; the system glue only hands it to iOS.
public struct NowPlayingCard: Equatable, Sendable {
    /// The queue entry it is about.
    public var entry: String
    public var title: String
    public var artist: String
    public var album: String
    public var trackNumber: Int?
    public var discNumber: Int?
    public var artworkKey: String?
    public var duration: Double
    /// Where the song was at `at`.
    public var position: Double
    /// Sounding and moving: not paused, not waiting for audio from the Mac.
    public var playing: Bool
    public var at: Date
    /// The song's place in the queue, counting from zero, and how many songs the queue holds.
    public var queueIndex: Int
    public var queueCount: Int

    /// nil with nothing playing: the lock screen then shows nothing of ours.
    public init?(queue: PhoneQueue, nowPlaying: PhoneQueue.Entry?, duration: Double, position: Double, playing: Bool, at: Date = Date()) {
        guard let nowPlaying else { return nil }
        entry = nowPlaying.id
        title = nowPlaying.track.title
        artist = nowPlaying.track.artist
        album = nowPlaying.track.album
        trackNumber = nowPlaying.track.trackNumber
        discNumber = nowPlaying.track.discNumber
        artworkKey = nowPlaying.track.artworkKey
        self.duration = max(0, duration)
        self.position = max(0, position)
        self.playing = playing
        self.at = at
        // The song being heard, which for a moment at a join is not yet the queue's current one.
        queueIndex = queue.entries.firstIndex { $0.id == nowPlaying.id } ?? queue.currentIndex ?? 0
        queueCount = queue.entries.count
    }

    /// Where the lock screen, counting on by itself, takes the song to be at `now`.
    public func expected(at now: Date) -> Double { playing ? position + now.timeIntervalSince(at) : position }

    /// Whether the lock screen has to be told again after it was told `shown`. A song that simply plays on is not news
    /// (the lock screen counts by itself); another song, a pause, a seek, a stall, or the queue changing around it is.
    public func isNews(after shown: NowPlayingCard?) -> Bool {
        guard let shown else { return true }
        var same = shown
        same.position = position
        same.at = at
        guard same == self else { return true }
        return abs(shown.expected(at: at) - position) >= 1.5
    }
}

/// Which of the lock screen's buttons do something right now. A button that would do nothing is shown greyed out rather
/// than accepting a press and ignoring it.
public struct SystemControls: Equatable, Sendable {
    /// Play, pause and the headphone button.
    public var playPause: Bool
    public var next: Bool
    public var previous: Bool
    /// Dragging the lock screen's scrubber.
    public var seek: Bool

    public static let none = SystemControls(playPause: false, next: false, previous: false, seek: false)

    public init(playPause: Bool, next: Bool, previous: Bool, seek: Bool) {
        self.playPause = playPause
        self.next = next
        self.previous = previous
        self.seek = seek
    }

    /// For the song on `card` in `queue`. Next needs a song to go to (the following one, or the first again under Repeat
    /// All; Repeat One doesn't stop Next moving on, as in the app). Previous always has something to do: it restarts the
    /// song when there is none before it. The scrubber needs a known length.
    public init(queue: PhoneQueue, card: NowPlayingCard?) {
        guard let card else { self = .none; return }
        let index = queue.entries.firstIndex { $0.id == card.entry }
        let hasFollowing = index.map { $0 + 1 < queue.entries.count } ?? false
        self.init(playPause: true, next: hasFollowing || (queue.repeatMode == .all && !queue.entries.isEmpty), previous: true, seek: card.duration > 0)
    }
}

public enum RouteChangePolicy {
    public enum Reason: Sendable, Equatable { case oldDeviceUnavailable, newDeviceAvailable, other }

    /// Headphones unplugged or a Bluetooth device gone: pause, so the music doesn't carry on from the speaker.
    public static func pauses(reason: Reason) -> Bool { reason == .oldDeviceUnavailable }

    /// The output changed under the player (iOS can say so before it says why). A DAC, headphones or an AirPlay speaker
    /// giving way to the device's own speaker, or to nothing, pauses: the music is never carried on from the speaker.
    public static func pauses(from old: PhoneRoute?, to new: PhoneRoute?) -> Bool {
        guard let old, !old.isBuiltIn else { return false }
        return new?.isBuiltIn ?? true
    }
}

/// Getting a DAC to the song's rate. iOS doesn't say which rates an output has: the app asks, waits a moment and reads back
/// what it got. Declined, it asks for the next best: the song's rate halved, and halved again, so what iOS then has to do
/// is the simplest conversion there is (352.8 kHz to 176.4, not to 48).
public struct RateLadder: Sendable, Equatable {
    private var route: String?
    private var song: Double = 0
    private var asked: [Double] = []

    public init() {}

    /// The song's rate, then its halves down to the CD-era rates: 192 → 96 → 48; 176.4 → 88.2 → 44.1.
    public static func rungs(for rate: Double) -> [Double] {
        guard rate > 0 else { return [] }
        var rungs = [rate], next = rate / 2
        while next >= 44_100 - 0.5 {
            rungs.append(next)
            next /= 2
        }
        return rungs
    }

    /// The rate asked for last, while iOS hasn't been seen to answer.
    public var pending: Double? { asked.last }

    /// A song is playing on `route`: the rate to ask for now, or nil when there is nothing (new) to ask. Asking again for
    /// the same song on the same output returns nil: `declined` moves down the ladder.
    public mutating func begin(route: PhoneRoute, songRate: Double) -> Double? {
        guard !route.hasFixedRate, songRate > 0 else {
            self = RateLadder()
            return nil
        }
        if self.route == route.name, abs(song - songRate) < 0.5 { return nil }
        self.route = route.name
        song = songRate
        asked = []
        guard abs(route.sampleRate - songRate) > 0.5 else { return nil }
        asked = [songRate]
        return songRate
    }

    /// A moment after asking: what `route` runs at now. Returns the next rate to ask for, or nil when iOS gave the rate
    /// asked for (or the song's), or there is nothing lower to try.
    public mutating func declined(route: PhoneRoute) -> Double? {
        guard self.route == route.name, let last = asked.last else { return nil }
        if abs(route.sampleRate - last) < 0.5 || abs(route.sampleRate - song) < 0.5 { return nil }
        guard let next = Self.rungs(for: song).first(where: { rung in !asked.contains { abs($0 - rung) < 0.5 } }) else { return nil }
        // Already there, by luck: nothing to ask.
        asked.append(next)
        return abs(route.sampleRate - next) < 0.5 ? nil : next
    }

    /// The output changed (unplugged, another DAC): the next song starts from the top.
    public mutating func forget() { self = RateLadder() }
}

extension PhoneRoute {
    /// Headphones of some kind: Bluetooth, the headphone jack or adapter, or a USB DAC (which usually feeds headphones from
    /// a phone).
    public var isHeadphones: Bool { isBluetooth || (isUSB && !isMultichannel) || portType == "Headphones" }

    /// An interface or a receiver with more than two outputs: a surround song's channels each go to an output of their own.
    public var isMultichannel: Bool { (isUSB || portType == "HDMI") && channels > 2 }

    /// The number of output channels to ask iOS for so a song of `songChannels` channels plays on outputs of its own: only
    /// for surround, only on an output that has more channels than it runs with now.
    public func channelsToAsk(for songChannels: Int) -> Int? {
        guard isUSB || portType == "HDMI", songChannels > 2, maximumChannels > channels else { return nil }
        let wanted = min(songChannels, maximumChannels)
        return wanted > channels ? wanted : nil
    }

    /// Where a surround song's channels go on this output when you asked for `wanted` (anything but Off means "Spatial
    /// Audio"). An interface with more than two outputs gets a channel on each. Off folds to stereo. Where iOS says it
    /// spatializes (`spatial`: AirPods or Beats with Spatial Audio on), the channels go to iOS as they are and iOS renders
    /// them, Fixed or Head Tracked as chosen in Control Center: no app on iOS can choose that for the system's renderer
    /// (the intended-spatial-experience APIs are visionOS-only in the iOS 27 SDK). Other headphones get Vespertine's own
    /// fixed rendering; speakers iOS doesn't spatialize get the fold.
    public func surroundPath(wanted: SpatialModeChoice, canTrackHead: Bool = true) -> SurroundPath {
        if isMultichannel { return .discrete }
        guard wanted != .off else { return .fold }
        if spatial { return .system }
        return surroundMode(wanted: wanted, canTrackHead: canTrackHead) == .off ? .fold : .binaural
    }

    /// How a surround song is played on this output when you asked for `wanted`: rendered for headphones only on
    /// headphones, head tracked only where the headphones follow your head and the system can turn the scene with it
    /// (`canTrackHead`: iOS 18 and later), folded to stereo everywhere else.
    public func surroundMode(wanted: SpatialModeChoice, canTrackHead: Bool = true) -> SpatialModeChoice {
        guard isHeadphones, !isMultichannel, wanted != .off else { return .off }
        return wanted == .headTracked && !(spatial && canTrackHead) ? .fixed : wanted
    }

    /// The rate to ask iOS for so `streamRate` isn't resampled: only on outputs that can change rate (a USB DAC, the
    /// headphone adapter), and only when they aren't there already. iOS may still decline: the app reads back what it got.
    public func rateToAsk(for streamRate: Double) -> Double? {
        guard !hasFixedRate, streamRate > 0, abs(streamRate - sampleRate) > 0.5 else { return nil }
        return streamRate
    }
}
