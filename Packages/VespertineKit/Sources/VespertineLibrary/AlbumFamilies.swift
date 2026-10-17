//
// Vespertine — one album card for its distinct releases, with every edition kept selectable.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public struct AlbumFamily: Sendable, Identifiable {
    public var id: String { editions[0].key }
    public let title: String
    public let artist: String
    public let year: Int?
    public var editions: [Album]
    public var representative: Album { editions[0] }

    /// An edition's tagged title is kept intact. Only the card title drops a recognized edition suffix.
    public func contains(_ albumKey: String) -> Bool { editions.contains { $0.key == albumKey } }
}

public enum AlbumFamilies {
    private struct Identity {
        let title: String
        let titleKey: String
        let artistKey: String
        let year: Int?
        let originalYear: Int?
        let hasEditionSuffix: Bool
    }

    /// Group after page filters have selected albums. A filtered DSD page can show one card even when the
    /// family also has an unfiltered PCM edition; opening the card finds all editions in the library.
    public static func group(_ albums: [Album]) -> [AlbumFamily] {
        var families: [AlbumFamily] = []
        var identities: [[Identity]] = []
        var byTitle: [String: [Int]] = [:]
        for album in albums {
            let identity = identity(of: album)
            let match = byTitle[identity.titleKey]?.first { index in
                identities[index].allSatisfy { other in
                    identity.originalYear == nil || other.originalYear == nil || identity.originalYear == other.originalYear
                } && identities[index].contains { other in
                    (identity.hasEditionSuffix || other.hasEditionSuffix) && compatibleArtists(identity.artistKey, other.artistKey)
                }
            }
            if let match {
                families[match].editions.append(album)
                identities[match].append(identity)
                // The plain title and the shorter artist credit make the card easier to recognize.
                if !identity.hasEditionSuffix {
                    families[match] = AlbumFamily(title: identity.title, artist: shorterArtist(families[match].artist, album.artist),
                                                  year: identity.year, editions: families[match].editions)
                }
            } else {
                byTitle[identity.titleKey, default: []].append(families.count)
                families.append(AlbumFamily(title: identity.title, artist: album.artist, year: identity.year, editions: [album]))
                identities.append([identity])
            }
        }
        return families
    }

    /// Keep a card when any edition passes a page filter, but show its full edition count and let
    /// the matched edition be the one initially selected when the card opens.
    public static func visibleGroups(_ selected: [Album], among all: [Album]) -> [AlbumFamily] {
        let full = group(all)
        let byAlbum = Dictionary(full.flatMap { family in family.editions.map { ($0.key, family) } },
                                 uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return selected.compactMap { matched in
            guard let whole = byAlbum[matched.key], seen.insert(whole.id).inserted else { return nil }
            return AlbumFamily(title: whole.title, artist: whole.artist, year: whole.year,
                               editions: [matched] + whole.editions.filter { $0.key != matched.key })
        }
    }

    private static func shorterArtist(_ a: String, _ b: String) -> String { a.count <= b.count ? a : b }

    private static func compatibleArtists(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        // A credited backing group should not split the same release from a solo artist's copy.
        return short.count >= 6 && (long.hasPrefix(short + "and") || long.hasPrefix(short + "feat"))
    }

    private static func identity(of album: Album) -> Identity {
        var title = album.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var hasEditionSuffix = false
        if let range = title.range(of: #"\s*(?:\[[^\[\]]+\]|\([^()]+\))\s*$"#, options: .regularExpression) {
            let suffix = String(title[range])
            if suffix.range(of: #"(?i)sacd|dsd|mofi|mobile fidelity|remaster|edition|deluxe|mono|stereo|\bmix\b|flac|vinyl|blu.?ray|dvd.a|spatial|surround|atmos|\b\d{2}[-/]\d{2,3}\b"#
                            + #"|\bdcc\b|master(?:ing|ed)?\b|\bhdcd\b|\bxrcd|\bshm\b|uhqcd|blu.?spec|\bgold\b|audiophile|japan(?:ese)?\b|\bimport\b"#
                            + #"|expanded|anniversary|bonus|hi.?res|\b24.?bit|\bmfsl\b|\bdts\b|quad|\b5\.1\b|reissue"#,
                            options: .regularExpression) != nil {
                title.removeSubrange(range)
                title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                hasEditionSuffix = true
            }
        }
        var year = album.year
        var originalYear: Int?
        if let range = title.range(of: #"\s*\((?:18|19|20)\d{2}\)\s*$"#, options: .regularExpression),
           let parsed = Int(title[range].filter(\.isNumber)) {
            originalYear = parsed
            year = parsed // the original album year in the title beats an erroneous remaster tag
            title.removeSubrange(range)
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Identity(title: title, titleKey: comparable(title), artistKey: comparable(album.artist.replacingOccurrences(of: "&", with: "and")),
                        year: year, originalYear: originalYear, hasEditionSuffix: hasEditionSuffix)
    }

    private static func comparable(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
