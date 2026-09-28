//
// Nocturne — exports multichannel tracks for Spatial Audio listening elsewhere, fully tagged.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import NocturneAudio
import SFBAudioEngine

public enum SpatialExporter {
    public struct Result: Sendable {
        public var written: [URL] = []
        public var skipped: [String] = []   // not multichannel
        public var failures: [(path: String, message: String)] = []
    }

    /// Exports every multichannel track to `folder/Album Artist/Album/NN Title.m4a`, tagged like the
    /// original (cover included). Stereo tracks are skipped. `progress` gets (track index, 0…1).
    public static func export(_ tracks: [Track], kind: MultichannelExport.Kind, to folder: URL, artwork: ArtworkStore?,
                              progress: (@Sendable (Int, Double) -> Void)? = nil) -> Result {
        var result = Result()
        for (index, track) in tracks.enumerated() {
            guard track.channels > 2, track.isLossless, !track.isDSD else { result.skipped.append(track.title); continue }
            let artist = Importer.sanitize(track.albumArtist ?? track.artist ?? "Unknown Artist")
            let album = Importer.sanitize(track.album ?? "Singles")
            let dir = folder.appendingPathComponent(artist, isDirectory: true).appendingPathComponent(album, isDirectory: true)
            let disc = (track.discTotal ?? 1) > 1 ? track.discNumber.map { "\($0)-" } ?? "" : ""
            let number = track.trackNumber.map { String(format: "%02d ", $0) } ?? ""
            let name = Importer.sanitize(disc + number + track.title + kind.fileSuffix)
            let dest = dir.appendingPathComponent(name, isDirectory: false).appendingPathExtension("m4a")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let item = PlayableItem(url: track.fileURL, trackID: track.id, regionStartFrame: track.cueStartFrame,
                                        regionFrameLength: track.cueFrameLength)
                try MultichannelExport.export(item, kind: kind, to: dest) { progress?(index, $0) }
                try tag(dest, from: track, kind: kind, artwork: artwork)
                result.written.append(dest)
            } catch {
                result.failures.append((track.filePath, error.localizedDescription))
            }
        }
        return result
    }

    static func tag(_ url: URL, from t: Track, kind: MultichannelExport.Kind, artwork: ArtworkStore?) throws {
        let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
        let m = file.metadata
        m.title = t.title
        m.artist = t.artist
        m.albumTitle = t.album
        m.albumArtist = t.albumArtist
        m.composer = t.composer
        m.genre = t.genre
        m.releaseDate = t.releaseDate
        m.trackNumber = t.trackNumber
        m.trackTotal = t.trackTotal
        m.discNumber = t.discNumber
        m.discTotal = t.discTotal
        m.isCompilation = t.compilation
        m.musicBrainzReleaseID = t.musicBrainzReleaseID
        m.musicBrainzRecordingID = t.musicBrainzRecordingID
        m.comment = kind == .spatialStereo
            ? "Spatial Audio (binaural) rendered by Nocturne from \(ChannelLayouts.name(channels: t.channels))"
            : "\(ChannelLayouts.name(channels: t.channels)) lossless, exported by Nocturne"
        if let key = t.artworkKey, let artwork, let data = try? Data(contentsOf: artwork.originalURL(key)) {
            m.attachPicture(AttachedPicture(imageData: data, type: .frontCover))
        }
        try file.writeMetadata()
    }
}
