//
// Vespertine: the phone's own index of a share: every song file it can play, with its tags, found by walking the
// share's folders. Kept on the phone between launches; a later scan reads only the files that are new or changed.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

public struct ShareSong: Codable, Equatable, Sendable, Identifiable {
    /// The same for the same path on every scan, so queues, favorites and kept songs survive a rescan.
    public var id: Int64
    /// From the share's music folder, `/` between names.
    public var path: String
    public var size: Int64
    public var modified: Date
    public var tags: SongTags

    public init(id: Int64, path: String, size: Int64, modified: Date, tags: SongTags) {
        self.id = id
        self.path = path
        self.size = size
        self.modified = modified
        self.tags = tags
    }

    /// The folder the file is in.
    public var folder: String { path.split(separator: "/").dropLast().joined(separator: "/") }
    public var fileName: String { path.split(separator: "/").last.map(String.init) ?? path }
}

public struct ShareLibrary: Codable, Equatable, Sendable {
    public var songs: [ShareSong]
    /// The picture file found in a folder (`cover.jpg` and the like), by folder.
    public var covers: [String: String]
    /// Music files of kinds the phone can't open without the Mac converting them (APE, WavPack, surround DSD…).
    public var needTheMac: Int
    /// Files with a playable name that couldn't be read as what the name says.
    public var unreadable: Int
    public var scanned: Date?

    public init(songs: [ShareSong] = [], covers: [String: String] = [:], needTheMac: Int = 0, unreadable: Int = 0, scanned: Date? = nil) {
        self.songs = songs
        self.covers = covers
        self.needTheMac = needTheMac
        self.unreadable = unreadable
        self.scanned = scanned
    }
}

public enum ShareScanner {
    public struct Progress: Equatable, Sendable {
        public var folders: Int
        public var songs: Int
    }

    /// Folders that are never music: a NAS's own, a recycle bin, a drive's bookkeeping.
    static let skippedFolders: Set<String> = ["@eadir", "#recycle", "$recycle.bin", "system volume information", "lost+found", "#snapshot", "@recycle"]
    private static let coverNames = ["cover", "folder", "front", "album", "albumart"]
    private static let coverTypes: Set<String> = ["jpg", "jpeg", "png"]

    /// An ID from a path (FNV-1a), kept below 2^53 so it is the same number wherever it is written.
    static func id(for path: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return Int64(hash & 0x1f_ffff_ffff_ffff) | 1
    }

    /// An MPEG-4 file an earlier scan found no title, artist or album in is read again though it has not changed: it may
    /// be tagged the QuickTime way, which earlier versions could not read. A file with no tags at all costs one small
    /// read more per scan.
    static func readsAgain(_ old: ShareSong, type: String) -> Bool {
        guard ["m4a", "mp4", "m4b"].contains(type) else { return false }
        return old.tags.title == nil && old.tags.artist == nil && old.tags.album == nil
    }

    /// Walks `files` from the top and returns its library. `previous`: the last scan, whose tags are reused for files
    /// with the same size and date. A folder that can't be opened is passed over; a share that stops answering ends the
    /// scan with the error (and `previous` stays what the app has).
    ///
    /// `glimpse`: while a share is scanned for the first time (no earlier scan ever finished), what has been found so
    /// far, every `glimpseEvery` songs and with `scanned` nil: a large library over a slow line can be browsed, and
    /// picked up again where it stopped, long before the scan is done.
    ///
    /// `decoders`: the kinds of file the app opens with a decoder library (DecodedFormats.swift).
    public static func scan(_ files: any ShareFiles, previous: ShareLibrary? = nil, now: Date = Date(), glimpseEvery: Int = 200,
                            decoders: (any ShareDecoders)? = nil,
                            progress: (Progress) -> Void = { _ in }, glimpse: (ShareLibrary) -> Void = { _ in },
                            cancelled: () -> Bool = { false }) throws -> ShareLibrary {
        var known: [String: ShareSong] = [:]
        for song in previous?.songs ?? [] { known[song.path] = song }
        var library = ShareLibrary(scanned: now)
        var used = Set<Int64>()
        var waiting = [""]
        var folders = 0
        var read = 0
        let firstTime = previous?.scanned == nil
        while let folder = waiting.popLast() {
            if cancelled() { throw CancellationError() }
            let entries: [SMBEntry]
            do {
                entries = try files.list(folder)
            } catch let error as SMBError where !SMBShare.lineIsGone(error) && error != .unreachable && !folder.isEmpty {
                continue
            }
            folders += 1
            let sorted = entries.filter { !$0.hidden && !$0.name.hasPrefix(".") }
                .sorted { $0.name.compare($1.name, options: [.numeric, .caseInsensitive]) == .orderedAscending }
            var cover: (rank: Int, name: String)?
            for entry in sorted {
                let path = folder.isEmpty ? entry.name : folder + "/" + entry.name
                if entry.isFolder {
                    if !skippedFolders.contains(entry.name.lowercased()), path.split(separator: "/").count <= 24 { waiting.append(path) }
                    continue
                }
                let type = SongTagReader.fileExtension(entry.name)
                if coverTypes.contains(type) {
                    let stem = entry.name.dropLast(type.count + 1).lowercased()
                    if let rank = coverNames.firstIndex(of: String(stem)), cover.map({ rank < $0.rank }) ?? true { cover = (rank, entry.name) }
                    continue
                }
                // A kind the app has a decoder for is opened here, whatever the list of the Mac's kinds says.
                let decoded = decoders?.extensions.contains(type) ?? false
                if !decoded, SongTagReader.needsTheMac.contains(type) { library.needTheMac += 1; continue }
                guard decoded || SongTagReader.playable.contains(type), entry.size > 0 else { continue }
                if let old = known[path], old.size == entry.size, old.modified == entry.modified, !readsAgain(old, type: type) {
                    used.insert(old.id)
                    library.songs.append(old)
                    continue
                }
                if cancelled() { throw CancellationError() }
                let tags: SongTags?
                do {
                    if decoded, let decoders {
                        switch try decoders.open(type: type, size: entry.size, read: { offset, length in try files.read(path, offset: offset, length: length) }) {
                        case .opened(let decoder) where decoder.info.playsHere: tags = SongTagReader.tags(decoder.info, size: entry.size)
                        case .opened, .needsTheMac: library.needTheMac += 1; continue
                        case .unreadable: tags = nil
                        }
                    } else {
                        tags = try SongTagReader.read(name: entry.name, size: entry.size) { offset, length in try files.read(path, offset: offset, length: length) }
                    }
                } catch let error as SMBError where !SMBShare.lineIsGone(error) && error != .unreachable {
                    tags = nil
                }
                guard let tags else { library.unreadable += 1; continue }
                // DSD in surround, or packed with DST: a file the Mac has to convert.
                if let dsd = tags.dsd, !dsd.playsHere { library.needTheMac += 1; continue }
                var songID = known[path]?.id ?? id(for: path)
                while used.contains(songID) { songID += 2 }
                used.insert(songID)
                library.songs.append(ShareSong(id: songID, path: path, size: entry.size, modified: entry.modified, tags: tags))
                progress(Progress(folders: folders, songs: library.songs.count))
                read += 1
                if firstTime, glimpseEvery > 0, read % glimpseEvery == 0 { glimpse(arranged(library, scanned: nil)) }
            }
            if let cover { library.covers[folder] = cover.name }
            progress(Progress(folders: folders, songs: library.songs.count))
        }
        return arranged(library, scanned: now)
    }

    private static func arranged(_ library: ShareLibrary, scanned: Date?) -> ShareLibrary {
        var library = library
        library.scanned = scanned
        library.songs.sort { $0.path.compare($1.path, options: [.numeric, .caseInsensitive]) == .orderedAscending }
        return library
    }
}

/// The few words the library puts where a file says nothing, in the app's language.
public struct ShareWords: Sendable, Equatable {
    public var unknownArtist: String
    public var unknownAlbum: String
    public var variousArtists: String

    public init(unknownArtist: String, unknownAlbum: String, variousArtists: String) {
        self.unknownArtist = unknownArtist
        self.unknownAlbum = unknownAlbum
        self.variousArtists = variousArtists
    }

    public static let english = ShareWords(unknownArtist: "Unknown Artist", unknownAlbum: "Unknown Album", variousArtists: "Various Artists")
}
