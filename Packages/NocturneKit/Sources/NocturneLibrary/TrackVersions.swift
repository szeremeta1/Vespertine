//
// Nocturne — one song in several versions on the same album (an SACD's stereo and 5.1 layers, a
// Blu-ray's stereo and surround mixes): which tracks they are, and which one suits the output.
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

    /// Tracks of one album grouped into songs, in the given order (each group in order of first appearance).
    /// Only versions that differ in channel layout (stereo and 5.1) are grouped; two copies of the same
    /// layout stay separate tracks.
    public static func group(_ tracks: [Track]) -> [[Track]] {
        var order: [String] = []
        var groups: [String: [Track]] = [:]
        for t in tracks {
            var key = songKey(t) ?? "#\(t.id ?? 0)-\(t.location)"
            if let existing = groups[key], existing.contains(where: { $0.isMultichannel == t.isMultichannel }) {
                key += "#\(t.id ?? 0)-\(t.location)"   // same layout twice: not a version, a separate track
            }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(t)
        }
        return order.compactMap { groups[$0] }
    }

    /// The other versions of `track` among `albumTracks` (including itself), or just `[track]`.
    public static func versions(of track: Track, in albumTracks: [Track]) -> [Track] {
        group(albumTracks).first { $0.contains { $0.id == track.id && $0.location == track.location } } ?? [track]
    }

    /// The version to play: multichannel when the output wants it, else stereo. With one version, that one.
    public static func choose(_ versions: [Track], multichannel wantsMultichannel: Bool) -> Track? {
        guard versions.count > 1 else { return versions.first }
        let match = versions.filter { $0.isMultichannel == wantsMultichannel }
        // Among several of the right kind, the most channels the output asked for (7.1 over 5.1), then the richest format.
        return match.max { ($0.channels, $0.sampleRate) < ($1.channels, $1.sampleRate) } ?? versions.first
    }

    /// Same disc, same number, same title (ignoring case, punctuation and a "(5.1 mix)"-style suffix).
    static func songKey(_ t: Track) -> String? {
        guard let number = t.trackNumber else { return nil }
        var title = t.title.lowercased()
        title = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*(stereo|surround|5\.1|7\.1|multichannel|quad)[^\)\]]*[\)\]]"#,
                                           with: "", options: .regularExpression)
        title = String(title.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        guard !title.isEmpty else { return nil }
        return "\(t.albumKey)\u{1F}\(t.discNumber ?? 1)\u{1F}\(number)\u{1F}\(title)"
    }
}
