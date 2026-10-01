//
// Vespertine — one song in several versions on the same album (an SACD's stereo and 5.1 layers, a
// Blu-ray's stereo and surround mixes) or several copies (the same file twice, two editions): which tracks
// they are, and which one to play.
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

    /// Tracks of one album grouped into songs: a song's versions (stereo and 5.1) and its copies (the same song
    /// twice in one layout: a file in your own folder and the album on a share, a CD and an SACD layer, two
    /// editions with one title) are one song. Songs come in disc and track order when every song has its own
    /// number, so a stray copy can't jump to the top; otherwise (numbers missing, or two different songs on one
    /// number: two editions with different track lists) in the given order.
    public static func group(_ tracks: [Track]) -> [[Track]] {
        var order: [String] = []
        var groups: [String: [Track]] = [:]
        for t in tracks {
            let key = songKey(t) ?? "#\(t.id ?? 0)-\(t.location)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(t)
        }
        let songs = order.compactMap { groups[$0] }
        let numbers = songs.map { s in s[0].trackNumber.map { "\(s[0].discNumber ?? 1)-\($0)" } }
        guard numbers.allSatisfy({ $0 != nil }), Set(numbers).count == numbers.count else { return songs }
        return songs.enumerated().sorted { a, b in
            let x = a.element[0], y = b.element[0]
            return ((x.discNumber ?? 1), x.trackNumber ?? 0, a.offset) < ((y.discNumber ?? 1), y.trackNumber ?? 0, b.offset)
        }.map(\.element)
    }

    /// The other versions of `track` among `albumTracks` (including itself), or just `[track]`.
    public static func versions(of track: Track, in albumTracks: [Track]) -> [Track] {
        group(albumTracks).first { $0.contains { $0.id == track.id && $0.location == track.location } } ?? [track]
    }

    /// The version to play: multichannel when the output wants it, else stereo. Among copies of that kind, the
    /// best: lossless, then the most channels the output asked for, then the highest rate and depth, then one
    /// that `isLocal` (no network needed), then the first. With one version, that one.
    public static func choose(_ versions: [Track], multichannel wantsMultichannel: Bool,
                              isLocal: (Track) -> Bool = { _ in true }) -> Track? {
        guard versions.count > 1 else { return versions.first }
        let match = versions.filter { $0.isMultichannel == wantsMultichannel }
        let pool = match.isEmpty ? versions : match
        func rank(_ t: Track) -> (Int, Int, Double, Int, Int) {
            (t.isLossless ? 1 : 0, t.channels, t.sampleRate, t.bitDepth ?? (t.isDSD ? 1 : 0), isLocal(t) ? 1 : 0)
        }
        return pool.enumerated().max { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            return ra != rb ? ra < rb : a.offset > b.offset   // equal: the first wins
        }?.element
    }

    /// Same disc, same number, same title (ignoring case, punctuation and a "(5.1 mix)", "(2012 Remaster)" or
    /// "(50th Anniversary Edition)" suffix; "(Live)", "(Demo)" or "(2026 Mix)" stay: they're other recordings).
    static func songKey(_ t: Track) -> String? {
        guard let number = t.trackNumber else { return nil }
        var title = t.title.lowercased()
        title = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*(stereo|surround|5\.1|7\.1|multichannel|quad|remaster|anniversary|edition)[^\)\]]*[\)\]]"#,
                                           with: "", options: .regularExpression)
        title = String(title.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        guard !title.isEmpty else { return nil }
        return "\(t.albumKey)\u{1F}\(t.discNumber ?? 1)\u{1F}\(number)\u{1F}\(title)"
    }
}
