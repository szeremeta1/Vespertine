//
// Vespertine — fills in missing metadata: from structured file names, then MusicBrainz + Cover Art Archive.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

// MARK: - File names

/// Tags inferred from a file name such as "Artist - Album - 01 Title.wav".
public struct InferredTags: Sendable, Hashable {
    public var artist: String?
    public var album: String?
    public var trackNumber: Int?
    public var title: String
}

public enum FilenameParser {
    /// Technical noise that is not part of a title.
    static let noise = [
        #"\[[A-Za-z0-9_-]{11}\]"#,                       // YouTube IDs
        #"\[TubeRipper\.cc\]"#,
        #"\((Official( Music)? (Audio|Video)|Audio|Lyric Video|HQ|HD)\)"#,
        #"\b(AI[ _-])?Enhanced\b"#,
        #"\b(16|24|32)[ _-]?bit\b"#,
        #"\b\d{2,3}(\.\d)?[ _-]?kHz\b"#,
    ]

    public static func parse(_ url: URL) -> InferredTags {
        var name = url.deletingPathExtension().lastPathComponent
        // Underscore-only names ("Childish_Gambino_-_Do_Ya_Like") use _ for spaces.
        if !name.contains(" ") && name.contains("_") { name = name.replacingOccurrences(of: "_", with: " ") }
        for pattern in noise {
            name = name.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        name = name.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_."))

        let parts = name.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        func splitNumber(_ s: String) -> (Int?, String) {
            // "01 Title", "01. Title", "01-Title", "1) Title"
            guard let r = s.range(of: #"^(\d{1,3})[\s.\-)_]+"#, options: .regularExpression) else { return (nil, s) }
            let digits = s[r].filter(\.isNumber)
            return (Int(digits), String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces))
        }

        switch parts.count {
        case 0:
            return InferredTags(title: url.deletingPathExtension().lastPathComponent)
        case 1:
            let (n, t) = splitNumber(parts[0])
            return InferredTags(trackNumber: n, title: t.isEmpty ? parts[0] : t)
        case 2:
            // "NN - Title", "NN. Artist - Title" or "Artist - Title"
            if let n = Int(parts[0]), parts[0].count <= 3 { return InferredTags(trackNumber: n, title: parts[1]) }
            let (leading, artist) = splitNumber(parts[0])
            let (n, t) = splitNumber(parts[1])
            return InferredTags(artist: artist, trackNumber: leading ?? n, title: t)
        default:
            // "Artist - Album - NN Title", "Artist - NN - Title", or "Artist - Album - Title"
            let artist = parts[0]
            if let n = Int(parts[1]), parts[1].count <= 3 {
                return InferredTags(artist: artist, trackNumber: n, title: parts[2...].joined(separator: " - "))
            }
            let (n, t) = splitNumber(parts[2...].joined(separator: " - "))
            return InferredTags(artist: artist, album: parts[1], trackNumber: n, title: t)
        }
    }
}

// MARK: - Proposals

public struct EnrichmentProposal: Sendable, Identifiable {
    public enum Source: Sendable, Hashable {
        case fileNames
        case musicBrainz(score: Int, releaseID: String)
    }

    public var id: String { albumKey }
    public var albumKey: String
    public var title: String          // proposed album (or track) title
    public var artist: String
    public var year: String?
    public var sources: [Source]
    /// Track ID → edit (only fields that change).
    public var edits: [Int64: TagEdit]
    public var cover: Data?
    /// Safe to apply without review.
    public var isHighConfidence: Bool
    public var summary: String         // e.g. "Fills artist, album, track numbers · adds cover art"

    public var changeCount: Int { edits.values.reduce(0) { $0 + $1.fields.count } + (cover == nil ? 0 : 1) }
}

public actor MetadataEnricher {
    let database: LibraryDatabase
    let musicBrainz: MusicBrainzClient
    /// Replace existing tags when MusicBrainz is confident (off = fill gaps only).
    public var correctExisting = false

    public init(database: LibraryDatabase, musicBrainz: MusicBrainzClient = .shared) {
        self.database = database
        self.musicBrainz = musicBrainz
    }

    public func setCorrectExisting(_ value: Bool) { correctExisting = value }

    /// Albums (or loose tracks) that are missing something worth fixing.
    public nonisolated static func needsEnrichment(_ tracks: [Track]) -> Bool {
        tracks.contains { t in
            t.artist == nil || t.album == nil || t.year == nil || t.trackNumber == nil || t.artworkKey == nil
                || t.title == t.fileURL.deletingPathExtension().lastPathComponent
        }
    }

    /// Builds a proposal for one album's tracks. Network lookups are rate-limited by MusicBrainzClient.
    public func propose(albumKey: String, tracks: [Track], lookUpOnline: Bool = true) async -> EnrichmentProposal? {
        guard !tracks.isEmpty else { return nil }
        var working = tracks
        var sources: [EnrichmentProposal.Source] = []
        var edits: [Int64: [TagField: String?]] = [:]

        func set(_ field: TagField, _ value: String?, on track: Track, replacing: Bool = false) {
            guard let id = track.id, let value, !value.isEmpty else { return }
            let current = field.value(in: track)
            guard current != value else { return }   // no-op
            let untitled = field == .title && current == track.fileURL.deletingPathExtension().lastPathComponent
            // A date that doesn't yield a plausible year (e.g. "0001-01-01") counts as missing.
            let invalidDate = field == .releaseDate && current != nil && MetadataReader.year(from: current!) == nil
            guard current == nil || current?.isEmpty == true || untitled || invalidDate || (replacing && current != value) else { return }
            edits[id, default: [:]][field] = value
        }

        // 1. File names, for tracks whose tags are missing.
        var usedFileNames = false
        for (i, track) in working.enumerated() where track.cueStartFrame == nil {
            let untitled = track.title == track.fileURL.deletingPathExtension().lastPathComponent
            guard untitled || track.artist == nil || track.album == nil || track.trackNumber == nil else { continue }
            let inferred = FilenameParser.parse(track.fileURL)
            let before = edits.count
            set(.title, inferred.title, on: track)
            set(.artist, inferred.artist, on: track)
            set(.albumArtist, inferred.artist, on: track)
            set(.album, inferred.album, on: track)
            set(.trackNumber, inferred.trackNumber.map(String.init), on: track)
            if edits.count != before || edits[track.id ?? -1] != nil { usedFileNames = true }
            // Continue with the inferred values so the online lookup can use them.
            if untitled { working[i].title = inferred.title }
            working[i].artist = working[i].artist ?? inferred.artist
            working[i].albumArtist = working[i].albumArtist ?? inferred.artist
            working[i].album = working[i].album ?? inferred.album
            working[i].trackNumber = working[i].trackNumber ?? inferred.trackNumber
        }
        if usedFileNames { sources.append(.fileNames) }

        // 2. MusicBrainz.
        var cover: Data?
        var highConfidence = !usedFileNames || working.allSatisfy { $0.artist != nil && $0.album != nil }
        var year = working.compactMap(\.year).first.map(String.init)
        let artist = working.first?.albumArtist ?? working.first?.artist
        let album = working.first?.album
        let needsOnline = working.contains { $0.year == nil || $0.artworkKey == nil || $0.album == nil || $0.musicBrainzReleaseID == nil }
            || working.contains { $0.releaseDate.map { MetadataReader.year(from: $0) == nil } ?? false }

        if lookUpOnline, needsOnline, let artist {
            var release: MBRelease?
            var score = 0
            if let knownID = working.compactMap(\.musicBrainzReleaseID).first,
               let exact = try? await musicBrainz.release(id: knownID) {
                // Already tagged with a MusicBrainz release (e.g. by Picard): use that exact release.
                release = exact
                score = 100
            } else if let album {
                // Prefer releases long enough to contain our highest track number, then the best score,
                // then the track count closest to the album's (known total, else what we have).
                let needed = working.compactMap(\.trackNumber).max() ?? 0
                let expected = working.compactMap(\.trackTotal).max() ?? working.count
                let candidates = ((try? await musicBrainz.searchReleases(artist: artist, album: album)) ?? []).filter { $0.score >= 80 }
                let fitting = candidates.filter { $0.trackCount >= needed }
                if let best = (fitting.isEmpty ? candidates : fitting).max(by: {
                    ($0.score, -abs($0.trackCount - expected)) < ($1.score, -abs($1.trackCount - expected))
                }) {
                    score = best.score
                    release = try? await musicBrainz.release(id: best.id)
                }
            } else if working.count == 1, let title = working.first?.title {
                // Loose single: find the recording, take its earliest release.
                if let hit = try? await musicBrainz.searchRecording(artist: artist, title: title), hit.score >= 90 {
                    score = hit.score
                    release = try? await musicBrainz.release(id: hit.releaseID)
                }
            }
            if let release {
                let corrected = correctExisting && score >= 95
                sources.append(.musicBrainz(score: score, releaseID: release.id))
                year = release.date.map { String($0.prefix(4)) } ?? year
                for (i, track) in working.enumerated() {
                    let match = release.tracks.first { $0.disc == (track.discNumber ?? 1) && $0.position == track.trackNumber }
                        ?? release.tracks.first { $0.title.caseInsensitiveCompare(track.title) == .orderedSame }
                        ?? (working.count == release.tracks.count ? release.tracks[i] : nil)
                    set(.album, release.title, on: track, replacing: corrected)
                    set(.albumArtist, release.artist, on: track, replacing: corrected)
                    set(.releaseDate, release.date, on: track)
                    // MusicBrainz uses "[no label]" / "[unknown]" as placeholders, not real labels.
                    set(.label, release.label.flatMap { $0.hasPrefix("[") ? nil : $0 }, on: track)
                    set(.genre, release.genre, on: track)
                    set(.musicBrainzReleaseID, release.id, on: track)
                    set(.discTotal, String(release.discCount), on: track)
                    if let match {
                        set(.title, match.title, on: track, replacing: corrected)
                        set(.artist, match.artist, on: track, replacing: corrected)
                        set(.trackNumber, String(match.position), on: track)
                        set(.trackTotal, String(release.tracks.filter { $0.disc == match.disc }.count), on: track)
                        set(.discNumber, String(match.disc), on: track)
                        set(.musicBrainzRecordingID, match.recordingID, on: track)
                    }
                }
                if working.contains(where: { $0.artworkKey == nil }) {
                    cover = try? await musicBrainz.frontCover(releaseID: release.id, releaseGroupID: release.releaseGroupID)
                }
                // Confident when the release scores highly and every track we have matches one on it by title
                // (a partial album is fine), or the track counts line up.
                let titlesMatch = working.allSatisfy { t in release.tracks.contains { $0.title.caseInsensitiveCompare(t.title) == .orderedSame } }
                highConfidence = score >= 95 && (titlesMatch || album == nil || abs(release.tracks.count - working.count) <= 1)
            } else {
                highConfidence = highConfidence && usedFileNames
            }
        }

        // A loose single with no album: the convention is to use its title as the album.
        if !sources.contains(where: { if case .musicBrainz = $0 { true } else { false } }),
           working.count == 1, let track = working.first, track.album == nil {
            set(.album, track.title, on: track)
            set(.albumArtist, track.artist, on: track)
        }

        guard !edits.isEmpty || cover != nil else { return nil }
        var parts: [String] = []
        let fields = Set(edits.values.flatMap(\.keys))
        let named: [(TagField, String)] = [(.title, "titles"), (.artist, "artists"), (.album, "album"), (.trackNumber, "track numbers"),
                                           (.releaseDate, "year"), (.genre, "genre"), (.label, "label"), (.musicBrainzReleaseID, "MusicBrainz IDs")]
        let filled = named.filter { fields.contains($0.0) }.map(\.1)
        if !filled.isEmpty { parts.append("Fills " + filled.joined(separator: ", ")) }
        if cover != nil { parts.append("adds cover art") }

        return EnrichmentProposal(
            albumKey: albumKey,
            title: edits.values.compactMap { $0[.album] ?? nil }.first ?? album ?? working.first?.title ?? "Untitled",
            artist: edits.values.compactMap { $0[.albumArtist] ?? nil }.first ?? artist ?? "Unknown Artist",
            year: year, sources: sources,
            edits: edits.mapValues { TagEdit(fields: $0) },
            cover: cover, isHighConfidence: highConfidence,
            summary: parts.joined(separator: " · "))
    }
}
