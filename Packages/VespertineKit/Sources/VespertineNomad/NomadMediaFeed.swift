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
public actor NomadMediaFeed {
    private let link: any NomadWidgetPort
    private let encodeArtwork: @Sendable (String) async -> Data?
    private var style: NomadFormatStyle
    private var nowPlaying: NomadNowPlaying?
    private var screenOpen = false
    /// Another program (Work Louder's Input) is writing to the same widget: say the text again every few seconds.
    private var contested = false
    private var ticks = 0
    private var connected = false
    private var ticker: Task<Void, Never>?
    /// What the keyboard already has.
    private var sentTitle: String?, sentArtist: String?, sentDuration: Int?, sentPlaying: Bool?, sentElapsed: Int?
    private var sentArtworkID: String??
    private var artworkTask: Task<Void, Never>?

    /// `artwork` turns an artwork ID into the keyboard's image bytes (the app owns the covers).
    public init(link: any NomadWidgetPort, style: NomadFormatStyle, artwork: @escaping @Sendable (String) async -> Data?) {
        self.link = link
        self.style = style
        self.encodeArtwork = artwork
    }

    // MARK: Inputs

    public func setStyle(_ style: NomadFormatStyle) async {
        guard style != self.style else { return }
        self.style = style
        sentArtist = nil
        await sync()
    }

    public func setContested(_ on: Bool) { contested = on }

    public func update(_ now: NomadNowPlaying?) async {
        nowPlaying = now
        await sync()
    }

    public func handle(_ event: NomadLink.Event) async {
        switch event {
        case .connected:
            connected = true
            forgetSent()
            sentArtworkID = nil   // the keyboard may have been showing Input's cover
            await sync()
        case .disconnected:
            connected = false
            screenOpen = false
            ticker?.cancel(); ticker = nil
        case .mediaScreen(let wants):
            screenOpen = wants
            if wants { forgetSent() }
            await sync()
        case .notification, .problem:
            break
        }
    }

    // MARK: Output

    private func forgetSent() {
        sentTitle = nil; sentArtist = nil; sentDuration = nil; sentPlaying = nil; sentElapsed = nil
    }

    private func sync() async {
        guard connected else { return }
        guard let current = nowPlaying else {
            // Only if the widget was showing our track: when something else (Spotify, Music) owns it, stay out of its way.
            if sentPlaying == true {
                if (try? await link.sendInfo(title: nil, artist: nil, elapsed: nil, duration: nil, isPlaying: false)) != nil { sentPlaying = false }
            }
            ticker?.cancel(); ticker = nil
            return
        }
        let now = Date()
        let artist = NomadText.artistLine(artist: current.artist, format: current.format, style: style)
        let duration = Int(current.duration.rounded())
        let elapsed = current.elapsed(at: now)
        // Fields the keyboard already has are left out of the call, as Input does.
        let titleChanged = current.title != sentTitle, artistChanged = artist != sentArtist
        let durationChanged = duration != sentDuration, playingChanged = current.isPlaying != sentPlaying
        // The clock is sent when it drifts from what the keyboard would count on its own, or when the state changes.
        let drift = sentElapsed.map { abs(($0 + (sentPlaying == true ? Int(now.timeIntervalSince(lastSend)) : 0)) - elapsed) >= 2 } ?? true
        if titleChanged || artistChanged || durationChanged || playingChanged || drift || screenOpen {
            do {
                try await link.sendInfo(title: titleChanged ? current.title : nil, artist: artistChanged ? artist : nil,
                                        elapsed: elapsed, duration: durationChanged ? duration : nil, isPlaying: current.isPlaying)
                sentTitle = current.title; sentArtist = artist; sentDuration = duration
                sentPlaying = current.isPlaying; sentElapsed = elapsed; lastSend = now
            } catch {
                log.error("Couldn't update the widget: \(String(describing: error), privacy: .public)")
                return   // the next change or tick tries again
            }
        }
        if let id = current.artworkID, sentArtworkID != .some(id) { sendArtwork(id) }
        ticker?.cancel(); ticker = nil
        if screenOpen, current.isPlaying {
            ticker = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled { await self?.tick() }
            }
        }
    }

    private var lastSend = Date.distantPast

    private func tick() async {
        ticks += 1
        if contested, ticks % 5 == 0 { sentTitle = nil; sentArtist = nil; sentDuration = nil }
        await sync()
    }

    /// Covers go in a task of their own: about 150 ms of HID traffic that title changes shouldn't wait behind.
    private func sendArtwork(_ id: String) {
        artworkTask?.cancel()
        let encode = encodeArtwork, link = self.link
        artworkTask = Task { [weak self] in
            guard let data = await encode(id), !Task.isCancelled else { return }
            do {
                try await link.sendArtwork(data)
                await self?.artworkSent(id)
            } catch {
                log.error("Couldn't send the cover: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func artworkSent(_ id: String) { sentArtworkID = .some(id) }
}
