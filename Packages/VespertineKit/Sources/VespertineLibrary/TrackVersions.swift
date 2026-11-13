//
// Vespertine: one song in several versions on the same album (an SACD's stereo and 5.1 layers, a
// Blu-ray's stereo and surround mixes) or several copies (the same file twice, two editions): which tracks
// they are, and which one to play when the album's copies are bundled.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum TrackVersions {
    /// Which version plays when a song has a stereo and a multichannel one.
    public enum Preference: String, Sendable, CaseIterable, Identifiable {
        /// Multichannel on outputs that can play it (more than two channels, or Spatial Audio on), stereo elsewhere.
        case matchOutput
        case stereo
        case multichannel
        public var id: String { rawValue }
    }

    /// Tracks grouped into songs, album by album: a song's versions (stereo and 5.1) and its copies (the same song
    /// twice in one layout: a file in your own folder and the album on a share, a CD and an SACD layer, two editions
    /// with one title) are one song, matched across the album's copies (`LibraryCopies`) by recording, title and
    /// length rather than by number, so a one-disc CD and a two-disc SACD of the same album pair up song by song.
    /// Songs come in disc and track order when every song has its own number, so a stray copy can't jump to the top;
    /// otherwise (numbers missing, or two different songs on one number: two editions with different track lists) in
    /// the given order. A song's tracks keep the given order.
    public static func group(_ tracks: [Track]) -> [[Track]] {
        var position: [String: Int] = [:]
        for (i, t) in tracks.enumerated() where position[t.location] == nil { position[t.location] = i }
        var albumOrder: [String] = []
        var byAlbum: [String: [Track]] = [:]
        for t in tracks {
            if byAlbum[t.albumKey] == nil { albumOrder.append(t.albumKey) }
            byAlbum[t.albumKey, default: []].append(t)
        }
        return albumOrder.flatMap { key in
            LibraryCopies.analyze(byAlbum[key] ?? []).songs.map { song in
                song.tracks.sorted { (position[$0.location] ?? 0) < (position[$1.location] ?? 0) }
            }
        }
    }

    /// The other versions of `track` among `albumTracks` (including itself), or just `[track]`.
    public static func versions(of track: Track, in albumTracks: [Track]) -> [Track] {
        group(albumTracks).first { $0.contains { $0.id == track.id && $0.location == track.location } } ?? [track]
    }

    /// The version to play: multichannel when the output wants it, else stereo. Among copies of that kind, the
    /// best: lossless, then the most channels the output asked for, then the highest rate and depth, then one
    /// that `isLocal` (no network needed), then the first. With one version, that one.
    /// A copy the listener preferred (`isPreferred`) wins among those of the kind the output wants.
    public static func choose(_ versions: [Track], multichannel wantsMultichannel: Bool,
                              isLocal: (Track) -> Bool = { _ in true }, isPreferred: (Track) -> Bool = { _ in false }) -> Track? {
        guard versions.count > 1 else { return versions.first }
        let match = versions.filter { $0.isMultichannel == wantsMultichannel }
        let pool = match.isEmpty ? versions : match
        if let preferred = pool.first(where: isPreferred) { return preferred }
        // A TIDAL song with no file (streamed) ranks below a file of the same kind of format: its listed format is unconfirmed.
        func rank(_ t: Track) -> (Int, Int, Double, Int, Int) {
            ((t.isLossless ? 2 : 0) + (t.isTidalTrack && t.filePath.isEmpty ? 0 : 1), t.channels, t.sampleRate, t.bitDepth ?? (t.isDSD ? 1 : 0), isLocal(t) ? 1 : 0)
        }
        return pool.enumerated().max { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            return ra != rb ? ra < rb : a.offset > b.offset   // equal: the first wins
        }?.element
    }
}
