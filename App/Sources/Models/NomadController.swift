//
// Vespertine — a Work Louder Nomad [E] keyboard's media widget: what's playing, its cover, where it is in the song.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import Foundation
import Observation
import VespertineAudio
import VespertineLibrary
import VespertineNomad

/// Owns the link to the keyboard and the feed that follows playback. Work Louder's Input app also writes to the
/// widget (title and artist, never the cover or the time, for a player it doesn't know), so while it runs the feed
/// repeats its text now and then, and the settings say so.
@Observable
@MainActor
final class NomadController {
    /// The connected keyboard's name, nil while there is none.
    private(set) var keyboard: String?
    private(set) var problem: String?
    /// The keyboard has its media screen open (it is asking for track data).
    private(set) var mediaScreenOpen = false
    private(set) var inputIsRunning = false

    static let inputBundleID = "it.focusense.input-app"

    private let settings: AppSettings
    private var link: NomadLink?
    private var feed: NomadMediaFeed?
    private var eventTask: Task<Void, Never>?
    private var latest: NomadNowPlaying?
    private var observers: [NSObjectProtocol] = []

    init(settings: AppSettings) {
        self.settings = settings
        refreshInput()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshInput() }
            })
        }
    }

    /// Starts or stops the link as the setting says.
    func apply() {
        if settings.nomadWidget { start() } else { stop() }
    }

    func formatChanged() {
        let style = settings.nomadFormat
        Task { await feed?.setStyle(style) }
    }

    /// What's playing now (nil: nothing, or stopped).
    func update(_ nowPlaying: NomadNowPlaying?) {
        latest = nowPlaying
        guard let feed else { return }
        Task { await feed.update(nowPlaying) }
    }

    // MARK: Link

    private func start() {
        guard link == nil else { return }
        let (events, continuation) = AsyncStream.makeStream(of: NomadLink.Event.self)
        let link = NomadLink { continuation.yield($0) }
        let feed = NomadMediaFeed(link: link, style: settings.nomadFormat) { key in await Self.cover(key) }
        self.link = link
        self.feed = feed
        let contested = inputIsRunning
        eventTask = Task { [weak self] in
            await feed.setContested(contested)
            if let latest = await self?.latest { await feed.update(latest) }
            // One consumer, so the feed sees the keyboard's events in the order they happened.
            for await event in events {
                await feed.handle(event)
                await self?.show(event)
            }
        }
        link.start()
    }

    private func stop() {
        eventTask?.cancel(); eventTask = nil
        link?.stop()
        link = nil; feed = nil
        keyboard = nil; problem = nil; mediaScreenOpen = false
    }

    /// Stops the link (when quitting), leaving the widget as it is.
    func shutDown() { stop() }

    private func show(_ event: NomadLink.Event) {
        switch event {
        case .connected(let name): keyboard = name; problem = nil
        case .disconnected: keyboard = nil; mediaScreenOpen = false
        case .mediaScreen(let wants): mediaScreenOpen = wants
        case .problem(let reason): problem = reason
        case .notification: break
        }
    }

    private func refreshInput() {
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.inputBundleID).isEmpty
        guard running != inputIsRunning else { return }
        inputIsRunning = running
        Task { await feed?.setContested(running) }
    }

    // MARK: What the widget shows

    /// The widget's view of a track: title, artist, a short format tag, and where in the song it is.
    static func snapshot(_ track: Track, state: PlaybackState, position: TimeInterval, duration: TimeInterval) -> NomadNowPlaying {
        NomadNowPlaying(title: track.title, artist: track.displayArtist, format: formatTag(track),
                        duration: duration > 0 ? duration : track.duration, position: position, isPlaying: state == .playing,
                        artworkID: track.artworkKey)
    }

    /// "FLAC 24/96", "DSD64", "MP3 320k", "FLAC 24/96 5.1": the library's summary, with its dots taken out (the keyboard's
    /// font may not have them, and the line is short).
    static func formatTag(_ track: Track) -> String {
        track.formatSummary.replacingOccurrences(of: " · ", with: " ")
    }

    /// A cover in the keyboard's image format, or nil if there isn't one.
    private static func cover(_ key: String) async -> Data? {
        guard let image = await ArtworkCache.shared.image(key, size: 160),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return await Task.detached(priority: .utility) { NomadArtwork.encode(cg) }.value
    }
}
