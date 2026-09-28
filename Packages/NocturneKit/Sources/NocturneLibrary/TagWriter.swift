//
// Nocturne — writes metadata into files (TagLib via SFBAudioEngine) with history and backups.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Darwin
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
        var result = TagWriteResult(written: 0, databaseOnly: 0, failures: [])
        var refreshIDs: [Int64] = []

        for track in tracks {
            guard let id = track.id else { continue }
            if track.cueStartFrame != nil {
                try await updateDatabaseOnly(track, edit: edit)
                result.databaseOnly += 1
                continue
            }
            let url = track.fileURL
            do {
                let file = try AudioFile(url: url)
                try file.readPropertiesAndMetadata()
                let previous = Self.snapshot(file.metadata)
                let backup = makeBackup(of: url)

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
                TagWriter.protectDate(in: file)
                try file.writeMetadata()

                try await database.writer.write { db in
                    var entry = TagHistoryEntry(id: nil, trackId: id, editedAt: .now, previous: previous, fileBackupPath: backup?.path)
                    try entry.insert(db)
                }
                refreshIDs.append(id)
                result.written += 1
            } catch {
                result.failures.append((url.path, error.localizedDescription))
            }
        }
        if !refreshIDs.isEmpty { try await scanner.refresh(trackIDs: refreshIDs) }
        return result
    }

    /// Restores the tags saved before the most recent edit of `trackID`.
    public func revertLastEdit(trackID: Int64) async throws -> Bool {
        let entry = try await database.writer.read { db in
            try TagHistoryEntry.filter(Column("trackId") == trackID).order(Column("editedAt").desc).fetchOne(db)
        }
        guard let entry, let track = try database.tracks(ids: [trackID]).first else { return false }
        let file = try AudioFile(url: track.fileURL)
        try file.readPropertiesAndMetadata()
        let pictures = file.metadata.attachedPictures
        let numericKeys: Set<AudioMetadata.Key> = [.trackNumber, .trackTotal, .discNumber, .discTotal, .BPM, .rating,
            .compilation, .replayGainReferenceLoudness, .replayGainTrackGain, .replayGainTrackPeak, .replayGainAlbumGain, .replayGainAlbumPeak]
        var dictionary: [AudioMetadata.Key: Any] = [:]
        for (raw, value) in entry.previous {
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
        var t = track
        for (field, value) in edit.fields {
            let s = value.flatMap { $0.isEmpty ? nil : $0 }
            let n = s.flatMap { Int($0) }
            switch field {
            case .title: t.title = s ?? t.title
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
            case .comment: t.comment = s
            case .grouping: t.grouping = s
            case .label: t.label = s
            default: break
            }
        }
        let updated = t
        try await database.writer.write { db in try updated.update(db) }
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
    private func makeBackup(of url: URL) -> URL? {
        let day = ISO8601DateFormatter.string(from: .now, timeZone: .current, formatOptions: [.withFullDate])
        let dir = backupDirectory.appendingPathComponent(day, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
        let status = url.withUnsafeFileSystemRepresentation { src in
            dest.withUnsafeFileSystemRepresentation { dst in clonefile(src!, dst!, 0) }
        }
        return status == 0 ? dest : nil
    }

    /// Deletes backups older than `days`.
    public func purgeBackups(olderThan days: Int = 30) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for dir in dirs {
            let created = (try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .now
            if created < cutoff { try? FileManager.default.removeItem(at: dir) }
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
