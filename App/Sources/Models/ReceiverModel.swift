//
// Vespertine: "Play to Vespertine": this Mac as a UPnP receiver that control apps send music to, behind its Settings › Playback
// switch, off by default. The model exists only while the switch is on; until then no socket is open and nothing is announced.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import Foundation
import Observation
import VespertineAudio
import VespertineUPnP

/// The volume a control app reads and, when the listener allows it, sets: the app model's, for the output that is playing.
@MainActor
struct ReceiverVolume {
    var read: () -> (level: Double, muted: Bool) = { (1, false) }
    var set: (Double) -> Void = { _ in }
    var setMuted: (Bool) -> Void = { _ in }
}

@Observable
@MainActor
final class ReceiverModel {
    enum Status: Equatable { case starting, running, failed(String) }

    private(set) var status = Status.starting
    @ObservationIgnored private let player: PlayerController
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var receiver: UPnPReceiver?
    /// Starts and stops are done one after the other, in the order they were asked for (a quick off and on can't race).
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored var volume = ReceiverVolume()
    /// Tests: the receiver on loopback, announcing nowhere.
    @ObservationIgnored var configure: (inout UPnPReceiver.Configuration) -> Void = { _ in }
    /// The Mac stays awake while a control app's song is meant to be playing, also while it buffers.
    @ObservationIgnored private let activity = PlaybackActivity(reason: "Playing what a control app sent")
    @ObservationIgnored private var lastVolume: (level: Double, muted: Bool)?

    init(player: PlayerController, settings: AppSettings) {
        self.player = player
        self.settings = settings
    }

    /// The name control apps show.
    var name: String { ReceiverSwitch.name(settings) }

    func start() {
        let previous = work
        status = .starting
        var configuration = UPnPReceiver.Configuration(udn: settings.upnpReceiverID, name: name,
                                                       version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1")
        configuration.ownSubnetsOnly = settings.upnpReceiverOwnNetworks
        configuration.allowsVolume = settings.upnpReceiverVolume
        configuration.onRefusal = { [weak player] message, _ in
            Task { @MainActor in player?.receiverRefused(message) }
        }
        configure(&configuration)
        let receiver = UPnPReceiver(configuration, player: self)
        self.receiver = receiver
        player.receiverEvents = { [weak self, weak receiver] event in
            switch event {
            case .started, .resumed: self?.activity.set(true)
            case .ended, .tookOver, .failed: self?.activity.set(false)
            case .paused, .volume: break
            }
            receiver?.playerEvent(event)
        }
        work = Task { [weak self] in
            await previous?.value
            do {
                try await receiver.start()
                if self?.receiver === receiver { self?.status = .running }
            } catch {
                if self?.receiver === receiver { self?.status = .failed(error.localizedDescription) }
            }
        }
    }

    /// Stops what a control app was playing (the listener's queue comes back), says goodbye on the network and closes every socket.
    func stop() {
        let previous = work
        let receiver = receiver
        self.receiver = nil
        player.endReceiverSession()
        player.receiverEvents = nil
        activity.set(false)
        work = Task {
            await previous?.value
            await receiver?.stop()
        }
    }

    /// The name or who may control it changed: control apps are told the old one is gone and find the new one.
    func restart() {
        guard receiver != nil else { return }
        stop()
        start()
    }

    /// Every start and stop asked for so far has been done.
    func settled() async { await work?.value }

    /// The port control apps reach it on; 0 while it is not running.
    var port: UInt16 { get async { await receiver?.port ?? 0 } }

    func volumeAllowedChanged() {
        let allowed = settings.upnpReceiverVolume
        Task { [receiver] in await receiver?.setAllowsVolume(allowed) }
    }

    /// The listener's volume may have moved: control apps that show it are told.
    func volumeMayHaveChanged() {
        guard receiver != nil else { return }
        let now = volume.read()
        guard lastVolume.map({ $0.level != now.level || $0.muted != now.muted }) ?? true else { return }
        lastVolume = now
        receiver?.playerEvent(.volume(level: now.level, muted: now.muted))
    }

    /// For the quit sequence, which runs off the main thread while the main thread waits: goodbye on the network and the sockets
    /// closed, without a word to the player (it is stopped by its own step).
    func goodbyeStep() -> @Sendable () -> Void {
        guard let receiver else { return {} }
        return {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await receiver.stop(stoppingPlayer: false)
                done.signal()
            }
            _ = done.wait(timeout: .now() + 1)
        }
    }

    /// A picture a control app named for its song: fetched under the same rules as the song, kept in memory only.
    private func fetchArtwork(for track: ReceiverTrack) {
        guard let url = track.info.artworkURL else { return }
        let id = track.id
        Task { [weak self] in
            guard let data = await ReceiverArtwork.fetch(url), let image = NSImage(data: data), image.isValid else { return }
            let key = ArtworkCache.shared.keepInMemory(image)
            self?.player.receiverArtwork(key, for: id)
        }
    }
}

extension ReceiverModel: ReceiverPlayer {
    func receiverPlay(_ track: ReceiverTrack, next: ReceiverTrack?, from app: ReceiverControlApp) async {
        activity.set(true)
        player.receiverPlay(track, next: next, from: app)
        fetchArtwork(for: track)
        if let next { fetchArtwork(for: next) }
    }

    func receiverSetNext(_ track: ReceiverTrack?) async {
        player.receiverSetNext(track)
        if let track { fetchArtwork(for: track) }
    }

    func receiverPause() async { if player.receiverSession != nil { player.pause() } }
    func receiverResume() async { player.receiverResume() }

    func receiverStop() async {
        activity.set(false)
        player.receiverStop()
    }

    func receiverSeek(to seconds: TimeInterval) async { if player.receiverSession != nil { player.seek(to: seconds) } }

    func receiverPosition() async -> ReceiverPosition {
        guard player.receiverSession != nil else { return ReceiverPosition() }
        return ReceiverPosition(position: player.position, duration: player.duration > 0 ? player.duration : nil)
    }

    func receiverVolume() async -> (level: Double, muted: Bool) { volume.read() }
    func receiverSetVolume(_ level: Double) async { if settings.upnpReceiverVolume { volume.set(min(max(level, 0), 1)) } }
    func receiverSetMuted(_ muted: Bool) async { if settings.upnpReceiverVolume { volume.setMuted(muted) } }
}

/// The Settings › Playback switch for the receiver, like Network Players': its words, and what turning it on or off does.
@MainActor
enum ReceiverSwitch {
    static var title: String {
        String(localized: "Play to Vespertine (UPnP, beta)", comment: "Settings › Playback: the switch that lets other apps on the network (UPnP control apps, such as a streaming service’s own app) send music to Vespertine to play. “UPnP” and “beta” stay as they are in your language.")
    }

    static var explanation: String {
        String(localized: "Lets apps on your network send music to Vespertine, which plays it on the output you chose. Off, Vespertine opens no port for them, doesn’t announce itself, and plays as before.", comment: "Settings › Playback: the caption under the Play to Vespertine (UPnP, beta) switch.")
    }

    /// The name control apps show when the listener has given none: the app's and the computer's.
    static var defaultName: String { "Vespertine (\(RemoteServer.computerName))" }

    static func name(_ settings: AppSettings) -> String {
        let chosen = settings.upnpReceiverName.trimmingCharacters(in: .whitespacesAndNewlines)
        return chosen.isEmpty ? defaultName : chosen
    }

    /// Turns the feature on or off and answers the model that should exist now: `current` or a new, started one while on; nil off.
    static func apply(_ on: Bool, to settings: AppSettings, current: ReceiverModel?, make: () -> ReceiverModel) -> ReceiverModel? {
        settings.upnpReceiverFeature = on
        guard on else {
            current?.stop()
            return nil
        }
        if let current { return current }
        // What tells this receiver from another, made once: a random UUID, nothing of the Mac's.
        if settings.upnpReceiverID.isEmpty { settings.upnpReceiverID = "uuid:\(UUID().uuidString.lowercased())" }
        let model = make()
        model.start()
        return model
    }
}

/// How a control app's session shows while one plays. The listener doesn't choose: these are the candidates the maintainer
/// picks from (`defaults write … receiverPresentation banner`), and the default is the one in use.
enum ReceiverPresentation: String {
    /// A chip beside the song ("FROM MCONNECT").
    case chip
    /// A line above the queue.
    case banner
    /// Only the first step of the signal path.
    case path

    static var current: ReceiverPresentation {
        ReceiverPresentation(rawValue: UserDefaults.standard.string(forKey: "receiverPresentation") ?? "") ?? .chip
    }
}

/// What the queue shows while a control app plays (`defaults write … receiverQueue remote`).
enum ReceiverQueueStyle: String {
    /// The control app's song and the one after it, not editable; the listener's queue is out of sight until it returns.
    case remote
    /// The same, with the listener's own queue under it, dimmed, under a line that says who is playing.
    case dimmed

    static var current: ReceiverQueueStyle {
        ReceiverQueueStyle(rawValue: UserDefaults.standard.string(forKey: "receiverQueue") ?? "") ?? .dimmed
    }
}

enum ReceiverText {
    /// "Playing from mconnect", or without a name when the control app gives none worth showing.
    static func playingFrom(_ app: ReceiverControlApp) -> String {
        if let name = app.name {
            return String(localized: "Playing from \(name)", comment: "Above the queue while another app on the network (a UPnP control app, named by %@) is sending the music Vespertine plays.")
        }
        return String(localized: "Playing from another app", comment: "Above the queue while another app on the network is sending the music Vespertine plays, and the app gave no name.")
    }

    /// The chip beside the song: "FROM MCONNECT".
    static func chip(_ app: ReceiverControlApp) -> String {
        if let name = app.name {
            return String(localized: "FROM \(name.localizedUppercase)", comment: "A short uppercase chip beside the song while another app on the network (named by %@) is sending the music.")
        }
        return String(localized: "FROM ANOTHER APP", comment: "A short uppercase chip beside the song while another app on the network is sending the music, and the app gave no name.")
    }

    /// The first step of the signal path.
    static func pathTitle(_ app: ReceiverControlApp) -> String {
        if let name = app.name {
            return String(localized: "From \(name), over the network", comment: "Signal path, first step: the song was sent by another app on the network (a UPnP control app, named by %@).")
        }
        return String(localized: "From a control app, over the network", comment: "Signal path, first step: the song was sent by another app on the network that gave no name.")
    }

    static var pathDetail: String {
        String(localized: "Fetched from the address the app sent, played like a file", comment: "Signal path: under “From …, over the network”.")
    }

    static var pathValue: String {
        String(localized: "not kept", comment: "Signal path, short: a song another app sent is played and not saved anywhere.")
    }

    static var yourQueue: String {
        String(localized: "Your Queue, Paused", comment: "Header over the listener’s own queue while another app’s music plays; it comes back when that app stops.")
    }

    static var backToQueue: String {
        String(localized: "Back to My Queue", comment: "Button: stops the music another app is sending and returns to the listener’s own queue.")
    }
}
