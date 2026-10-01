//
// Vespertine — reads technical properties and tags into Track records.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio
import SFBAudioEngine

public enum MetadataReader {
    static let lossyCodecs: Set<String> = ["MP3", "AAC", "Vorbis", "Opus", "Musepack", "Speex"]

    /// Reads one file. `artwork` receives the embedded (or folder) cover. `original` is the real
    /// file when `url` is a local stand-in for it (see RemoteMetadata); folder art is looked up there.
    public static func read(url: URL, artwork: ArtworkStore?, folderArt: FolderArtCache? = nil, original: URL? = nil) throws -> Track {
        let home = original ?? url
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        // Bare Dolby streams (.ac3/.ec3) have no tag format: take what the decoder knows and the file name.
        let file: AudioFile?
        do { file = try AudioFile(readingPropertiesAndMetadataFrom: url) }
        catch { guard SourceInspector.untaggedExtensions.contains(url.pathExtension.lowercased()) else { throw error }; file = nil }
        let props = file?.properties
        let md = file?.metadata ?? containerMetadata(url)

        let inspected = try? SourceInspector.inspectWithDuration(url)
        let format = inspected?.format
        let codec = format?.codec ?? (props?.formatName ?? url.pathExtension.uppercased())
        let isDSD = format?.encoding == .dsd
        let isLossless = format.map { $0.encoding != .lossy } ?? !lossyCodecs.contains(codec)

        var extra: [String: String] = [:]
        if let additional = md.additionalMetadata as? [String: Any] {
            for (k, v) in additional { extra[k.uppercased()] = "\(v)" }
        }
        // MP3: the tag reader passes on only the common ID3 fields; read the others ourselves.
        if url.pathExtension.lowercased() == "mp3" || home.pathExtension.lowercased() == "mp3" {
            for (k, v) in ID3Extras.read(url) where extra[k] == nil { extra[k] = v }
        }
        if url.pathExtension.lowercased() == "dsf" || home.pathExtension.lowercased() == "dsf" {
            for (k, v) in ID3Extras.readDSF(url) where extra[k] == nil { extra[k] = v }
        }
        // Readers that drop the ID3 date (DSF) still have it here; a date with no year in it counts as none.
        let releaseDate = md.releaseDate.flatMap(nonEmpty).flatMap { year(from: $0) != nil ? $0 : nil } ?? extra["DATE"]
        let label = extra["LABEL"] ?? extra["ORGANIZATION"] ?? extra["PUBLISHER"]

        var artworkKey: String?
        if let artwork {
            let pictures = md.attachedPictures
            let front = pictures.first { $0.type == .frontCover } ?? pictures.first
            if let data = front?.imageData ?? CommentPictures.flacCover(at: url) { artworkKey = artwork.store(data) }
            else if let folderArt { artworkKey = folderArt.artworkKey(near: home, store: artwork) }
            else if let data = ArtworkStore.folderImage(near: home) { artworkKey = artwork.store(data) }
        }

        // Files that can't hold tags (bare Dolby, DTS and TrueHD streams): the file name gives the title, and the
        // artist and number when it has them; the folder gives the album, so they don't all pile into one
        // "Unknown Album". Taggable files that nobody tagged stay as they are so enrichment offers to tag them.
        let untagged = file == nil && md.title.flatMap(nonEmpty) == nil && md.albumTitle.flatMap(nonEmpty) == nil
        let inferred = untagged ? FilenameParser.parse(home) : nil
        // DTS CDs sit in a PCM file whose bitrate (1411k) is the carrier's, not the DTS stream's.
        let dtsInPCM = codec == "DTS" && ["wav", "flac"].contains(home.pathExtension.lowercased())
        let title = md.title.flatMap(nonEmpty) ?? inferred.flatMap { nonEmpty($0.title) } ?? url.deletingPathExtension().lastPathComponent
        return Track(
            id: nil, sourceId: nil,
            location: url.path, filePath: url.path,
            fileSize: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate ?? .now, addedAt: .now,
            codec: codec, isLossless: isLossless, isDSD: isDSD,
            sampleRate: format?.sampleRate ?? props?.sampleRate ?? 0,
            bitDepth: isDSD ? nil : (format?.bitDepth ?? (isLossless ? props?.bitDepth : nil)),
            channels: format?.channels ?? Int(props?.channelCount ?? 2),
            duration: props?.duration ?? inspected?.duration ?? 0, bitrate: dtsInPCM ? nil : props?.bitrate,
            cueStartFrame: nil, cueFrameLength: nil,
            title: title,
            artist: md.artist.flatMap(nonEmpty) ?? inferred?.artist,
            album: md.albumTitle.flatMap(nonEmpty) ?? inferred?.album ?? (untagged ? albumFolder(of: home) : nil),
            albumArtist: md.albumArtist.flatMap(nonEmpty), composer: md.composer.flatMap(nonEmpty),
            genre: md.genre.flatMap(nonEmpty), releaseDate: releaseDate.map(displayDate),
            year: originalYear(extra, releaseYear: releaseDate.flatMap(year(from:))),
            // A number of 0 is no number. Missing numbers come from the file name ("… - 05 - Title", "05 Title"),
            // a missing disc from a numbered disc folder ("CD 02"), so albums with incomplete tags still list in order.
            trackNumber: md.trackNumber.flatMap { $0 > 0 ? $0 : nil } ?? inferred?.trackNumber ?? Self.trackNumber(fromFileName: home),
            trackTotal: md.trackTotal,
            discNumber: md.discNumber.flatMap { $0 > 0 ? $0 : nil } ?? ArtworkStore.discNumber(fromFolder: home.deletingLastPathComponent().lastPathComponent),
            discTotal: md.discTotal,
            compilation: md.isCompilation ?? false,
            grouping: md.grouping.flatMap(nonEmpty), comment: md.comment.flatMap(nonEmpty),
            lyrics: md.lyrics.flatMap(nonEmpty), bpm: md.bpm, rating: md.rating,
            isrc: md.isrc.flatMap(nonEmpty), label: label,
            musicBrainzReleaseID: md.musicBrainzReleaseID.flatMap(nonEmpty),
            musicBrainzRecordingID: md.musicBrainzRecordingID.flatMap(nonEmpty),
            titleSort: md.titleSortOrder.flatMap(nonEmpty), artistSort: md.artistSortOrder.flatMap(nonEmpty),
            albumSort: md.albumTitleSortOrder.flatMap(nonEmpty), albumArtistSort: md.albumArtistSortOrder.flatMap(nonEmpty),
            extraTags: extra,
            rgTrackGain: md.replayGainTrackGain, rgTrackPeak: md.replayGainTrackPeak,
            rgAlbumGain: md.replayGainAlbumGain, rgAlbumPeak: md.replayGainAlbumPeak,
            artworkKey: artworkKey, playCount: 0, lastPlayedAt: nil, isMissing: false,
            effectiveBitDepth: nil, bandwidthHz: nil, analysisVerdict: nil)
    }

    /// A track number written into a file name in a way that can't be mistaken for part of a name: zero-padded
    /// ("05 Title", "05. Title"), followed by a separator ("5. Title", "5 - Title"), or between dashes
    /// ("Artist - Album - 05 - Title"). "50 Cent - In da Club" has none.
    static func trackNumber(fromFileName url: URL) -> Int? {
        let name = url.deletingPathExtension().lastPathComponent
        for pattern in [#"^0(\d{1,2})(?=\D)"#, #"^(\d{1,3})(?=\.\s| - |\.\D)"#, #" - (\d{1,3}) - "#] {
            guard let r = name.range(of: pattern, options: .regularExpression) else { continue }
            if let n = Int(name[r].filter(\.isNumber)), n > 0 { return n }
        }
        return nil
    }

    /// The folder a file sits in, or the one above for a disc folder ("CD 2").
    static func albumFolder(of url: URL) -> String? {
        var dir = url.deletingLastPathComponent()
        if ArtworkStore.isDiscFolder(dir.lastPathComponent) { dir = dir.deletingLastPathComponent() }
        let name = dir.lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// "2018-08-27T12:00:00Z" (written for ID3v2, see TagWriter.id3Timestamp) → "2018-08-27".
    static func displayDate(_ date: String) -> String {
        for suffix in ["T12:00:00Z", "T00:00:00Z"] where date.hasSuffix(suffix) { return String(date.dropLast(suffix.count)) }
        return date
    }

    /// Tags holding the original release date (MusicBrainz Picard / Lidarr / foobar2000 spellings).
    /// `ORIGDATE` is left out: in WAV files it's the broadcast-wave recording timestamp.
    static let originalDateKeys = ["ORIGINALDATE", "ORIGINALYEAR", "ORIGINAL DATE", "ORIGINAL YEAR"]

    /// The year an album first came out: the original-date tag when there is one (reissues and
    /// remasters carry their own date in DATE), else the release date's year.
    static func originalYear(_ extra: [String: String], releaseYear: Int?) -> Int? {
        let original = originalDateKeys.lazy.compactMap { extra[$0] }.compactMap(year(from:)).first
        guard let original else { return releaseYear }
        if let releaseYear, original > releaseYear { return releaseYear }   // an original can't be later
        return original
    }

    /// Tags from containers the tag reader doesn't know (Matroska, via FFmpeg).
    static func containerMetadata(_ url: URL) -> AudioMetadata {
        let md = AudioMetadata()
        let tags = SourceInspector.containerTags(url)
        md.title = tags["title"]
        md.artist = tags["artist"]
        md.albumArtist = tags["album_artist"]
        md.albumTitle = tags["album"]
        md.releaseDate = tags["date"]
        md.genre = tags["genre"]
        md.composer = tags["composer"]
        if let track = tags["track"] {
            let parts = track.split(separator: "/")
            md.trackNumber = parts.first.flatMap { Int($0) }
            if parts.count > 1 { md.trackTotal = Int(parts[1]) }
        }
        if let disc = tags["disc"] { md.discNumber = disc.split(separator: "/").first.flatMap { Int($0) } }
        return md
    }

    static func year(from date: String) -> Int? {
        let digits = date.prefix(4)
        guard digits.count == 4, let y = Int(digits), y > 1000 else { return nil }
        return y
    }
}
