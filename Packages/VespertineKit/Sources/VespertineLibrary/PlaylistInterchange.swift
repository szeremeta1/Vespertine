//
// Vespertine — playlists in and out: M3U / M3U8 both ways, and the library Apple Music exports.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Nothing here adds files to the library. An imported entry is matched to a song already in it: by its file, or,
// when the file has moved (another drive, another Mac), by title, artist and length, as long as exactly one song fits.
//

import Foundation
import GRDB

/// One song as another player lists it.
public struct PlaylistEntry: Sendable, Hashable {
    public var path: String?
    public var title: String?
    public var artist: String?
    public var album: String?
    public var duration: Double?

    public init(path: String? = nil, title: String? = nil, artist: String? = nil, album: String? = nil, duration: Double? = nil) {
        self.path = path
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

public enum M3U {
    /// An extended M3U8 (UTF-8) of `tracks`, in order, with absolute paths. A song from a CUE-split image points at
    /// the image, as M3U has no way to name a part of a file.
    public static func text(_ tracks: [Track]) -> String {
        var lines = ["#EXTM3U"]
        for t in tracks {
            let who = [t.artist ?? t.albumArtist, t.title].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " - ")
            lines.append("#EXTINF:\(Int(t.duration.rounded())),\(who.replacingOccurrences(of: "\n", with: " "))")
            lines.append(t.filePath)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The entries of an M3U or M3U8 file whose folder is `base`: absolute paths, paths relative to the playlist,
    /// `file://` URLs, Windows separators, and #EXTINF titles. Web streams are skipped.
    public static func entries(_ text: String, base: URL) -> [PlaylistEntry] {
        var result: [PlaylistEntry] = []
        var pending: PlaylistEntry?
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            guard !line.isEmpty else { continue }
            if line.uppercased().hasPrefix("#EXTINF:") {
                pending = extinf(String(line.dropFirst(8)))
                continue
            }
            if line.hasPrefix("#") { continue }
            var entry = pending ?? PlaylistEntry()
            pending = nil
            if let url = URL(string: line), let scheme = url.scheme?.lowercased(), scheme.count > 1 {
                guard scheme == "file" else { continue }   // http streams and the like aren't songs in the library
                entry.path = url.standardizedFileURL.path
            } else {
                let path = line.replacingOccurrences(of: "\\", with: "/")
                entry.path = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)).standardizedFileURL.path
            }
            result.append(entry)
        }
        return result
    }

    /// "#EXTINF:245,Artist - Title" → duration, artist and title.
    private static func extinf(_ body: String) -> PlaylistEntry {
        guard let comma = body.firstIndex(of: ",") else { return PlaylistEntry(duration: Double(body)) }
        let seconds = Double(body[..<comma].split(separator: " ").first ?? "")
        let label = body[body.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        let parts = label.components(separatedBy: " - ")
        let duration = seconds.flatMap { $0 > 0 ? $0 : nil }
        if parts.count >= 2 {
            return PlaylistEntry(title: parts.dropFirst().joined(separator: " - "), artist: parts[0], duration: duration)
        }
        return PlaylistEntry(title: label.isEmpty ? nil : label, duration: duration)
    }
}

/// The library Apple Music (or iTunes) writes with File › Library › Export Library…: an XML property list.
public struct AppleMusicLibrary: Sendable {
    public struct Song: Sendable, Hashable {
        public var entry: PlaylistEntry
        public var playCount: Int
        /// Loved, or Favorited in newer versions of Music.
        public var loved: Bool
    }

    public struct List: Sendable, Hashable {
        public var name: String
        public var songIDs: [Int]
    }

    public var songs: [Int: Song]
    /// The playlists people made (and smart playlists, as the songs they held when exported). Music's own lists
    /// (the whole library, Music, Downloaded…) and folders are left out.
    public var playlists: [List]

    public enum ReadError: Error, Equatable, LocalizedError {
        case notALibrary
        public var errorDescription: String? {
            "This isn't a library exported from Apple Music. In Music, choose File \u{203A} Library \u{203A} Export Library\u{2026} and pick the file it saves."
        }
    }

    public init(data: Data) throws {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let tracks = plist["Tracks"] as? [String: [String: Any]] else { throw ReadError.notALibrary }
        var songs: [Int: Song] = [:]
        for (key, t) in tracks {
            guard let id = (t["Track ID"] as? Int) ?? Int(key) else { continue }
            let path = (t["Location"] as? String).flatMap(URL.init(string:)).flatMap { $0.isFileURL ? $0.standardizedFileURL.path : nil }
            let entry = PlaylistEntry(path: path, title: t["Name"] as? String, artist: t["Artist"] as? String,
                                      album: t["Album"] as? String, duration: (t["Total Time"] as? Int).map { Double($0) / 1000 })
            songs[id] = Song(entry: entry, playCount: t["Play Count"] as? Int ?? 0,
                             loved: (t["Loved"] as? Bool ?? false) || (t["Favorited"] as? Bool ?? false))
        }
        var lists: [List] = []
        for p in plist["Playlists"] as? [[String: Any]] ?? [] {
            if p["Master"] as? Bool == true || p["Distinguished Kind"] != nil || p["Folder"] as? Bool == true || p["Visible"] as? Bool == false { continue }
            guard let name = p["Name"] as? String else { continue }
            let ids = (p["Playlist Items"] as? [[String: Any]] ?? []).compactMap { $0["Track ID"] as? Int }
            lists.append(List(name: name, songIDs: ids))
        }
        self.songs = songs
        self.playlists = lists
    }
}

// MARK: - Matching and importing

public extension LibraryDatabase {
    /// The library song each entry is, in order; nil where none fits. A file in the library is matched by its path
    /// (either Unicode normalization: Finder and other players disagree). Otherwise a song with the same title and
    /// artist (ignoring case and accents), and the same length within two seconds where both are known, is used when
    /// it's the only one.
    func match(_ entries: [PlaylistEntry]) throws -> [Int64?] {
        try writer.read { db in
            var byPath: [String: Int64] = [:]
            var byName: [String: [(id: Int64, duration: Double)]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, filePath, title, artist, albumArtist, duration, cueStartFrame FROM track WHERE isMissing = 0 ORDER BY id") {
                let id: Int64 = row["id"], path: String = row["filePath"]
                // A CUE image holds several songs: its path alone names none of them.
                if (row["cueStartFrame"] as Int64?) == nil {
                    byPath[path.precomposedStringWithCanonicalMapping] = byPath[path.precomposedStringWithCanonicalMapping] ?? id
                }
                let title: String = row["title"], duration: Double = row["duration"]
                let artists: [String?] = [row["artist"], row["albumArtist"]]
                for artist in Set(artists.compactMap { $0 }) {
                    byName[Self.nameKey(title, artist), default: []].append((id: id, duration: duration))
                }
            }
            return entries.map { (e: PlaylistEntry) -> Int64? in
                if let path = e.path {
                    // The library keeps paths with symlinks resolved (/tmp is /private/tmp); so must the lookup.
                    for p in [path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path] {
                        if let id = byPath[p.precomposedStringWithCanonicalMapping] { return id }
                    }
                }
                guard let title = e.title, let artist = e.artist else { return nil }
                var fits = byName[Self.nameKey(title, artist)] ?? []
                if let d = e.duration, d > 0 { fits = fits.filter { abs($0.duration - d) <= 2 } }
                let ids = Set(fits.map(\.id))
                return ids.count == 1 ? ids.first : nil
            }
        }
    }

    private static func nameKey(_ title: String, _ artist: String) -> String {
        func fold(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return fold(title) + "\u{1F}" + fold(artist)
    }
}

/// What an import did, for the message afterwards.
public struct PlaylistImportResult: Sendable, Equatable {
    public var playlists = 0
    public var songs = 0
    public var unmatched = 0
    public var favorites = 0
    public var playCounts = 0
    public init() {}
}

public extension LibraryDatabase {
    /// Makes a playlist of the entries that are in the library. Returns nil when none are.
    func importPlaylist(named name: String, entries: [PlaylistEntry]) throws -> (Playlist, PlaylistImportResult)? {
        let ids = try match(entries)
        let found = ids.compactMap { $0 }
        guard !found.isEmpty else { return nil }
        let playlist = try createPlaylist(name: name)
        if let pid = playlist.id { try append(trackIDs: found, to: pid) }
        var result = PlaylistImportResult()
        result.playlists = 1
        result.songs = found.count
        result.unmatched = ids.count - found.count
        return (playlist, result)
    }

    /// Brings in Apple Music's playlists, and optionally its loved songs (as favorites) and play counts. A play
    /// count only ever goes up to Music's, so importing the same library twice counts nothing twice.
    func importAppleMusic(_ library: AppleMusicLibrary, playlists: Bool = true, favorites: Bool = true, playCounts: Bool = true) throws -> PlaylistImportResult {
        let ids = library.songs.keys.sorted()
        let matched = try match(ids.map { library.songs[$0]!.entry })
        var trackFor: [Int: Int64] = [:]
        for (i, id) in ids.enumerated() { if let t = matched[i] { trackFor[id] = t } }
        var result = PlaylistImportResult()
        if playlists {
            for list in library.playlists {
                let found = list.songIDs.compactMap { trackFor[$0] }
                result.unmatched += list.songIDs.count - found.count
                guard !found.isEmpty else { continue }
                let playlist = try createPlaylist(name: list.name)
                if let pid = playlist.id { try append(trackIDs: found, to: pid) }
                result.playlists += 1
                result.songs += found.count
            }
        }
        if favorites {
            let loved = ids.filter { library.songs[$0]!.loved }.compactMap { trackFor[$0] }
            try setFavorite(true, trackIDs: loved)
            result.favorites = loved.count
        }
        if playCounts {
            let counts = ids.compactMap { id -> (Int64, Int)? in
                guard let t = trackFor[id], let n = library.songs[id]?.playCount, n > 0 else { return nil }
                return (t, n)
            }
            result.playCounts = try writer.write { db in
                var changed = 0
                for (track, n) in counts {
                    try db.execute(sql: "UPDATE track SET playCount = ? WHERE id = ? AND playCount < ?", arguments: [n, track, n])
                    changed += db.changesCount
                }
                return changed
            }
        }
        return result
    }
}
