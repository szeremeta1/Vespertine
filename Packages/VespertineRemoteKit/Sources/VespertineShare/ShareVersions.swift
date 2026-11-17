//
// Vespertine: which songs of a share or a folder are one song in two speaker layouts: the stereo track and its 5.1 or
// Dolby Atmos mix, on one album or on the album's surround edition tagged as an album of its own.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import Foundation

/// The rule, kept narrow on purpose (a wrong match hides a recording, a missed one only lists a song twice). It is the
/// Mac's (`SongVersions`), as far as tags alone carry it. A stereo track and a surround track are one song when:
///
/// 1. They are on one album, or on two albums by the same album artist whose titles are the same once a label that
///    names a layout ("(Dolby Atmos)", "[5.1 Mix]", "(Surround)", "(Stereo Mix)") is dropped from the end.
/// 2. Their titles are the same (case, accents and such a label aside). "(Live)", "(Demo)", "(Acoustic)" are part of a
///    title, so those stay recordings of their own.
/// 3. Their lengths are within 6 seconds or 4 %.
///
/// Two tracks in the same layout are never matched here. A song takes one version in the other layout: the nearest in
/// track number, then in length.
public enum ShareVersions {
    public struct Candidate: Sendable {
        public var id: Int64
        public var artist: String, album: String, albumKey: String, title: String
        public var disc: Int?, number: Int?
        public var duration: Double
        public var surround: Bool

        public init(id: Int64, artist: String, album: String, albumKey: String, title: String, disc: Int?, number: Int?, duration: Double, surround: Bool) {
            self.id = id
            self.artist = artist
            self.album = album
            self.albumKey = albumKey
            self.title = title
            self.disc = disc
            self.number = number
            self.duration = duration
            self.surround = surround
        }
    }

    /// Words that make a bracketed label one about the speaker layout.
    static let layoutWords = ["atmos", "5.1", "7.1", "surround", "multichannel", "multi-channel", "quad", "stereo", "spatial"]

    /// A title for comparing: case and accents folded, and bracketed labels that name a layout dropped from its end.
    static func base(_ title: String) -> String {
        var text = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
        while let last = text.last, last == ")" || last == "]" {
            let open: Character = last == ")" ? "(" : "["
            guard let start = text.lastIndex(of: open), start != text.startIndex else { break }
            let label = text[text.index(after: start)..<text.index(before: text.endIndex)]
            guard layoutWords.contains(where: { label.contains($0) }) else { break }
            text = String(text[..<start]).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    static func sameLength(_ a: Double, _ b: Double) -> Bool {
        guard a > 0, b > 0 else { return false }
        return abs(a - b) <= max(6, 0.04 * max(a, b))
    }

    /// The songs among `candidates` that are in both layouts, each as its stereo and its surround version.
    public static func pairs(_ candidates: [Candidate]) -> [(stereo: Int64, surround: Int64)] {
        var groups: [String: (stereo: [Int], surround: [Int])] = [:]
        var order: [String] = []
        for (i, c) in candidates.enumerated() {
            let key = base(c.artist) + "\u{1F}" + base(c.album) + "\u{1F}" + base(c.title)
            if groups[key] == nil { order.append(key) }
            if c.surround { groups[key, default: ([], [])].surround.append(i) } else { groups[key, default: ([], [])].stereo.append(i) }
        }
        var found: [(stereo: Int64, surround: Int64)] = []
        for key in order {
            guard let group = groups[key], !group.stereo.isEmpty, !group.surround.isEmpty else { continue }
            // Every possible pair, the surest first: on one album, the same disc and number, the nearest length.
            var possible: [(rank: [Double], stereo: Int, surround: Int)] = []
            for s in group.stereo {
                for m in group.surround {
                    let a = candidates[s], b = candidates[m]
                    guard sameLength(a.duration, b.duration) else { continue }
                    let numbered = a.number != nil && a.number == b.number && (a.disc ?? 1) == (b.disc ?? 1)
                    possible.append(([a.albumKey == b.albumKey ? 0 : 1, numbered ? 0 : 1, abs(a.duration - b.duration)], s, m))
                }
            }
            possible.sort { $0.rank.lexicographicallyPrecedes($1.rank) || ($0.rank == $1.rank && ($0.stereo, $0.surround) < ($1.stereo, $1.surround)) }
            var used = Set<Int>()
            for pair in possible where !used.contains(pair.stereo) && !used.contains(pair.surround) {
                used.insert(pair.stereo)
                used.insert(pair.surround)
                found.append((candidates[pair.stereo].id, candidates[pair.surround].id))
            }
        }
        return found
    }
}
