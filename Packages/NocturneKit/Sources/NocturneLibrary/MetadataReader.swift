//
// Nocturne — reads technical properties and tags into Track records.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import NocturneAudio
import SFBAudioEngine

public enum MetadataReader {
    static let lossyCodecs: Set<String> = ["MP3", "AAC", "Vorbis", "Opus", "Musepack", "Speex"]

    /// Reads one file. `artwork` receives the embedded (or folder) cover.
    public static func read(url: URL, artwork: ArtworkStore?) throws -> Track {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
        let props = file.properties
        let md = file.metadata

        let inspected = try? SourceInspector.inspect(url)
        let format = inspected?.format
        let codec = format?.codec ?? (props.formatName ?? url.pathExtension.uppercased())
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
            if let data = front?.imageData { artworkKey = artwork.store(data) }
            else if let data = ArtworkStore.folderImage(near: url) { artworkKey = artwork.store(data) }
        }

        let title = md.title.flatMap(nonEmpty) ?? url.deletingPathExtension().lastPathComponent
        return Track(
            id: nil, sourceId: nil,
            location: url.path, filePath: url.path,
            fileSize: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate ?? .now, addedAt: .now,
            codec: codec, isLossless: isLossless, isDSD: isDSD,
            sampleRate: format?.sampleRate ?? props.sampleRate ?? 0,
            bitDepth: isDSD ? nil : (format?.bitDepth ?? (isLossless ? props.bitDepth : nil)),
            channels: format?.channels ?? Int(props.channelCount ?? 2),
            duration: props.duration ?? 0, bitrate: props.bitrate,
            cueStartFrame: nil, cueFrameLength: nil,
            title: title,
            artist: md.artist.flatMap(nonEmpty), album: md.albumTitle.flatMap(nonEmpty),
            albumArtist: md.albumArtist.flatMap(nonEmpty), composer: md.composer.flatMap(nonEmpty),
            genre: md.genre.flatMap(nonEmpty), releaseDate: md.releaseDate.flatMap(nonEmpty),
            year: md.releaseDate.flatMap(year(from:)),
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

    static func year(from date: String) -> Int? {
        let digits = date.prefix(4)
        guard digits.count == 4, let y = Int(digits), y > 1000 else { return nil }
        return y
    }
}
