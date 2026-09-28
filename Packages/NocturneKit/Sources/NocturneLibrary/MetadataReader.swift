//
// Nocturne — reads technical properties and tags into Track records.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import NocturneAudio
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
        let label = extra["LABEL"] ?? extra["ORGANIZATION"] ?? extra["PUBLISHER"]

        var artworkKey: String?
        if let artwork {
            let pictures = md.attachedPictures
            let front = pictures.first { $0.type == .frontCover } ?? pictures.first
            if let data = front?.imageData ?? CommentPictures.flacCover(at: url) { artworkKey = artwork.store(data) }
            else if let folderArt { artworkKey = folderArt.artworkKey(near: home, store: artwork) }
            else if let data = ArtworkStore.folderImage(near: home) { artworkKey = artwork.store(data) }
        }

        let title = md.title.flatMap(nonEmpty) ?? url.deletingPathExtension().lastPathComponent
        return Track(
            id: nil, sourceId: nil,
            location: url.path, filePath: url.path,
            fileSize: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate ?? .now, addedAt: .now,
            codec: codec, isLossless: isLossless, isDSD: isDSD,
            sampleRate: format?.sampleRate ?? props?.sampleRate ?? 0,
            bitDepth: isDSD ? nil : (format?.bitDepth ?? (isLossless ? props?.bitDepth : nil)),
            channels: format?.channels ?? Int(props?.channelCount ?? 2),
            duration: props?.duration ?? inspected?.duration ?? 0, bitrate: props?.bitrate,
            cueStartFrame: nil, cueFrameLength: nil,
            title: title,
            artist: md.artist.flatMap(nonEmpty), album: md.albumTitle.flatMap(nonEmpty),
            albumArtist: md.albumArtist.flatMap(nonEmpty), composer: md.composer.flatMap(nonEmpty),
            genre: md.genre.flatMap(nonEmpty), releaseDate: md.releaseDate.flatMap(nonEmpty).map(displayDate),
            year: originalYear(extra, releaseYear: md.releaseDate.flatMap(year(from:))),
            trackNumber: md.trackNumber, trackTotal: md.trackTotal,
            discNumber: md.discNumber, discTotal: md.discTotal,
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
