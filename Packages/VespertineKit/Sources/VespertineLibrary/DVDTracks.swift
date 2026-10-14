//
// Vespertine — a DVD-Video's LPCM music as library tracks: one album per title, a track per chapter, each a sample
// range of its VOB's LPCM run (exact, from the disc's 90 kHz time stamps). DVD-Video carries no artist or song text,
// so tracks are named by number and the album by the disc; edits stay in the library.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

enum DVDTracks {
    /// The tracks of a DVD-Video disc image or VIDEO_TS folder (listed by its VIDEO_TS.IFO). [] for anything that isn't
    /// a DVD-Video with LPCM (a movie with AC-3 sound, a DVD-Audio disc, another IFO of the folder); throws for a DVD
    /// that is damaged. `size` and `modified` come from a listing when there is one (a network share).
    static func read(url: URL, artwork: ArtworkStore?, folderArt: FolderArtCache? = nil,
                     size: Int64? = nil, modified: Date? = nil) throws -> [Track] {
        if url.pathExtension.lowercased() == "ifo", !DVDVideoVolume.isFolderEntry(url) { return [] }
        let disc: DVDVideoDisc
        do { disc = try DVDVideoDisc.read(url) } catch let error as DVDVideoError {
            switch error {
            case .notDVDVideo, .dvdAudioOnly, .unsupportedAudio: return []
            case .damaged: throw error
            }
        }
        var fileSize = size, date = modified
        if fileSize == nil || date == nil {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            fileSize = fileSize ?? Int64(values.fileSize ?? 0)
            date = date ?? values.contentModificationDate ?? .now
        }
        // The disc's name: the image's, or the folder holding VIDEO_TS ("… Audio-DVD/VIDEO_TS/VIDEO_TS.IFO").
        let discName: String = disc.volume.isImage ? url.deletingPathExtension().lastPathComponent
            : url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let coverNear = disc.volume.isImage ? url : url.deletingLastPathComponent()
        var artworkKey: String?
        if let artwork {
            if let folderArt { artworkKey = folderArt.artworkKey(near: coverNear, store: artwork) }
            else if let data = ArtworkStore.folderImage(near: coverNear) { artworkKey = artwork.store(data) }
        }
        let several = disc.albums.count > 1
        var index = 0
        return disc.albums.flatMap { album in
            // A disc holding several titles holds several albums (often by different artists): each title its own.
            let name = !several ? discName
                : album.title == 0 ? String(localized: "\(discName) · Other cells", comment: "Album of a DVD's cells no title plays.")
                : String(localized: "\(discName) · Title \(album.title)", comment: "Album name for one title of a DVD-Video: the disc's name and the title number.")
            return album.tracks.map { t in
                index += 1
                let f = t.run.format
                return Track(
                    id: nil, sourceId: nil,
                    location: t.ref.location(path: url.path, track: index), filePath: url.path,
                    fileSize: fileSize ?? 0, modifiedAt: date ?? .now, addedAt: .now,
                    codec: "LPCM", isLossless: true, isDSD: false, sampleRate: Double(f.sampleRate), bitDepth: f.bits, channels: f.channels,
                    duration: t.duration, bitrate: Double(f.bits * f.sampleRate * f.channels) / 1000,
                    // The track's stretch of its run, in sample frames.
                    cueStartFrame: t.startFrame, cueFrameLength: t.frameCount,
                    title: String(localized: "Track \(t.number)", comment: "A DVD track's name before it's tagged."),
                    artist: nil, album: name, albumArtist: nil,
                    composer: nil, genre: nil, releaseDate: nil, year: nil,
                    trackNumber: t.number, trackTotal: album.tracks.count,
                    discNumber: nil, discTotal: nil,
                    compilation: false, grouping: nil, comment: nil, lyrics: nil, bpm: nil, rating: nil,
                    isrc: nil, label: nil,
                    musicBrainzReleaseID: nil, musicBrainzRecordingID: nil,
                    titleSort: nil, artistSort: nil, albumSort: nil, albumArtistSort: nil,
                    extraTags: ["DVD_TITLE": String(t.title), "DVD_CHAPTER": String(t.chapter),
                                "DVD_CELLS": t.cells.map { "\($0.vobID)/\($0.cellID)" }.joined(separator: " ")],
                    rgTrackGain: nil, rgTrackPeak: nil, rgAlbumGain: nil, rgAlbumPeak: nil,
                    artworkKey: artworkKey, playCount: 0, lastPlayedAt: nil, isMissing: false,
                    effectiveBitDepth: nil, bandwidthHz: nil, analysisVerdict: nil)
            }
        }
    }
}
