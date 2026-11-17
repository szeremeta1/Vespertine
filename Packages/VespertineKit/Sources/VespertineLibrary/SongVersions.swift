//
// Vespertine: one song across the editions of an album: the stereo album and its "(Dolby Atmos)" or "[5.1 Mix]"
// edition tagged as an album of its own. Which tracks of those albums are the same song, so that lists show it once
// and the output picks the version that plays.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The rule, kept narrow on purpose: a wrong match hides a recording, a missed one only lists a song twice.
///
/// Two tracks on the same album are one song by `LibraryCopies` (recording, title and length; see `MatchKey.score`).
/// Two tracks on different albums are one song only when all of these hold:
///
/// 1. Their albums are editions of one album (`AlbumFamilies`): the same title once an edition label such as
///    "(Dolby Atmos)", "[5.1 Mix]" or "(Deluxe Edition)" is dropped from at least one of them, artists that agree,
///    and no two different original years. A song on its album and on a compilation is never matched.
/// 2. The tracks match as the copies of one album do: the same MusicBrainz recording or ISRC, else the same title
///    (a "(5.1 mix)" or "(2009 Remaster)" label aside) with lengths within 6 s or 4 %. "(Live)", "(Demo)",
///    "(Acoustic)", "(Instrumental)" and the like stay recordings of their own.
/// 3. They are in different speaker layouts (stereo, 5.1, 7.1, Dolby Atmos), or they carry the same MusicBrainz
///    recording ID or ISRC. Two stereo tracks told apart only by their albums ("Rumours" and "Rumours (2004
///    Remaster)") may be different masters, so without an ID that says otherwise they stay two songs.
///
/// A song takes at most one song of each edition, the best match first.
public enum SongVersions {
    /// A score at or above this is an ID both tracks carry (a MusicBrainz recording, an ISRC), not a title.
    static let sameRecording = 900

    /// For every album that is one of several editions: the keys of all its editions, itself among them.
    public static func editions(_ albums: [Album]) -> [String: [String]] {
        var siblings: [String: [String]] = [:]
        for family in AlbumFamilies.group(albums) where family.editions.count > 1 {
            let keys = family.editions.map(\.key)
            for key in keys { siblings[key] = keys }
        }
        return siblings
    }

    /// The tracks of one album's editions (`tracks`: every track of those albums) as songs: each album's own songs
    /// (`TrackVersions.group`), joined across the editions by the rule above. Editions come in the order their
    /// tracks first appear; a song's tracks are edition after edition.
    public static func group(_ tracks: [Track]) -> [[Track]] {
        var order: [String] = []
        var byAlbum: [String: [Track]] = [:]
        for t in tracks {
            if byAlbum[t.albumKey] == nil { order.append(t.albumKey) }
            byAlbum[t.albumKey, default: []].append(t)
        }
        guard order.count > 1 else { return TrackVersions.group(tracks) }
        var keys: [String: LibraryCopies.MatchKey] = [:]
        for t in tracks { keys[t.location] = LibraryCopies.MatchKey(t) }
        // Each song: its tracks on each edition that has it.
        var songs: [[[Track]]] = []
        for (albumIndex, album) in order.enumerated() {
            let own = TrackVersions.group(byAlbum[album] ?? [])
            guard albumIndex > 0 else { songs = own.map { [$0] }; continue }
            // Only songs of earlier editions can be joined: two songs of this album are two songs.
            let earlier = songs.count
            var candidates: [(score: Int, own: Int, song: Int)] = []
            for (oi, song) in own.enumerated() {
                for si in 0..<earlier {
                    let score = link(song, songs[si].flatMap { $0 }, keys: keys)
                    if score > 0 { candidates.append((score, oi, si)) }
                }
            }
            // Strongest first; ties go to the songs that come first, so the albums' own order wins.
            candidates.sort { ($0.score, -$0.own, -$0.song) > ($1.score, -$1.own, -$1.song) }
            var usedOwn = Set<Int>(), usedSongs = Set<Int>()
            for c in candidates where !usedOwn.contains(c.own) && !usedSongs.contains(c.song) {
                usedOwn.insert(c.own); usedSongs.insert(c.song)
                songs[c.song].append(own[c.own])
            }
            for (oi, song) in own.enumerated() where !usedOwn.contains(oi) { songs.append([song]) }
        }
        return songs.map { $0.flatMap { $0 } }
    }

    /// How surely a song of one edition (`a`) and a song of another (`b`) are the same song; 0 when they aren't, or
    /// when only their titles say so and they share a layout.
    static func link(_ a: [Track], _ b: [Track], keys: [String: LibraryCopies.MatchKey]) -> Int {
        var best = 0
        for x in a {
            guard let kx = keys[x.location] else { continue }
            for y in b {
                guard let ky = keys[y.location] else { continue }
                best = max(best, kx.score(ky))
            }
        }
        guard best > 0 else { return 0 }
        if best >= sameRecording { return best }
        return Set(a.map(CopyLayout.init)).isDisjoint(with: Set(b.map(CopyLayout.init))) ? best : 0
    }

    /// Among a song's tracks, those playback may pick between when `track` is asked for and the output decides the
    /// layout: `track` itself, and the song's tracks of the other kind (surround for a stereo track, stereo for a
    /// surround one). On an output that wants `track`'s kind it plays as itself, so a copy chosen among several of one
    /// layout (the vinyl transfer, not the download) stays the copy that plays there.
    public static func followingOutput(_ track: Track, in song: [Track]) -> [Track] {
        [track] + song.filter { $0.location != track.location && $0.isMultichannel != track.isMultichannel }
    }
}
