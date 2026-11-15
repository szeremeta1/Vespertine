//
// Vespertine: the phone player's manners on iOS: the lock screen and Control Center (what is playing, its cover, the
// buttons and the scrubber), a call or an alarm pausing the music and giving it back, unplugged headphones pausing it, the
// output changing under the engine, and a DAC being asked for the song's own rate. iOS only; the decisions are in
// PhoneSystemPolicy.swift, where they are tested.
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
    /// What a DAC has been asked for, and what to ask next when it declines.
    private var ladder = RateLadder()
    private var settling: Task<Void, Never>?
    /// The channel count last asked of an output, so it isn't asked again for every song.
    private var askedChannels: (route: String, channels: Int)?
    private var volumeWatch: NSKeyValueObservation?

    /// `artwork`: a cover's image data for its key (the app's cover cache).
    public init(remote: PhoneRemote, artwork: @escaping @MainActor (String) async -> Data?) {
        self.remote = remote
        self.artwork = artwork
    }

    public func start() {
        guard !running else { return }
        running = true
        refreshRoute()
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
        observers.append(Self.observe(AVAudioSession.mediaServicesWereResetNotification, session) { [weak self] _, _, _ in
            Task { @MainActor in self?.outputChanged() }
        })
        observers.append(Self.observe(.AVAudioEngineConfigurationChange, nil) { [weak self] _, _, _ in
            Task { @MainActor in self?.outputChanged() }
        })
        remote.outputVolume = Double(session.outputVolume)
        volumeWatch = Self.watchVolume(session) { [weak self] level in
            Task { @MainActor in self?.remote.outputVolume = level }
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
        settling?.cancel()
        volumeWatch = nil
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
        refreshRoute()
        if RouteChangePolicy.pauses(reason: reason) || RouteChangePolicy.pauses(from: old, to: remote.route), remote.playback.isPlaying {
            remote.playback.pause()
        }
        askOutput()
    }

    /// The engine stopped because its output changed (another device, another rate, or iOS restarted its audio services).
    /// iOS may say this before it says a DAC was unplugged: the music is paused first, so it is never started on the speaker.
    private func outputChanged() {
        let old = remote.route
        refreshRoute()
        if RouteChangePolicy.pauses(from: old, to: remote.route), remote.playback.isPlaying { remote.playback.pause() }
        remote.playback.player.recoverFromConfigurationChange()
    }

    private func refreshRoute() {
        let route = PhoneAudioSession.currentRoute().map {
            PhoneRoute(name: $0.outputName, portType: $0.portType, sampleRate: $0.sampleRate, channels: $0.outputChannels, spatial: $0.isSpatialAudioEnabled,
                       maximumChannels: $0.maximumChannels, channelLabels: $0.channelLabels, uid: $0.uid)
        }
        if remote.route != route { remote.route = route }
    }

    /// A DAC (or the headphone adapter) is asked to run at the song's rate, and an interface with more than two outputs
    /// to run with enough of them for a surround song; Bluetooth and the speaker are never asked for anything. iOS
    /// answers by changing the route, which comes back as an output change. What it gave is read back and shown.
    private func askOutput() {
        guard let route = remote.route, let format = remote.playback.stream?.format else { return }
        let session = AVAudioSession.sharedInstance()
        if let channels = route.channelsToAsk(for: format.channels),
           askedChannels?.route != route.name || askedChannels?.channels != channels {
            askedChannels = (route.name, channels)
            try? session.setPreferredOutputNumberOfChannels(channels)
        }
        if let rate = ladder.begin(route: route, songRate: format.sampleRate) { ask(rate) }
    }

    /// Asks for `rate`, then looks at what the output runs at once the song is playing: declined, the next rate down the
    /// ladder is asked for (`RateLadder`).
    private func ask(_ rate: Double) {
        try? AVAudioSession.sharedInstance().setPreferredSampleRate(rate)
        settling?.cancel()
        settling = Task { [weak self] in
            // A preferred rate takes effect while the session is active: wait for the song to be playing.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, !Task.isCancelled else { return }
                guard self.remote.playback.player.state == .playing else { continue }
                self.refreshRoute()
                if let route = self.remote.route, let next = self.ladder.declined(route: route) { self.ask(next) }
                return
            }
            // Never played: the next song asks afresh.
            self?.ladder.forget()
        }
    }

    /// Before a song that arrives as DoP frames starts: the DAC is asked to run at their rate, and for up to two seconds
    /// the session is read to see that it does. Only then are the frames DSD; otherwise the song is asked for as PCM.
    private func bring(_ carrier: Double) async -> Bool {
        func there() -> Bool {
            refreshRoute()
            return remote.route.map { abs($0.sampleRate - carrier) < 0.5 } ?? false
        }
        if there() { return true }
        // A preferred rate is honoured only for an active session.
        try? PhoneAudioSession.activate()
        try? AVAudioSession.sharedInstance().setPreferredSampleRate(carrier)
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return false }
            if there() { return true }
        }
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
        askOutput()
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
