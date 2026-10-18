//
// Vespertine — what's playing, as a Discord status: song, artist, album, format, cover and progress.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Observation
import VespertineAudio
import VespertineLibrary

/// A Discord activity, as the local RPC's SET_ACTIVITY takes it.
nonisolated struct DiscordActivity: Codable, Equatable, Sendable {
    struct Timestamps: Codable, Equatable, Sendable {
        /// Unix time in milliseconds. Start and end together draw the progress bar.
        var start: Int64
        var end: Int64?
    }

    struct Assets: Codable, Equatable, Sendable {
        var largeImage: String?
        var largeText: String?
        var smallImage: String?
        var smallText: String?
        enum CodingKeys: String, CodingKey {
            case largeImage = "large_image", largeText = "large_text", smallImage = "small_image", smallText = "small_text"
        }
    }

    struct Button: Codable, Equatable, Sendable {
        var label: String
        var url: String
    }

    /// 2: "Listening to".
    var type = 2
    /// Which line the member list shows after "Listening to": 2 is `details` (the song).
    var statusDisplayType: Int? = 2
    var details: String
    var state: String?
    var timestamps: Timestamps?
    var assets: Assets?
    var buttons: [Button]?

    enum CodingKeys: String, CodingKey {
        case type, details, state, timestamps, assets, buttons
        case statusDisplayType = "status_display_type"
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(self)
    }
}

/// The song as the status describes it.
nonisolated struct DiscordNowPlaying: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String?
    /// "24/192 FLAC", "DSD128", "320 kbps MP3"…
    var format: String
    var bitPerfect: Bool
    /// When the song would have started, had it played straight through to where it is now.
    var startedAt: Date
    var duration: TimeInterval
    var artwork: DiscordArtworkQuery?

    /// The same status, give or take the clock (positions are polled, so the start wanders by a few hundredths).
    func isSame(as other: DiscordNowPlaying) -> Bool {
        var a = self, b = other
        a.startedAt = .distantPast; b.startedAt = .distantPast
        return a == b && abs(startedAt.timeIntervalSince(other.startedAt)) < 2
    }
}

nonisolated enum DiscordStatus {
    /// Shown on the status when the cover can't be found: Vespertine's icon, uploaded to the
    /// Discord application's Rich Presence art assets under this key.
    static let appIcon = "logo"
    /// Vespertine's icon on the website, shown small over the album cover.
    static let appIconURL = "https://vespertineapp.com/icon-512.png"
    static let siteURL = "https://vespertineapp.com"

    /// Discord refuses text under 2 or over 128 UTF-16 units.
    static func fit(_ text: String, max: Int = 128) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.utf16.count > max {
            var cut = ""
            for character in text {
                if cut.utf16.count + character.utf16.count > max - 1 { break }
                cut.append(character)
            }
            text = cut.trimmingCharacters(in: .whitespaces) + "…"
        }
        // A one-letter title ("X") is a real title: pad it invisibly rather than drop it.
        while text.utf16.count < 2 { text += "\u{200B}" }
        return text
    }

    /// "24/192 FLAC", "DSD128", "16/44.1 ALAC · 5.1", "320 kbps MP3", "Dolby TrueHD · 7.1". `path` is what the
    /// engine reports once the song is open; until then (or without it) the library's description of the file.
    /// When the DAC gets something else (resampled, DSD as PCM), it says so: "24/192 FLAC → 24/96".
    static func formatLine(track: Track, path: SignalPath?) -> String {
        let converted = path.map { $0.plan.mode == .pcm && ($0.isResampling || $0.plan.dsdConvertedToPCM) } ?? false
        return formatLine(codec: path?.source.codec ?? track.codec,
                          encoding: path?.source.encoding ?? (track.isDSD ? .dsd : track.isLossless ? .pcm : .lossy),
                          sampleRate: path?.source.sampleRate ?? track.sampleRate,
                          bitDepth: path.map { $0.source.bitDepth } ?? track.bitDepth,
                          channels: path?.source.channels ?? track.channels,
                          kbps: track.bitrate,
                          deviceFormat: converted ? path?.deviceFormatShort : nil)
    }

    static func formatLine(codec: String, encoding: SourceFormat.Encoding, sampleRate: Double, bitDepth: Int?, channels: Int,
                           kbps: Double?, deviceFormat: String?) -> String {
        var line: String
        if BitstreamFormat(codec: codec) != nil || codec.hasPrefix("Dolby") || codec.hasPrefix("DTS") || codec == "MLP Lossless" {
            line = codec
        } else {
            switch encoding {
            case .dsd:
                line = "DSD\(Int((sampleRate / 44_100).rounded()))"
            case .lossy:
                if let kbps, kbps > 0 { line = "\(Int(kbps.rounded())) kbps \(codec)" } else { line = codec }
            case .pcm:
                let khz = SampleRate.format(sampleRate)
                line = bitDepth.map { "\($0)/\(khz) \(codec)" } ?? "\(khz) kHz \(codec)"
            }
        }
        if channels > 2 { line += " · " + ChannelLayouts.name(channels: channels) }
        if let deviceFormat { line += " → " + deviceFormat }
        return line
    }

    static func activity(for song: DiscordNowPlaying, artworkURL: String?) -> DiscordActivity {
        let start = Int64((song.startedAt.timeIntervalSince1970 * 1000).rounded())
        let end = song.duration > 0 ? start + Int64((song.duration * 1000).rounded()) : nil
        // Hovering the cover shows the album; the format follows it on the album line, where Discord shows it under
        // the artist.
        let albumLine = [song.album, song.format].compactMap { $0 }.joined(separator: " · ")
        let quality = song.bitPerfect
            ? String(localized: "Bit-perfect in Vespertine", comment: "Discord status, shown on Vespertine's small icon over the album cover.")
            : String(localized: "Playing in Vespertine", comment: "Discord status, shown on Vespertine's small icon over the album cover.")
        let assets = DiscordActivity.Assets(
            largeImage: artworkURL ?? appIcon,
            largeText: fit(albumLine),
            smallImage: artworkURL == nil ? nil : appIconURL,
            smallText: artworkURL == nil ? nil : fit(quality))
        let label = String(localized: "Get Vespertine", comment: "Button on a Discord status (at most 32 characters) linking to Vespertine's website.")
        return DiscordActivity(
            details: fit(song.title),
            state: fit(song.artist),
            timestamps: .init(start: start, end: end),
            assets: assets,
            buttons: [.init(label: fit(label, max: 32), url: siteURL)])
    }
}

/// Keeps the Discord status in step with what's playing, while the setting is on.
@Observable
@MainActor
final class DiscordPresence {
    /// Vespertine's application on Discord's developer portal: Discord shows its name ("Listening to Vespertine").
    /// `-DiscordApplicationID <id>` (or the same default) overrides it for testing.
    nonisolated static let builtInApplicationID = "1561080379203653692"
    nonisolated static var applicationID: String {
        UserDefaults.standard.string(forKey: "DiscordApplicationID") ?? builtInApplicationID
    }

    private(set) var connection: DiscordConnectionState = .idle

    @ObservationIgnored private var client: DiscordRPCClient?
    @ObservationIgnored private var showing: DiscordNowPlaying?
    @ObservationIgnored private var artworkURLs: [DiscordArtworkQuery: String] = [:]
    @ObservationIgnored private var lookups: Set<DiscordArtworkQuery> = []
    @ObservationIgnored private let artwork: DiscordArtworkFinder

    init(artwork: DiscordArtworkFinder = .shared) {
        self.artwork = artwork
    }

    /// Shows `song` (nil: nothing is playing, so no status) while `enabled`. Cheap to call often: Discord only hears
    /// about changes.
    func update(enabled: Bool, song: DiscordNowPlaying?, lookUpArtwork: Bool) {
        guard enabled else {
            if client != nil {
                client?.shutdown()
                client = nil
                showing = nil
            }
            if connection != .idle { connection = .idle }
            return
        }
        var song = song
        if !lookUpArtwork { song?.artwork = nil }
        guard let song else {
            // Paused or stopped: no status (and no connection to Discord until something plays).
            if showing != nil { showing = nil; client?.setActivity(nil) }
            return
        }
        if let showing, showing.isSame(as: song) { return }
        showing = song
        if let query = song.artwork, case let key = query.cacheKey, artworkURLs[key] == nil, !lookups.contains(key) {
            lookups.insert(key)
            Task { [weak self, artwork] in
                let url = await artwork.url(for: query)
                guard let self else { return }
                self.lookups.remove(key)
                guard let url else { return }
                self.artworkURLs[key] = url
                // The cover arrived while a song of that album still plays: show it.
                if let showing = self.showing, showing.artwork?.cacheKey == key { self.send(showing) }
            }
        }
        send(song)
    }

    /// Clears the status before Vespertine quits (Discord would also clear it once the connection closes).
    func shutdown() {
        client?.shutdown(wait: true)
        client = nil
        showing = nil
    }

    private func send(_ song: DiscordNowPlaying) {
        let url = song.artwork.flatMap { artworkURLs[$0.cacheKey] }
        (client ?? makeClient()).setActivity(DiscordStatus.activity(for: song, artworkURL: url).encoded())
    }

    private func makeClient() -> DiscordRPCClient {
        let client = DiscordRPCClient(applicationID: Self.applicationID) { [weak self] state in
            Task { @MainActor in self?.connection = state }
        }
        self.client = client
        return client
    }
}

/// What to look the cover up by.
nonisolated struct DiscordArtworkQuery: Hashable, Sendable {
    var artist: String
    var album: String?
    var title: String
    var musicBrainzReleaseID: String?

    /// Songs of one album share a cover, so the album (not the song) is what's looked up and remembered: the next
    /// song shows the cover at once instead of Vespertine's logo while it's looked up again.
    var cacheKey: DiscordArtworkQuery {
        let hasAlbum = musicBrainzReleaseID != nil || (album.map { !$0.isEmpty && $0 != "Unknown Album" } ?? false)
        return hasAlbum ? DiscordArtworkQuery(artist: artist, album: album, title: "", musicBrainzReleaseID: musicBrainzReleaseID) : self
    }
}

/// Finds a public address for an album's cover, since Discord can only show images it can download. The cover in
/// the library is never uploaded: the album is looked up by name on the Cover Art Archive (when the files carry a
/// MusicBrainz release ID) or in Apple's music catalog, and nothing is shown when neither has it for sure.
actor DiscordArtworkFinder {
    static let shared = DiscordArtworkFinder()

    private let session: URLSession
    private var found: [DiscordArtworkQuery: String?] = [:]

    init(session: URLSession? = nil) {
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            self.session = URLSession(configuration: config)
        }
    }

    func url(for query: DiscordArtworkQuery) async -> String? {
        let key = query.cacheKey
        if let known = found[key] { return known }
        var url: String?
        if let id = query.musicBrainzReleaseID, UUID(uuidString: id) != nil { url = await coverArtArchive(releaseID: id) }
        if url == nil { url = await appleCatalog(query) }
        found[key] = url
        return url
    }

    /// The Cover Art Archive redirects to the Internet Archive; Discord gets the final address of the image.
    private func coverArtArchive(releaseID: String) async -> String? {
        guard let url = URL(string: "https://coverartarchive.org/release/\(releaseID.lowercased())/front-500") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse,
              http.statusCode == 200, let final = http.url?.absoluteString, final.hasPrefix("https://"),
              final.utf16.count <= 256 else { return nil }
        return final
    }

    private func appleCatalog(_ query: DiscordArtworkQuery) async -> String? {
        let album = query.album.flatMap { $0 == "Unknown Album" ? nil : $0 }
        let artist = query.artist == "Unknown Artist" ? "" : query.artist
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(album ?? query.title)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: album == nil ? "song" : "album"),
            URLQueryItem(name: "limit", value: "15"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US"),
        ]
        guard let url = components.url, let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Self.bestAppleMatch(data, artist: artist, album: album, title: query.title)
    }

    /// The cover of the result that is this album (or, without an album, this song) by this artist, at 600 px. Only a
    /// clear match counts: a wrong cover is worse than Vespertine's icon.
    nonisolated static func bestAppleMatch(_ data: Data, artist: String, album: String?, title: String) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        let wantedArtist = normalized(artist)
        let wantedName = normalized(album ?? title)
        guard !wantedName.isEmpty else { return nil }
        var best: (score: Int, url: String)?
        for result in results {
            guard let art = result["artworkUrl100"] as? String, art.hasPrefix("https://") else { continue }
            let rawName = result[album == nil ? "trackName" : "collectionName"] as? String ?? ""
            let name = normalized(rawName)
            let resultArtist = normalized(result["artistName"] as? String ?? "")
            // Close enough: equal, or one holding the other ("Abbey Road" in "Abbey Road Super Deluxe").
            func near(_ a: String, _ b: String) -> Bool { a.count >= 4 && b.count >= 4 && (a.contains(b) || b.contains(a)) }
            var score: Int
            if name == wantedName { score = 2 } else if near(name, wantedName) { score = 1 } else { continue }
            if resultArtist == wantedArtist, !wantedArtist.isEmpty { score += 2 }
            else if near(resultArtist, wantedArtist) { score += 1 }
            // A compilation is listed under Various Artists; no artist to check means the name has to do.
            else if !wantedArtist.isEmpty, resultArtist != "variousartists" { continue }
            // The very same name beats one that matches once editions are set aside ("Kind of Blue (Legacy Edition)").
            if rawName.compare(album ?? title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { score += 1 }
            // Without an artist to confirm it, only an exact title will do.
            if wantedArtist.isEmpty, score < 2 { continue }
            let large = art.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            if best == nil || score > best!.score { best = (score, large) }
        }
        return best?.url
    }

    /// Lowercased letters and digits only, without accents or what's in brackets ("Abbey Road (Remastered)" and
    /// "abbey road" are the same album); "&" reads as "and".
    nonisolated static func normalized(_ text: String) -> String {
        var s = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        s = s.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+-\s+(single|ep)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "&", with: "and")
        return String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
