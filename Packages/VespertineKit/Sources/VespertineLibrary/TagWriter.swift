//
// Vespertine — writes metadata into files (TagLib via SFBAudioEngine) with history and backups.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Darwin
import CryptoKit
import CVespertineTags
import Foundation
import GRDB
import SFBAudioEngine

public enum TagField: String, CaseIterable, Sendable, Hashable {
    case title, artist, album, albumArtist, composer, genre, releaseDate
    case trackNumber, trackTotal, discNumber, discTotal, compilation
    case grouping, comment, lyrics, bpm, rating, isrc, label
    case titleSort, artistSort, albumSort, albumArtistSort
    case musicBrainzReleaseID, musicBrainzRecordingID

    public var label: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .albumArtist: "Album Artist"
        case .composer: "Composer"
        case .genre: "Genre"
        case .releaseDate: "Year / Date"
        case .trackNumber: "Track"
        case .trackTotal: "Track Total"
        case .discNumber: "Disc"
        case .discTotal: "Disc Total"
        case .compilation: "Compilation"
        case .grouping: "Grouping"
        case .comment: "Comment"
        case .lyrics: "Lyrics"
        case .bpm: "BPM"
        case .rating: "Rating"
        case .isrc: "ISRC"
        case .label: "Label"
        case .titleSort: "Sort Title"
        case .artistSort: "Sort Artist"
        case .albumSort: "Sort Album"
        case .albumArtistSort: "Sort Album Artist"
        case .musicBrainzReleaseID: "MusicBrainz Release"
        case .musicBrainzRecordingID: "MusicBrainz Recording"
        }
    }

    /// The names TagLib's property map gives this field, in every tag format (a few have more than one).
    var propertyNames: [String] {
        switch self {
        case .title: ["TITLE"]
        case .artist: ["ARTIST"]
        case .album: ["ALBUM"]
        case .albumArtist: ["ALBUMARTIST"]
        case .composer: ["COMPOSER"]
        case .genre: ["GENRE"]
        case .releaseDate: ["DATE"]
        case .trackNumber, .trackTotal: ["TRACKNUMBER", "TRACKTOTAL", "TOTALTRACKS"]
        case .discNumber, .discTotal: ["DISCNUMBER", "DISCTOTAL", "TOTALDISCS"]
        case .compilation: ["COMPILATION"]
        case .grouping: ["GROUPING", "CONTENTGROUP", "WORK"]
        case .comment: ["COMMENT", "DESCRIPTION"]
        case .lyrics: ["LYRICS", "UNSYNCEDLYRICS"]
        case .bpm: ["BPM"]
        case .rating: ["RATING"]
        case .isrc: ["ISRC"]
        case .label: ["LABEL", "ORGANIZATION", "PUBLISHER"]
        case .titleSort: ["TITLESORT"]
        case .artistSort: ["ARTISTSORT"]
        case .albumSort: ["ALBUMSORT"]
        case .albumArtistSort: ["ALBUMARTISTSORT"]
        case .musicBrainzReleaseID: ["MUSICBRAINZ_ALBUMID"]
        case .musicBrainzRecordingID: ["MUSICBRAINZ_TRACKID"]
        }
    }

    /// Current value of this field on a track, as editable text.
    public func value(in t: Track) -> String? {
        switch self {
        case .title: t.title
        case .artist: t.artist
        case .album: t.album
        case .albumArtist: t.albumArtist
        case .composer: t.composer
        case .genre: t.genre
        case .releaseDate: t.releaseDate
        case .trackNumber: t.trackNumber.map(String.init)
        case .trackTotal: t.trackTotal.map(String.init)
        case .discNumber: t.discNumber.map(String.init)
        case .discTotal: t.discTotal.map(String.init)
        case .compilation: t.compilation ? "1" : nil
        case .grouping: t.grouping
        case .comment: t.comment
        case .lyrics: t.lyrics
        case .bpm: t.bpm.map(String.init)
        case .rating: t.rating.map(String.init)
        case .isrc: t.isrc
        case .label: t.label
        case .titleSort: t.titleSort
        case .artistSort: t.artistSort
        case .albumSort: t.albumSort
        case .albumArtistSort: t.albumArtistSort
        case .musicBrainzReleaseID: t.musicBrainzReleaseID
        case .musicBrainzRecordingID: t.musicBrainzRecordingID
        }
    }

    func apply(_ text: String?, to md: AudioMetadata) {
        let s = text.flatMap { $0.isEmpty ? nil : $0 }
        let n = s.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        switch self {
        case .title: md.title = s
        case .artist: md.artist = s
        case .album: md.albumTitle = s
        case .albumArtist: md.albumArtist = s
        case .composer: md.composer = s
        case .genre: md.genre = s
        case .releaseDate: md.releaseDate = s
        case .trackNumber: md.trackNumber = n
        case .trackTotal: md.trackTotal = n
        case .discNumber: md.discNumber = n
        case .discTotal: md.discTotal = n
        case .compilation: md.isCompilation = s.map { ["1", "true", "yes"].contains($0.lowercased()) }
        case .grouping: md.grouping = s
        case .comment: md.comment = s
        case .lyrics: md.lyrics = s
        case .bpm: md.bpm = n
        case .rating: md.rating = n
        case .isrc: md.isrc = s
        case .label:
            var extra = (md.additionalMetadata as? [String: Any]) ?? [:]
            extra["LABEL"] = s
            md.additionalMetadata = extra
        case .titleSort: md.titleSortOrder = s
        case .artistSort: md.artistSortOrder = s
        case .albumSort: md.albumTitleSortOrder = s
        case .albumArtistSort: md.albumArtistSortOrder = s
        case .musicBrainzReleaseID: md.musicBrainzReleaseID = s
        case .musicBrainzRecordingID: md.musicBrainzRecordingID = s
        }
    }
}

public struct TagEdit: Sendable {
    public enum ArtworkChange: Sendable { case replace(Data), remove }

    /// Field → new value (nil clears the tag). Fields absent from the map are left untouched.
    public var fields: [TagField: String?]
    /// Free-form tags (e.g. "RECORDING_LOCATION") → value (nil removes).
    public var custom: [String: String?]
    public var artwork: ArtworkChange?

    public init(fields: [TagField: String?] = [:], custom: [String: String?] = [:], artwork: ArtworkChange? = nil) {
        self.fields = fields
        self.custom = custom
        self.artwork = artwork
    }

    public var isEmpty: Bool { fields.isEmpty && custom.isEmpty && artwork == nil }
}

public struct TagWriteResult: Sendable {
    public var written: Int
    public var databaseOnly: Int
    public var failures: [(path: String, message: String)]
}

public actor TagWriter {
    let database: LibraryDatabase
    let scanner: LibraryScanner
    public let backupDirectory: URL
    private var mutationActive = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireMutation() async {
        if mutationActive { await withCheckedContinuation { mutationWaiters.append($0) } }
        mutationActive = true
    }
    private func releaseMutation() {
        if mutationWaiters.isEmpty { mutationActive = false }
        else { mutationWaiters.removeFirst().resume() }
    }

    public init(database: LibraryDatabase, scanner: LibraryScanner, backupDirectory: URL = TagWriter.defaultBackupDirectory) {
        self.database = database
        self.scanner = scanner
        self.backupDirectory = backupDirectory
    }

    public static var defaultBackupDirectory: URL {
        LibraryDatabase.defaultURL.deletingLastPathComponent().appendingPathComponent("Tag Backups", isDirectory: true)
    }

    /// Applies `edit` to every track. Whole files get their tags rewritten; CUE sub-tracks are edited in the library only.
    public func apply(_ edit: TagEdit, to tracks: [Track]) async throws -> TagWriteResult {
        await acquireMutation()
        defer { releaseMutation() }
        try Task.checkCancellation()
        var result = TagWriteResult(written: 0, databaseOnly: 0, failures: [])
        guard !edit.isEmpty else { return result }
        let numeric: Set<TagField> = [.trackNumber, .trackTotal, .discNumber, .discTotal, .bpm, .rating]
        for (field, value) in edit.fields where numeric.contains(field) {
            if let value, !value.isEmpty {
                guard let number = Int(value.trimmingCharacters(in: .whitespaces)), number >= 0 else {
                    throw TagWriteError.invalidNumber(field.label)
                }
            }
        }
        var refreshIDs: [Int64] = []
        let readOnly = try Self.readOnlyShares(database.sources())

        for track in tracks {
            guard let id = track.id else { continue }
            // CUE tracks share one file, and a read-only share can't be written: those edits live in the library
            // (and survive rescans). Checked first, so no backup is copied for a write that would fail.
            // A share added read-only is never written, even when it's mounted read-write (by Finder, say).
            if track.cueStartFrame != nil || track.sourceId.map(readOnly.contains) == true || !Self.isWritable(track.fileURL) {
                try await updateDatabaseOnly(track, edit: edit)
                result.databaseOnly += 1
                continue
            }
            let url = track.fileURL
            do {
                let backup = try makeBackup(of: url)
                // The tags are written into a clone of the file, which then takes its place in one step (see
                // `editingClone`); where that isn't possible, into the file itself, with the backup to fall back on.
                let target = Self.editingClone(of: url) ?? url
                defer { if target != url { try? FileManager.default.removeItem(at: target) } }
                var replaced = target == url
                let file = try AudioFile(url: target)
                try file.readPropertiesAndMetadata()
                var previous = Self.snapshot(file.metadata)
                // SFBAudioEngine writes one value per field, so the save would keep only the first of several artists,
                // genres or MusicBrainz IDs, edited or not. Read them now, and put back each one the save cut down.
                let multiValued = target.withUnsafeFileSystemRepresentation { $0.flatMap { nvt_multivalued_read($0) } }
                defer { nvt_multivalued_free(multiValued) }

                for (field, value) in edit.fields {
                    if field == .releaseDate, let value, TagWriter.usesID3v2(url) {
                        field.apply(TagWriter.id3Timestamp(value), to: file.metadata)
                    } else {
                        field.apply(value, to: file.metadata)
                    }
                }
                if !edit.custom.isEmpty {
                    var extra = (file.metadata.additionalMetadata as? [String: Any]) ?? [:]
                    for (k, v) in edit.custom { extra[k.uppercased()] = v }
                    file.metadata.additionalMetadata = extra
                }
                switch edit.artwork {
                case .replace(let data):
                    file.metadata.removeAttachedPicturesOfType(.frontCover)
                    file.metadata.attachPicture(AttachedPicture(imageData: data, type: .frontCover))
                case .remove:
                    file.metadata.removeAllAttachedPictures()
                case nil:
                    break
                }
                do {
                    TagWriter.protectDate(in: file)
                    try file.writeMetadata()
                    try Self.keepEveryValue(multiValued, of: target, edit: edit)
                    if !replaced { try Self.move(target, over: url); replaced = true }
                    previous["__fileSHA256"] = try Self.fileHash(url)
                    let history = previous
                    try await database.writer.write { db in
                        var entry = TagHistoryEntry(id: nil, trackId: id, editedAt: .now, previous: history, fileBackupPath: backup.path)
                        try entry.insert(db)
                    }
                } catch {
                    if replaced { try Self.restore(backup, to: url) }   // otherwise the file was never touched
                    throw error
                }
                refreshIDs.append(id)
                result.written += 1
            } catch {
                result.failures.append((url.path, error.localizedDescription))
            }
        }
        // A clone backup costs nothing when it's made, but it keeps the file's old blocks once the edit replaces them,
        // so clones count against the budget too: trim it after every edit, not only before a full copy.
        if result.written > 0 { pruneBackups() }
        if !refreshIDs.isEmpty { try await scanner.refresh(trackIDs: refreshIDs) }
        return result
    }

    /// Restores the tags saved before the most recent edit of `trackID`.
    public func revertLastEdit(trackID: Int64) async throws -> Bool {
        await acquireMutation()
        defer { releaseMutation() }
        try Task.checkCancellation()
        let entry = try await database.writer.read { db in
            try TagHistoryEntry.filter(Column("trackId") == trackID).order(Column("editedAt").desc).fetchOne(db)
        }
        guard let entry, let track = try database.tracks(ids: [trackID]).first else { return false }
        if let encoded = entry.previous["__cueTrack"], let data = Data(base64Encoded: encoded) {
            let previous = try JSONDecoder().decode(Track.self, from: data)
            try await database.writer.write { db in
                guard var current = try Track.fetchOne(db, key: trackID) else { return }
                current.copyMetadata(from: previous)
                try current.update(db)
                if let encoded = entry.previous["__cueOverride"], !encoded.isEmpty, let override = Data(base64Encoded: encoded) {
                    try db.execute(sql: "INSERT OR REPLACE INTO cueTagOverride (trackId, metadata) VALUES (?, ?)", arguments: [trackID, override])
                } else {
                    try db.execute(sql: "DELETE FROM cueTagOverride WHERE trackId = ?", arguments: [trackID])
                }
                try TagHistoryEntry.deleteOne(db, key: entry.id)
            }
            return true
        }
        if let path = entry.fileBackupPath {
            // Restore the complete file: artwork and structured custom tags are not in the legacy string snapshot.
            if let expected = entry.previous["__fileSHA256"] {
                guard try Self.fileHash(track.fileURL) == expected else { throw TagWriteError.fileChanged }
                try Self.restore(URL(fileURLWithPath: path, isDirectory: false), to: track.fileURL)
            } else {
                // Legacy edits did not record a fingerprint. Restore metadata from the backup without replacing audio.
                let backup = try AudioFile(readingPropertiesAndMetadataFrom: URL(fileURLWithPath: path, isDirectory: false))
                let current = try AudioFile(readingPropertiesAndMetadataFrom: track.fileURL)
                current.metadata.removeAllMetadata()
                current.metadata.removeAllAttachedPictures()
                current.metadata.copyMetadata(from: backup.metadata)
                for picture in backup.metadata.attachedPictures { current.metadata.attachPicture(picture) }
                try current.writeMetadata()
            }
            try await scanner.refresh(trackIDs: [trackID])
            _ = try await database.writer.write { db in try TagHistoryEntry.deleteOne(db, key: entry.id) }
            return true
        }
        let file = try AudioFile(url: track.fileURL)
        try file.readPropertiesAndMetadata()
        let pictures = file.metadata.attachedPictures
        let numericKeys: Set<AudioMetadata.Key> = [.trackNumber, .trackTotal, .discNumber, .discTotal, .BPM, .rating,
            .compilation, .replayGainReferenceLoudness, .replayGainTrackGain, .replayGainTrackPeak, .replayGainAlbumGain, .replayGainAlbumPeak]
        var dictionary: [AudioMetadata.Key: Any] = [:]
        for (raw, value) in entry.previous where !raw.hasPrefix("__") {
            let key = AudioMetadata.Key(rawValue: raw)
            if numericKeys.contains(key), let number = Double(value) { dictionary[key] = NSNumber(value: number) }
            else { dictionary[key] = value }
        }
        let restored = AudioMetadata(dictionaryRepresentation: dictionary)
        file.metadata.removeAllMetadata()
        file.metadata.copyMetadata(from: restored)
        pictures.forEach { file.metadata.attachPicture($0) }
        TagWriter.protectDate(in: file)
        try file.writeMetadata()
        _ = try await database.writer.write { db in try TagHistoryEntry.deleteOne(db, key: entry.id) }
        try await scanner.refresh(trackIDs: [trackID])
        return true
    }

    private func updateDatabaseOnly(_ track: Track, edit: TagEdit) async throws {
        let cover: String?
        if case .replace(let data) = edit.artwork {
            guard let key = scanner.artwork.store(data) else { throw CocoaError(.fileReadCorruptFile) }
            cover = key
        } else { cover = nil }
        try await database.writer.write { db in
            guard let id = track.id, var t = try Track.fetchOne(db, key: id) else { return }
            let previous = try JSONEncoder().encode(t).base64EncodedString()
            let previousOverride = try Data.fetchOne(db, sql: "SELECT metadata FROM cueTagOverride WHERE trackId = ?", arguments: [id])
            for (field, value) in edit.fields {
                let s = value.flatMap { $0.isEmpty ? nil : $0 }
                let n = s.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                switch field {
                case .title: t.title = s ?? "Track \(t.trackNumber ?? 1)"
                case .artist: t.artist = s
                case .album: t.album = s
                case .albumArtist: t.albumArtist = s
                case .composer: t.composer = s
                case .genre: t.genre = s
                case .releaseDate: t.releaseDate = s; t.year = s.flatMap(MetadataReader.year(from:))
                case .trackNumber: t.trackNumber = n
                case .trackTotal: t.trackTotal = n
                case .discNumber: t.discNumber = n
                case .discTotal: t.discTotal = n
                case .compilation: t.compilation = s.map { ["1", "true", "yes"].contains($0.lowercased()) } ?? false
                case .comment: t.comment = s
                case .grouping: t.grouping = s
                case .label: t.label = s
                case .lyrics: t.lyrics = s
                case .bpm: t.bpm = n
                case .rating: t.rating = n
                case .isrc: t.isrc = s
                case .titleSort: t.titleSort = s
                case .artistSort: t.artistSort = s
                case .albumSort: t.albumSort = s
                case .albumArtistSort: t.albumArtistSort = s
                case .musicBrainzReleaseID: t.musicBrainzReleaseID = s
                case .musicBrainzRecordingID: t.musicBrainzRecordingID = s
                }
            }
            for (key, value) in edit.custom { t.extraTags[key.uppercased()] = value }
            switch edit.artwork {
            case .replace: t.artworkKey = cover
            case .remove: t.artworkKey = nil
            case nil: break
            }
            var history = TagHistoryEntry(id: nil, trackId: id, editedAt: .now,
                previous: ["__cueTrack": previous, "__cueOverride": previousOverride?.base64EncodedString() ?? ""], fileBackupPath: nil)
            try history.insert(db)
            try t.update(db)
            try db.execute(sql: "INSERT OR REPLACE INTO cueTagOverride (trackId, metadata) VALUES (?, ?)",
                           arguments: [id, try JSONEncoder().encode(t)])
        }
    }

    /// Every write re-serialises all tags, and SFBAudioEngine drops ID3v2 dates that aren't full timestamps
    /// (a year read back from ID3v2.3 is just "2012"). Normalise before each write so no edit erases the year.
    public static func protectDate(in file: AudioFile) {
        guard usesID3v2(file.url), let date = file.metadata.releaseDate, !date.isEmpty else { return }
        file.metadata.releaseDate = id3Timestamp(date)
    }

    /// Formats whose tags SFBAudioEngine writes as ID3v2.
    static func usesID3v2(_ url: URL) -> Bool {
        ["mp3", "wav", "wave", "aif", "aiff", "aifc", "dsf", "dff", "tta"].contains(url.pathExtension.lowercased())
    }

    /// SFBAudioEngine 0.14 validates ID3v2 dates with a default NSISO8601DateFormatter, which only accepts
    /// full timestamps; "2012" or "2018-08-27" are silently dropped (and the old date removed). It then takes
    /// the year in the *local* time zone, so midnight UTC on 1 January becomes the previous year west of UTC.
    /// Noon UTC stays on the same calendar day from UTC−12 to UTC+11. (TagLib saves WAV/AIFF as ID3v2.3,
    /// so only the year is kept there; MP3 keeps the full date.)
    static func id3Timestamp(_ date: String) -> String {
        let d = date.trimmingCharacters(in: .whitespaces)
        if d.range(of: #"^\d{4}$"#, options: .regularExpression) != nil { return d + "-01-01T12:00:00Z" }
        if d.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil { return d + "-01T12:00:00Z" }
        if d.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return d + "T12:00:00Z" }
        return d
    }

    /// String snapshot of every tag (pictures excluded) for undo.
    static func snapshot(_ md: AudioMetadata) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in md.dictionaryRepresentation where key != .attachedPictures {
            if let s = value as? String { out[key.rawValue] = s }
            else if let n = value as? NSNumber { out[key.rawValue] = n.stringValue }
        }
        return out
    }

    /// APFS clone of the file before writing (free on the same volume). Returns nil across volumes.
    /// Whether the file itself can be rewritten (false on a share mounted read-only).
    public static func isWritable(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { $0.map { access($0, W_OK) == 0 } ?? false }
    }

    /// Network shares added read-only. Their files are never rewritten, however the share is mounted: Vespertine
    /// reuses a mount that's already there (Finder's, or one shared with a writable source), which may be read-write.
    public static func readOnlyShares(_ sources: [LibrarySource]) -> Set<Int64> {
        Set(sources.filter { $0.isNetwork && !$0.isWritable }.compactMap(\.id))
    }

    /// After SFBAudioEngine's save: puts back the values of multi-valued fields it cut to one (fields the edit set
    /// are left as edited), and removes custom tags the edit deleted, which its writer leaves in the file.
    static func keepEveryValue(_ multiValued: OpaquePointer?, of url: URL, edit: TagEdit) throws {
        let edited = edit.fields.keys.flatMap(\.propertyNames) + edit.custom.keys.map { $0.uppercased() }
        let removed = edit.custom.filter { $0.value == nil }.map { $0.key.uppercased() }
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            if let multiValued, nvt_multivalued_count(multiValued) > 0 {
                let restored = withCStrings(edited) { nvt_multivalued_restore(multiValued, path, $0, Int32(edited.count)) }
                guard restored >= 0 else { throw TagWriteError.valuesNotKept }
            }
            for key in removed where nvt_property_set(path, key, nil, 0) != 0 { throw TagWriteError.valuesNotKept }
        }
    }

    private static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>>?) -> R) -> R {
        let copies = strings.compactMap { strdup($0) }
        defer { copies.forEach { free($0) } }
        return copies.map { UnsafePointer($0) }.withUnsafeBufferPointer { body($0.baseAddress) }
    }

    private func makeBackup(of url: URL) throws -> URL {
        let day = ISO8601DateFormatter.string(from: .now, timeZone: .current, formatOptions: [.withFullDate])
        let dir = backupDirectory.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        let status = url.withUnsafeFileSystemRepresentation { src in
            dest.withUnsafeFileSystemRepresentation { dst in clonefile(src!, dst!, 0) }
        }
        if status != 0 {
            // Not a free clone (another volume, a share): a full copy. Make room within the budget, and never let
            // backups take the last of the disk.
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            pruneBackups(making: size)
            // Pruning removes day folders left empty, today's (made above, still empty) among them.
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard freeSpace(at: backupDirectory) >= size + Self.backupFreeSpaceReserve else { throw TagWriteError.noRoomForBackup }
            try FileManager.default.copyItem(at: url, to: dest)
        }
        return dest
    }

    private func freeSpace(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        // "Important usage" can read 0 on some volumes; fall back to the plain figure.
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }

    private static func fileHash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A clone of `url` beside it to write the tags into, or nil where the volume can't clone (shares, non-APFS disks):
    /// those are written in place, since copying a large file for every edit would be slow. Writing into a clone
    /// means a crash or a full disk mid-write leaves the original whole, and a song that's playing goes on reading the
    /// file it opened instead of one being rewritten under it.
    static func editingClone(of url: URL) -> URL? {
        let clone = url.deletingLastPathComponent().appendingPathComponent(".vespertine-edit-\(UUID().uuidString).\(url.pathExtension)")
        let status = url.withUnsafeFileSystemRepresentation { src in
            clone.withUnsafeFileSystemRepresentation { dst in clonefile(src!, dst!, UInt32(CLONE_NOFOLLOW)) }
        }
        guard status == 0 else { return nil }
        // The clone gets the file's dates and permissions, but its creation date is today's: keep the file's own.
        if let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate {
            var values = URLResourceValues()
            values.creationDate = created
            var target = clone
            try? target.setResourceValues(values)
        }
        return clone
    }

    /// Puts the edited clone in the file's place, in one step.
    private static func move(_ clone: URL, over url: URL) throws {
        let status = clone.withUnsafeFileSystemRepresentation { src in
            url.withUnsafeFileSystemRepresentation { dst in rename(src!, dst!) }
        }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func restore(_ backup: URL, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".vespertine-restore-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: backup, to: temporary)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    /// The most space tag backups may take. Past it the oldest go first; an edit whose backup is gone can still be
    /// undone from the tags recorded with it (all but artwork and custom tags).
    public static let backupBudget: Int64 = 5 * 1_073_741_824
    /// Free space a full-copy backup must leave on its volume.
    static let backupFreeSpaceReserve: Int64 = 2 * 1_073_741_824

    /// Deletes backups no edit refers to once they're older than `days`, then the oldest of the rest until they fit
    /// in `backupBudget` with room for `making` more bytes. An edit whose backup goes keeps its recorded tags.
    public func pruneBackups(olderThan days: Int = 30, making needed: Int64 = 0) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let keys: [URLResourceKey] = [.creationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: backupDirectory, includingPropertiesForKeys: keys),
              let recorded = try? database.writer.read({ db in
                  try String.fetchAll(db, sql: "SELECT fileBackupPath FROM tagHistory WHERE fileBackupPath IS NOT NULL")
              })
        else { return }
        // By resolved path, as recorded (the enumerator may spell a path through /private, say).
        let resolved = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let referenced = Dictionary(recorded.map { (resolved($0), $0) }, uniquingKeysWith: { first, _ in first })
        var files: [(url: URL, created: Date, size: Int64, recordedAs: String?)] = []
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            files.append((url, v.creationDate ?? .now, Int64(v.totalFileAllocatedSize ?? 0), referenced[resolved(url.path)]))
        }
        files.sort { $0.created < $1.created }
        var total = files.reduce(0) { $0 + $1.size }
        var orphaned: [String] = []
        for file in files {
            let stale = file.recordedAs == nil && file.created < cutoff
            guard stale || total + needed > Self.backupBudget else { continue }
            guard (try? FileManager.default.removeItem(at: file.url)) != nil else { continue }
            total -= file.size
            if let path = file.recordedAs { orphaned.append(path) }
        }
        if !orphaned.isEmpty {
            _ = try? database.writer.write { db in
                for path in orphaned {
                    try db.execute(sql: "UPDATE tagHistory SET fileBackupPath = NULL WHERE fileBackupPath = ?", arguments: [path])
                }
            }
        }
        // Day folders left empty.
        for dir in (try? FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)) ?? []
        where (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

public extension TagWriter {
    /// Writes an enrichment proposal: its field edits, plus the cover on every track that has no artwork.
    func apply(_ proposal: EnrichmentProposal, tracks: [Track]) async throws -> TagWriteResult {
        var total = TagWriteResult(written: 0, databaseOnly: 0, failures: [])
        for track in tracks {
            guard let id = track.id else { continue }
            var edit = proposal.edits[id] ?? TagEdit()
            if let cover = proposal.cover, track.artworkKey == nil { edit.artwork = .replace(cover) }
            guard !edit.isEmpty else { continue }
            let r = try await apply(edit, to: [track])
            total.written += r.written
            total.databaseOnly += r.databaseOnly
            total.failures += r.failures
        }
        return total
    }
}

private enum TagWriteError: LocalizedError {
    case invalidNumber(String), fileChanged, valuesNotKept, noRoomForBackup
    var errorDescription: String? {
        switch self {
        case .invalidNumber(let field): "\(field) must be a nonnegative whole number or blank."
        case .noRoomForBackup: "There isn't enough free space for a backup of this file, so its tags weren't changed. Free some space and try again."
        case .valuesNotKept: "The tags couldn't be saved with every value of fields that have several (artists, genres), so the file was left as it was."
        case .fileChanged: "This file changed after the last tag edit. Undo was stopped to preserve the newer file; its earlier backup is still available."
        }
    }
}
