//
// Vespertine: the phone player's manners on iOS: the lock screen and Control Center (what is playing, its cover, the
// buttons and the scrubber), a call or an alarm pausing the music and giving it back, unplugged headphones pausing it, the
// output changing under the engine, and a DAC being asked for the song's own rate. iOS only; the decisions are in
// PhoneSystemPolicy.swift and the reading of the output in PhoneOutputState.swift, where they are tested.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#if os(iOS)
import AVFAudio
import Foundation
import MediaPlayer
import Observation
import os
import UIKit
import VespertineRemoteProtocol

@MainActor
public final class PhoneSystem {
    public let remote: PhoneRemote
    private let artwork: @MainActor (String) async -> Data?

    private var policy = InterruptionPolicy()
    private var observers: [NSObjectProtocol] = []
    private var commands: [(command: MPRemoteCommand, target: Any)] = []
    private var running = false

    /// What the lock screen was last told.
    private var shown: NowPlayingCard?
    /// Which buttons work right now. Read by MediaPlayer's handlers on whatever queue they are called on, so a press that
    /// can do nothing is answered as such at once.
    private let controls = OSAllocatedUnfairLock(initialState: SystemControls.none)
    private var cover: (key: String, art: MPMediaItemArtwork)?
    private var coverTask: Task<Void, Never>?
    private var coverTried: String?
    /// Reads the output from iOS (its route, rate, channels, volume and rendering together) and asks a DAC for a song's rate.
    private let watch = OutputWatch(session: SystemOutputSession())
    /// Looks at the output again while a rate that was asked for is on its way, and every two seconds while music plays.
    private var driver: Task<Void, Never>?
    private var driverIsFast = false
    /// The song and whether it was sounding when the output was last read for a song starting.
    private var songSeen: (entry: String?, playing: Bool) = (nil, false)
    private var volumeWatch: NSKeyValueObservation?
    #if DEBUG
    private static let outputLog = Logger(subsystem: "org.szeremeta.VespertineRemote", category: "output")
    #endif

    /// `artwork`: a cover's image data for its key (the app's cover cache).
    public init(remote: PhoneRemote, artwork: @escaping @MainActor (String) async -> Data?) {
        self.remote = remote
        self.artwork = artwork
    }

    public func start() {
        guard !running else { return }
        running = true
        watch.onChange = { [weak self] state in self?.remote.output = state }
        #if DEBUG
        // Every read of the output and every rate asked of it, with the log's own timestamps: a rate shown wrong can be
        // traced to the read that was missing or late.
        watch.log = { line in Self.outputLog.debug("\(line, privacy: .public)") }
        #endif
        remote.readOutput = { [weak self] occasion in self?.look(occasion) ?? OutputState() }
        look(.start)
        remote.onTransport = { [weak self] command in self?.transport(command) }
        remote.playback.dop.bring = { [weak self] carrier in await self?.bring(carrier) ?? false }
        let session = AVAudioSession.sharedInstance()
        observers.append(Self.observe(AVAudioSession.interruptionNotification, session) { [weak self] type, options, _ in
            let began = type.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            let mayResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            Task { @MainActor in self?.interrupted(began: began, mayResume: mayResume) }
        })
        observers.append(Self.observe(AVAudioSession.routeChangeNotification, session) { [weak self] _, _, raw in
            let reason: RouteChangePolicy.Reason = switch AVAudioSession.RouteChangeReason(rawValue: raw) {
            case .oldDeviceUnavailable: .oldDeviceUnavailable
            case .newDeviceAvailable: .newDeviceAvailable
            default: .other
            }
            Task { @MainActor in self?.routeChanged(reason) }
        })
        // Spatial Audio switched on or off for the headphones in Control Center: whether they follow your head changed.
        observers.append(Self.observe(AVAudioSession.spatialPlaybackCapabilitiesChangedNotification, session) { [weak self] _, _, _ in
            Task { @MainActor in self?.look(.rendering) }
        })
        // What iOS renders the app's audio as (stereo, surround, Spatial Audio, Dolby Atmos): the badge says only what this says.
        if #available(iOS 17.2, *) {
            observers.append(Self.observe(AVAudioSession.renderingModeChangeNotification, session) { [weak self] _, _, _ in
                Task { @MainActor in self?.look(.rendering) }
            })
        }
        observers.append(Self.observe(AVAudioSession.mediaServicesWereResetNotification, session) { [weak self] _, _, _ in
            Task { @MainActor in self?.outputChanged() }
        })
        observers.append(Self.observe(.AVAudioEngineConfigurationChange, nil) { [weak self] _, _, _ in
            Task { @MainActor in self?.outputChanged() }
        })
        // Back at the front: iOS may have changed the output or the volume while nobody was told.
        observers.append(Self.observe(UIApplication.didBecomeActiveNotification, nil) { [weak self] _, _, _ in
            Task { @MainActor in self?.look(.foreground) }
        })
        // iOS says the volume changed. It doesn't always (a DAC plugged in can bring a volume of its own and no word of
        // it), which is why every other occasion reads the volume too.
        volumeWatch = Self.watchVolume(session) { [weak self] _ in
            Task { @MainActor in self?.look(.volume) }
        }
        registerCommands()
        track()
    }

    public func stop() {
        guard running else { return }
        running = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        for (command, target) in commands { command.removeTarget(target) }
        commands = []
        coverTask?.cancel()
        driver?.cancel()
        driver = nil
        renderingCheck?.cancel()
        volumeWatch = nil
        watch.onChange = nil
        remote.readOutput = nil
        controls.withLock { $0 = .none }
        remote.onTransport = nil
        remote.playback.dop.bring = { _ in false }
        shown = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Interruptions and outputs

    private func interrupted(began: Bool, mayResume: Bool) {
        let action = began ? policy.began(isPlaying: remote.playback.isPlaying) : policy.ended(shouldResume: mayResume)
        switch action {
        case .pause: remote.playback.pause()
        case .resume: remote.playback.resume()
        case .nothing: break
        }
    }

    private func routeChanged(_ reason: RouteChangePolicy.Reason) {
        let old = remote.route
        look(.routeChange)
        if RouteChangePolicy.pauses(reason: reason) || RouteChangePolicy.pauses(from: old, to: remote.route), remote.playback.isPlaying {
            remote.playback.pause()
        }
    }

    /// The engine stopped because its output changed (another device, another rate, or iOS restarted its audio services).
    /// iOS may say this before it says a DAC was unplugged: the music is paused first, so it is never started on the speaker.
    private func outputChanged() {
        let old = remote.route
        look(.outputChange)
        if RouteChangePolicy.pauses(from: old, to: remote.route), remote.playback.isPlaying { remote.playback.pause() }
        remote.playback.player.recoverFromConfigurationChange()
    }

    /// Reads everything iOS says about the output, now: the route, its rate and channels, the volume and the rendering
    /// mode, together (`OutputWatch.refresh`). Every occasion on which any of it may have changed ends here; nothing else
    /// reads the session for the screens.
    @discardableResult private func look(_ occasion: OutputWatch.Occasion) -> OutputState {
        let state = watch.refresh(occasion)
        drive()
        return state
    }

    /// Keeps looking while there is something to wait for: every `OutputWatch.tick` while a rate that was asked for is
    /// on its way, and every two seconds while music plays (iOS doesn't announce every change: a DAC's rate can move
    /// with no notification at all when the engine isn't running yet).
    private func drive() {
        let fast = watch.needsTicks
        if driver != nil, driverIsFast || !fast { return }
        driver?.cancel()
        driverIsFast = fast
        driver = Task { [weak self] in
            while !Task.isCancelled {
                guard let pause = self?.driveStep() else { return }
                try? await Task.sleep(for: pause)
            }
        }
    }

    /// One look, and how long until the next; nil when there is nothing to wait for.
    private func driveStep() -> Duration? {
        guard running else { return nil }
        let playing = remote.playback.player.state == .playing && !remote.playback.player.isBuffering
        if watch.needsTicks {
            driverIsFast = true
            watch.tick(playing: playing)
            return OutputWatch.tick
        }
        driverIsFast = false
        guard playing else {
            driver = nil
            return nil
        }
        watch.refresh(.heartbeat)
        return watch.needsTicks ? OutputWatch.tick : .seconds(2)
    }

    private var renderingCheck: Task<Void, Never>?
    private var renderingSeen: (PhonePlayer.Rendering, Bool)?

    /// A song started, stopped or changed path: iOS resolves its rendering once audio flows, so it is read again shortly.
    private func settleRendering(_ rendering: PhonePlayer.Rendering, playing: Bool) {
        guard renderingSeen.map({ $0.0 != rendering || $0.1 != playing }) ?? true else { return }
        renderingSeen = (rendering, playing)
        look(.rendering)
        renderingCheck?.cancel()
        renderingCheck = Task { [weak self] in
            for delay in [300, 1_000, 3_000] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                self?.look(.rendering)
            }
        }
    }

    /// Before a song that arrives as DoP frames starts: the DAC is asked to run at their rate, and for up to two seconds
    /// the session is read to see that it does. Only then are the frames DSD; otherwise the song is asked for as PCM.
    private func bring(_ carrier: Double) async -> Bool {
        func there() -> Bool {
            look(.settle).route.map { abs($0.sampleRate - carrier) < 0.5 } ?? false
        }
        if there() { return true }
        // A preferred rate is honoured only for an active session.
        try? PhoneAudioSession.activate()
        look(.activation)
        watch.bring(to: carrier)
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { watch.giveUp(); return false }
            if there() { return true }
        }
        watch.giveUp()
        return false
    }

    private func transport(_ command: RemoteCommand) {
        policy.userActed()
        if case .stop = command {
            // Let other apps' audio come back.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: Lock screen and Control Center

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        let controls = controls
        func on(_ command: MPRemoteCommand, needs: @escaping @Sendable (SystemControls) -> Bool,
                _ action: @escaping @MainActor @Sendable (PhoneSystem, Double?) -> Void) {
            // Greyed out until there is a song for it (`apply`).
            command.isEnabled = false
            let target = Self.register(command, allowed: { needs(controls.withLock { $0 }) }) { [weak self] seconds in
                Task { @MainActor in
                    guard let self, self.remote.playback.nowPlaying != nil else { return }
                    self.policy.userActed()
                    action(self, seconds)
                }
            }
            commands.append((command, target))
        }
        on(center.playCommand, needs: { $0.playPause }) { me, _ in me.remote.playback.resume() }
        on(center.pauseCommand, needs: { $0.playPause }) { me, _ in me.remote.playback.pause() }
        on(center.togglePlayPauseCommand, needs: { $0.playPause }) { me, _ in me.remote.playback.playPause() }
        on(center.nextTrackCommand, needs: { $0.next }) { me, _ in me.remote.playback.next() }
        on(center.previousTrackCommand, needs: { $0.previous }) { me, _ in me.remote.playback.previous() }
        on(center.changePlaybackPositionCommand, needs: { $0.seek }) { me, seconds in if let seconds { me.remote.playback.seek(to: seconds) } }
    }

    /// Greys out the lock screen's buttons that would do nothing, and lights the others.
    private func apply(_ now: SystemControls) {
        guard controls.withLock({ $0 }) != now else { return }
        controls.withLock { $0 = now }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = now.playPause
        center.pauseCommand.isEnabled = now.playPause
        center.togglePlayPauseCommand.isEnabled = now.playPause
        center.nextTrackCommand.isEnabled = now.next
        center.previousTrackCommand.isEnabled = now.previous
        center.changePlaybackPositionCommand.isEnabled = now.seek
    }

    /// MediaPlayer may call a handler on any queue: it isn't the main actor's, and hops there. A press that can do nothing
    /// right now (headphone buttons and CarPlay send them whatever is greyed out) is answered as that, not as done.
    nonisolated private static func register(_ command: MPRemoteCommand, allowed: @escaping @Sendable () -> Bool,
                                             _ action: @escaping @Sendable (Double?) -> Void) -> Any {
        command.addTarget { event in
            guard allowed() else { return .noActionableNowPlayingItem }
            action((event as? MPChangePlaybackPositionCommandEvent)?.positionTime)
            return .success
        }
    }

    /// The volume buttons: KVO calls on whichever thread changed it.
    nonisolated private static func watchVolume(_ session: AVAudioSession, _ changed: @escaping @Sendable (Double) -> Void) -> NSKeyValueObservation {
        session.observe(\.outputVolume, options: [.new]) { _, change in
            if let level = change.newValue { changed(Double(level)) }
        }
    }

    /// MediaPlayer asks for the image on its own queue, so the closure must not be the main actor's.
    nonisolated private static func art(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    /// Notifications are delivered on the main queue (asked for below); the closure itself belongs to no actor.
    nonisolated private static func observe(_ name: Notification.Name, _ object: AnyObject?,
                                            _ action: @escaping @Sendable (_ type: UInt?, _ options: UInt, _ reason: UInt) -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { note in
            action(note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                   note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0,
                   note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0)
        }
    }

    /// Follows the player: runs `update` whenever something it reads changes.
    private func track() {
        guard running else { return }
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
    }

    private func update() {
        let playback = remote.playback
        _ = playback.stream
        // Read so a seek or a stall brings this back; the lock screen is told where the song is this instant.
        _ = playback.anchor
        // A DAC is asked for the song's own rate, and an interface for a surround song's channels (`OutputWatch.want`).
        if let format = playback.stream?.format { watch.want(rate: format.sampleRate, channels: format.channels) }
        // A song started, or started sounding (which is when the session is made active and a rate asked for takes
        // effect): the output is read again, volume and all.
        let song = (entry: playback.nowPlaying?.id, playing: playback.player.state == .playing)
        if song != songSeen {
            songSeen = song
            look(.song)
        }
        drive()
        settleRendering(playback.player.rendering, playing: playback.player.state == .playing)
        // Shuffle, repeat and edits change what Next can do and where the song is in the queue.
        let queue = playback.queue
        let card = NowPlayingCard(queue: queue, nowPlaying: playback.nowPlaying, duration: playback.duration, position: playback.livePosition,
                                  playing: playback.player.state == .playing && !playback.player.isBuffering)
        apply(SystemControls(queue: queue, card: card))
        guard let card else {
            if shown != nil {
                shown = nil
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
            return
        }
        loadCover(card.artworkKey)
        guard card.isNews(after: shown) else { return }
        shown = card
        publish(card)
    }

    private func publish(_ card: NowPlayingCard) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: card.title,
            MPMediaItemPropertyArtist: card.artist,
            MPMediaItemPropertyAlbumTitle: card.album,
            MPMediaItemPropertyPlaybackDuration: card.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: card.position,
            MPNowPlayingInfoPropertyPlaybackRate: card.playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: card.queueIndex,
            MPNowPlayingInfoPropertyPlaybackQueueCount: card.queueCount,
        ]
        if let number = card.trackNumber { info[MPMediaItemPropertyAlbumTrackNumber] = number }
        if let disc = card.discNumber { info[MPMediaItemPropertyDiscNumber] = disc }
        if let cover, cover.key == card.artworkKey { info[MPMediaItemPropertyArtwork] = cover.art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadCover(_ key: String?) {
        guard let key else { cover = nil; return }
        guard cover?.key != key, coverTried != key, coverTask == nil else { return }
        coverTried = key
        coverTask = Task { [weak self] in
            guard let self else { return }
            defer { coverTask = nil }
            guard let data = await artwork(key), let image = UIImage(data: data), !Task.isCancelled else { return }
            cover = (key, Self.art(image))
            if let shown, shown.artworkKey == key, remote.playback.nowPlaying?.id == shown.entry { publish(shown) }
        }
    }
}
#endif
