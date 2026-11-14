//
// Vespertine: a share's index arranged the way the app's screens ask for a library: albums, artists, genres, songs,
// search. The same shapes a Mac answers with, so the screens are the same screens.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation
import VespertineRemoteProtocol

public struct ShareCatalog: Sendable {
    public struct Album: Sendable {
        public var summary: AlbumSummary
        public var tracks: [Int64]
        public var genre: String?
        /// When its newest file was last changed: the nearest thing a share has to "added".
        public var newest: Date
    }

    public private(set) var albums: [Album] = []
    public private(set) var tracks: [Int64: TrackSummary] = [:]
    public private(set) var songs: [Int64: ShareSong] = [:]
    /// Where each album's cover is: a picture file in its folder, or the song whose file carries one.
    public private(set) var covers: [String: Cover] = [:]

    public enum Cover: Sendable, Equatable {
        case file(path: String)
        case embedded(song: Int64)
    }

    public init() {}

    public init(_ library: ShareLibrary, favorites: Set<Int64> = [], words: ShareWords = .english) {
        // A folder whose songs name one album and several artists, with no album artist, is a compilation.
        var artistsByAlbum: [String: Set<String>] = [:]
        for song in library.songs where song.tags.albumArtist == nil {
            artistsByAlbum[song.folder + "\u{1F}" + (song.tags.album ?? ""), default: []].insert(song.tags.artist ?? "")
        }

        struct Named {
            var song: ShareSong
            var title: String, artist: String, albumArtist: String, album: String
            var track: Int?
        }
        var grouped: [String: [Named]] = [:]
        var order: [String] = []
        for song in library.songs {
            let parts = song.path.split(separator: "/").map(String.init)
            let fromName = Self.titleAndNumber(fileName: song.fileName)
            let album = song.tags.album ?? (parts.count >= 2 ? parts[parts.count - 2] : words.unknownAlbum)
            let artist = song.tags.artist ?? song.tags.albumArtist ?? (parts.count >= 3 ? parts[parts.count - 3] : words.unknownArtist)
            var albumArtist = song.tags.albumArtist ?? artist
            if song.tags.albumArtist == nil, (artistsByAlbum[song.folder + "\u{1F}" + (song.tags.album ?? "")]?.count ?? 0) > 1 {
                albumArtist = words.variousArtists
            }
            let named = Named(song: song, title: song.tags.title ?? fromName.title, artist: artist, albumArtist: albumArtist, album: album,
                              track: song.tags.track ?? fromName.number)
            let key = Self.albumKey(artist: albumArtist, album: album)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(named)
        }

        for key in order {
            guard var members = grouped[key], let first = members.first else { continue }
            members.sort { a, b in
                let da = a.song.tags.disc ?? 1, db = b.song.tags.disc ?? 1
                if da != db { return da < db }
                let ta = a.track ?? Int.max, tb = b.track ?? Int.max
                if ta != tb { return ta < tb }
                return a.song.path.compare(b.song.path, options: [.numeric, .caseInsensitive]) == .orderedAscending
            }
            var cover: Cover?
            if let folder = members.lazy.map(\.song.folder).first(where: { library.covers[$0] != nil }), let name = library.covers[folder] {
                cover = .file(path: folder.isEmpty ? name : folder + "/" + name)
            } else if let carrier = members.first(where: { $0.song.tags.pictureOffset != nil }) {
                cover = .embedded(song: carrier.song.id)
            }
            let artworkKey = cover.map { _ in "share-" + String(first.song.id) }
            if let cover, let artworkKey { covers[artworkKey] = cover }

            var ids: [Int64] = []
            var total = 0.0
            for member in members {
                let song = member.song
                ids.append(song.id)
                total += song.tags.duration
                songs[song.id] = song
                tracks[song.id] = TrackSummary(id: song.id, title: member.title, artist: member.artist, album: member.album, albumKey: key,
                                               duration: song.tags.duration, trackNumber: member.track, discNumber: song.tags.disc,
                                               format: Self.format(song.tags), artworkKey: artworkKey, favorite: favorites.contains(song.id))
            }
            // The album is described by its best file: a 24/96 album with one 16/44.1 bonus track is a 24/96 album.
            let best = members.map(\.song.tags).max { Self.weight($0) < Self.weight($1) } ?? first.song.tags
            let aboveCD = best.lossless && ((best.bitDepth ?? 16) > 16 || best.sampleRate > 48_000)
            albums.append(Album(
                summary: AlbumSummary(key: key, title: first.album, artist: first.albumArtist, year: members.compactMap(\.song.tags.year).min(),
                                      trackCount: ids.count, duration: total, format: Self.format(best), artworkKey: artworkKey,
                                      hiRes: AlbumFilter.countsAsHiRes(aboveCD: aboveCD, dsd: false, maxSampleRate: best.sampleRate),
                                      dsd: false, multichannel: members.contains { $0.song.tags.channels > 2 }),
                tracks: ids, genre: members.lazy.compactMap(\.song.tags.genre).first, newest: members.map(\.song.modified).max() ?? .distantPast))
        }
        func before(_ a: String, _ b: String) -> ComparisonResult { a.compare(b, options: [.caseInsensitive, .diacriticInsensitive, .numeric]) }
        albums.sort { a, b in
            let artists = before(a.summary.artist, b.summary.artist)
            if artists != .orderedSame { return artists == .orderedAscending }
            if let x = a.summary.year, let y = b.summary.year, x != y { return x < y }
            return before(a.summary.title, b.summary.title) == .orderedAscending
        }
    }

    // MARK: Words and keys

    /// As the Mac groups songs into albums: album artist and album, ASCII letters lowered.
    static func albumKey(artist: String, album: String) -> String {
        let bytes = "\(artist)\u{1F}\(album)".utf8.map { (b: UInt8) -> UInt8 in b >= 0x41 && b <= 0x5A ? b + 0x20 : b }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// "FLAC · 24/96", "MP3 · 320k", "FLAC · 24/96 · 5.1": the Mac's words for a format.
    public static func format(_ tags: SongTags) -> String {
        var text = tags.codec
        if let depth = tags.bitDepth {
            let rate = tags.sampleRate.truncatingRemainder(dividingBy: 1000) == 0 ? String(Int(tags.sampleRate / 1000))
                : String((tags.sampleRate / 100).rounded() / 10)
            text += " · \(depth)/\(rate)"
        } else if let bitRate = tags.bitRate {
            text += " · \(bitRate)k"
        }
        switch tags.channels {
        case ...2: break
        case 6: text += " · 5.1"
        case 7: text += " · 6.1"
        case 8: text += " · 7.1"
        default: text += " · \(tags.channels).0"
        }
        return text
    }

    private static func weight(_ tags: SongTags) -> Double {
        (tags.lossless ? 1e9 : 0) + tags.sampleRate * Double(tags.bitDepth ?? 1)
    }

    /// "03 Night Ferry.flac" → ("Night Ferry", 3); "1-07 - Lanterns.m4a" → ("Lanterns", 7).
    static func titleAndNumber(fileName: String) -> (title: String, number: Int?) {
        var stem = fileName
        if let dot = stem.lastIndex(of: "."), dot != stem.startIndex { stem = String(stem[..<dot]) }
        var rest = Substring(stem)
        var digits = rest.prefix { $0.isASCII && $0.isNumber }
        // A disc number and a dash first ("1-07").
        if !digits.isEmpty, digits.count <= 2, rest.dropFirst(digits.count).first == "-",
           let after = Optional(rest.dropFirst(digits.count + 1)), !after.prefix(while: { $0.isASCII && $0.isNumber }).isEmpty {
            rest = after
            digits = rest.prefix { $0.isASCII && $0.isNumber }
        }
        guard !digits.isEmpty, digits.count <= 3, let number = Int(digits) else { return (stem, nil) }
        let title = rest.dropFirst(digits.count).drop { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" }
        return title.isEmpty ? (stem, nil) : (String(title), number)
    }

    // MARK: Lists

    public var allTracks: [TrackSummary] { albums.flatMap(\.tracks).compactMap { tracks[$0] } }

    public func album(_ key: String) -> Album? { albums.first { $0.summary.key == key } }

    public var artists: [ArtistSummary] {
        var seen: [String: (count: Int, cover: String?)] = [:]
        var order: [String] = []
        for album in albums {
            let name = album.summary.artist
            if seen[name] == nil { order.append(name) }
            seen[name] = ((seen[name]?.count ?? 0) + 1, seen[name]?.cover ?? album.summary.artworkKey)
        }
        return order.map { ArtistSummary(name: $0, albumCount: seen[$0]?.count ?? 0, artworkKey: seen[$0]?.cover) }
    }

    public var genres: [GenreSummary] {
        var byKey: [String: (name: String, albums: [Album])] = [:]
        for album in albums {
            guard let genre = album.genre else { continue }
            byKey[genre.lowercased(), default: (genre, [])].albums.append(album)
        }
        return byKey.sorted { $0.value.name.compare($1.value.name, options: .caseInsensitive) == .orderedAscending }.map { key, value in
            GenreSummary(key: key, name: value.name, albumCount: value.albums.count, artworkKeys: Array(value.albums.compactMap(\.summary.artworkKey).prefix(4)))
        }
    }

    public func albums(genre key: String) -> [AlbumSummary] { albums.filter { $0.genre?.lowercased() == key }.map(\.summary) }

    public func recentlyAdded(_ limit: Int) -> [AlbumSummary] {
        albums.enumerated().sorted { $0.element.newest != $1.element.newest ? $0.element.newest > $1.element.newest : $0.offset < $1.offset }
            .prefix(min(max(1, limit), 150)).map(\.element.summary)
    }

    private static func words(_ text: String) -> [String] { text.lowercased().split(separator: " ").map(String.init) }
    private static func matches(_ haystack: String, _ words: [String]) -> Bool {
        let folded = haystack.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return words.allSatisfy { folded.contains($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) }
    }

    public func search(_ text: String, limit: Int) -> [TrackSummary] {
        let words = Self.words(text)
        guard !words.isEmpty else { return [] }
        return Array(allTracks.lazy.filter { Self.matches("\($0.title) \($0.artist) \($0.album)", words) }.prefix(min(max(1, limit), 500)))
    }

    public func find(_ text: String, limit: Int) -> SearchResults {
        let words = Self.words(text)
        guard !words.isEmpty else { return SearchResults(tracks: [], albums: [], artists: [], playlists: []) }
        let limit = min(max(1, limit), 500)
        return SearchResults(tracks: search(text, limit: limit),
                             albums: Array(albums.lazy.map(\.summary).filter { Self.matches("\($0.title) \($0.artist)", words) }.prefix(limit)),
                             artists: Array(artists.filter { Self.matches($0.name, words) }.prefix(limit)),
                             playlists: [])
    }

    public func songs(offset: Int, limit: Int) -> (items: [TrackSummary], total: Int) {
        let sorted = allTracks.sorted {
            let order = $0.title.compare($1.title, options: [.caseInsensitive, .diacriticInsensitive, .numeric])
            return order != .orderedSame ? order == .orderedAscending : ($0.id ?? 0) < ($1.id ?? 0)
        }
        let start = min(max(0, offset), sorted.count)
        return (Array(sorted[start..<min(sorted.count, start + min(max(1, limit), 500))]), sorted.count)
    }

    public mutating func setFavorite(_ ids: [Int64], _ on: Bool) {
        for id in ids { tracks[id]?.favorite = on }
    }
}
