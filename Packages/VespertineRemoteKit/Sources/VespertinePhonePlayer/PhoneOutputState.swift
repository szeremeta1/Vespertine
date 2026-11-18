//
// Vespertine: what the phone's output is doing, as one reading. The output, the rate it runs at, its channels, the volume and
// how iOS renders are read from iOS together, by one function, on one list of occasions, and everything that speaks about
// the output (the signal chips, the Output screen, the DoP rules and the DoP test) reads that one state. Before this each was
// read by itself at its own moment, so the app could show a volume from before a DAC was plugged in, or a rate from before
// iOS switched it.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//
// Plain Swift, apart from iOS, so the tests drive it with a scripted session anywhere.
//

import Foundation

/// The output as iOS describes it at one moment.
public struct OutputState: Equatable, Sendable {
    /// Where the sound goes, with the rate and the channels it runs at. nil: iOS names no output.
    public var route: PhoneRoute?
    /// iOS's volume for the output, 0…1. nil: not read yet, or there is no output to have one.
    public var volume: Double?
    /// What iOS says it renders the app's audio as. nil: not read (before iOS 17.2).
    public var rendering: SystemRenderingMode?
    /// A rate the output was asked for that iOS hasn't been seen to give or to refuse yet. While it is set and the
    /// output runs at another rate, that other rate is on its way out: it is not shown as where the output settled.
    public var pendingRate: Double?
    /// iOS's volume has been seen at two different levels while this was the output: the phone's volume buttons move it.
    /// false says nothing either way (nobody may have pressed them); iOS has no API that says an output's volume is fixed.
    public var volumeMoved = false

    public init(route: PhoneRoute? = nil, volume: Double? = nil, rendering: SystemRenderingMode? = nil, pendingRate: Double? = nil, volumeMoved: Bool = false) {
        self.route = route
        self.volume = volume
        self.rendering = rendering
        self.pendingRate = pendingRate
        self.volumeMoved = volumeMoved
    }

    /// The rate the output is being switched to, while it still runs at another.
    public var switchingTo: Double? {
        guard let pendingRate, let route, abs(route.sampleRate - pendingRate) > 0.5 else { return nil }
        return pendingRate
    }
}

/// One look at the audio session: everything in it was read in the same call.
public struct OutputReading: Equatable, Sendable {
    public var route: PhoneRoute?
    public var volume: Double?
    public var rendering: SystemRenderingMode?

    public init(route: PhoneRoute? = nil, volume: Double? = nil, rendering: SystemRenderingMode? = nil) {
        self.route = route
        self.volume = volume
        self.rendering = rendering
    }
}

/// As much of the audio session as the output's state is read from and asked through: iOS's own on a phone, a script in
/// the tests.
@MainActor
public protocol OutputSession: AnyObject {
    /// The output, its rate and channels, the volume and the rendering mode, all as they are now.
    func read() -> OutputReading
    func ask(rate: Double)
    func ask(channels: Int)
}

/// Keeps `OutputState` true. Every occasion on which iOS may have changed something ends in one `refresh`, which reads
/// everything again; a rate that was asked for is read again and again until iOS gives it, or has had long enough.
@MainActor
public final class OutputWatch {
    /// Why the output is being read: for the log.
    public enum Occasion: String, Sendable {
        /// The player was made.
        case start
        /// iOS said the route changed (plugged, unplugged, another output chosen).
        case routeChange
        /// The engine's output changed under it, or iOS restarted its audio services.
        case outputChange
        /// Spatial Audio was switched for the headphones, or iOS changed how it renders.
        case rendering
        /// The audio session was made active.
        case activation
        /// The app came back to the front.
        case foreground
        /// A song started, or started sounding.
        case song
        /// iOS said the volume changed.
        case volume
        /// The DoP test ended, or is looking at the output while it plays.
        case dopTest
        /// A rate was asked for a moment ago.
        case settle
        /// Nothing in particular: a look every couple of seconds while music plays, in case iOS changed something and
        /// said nothing.
        case heartbeat
        /// A screen that shows the output came up.
        case shown
    }

    public private(set) var state = OutputState()
    /// Told each time a reading differs from the one before.
    public var onChange: ((OutputState) -> Void)?
    /// Every read and every ask, in words (debug builds send them to the system log).
    public var log: ((String) -> Void)?

    private let session: OutputSession
    private var ladder = RateLadder()
    /// The channel count last asked of an output, so it isn't asked again for every song.
    private var askedChannels: (route: String, channels: Int)?
    /// What the song being played is: the rate and the channel count asked of an output that can change them.
    private var wanted: (rate: Double, channels: Int)?
    private var playingTicks = 0
    private var waitingTicks = 0
    private var lingerTicks = 0

    /// How often an output that was asked for a rate is read again.
    public static let tick: Duration = .milliseconds(100)
    /// How long a song must have been sounding at another rate before the rate asked for counts as declined.
    static let patience = 20
    /// How long a rate asked for waits for a song to start sounding (a preferred rate only takes effect then).
    static let waitForSong = 150
    /// After the asking is over, the output is read this much longer, for a DAC that switches late.
    static let linger = 50

    public init(session: OutputSession) {
        self.session = session
    }

    /// Reads everything iOS says about the output, now. The one place it is read.
    @discardableResult public func refresh(_ occasion: Occasion) -> OutputState {
        let reading = session.read()
        var next = state
        next.route = reading.route
        next.volume = reading.volume
        next.rendering = reading.rendering
        // Another output (or none): what the old one was asked for is nothing to this one.
        if state.route?.name != reading.route?.name || state.route?.uid != reading.route?.uid {
            next.pendingRate = nil
            next.volumeMoved = false
            lingerTicks = 0
        } else if let was = state.volume, let now = reading.volume, abs(was - now) > 0.001 {
            next.volumeMoved = true
        }
        if let pending = next.pendingRate, let route = next.route, abs(route.sampleRate - pending) < 0.5 {
            next.pendingRate = nil
        }
        // The DoP test moves the DAC to rates of its own: what a song asked of it before the test no longer holds, and
        // the next song asks afresh.
        if occasion == .dopTest {
            ladder.forget()
            wanted = nil
        }
        note("read (\(occasion.rawValue)): \(Self.words(next))")
        set(next)
        ask()
        return state
    }

    /// The song being played (or about to be): an output that can change rate is asked for the song's, and an interface
    /// for a channel per speaker of a surround song. nil: nothing plays, nothing is asked.
    public func want(rate: Double, channels: Int) {
        if let wanted, abs(wanted.rate - rate) < 0.5, wanted.channels == channels { return }
        wanted = (rate, channels)
        ask()
    }

    public func wantNothing() { wanted = nil }

    /// Asks the output for `rate` outright (a DoP song's carrier rate, before any of it is played) and shows it as on
    /// its way until iOS gives it or `giveUp()` is called.
    public func bring(to rate: Double) {
        guard let route = state.route, abs(route.sampleRate - rate) > 0.5 else { return }
        request(rate)
    }

    /// The rate asked for won't come: what iOS reports is what the output runs at.
    public func giveUp() {
        guard state.pendingRate != nil else { return }
        var next = state
        next.pendingRate = nil
        note("gave up waiting: \(Self.words(next))")
        set(next)
        lingerTicks = Self.linger
    }

    /// Whether `tick` should be called again after `OutputWatch.tick`.
    public var needsTicks: Bool { state.pendingRate != nil || lingerTicks > 0 }

    /// A moment after a rate was asked for: reads the output again. `playing`: a song is sounding, so iOS has had its
    /// chance to switch. A rate iOS hasn't given after `patience` such looks counts as declined, and the next one down
    /// the ladder is asked for; with nothing left to ask, what iOS reports stands. Returns whether to call again.
    @discardableResult public func tick(playing: Bool) -> Bool {
        refresh(.settle)
        guard state.pendingRate != nil else {
            if lingerTicks > 0 { lingerTicks -= 1 }
            return needsTicks
        }
        if playing {
            playingTicks += 1
            if playingTicks >= Self.patience {
                if let route = state.route, let next = ladder.declined(route: route) {
                    note("declined after \(playingTicks) looks while playing; next rate down")
                    request(next)
                } else {
                    giveUp()
                }
            }
        } else {
            waitingTicks += 1
            if waitingTicks >= Self.waitForSong {
                // Never played: the next song asks afresh.
                ladder.forget()
                wanted = nil
                giveUp()
                lingerTicks = 0
            }
        }
        return needsTicks
    }

    private func ask() {
        guard let route = state.route, let wanted else { return }
        if let channels = route.channelsToAsk(for: wanted.channels),
           askedChannels?.route != route.name || askedChannels?.channels != channels {
            askedChannels = (route.name, channels)
            note("ask: \(channels) channels")
            session.ask(channels: channels)
        }
        if let rate = ladder.begin(route: route, songRate: wanted.rate) { request(rate) }
    }

    private func request(_ rate: Double) {
        playingTicks = 0
        waitingTicks = 0
        lingerTicks = 0
        note("ask: \(PhoneSignal.kilohertz(rate)) kHz")
        session.ask(rate: rate)
        var next = state
        next.pendingRate = rate
        set(next)
    }

    private func set(_ next: OutputState) {
        guard next != state else { return }
        state = next
        onChange?(next)
    }

    private func note(_ line: @autoclosure () -> String) {
        if let log { log(line()) }
    }

    static func words(_ state: OutputState) -> String {
        let route = state.route.map { "\($0.name) [\($0.portType)] uid=\($0.uid ?? "?") rate=\($0.sampleRate) channels=\($0.channels)" } ?? "no output"
        let volume = state.volume.map { String(format: "%.3f", $0) } ?? "unknown"
        let pending = state.pendingRate.map { " asked=\($0)" } ?? ""
        return "\(route) volume=\(volume)\(state.volumeMoved ? " (seen to move)" : "")\(pending)"
    }
}
