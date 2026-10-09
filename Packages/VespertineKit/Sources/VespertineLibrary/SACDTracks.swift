//
// Vespertine — an SACD image as library tracks: every track of its stereo area and of its multichannel area,
// tagged from the disc's own text. The two areas' tracks share titles and numbers, so each song lists once
// with a stereo and a surround version (TrackVersions).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

enum SACDTracks {
    /// The tracks of an SACD image; [] for a disc image that isn't an SACD (a DVD, an installer).
    /// `size` and `modified` come from a listing when there is one (a network share).
    static func read(url: URL, artwork: ArtworkStore?, folderArt: FolderArtCache? = nil,
                     size: Int64? = nil, modified: Date? = nil) throws -> [Track] {
        guard SACDImage.isSACD(url) else { return [] }
        let image = try SACDImage.read(url)
        var fileSize = size, date = modified
        if fileSize == nil || date == nil {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            fileSize = fileSize ?? Int64(values.fileSize ?? 0)
            date = date ?? values.contentModificationDate ?? .now
        }
        var artworkKey: String?
        if let artwork {
            if let folderArt { artworkKey = folderArt.artworkKey(near: url, store: artwork) }
            else if let data = ArtworkStore.folderImage(near: url) { artworkKey = artwork.store(data) }
        }
        let albumArtist = image.albumArtist ?? image.discArtist
        // An image without disc text is named by its file ("Kind of Blue (SACD).iso").
        let album = image.albumTitle ?? image.discTitle ?? url.deletingPathExtension().lastPathComponent
        var extra: [String: String] = [:]
        if let catalog = image.catalogNumber { extra["CATALOGNUMBER"] = catalog }
        if let copyright = image.albumCopyright { extra["COPYRIGHT"] = copyright }
        return image.areas.flatMap { area in
            area.tracks.map { t in
                var tags = extra
                if let arranger = t.arranger { tags["ARRANGER"] = arranger }
                if let songwriter = t.songwriter, songwriter != t.composer { tags["SONGWRITER"] = songwriter }
                return Track(
                    id: nil, sourceId: nil,
                    location: SACDArea.location(path: url.path, area: area.kind, track: t.number), filePath: url.path,
                    fileSize: fileSize ?? 0, modifiedAt: date ?? .now, addedAt: .now,
                    codec: "SACD", isLossless: true, isDSD: true, sampleRate: area.sampleRate, bitDepth: nil, channels: area.channels,
                    duration: Double(t.frameCount) / Double(SACDImage.framesPerSecond), bitrate: nil,
                    // The track's stretch of its area, in DSD samples (whole frames of 1/75 s).
                    cueStartFrame: Int64(t.startFrame) * area.samplesPerFrame, cueFrameLength: Int64(t.frameCount) * area.samplesPerFrame,
                    title: t.title ?? "Track \(t.number)",
                    artist: t.performer ?? albumArtist, album: album, albumArtist: albumArtist,
                    composer: t.composer ?? t.songwriter, genre: t.genre ?? image.genre,
                    releaseDate: image.releaseDate, year: image.year,
                    trackNumber: t.number, trackTotal: area.tracks.count,
                    discNumber: image.discNumber, discTotal: image.discTotal,
                    compilation: false, grouping: nil, comment: t.message, lyrics: nil, bpm: nil, rating: nil,
                    isrc: t.isrc, label: image.albumPublisher,
                    musicBrainzReleaseID: nil, musicBrainzRecordingID: nil,
                    titleSort: nil, artistSort: nil, albumSort: nil, albumArtistSort: nil,
                    extraTags: tags,
                    rgTrackGain: nil, rgTrackPeak: nil, rgAlbumGain: nil, rgAlbumPeak: nil,
                    artworkKey: artworkKey, playCount: 0, lastPlayedAt: nil, isMissing: false,
                    effectiveBitDepth: nil, bandwidthHz: nil, analysisVerdict: nil)
            }
        }
    }
}
