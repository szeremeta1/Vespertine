//
// Vespertine — keeps the Nomad's media widget in step with what's playing.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// What the widget should show, as the player knows it. `position` was true at `anchor`; while playing the widget's
/// clock is extrapolated from there, so the player only reports changes, not every tick.
public struct NomadNowPlaying: Sendable, Equatable {
    public var title: String
    public var artist: String
    /// Short format text for the artist line ("24/96", "DSD64", "MP3 320k"), or nil.
    public var format: String?
    public var duration: TimeInterval
    public var position: TimeInterval
    public var anchor: Date
    public var isPlaying: Bool
    /// Identifies the cover, so it is sent once per cover, not once per update.
    public var artworkID: String?

    public init(title: String, artist: String, format: String? = nil, duration: TimeInterval, position: TimeInterval,
                anchor: Date = .now, isPlaying: Bool, artworkID: String? = nil) {
        self.title = title; self.artist = artist; self.format = format; self.duration = duration
        self.position = position; self.anchor = anchor; self.isPlaying = isPlaying; self.artworkID = artworkID
    }

    func elapsed(at now: Date) -> Int {
        let t = isPlaying ? position + now.timeIntervalSince(anchor) : position
        return Int(max(0, min(t, duration > 0 ? duration : t)).rounded(.down))
    }
}

/// How format information shares the widget's artist line.
public enum NomadFormatStyle: String, Sendable, CaseIterable {
    case off, suffix
}

public enum NomadText {
    /// Artist plus the format, as one line. The keyboard's line is short, so the artist gives way before the format does.
    public static func artistLine(artist: String, format: String?, style: NomadFormatStyle, budget: Int = 28, separator: String = " - ") -> String {
        guard style == .suffix, let format, !format.isEmpty else { return artist }
        let tail = separator + format
        guard artist.count + tail.count > budget else { return artist + tail }
        let room = budget - tail.count
        guard room >= 6 else { return artist }   // no point keeping two letters of the name
        return String(artist.prefix(room - 1)).trimmingCharacters(in: .whitespaces) + "…" + tail
    }
}

/// What the feed needs from the keyboard link (a seam for tests).
public protocol NomadWidgetPort: Sendable {
    func sendInfo(title: String?, artist: String?, elapsed: Int?, duration: Int?, isPlaying: Bool?) async throws
    func sendArtwork(_ image: Data) async throws
}

extension NomadLink: NomadWidgetPort {}

/// Sends the current track to the keyboard whenever it asks (its media screen is open) and whenever the track or the
/// play state changes, and ticks the clock once a second while it's showing.
///
/// The keyboard takes one call at a time and a call can take a while, so updates are coalesced: one worker sends what is
/// true *now*, and anything that changes meanwhile is picked up on its next pass instead of queueing behind stale
/// calls. A text update always carries the whole track (title, artist, length, time, state): half a track, sent after
/// an earlier call that was still in flight, is how a title ends up next to another song's artist. Covers go separately,
/// at low priority and cancellable, a moment after the last track change.
public actor NomadMediaFeed {
    private let link: any NomadWidgetPort
    private let encodeArtwork: @Sendable (String) async -> Data?
    private var style: NomadFormatStyle
    private var nowPlaying: NomadNowPlaying?
    private var screenOpen = false
    private var connected = false
    /// Another program (Work Louder's Input) is writing to the same widget.
    private var contested = false

    /// What the keyboard shows, as far as an acknowledged call told us.
    private struct Shown {
        var title: String, artist: String, duration: Int
        var playing: Bool, elapsed: Int, at: Date
    }
    private var shown: Shown?
    /// When to say the text again: Input rewrites the artist (without the format) a moment after each new track.
    private var reasserts: [Date] = []

    private var working = false
    private var again = false
    private var wake: Task<Void, Never>?

    private var coverShown: String?
    private var coverWanted: String?
    private var coverTask: Task<Void, Never>?
    private var coverAttempts = 0
    /// How long the last track change settles before its cover is sent (skipping fast shouldn't upload every cover).
    private let coverDelay: Duration

    /// `artwork` turns an artwork ID into the keyboard's image bytes (the app owns the covers).
    public init(link: any NomadWidgetPort, style: NomadFormatStyle, coverDelay: Duration = .milliseconds(350),
                artwork: @escaping @Sendable (String) async -> Data?) {
        self.link = link
        self.style = style
        self.coverDelay = coverDelay
        self.encodeArtwork = artwork
    }

    // MARK: Inputs

    public func setStyle(_ style: NomadFormatStyle) async {
        guard style != self.style else { return }
        self.style = style
        shown = nil
        await run()
    }

    public func setContested(_ on: Bool) { contested = on }

    public func update(_ now: NomadNowPlaying?) async {
        nowPlaying = now
        await run()
    }

    public func handle(_ event: NomadLink.Event) async {
        switch event {
        case .connected:
            connected = true
            shown = nil
            coverShown = nil; coverWanted = nil   // the keyboard may have been showing Input's cover
            await run()
        case .disconnected:
            connected = false
            screenOpen = false
            wake?.cancel(); wake = nil
            coverTask?.cancel(); coverTask = nil
        case .mediaScreen(let wants):
            screenOpen = wants
            if wants { shown = nil }   // the screen may have lost it
            await run()
        case .notification, .problem:
            break
        }
    }

    // MARK: Worker

    /// Runs the worker unless one is running, in which case it will see the change on its next pass.
    private func run() async {
        again = true
        guard !working else { return }
        working = true
        while again {
            again = false
            await pass()
        }
        working = false
    }

    private func pass() async {
        guard connected else { return }
        guard let current = nowPlaying else {
            // Only if the widget was showing our track: when something else (Spotify, Music) owns it, stay out of its way.
            if shown?.playing == true {
                do {
                    try await link.sendInfo(title: nil, artist: nil, elapsed: nil, duration: nil, isPlaying: false)
                    shown?.playing = false
                } catch { log.error("Couldn't tell the widget playback stopped: \(String(describing: error), privacy: .public)") }
            }
            wake?.cancel(); wake = nil
            wantCover(nil)
            return
        }
        let now = Date()
        let artist = NomadText.artistLine(artist: current.artist, format: current.format, style: style)
        let duration = Int(current.duration.rounded())
        let elapsed = current.elapsed(at: now)

        let textChanged = shown.map { $0.title != current.title || $0.artist != artist || $0.duration != duration } ?? true
        let dueReassert = contested && screenOpen && reasserts.contains { $0 <= now }
        do {
            if textChanged || dueReassert {
                try await link.sendInfo(title: current.title, artist: artist, elapsed: elapsed, duration: duration, isPlaying: current.isPlaying)
                shown = Shown(title: current.title, artist: artist, duration: duration, playing: current.isPlaying, elapsed: elapsed, at: now)
                if textChanged, contested { reasserts = [now.addingTimeInterval(1.6), now.addingTimeInterval(3.6)] }
                else { reasserts.removeAll { $0 <= now } }
            } else if let s = shown {
                let expected = s.playing ? s.elapsed + Int(now.timeIntervalSince(s.at)) : s.elapsed
                let drifted = abs(expected - elapsed) >= 2
                if current.isPlaying != s.playing || drifted || (screenOpen && current.isPlaying) {
                    try await link.sendInfo(title: nil, artist: nil, elapsed: elapsed, duration: nil, isPlaying: current.isPlaying)
                    shown = Shown(title: s.title, artist: s.artist, duration: s.duration, playing: current.isPlaying, elapsed: elapsed, at: now)
                }
            }
        } catch {
            log.error("Couldn't update the widget: \(String(describing: error), privacy: .public)")
            shown = nil          // we no longer know what it shows: the next pass sends the whole track
            schedule(after: 1.5)
            wantCover(current.artworkID)
            return
        }
        wantCover(current.artworkID)

        // The next pass: a second on while the media screen shows a playing song, or when a reassert is due.
        var next: TimeInterval?
        if screenOpen, current.isPlaying { next = 1 }
        if contested, screenOpen, let due = reasserts.min() { next = min(next ?? .infinity, max(0.1, due.timeIntervalSince(Date()))) }
        if let next { schedule(after: next) } else { wake?.cancel(); wake = nil }
    }

    private func schedule(after seconds: TimeInterval) {
        wake?.cancel()
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { await self?.run() }
        }
    }

    // MARK: Covers

    private func wantCover(_ id: String?) {
        guard id != coverWanted else { return }
        coverWanted = id
        coverAttempts = 0
        coverTask?.cancel(); coverTask = nil
        guard let id, id != coverShown else { return }
        startCover(id, after: coverDelay)
    }

    private func startCover(_ id: String, after delay: Duration) {
        let encode = encodeArtwork, link = self.link
        coverTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let data = await encode(id), !Task.isCancelled else { return }
            do {
                try await link.sendArtwork(data)
                await self?.coverSent(id)
            } catch is CancellationError {
                return
            } catch {
                log.error("Couldn't send the cover: \(String(describing: error), privacy: .public)")
                await self?.coverFailed(id)
            }
        }
    }

    private func coverSent(_ id: String) { if coverWanted == id { coverShown = id } }

    /// A cover that didn't go through is tried again, a few times, unless a newer track has asked for another.
    private func coverFailed(_ id: String) {
        guard coverWanted == id, connected, coverAttempts < 3 else { return }
        coverAttempts += 1
        startCover(id, after: .seconds(2 * coverAttempts))
    }
}
