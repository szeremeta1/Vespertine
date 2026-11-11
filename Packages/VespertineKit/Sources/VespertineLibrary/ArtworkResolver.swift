//
// Vespertine: finds the cover of the song that is playing, whatever the scan left behind.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import SFBAudioEngine
import VespertineAudio

/// The cover to show for one song, and where it came from.
public struct ResolvedArtwork: Sendable, Equatable {
    public enum Source: String, Sendable {
        /// The key the library holds for the song (what the scan found).
        case library
        /// Read from the file's own tags just now.
        case embedded
        /// A `cover.jpg` and the like beside the file (or above its disc folder), found just now.
        case folder
        /// Another song of the same album has one.
        case album
        /// Nothing anywhere: the player shows its placeholder (and asks again later).
        case none
    }

    public var key: String?
    public var source: Source

    public init(key: String?, source: Source) { self.key = key; self.source = source }
    public static let none = ResolvedArtwork(key: nil, source: .none)
}

/// What the visualizer (and anything else that must always have a cover) asks when a song starts: the cover the library
/// holds for the song, else the file's embedded picture, else the folder's image, else the album's cover from another of
/// its songs, else nothing.
///
/// The scan decides a song's `artworkKey` once, so a cover that appeared afterwards, one the scan could not read, or one
/// the song's queue entry no longer knows (a tag edit changed it) never reached the screen. This asks again at play time,
/// from the library's current row and from the file, and keeps what it finds in the library so every page shows it.
///
/// It reads the song's own file (on a share: a few ranges of it, as the scan does) and never the staging copy a share
/// song plays from, which is partial while it downloads.
public final class ArtworkResolver: Sendable {
    public let database: LibraryDatabase
    public let store: ArtworkStore

    public init(database: LibraryDatabase, store: ArtworkStore) {
        self.database = database
        self.store = store
    }

    /// Blocking: call it off the main thread.
    public func resolve(_ track: Track, persist: Bool = true) -> ResolvedArtwork {
        // 1. The library's current key (the queue's copy of the song may predate a cover change), if its picture is on disk.
        let current = track.id.flatMap { id in (try? database.tracks(ids: [id]))?.first }
        let known = current.map(\.artworkKey) ?? track.artworkKey
        if let known, store.hasImage(known) { return ResolvedArtwork(key: known, source: .library) }

        // 2. The file's own picture, 3. the folder's image.
        let file = track.fileURL
        if let found = readFromFile(file, discImage: Self.isDiscImage(track)) {
            if persist, let id = track.id, let key = found.key { remember(key, forTrack: id, replacing: known) }
            return found
        }

        // 4. The album's cover, from a song that has one.
        if let key = albumKey(of: track, excluding: track.id) { return ResolvedArtwork(key: key, source: .album) }
        return .none
    }

    // MARK: Reading the file

    private func readFromFile(_ file: URL, discImage: Bool) -> ResolvedArtwork? {
        var embedded: [() -> Data?] = []
        if !discImage, FileManager.default.fileExists(atPath: file.path) {
            embedded = Self.embeddedPictures(of: file)
        }
        var folderKey: String?
        let key = store.coverKey(embedded: embedded) {
            folderKey = ArtworkStore.folderArtKey(near: file, store: store)
            return folderKey
        }
        guard let key else { return nil }
        return ResolvedArtwork(key: key, source: key == folderKey ? .folder : .embedded)
    }

    /// The pictures in a file's tags, best first, as readers that run only when asked for. A file on a network share is
    /// read through a sparse local copy of its tag regions (a few large reads, as the scan does it), not picture by picture.
    static func embeddedPictures(of file: URL) -> [() -> Data?] {
        var url = file
        var cleanup: URL?
        if (try? file.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == false,
           let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap({ $0 }).map(Int64.init) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-art-\(UUID().uuidString)", isDirectory: true)
            let shadow = dir.appendingPathComponent(file.lastPathComponent, isDirectory: false)
            if (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
               (try? RemoteMetadata.makeShadow(of: file, size: size, at: shadow)) != nil {
                url = shadow
                cleanup = dir
            }
        }
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }
        guard let tags = try? AudioFile(readingPropertiesAndMetadataFrom: url) else {
            let data = CommentPictures.flacCover(at: url)
            return [{ data }]
        }
        let pictures = MetadataReader.rankedPictures(tags.metadata)
        let comment = CommentPictures.flacCover(at: url)
        // Read now, while a share's local copy exists; the closures only hand the bytes on.
        return pictures.map { picture in { picture.imageData } } + [{ comment }]
    }

    static func isDiscImage(_ track: Track) -> Bool {
        let ext = (track.filePath as NSString).pathExtension.lowercased()
        return SourceInspector.discImageExtensions.contains(ext) || SourceInspector.dvdFolderExtensions.contains(ext)
    }

    // MARK: Library

    private func albumKey(of track: Track, excluding id: Int64?) -> String? {
        guard let siblings = try? database.tracks(albumKey: track.albumKey) else { return nil }
        return siblings.first { $0.id != id && $0.artworkKey.map(store.hasImage) == true }?.artworkKey
    }

    /// Keeps a cover found at play time with its song, so albums, queues and the next play have it too. Only a song with no
    /// cover (or one whose picture is gone from disk) takes it; a cover the scan or an edit set is not replaced.
    private func remember(_ key: String, forTrack id: Int64, replacing old: String?) {
        _ = try? database.writer.write { db in
            try db.execute(sql: "UPDATE track SET artworkKey = ? WHERE id = ? AND artworkKey IS ?", arguments: [key, id, old])
        }
    }
}
