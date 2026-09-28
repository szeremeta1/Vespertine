//
// Nocturne — genres as people mean them: case and accents don't matter ("rock" = "Rock"), multi-genre
// tags count under each ("Rock; Blues"), and names like "Pop/Rock" or "R&B/Soul" stay whole.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public struct GenreSummary: Identifiable, Hashable, Sendable {
    public let key: String
    public let name: String
    public let albumCount: Int
    /// Covers of a few of its albums, for the tile.
    public let artworkKeys: [String]
    public var id: String { key }
}

public enum Genres {
    /// The genres in a tag. Splits multi-value tags on ; | , and NUL; keeps "/" (it's part of names).
    public static func split(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        var seen = Set<String>(), out: [String] = []
        for part in raw.split(whereSeparator: { ";|,\u{0}".contains($0) }) {
            guard let name = clean(String(part)), seen.insert(key(name)).inserted else { continue }
            out.append(name)
        }
        return out
    }

    /// A usable genre name, or nil for junk. Old ID3 numeric genres ("13", "(13)") become names;
    /// stray punctuation ("& Country") is trimmed; numbers like "7.1" (channel layouts) are dropped.
    public static func clean(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("("), name.hasSuffix(")") { name = String(name.dropFirst().dropLast()) }
        if let n = Int(name) { return n >= 0 && n < id3.count ? id3[n] : nil }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "&/+-_.:·•~ ").union(.whitespaces))
        guard name.count >= 2, name.count <= 60, name.rangeOfCharacter(from: .letters) != nil else { return nil }
        return name
    }

    /// Comparison key: case, accents and extra spaces ignored.
    public static func key(_ name: String) -> String {
        // "Alternative-Rock" = "Alternative Rock", "Hip-Hop" = "hip hop", "Rock and Roll" = "Rock & Roll".
        var k = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: ". ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: " and ", with: " & ")
        // "Rap/Hip Hop" = "Hip-Hop/Rap": the parts of a slashed name in any order.
        if k.contains("/") {
            k = k.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.sorted().joined(separator: "/")
        }
        return aliases[k] ?? k
    }

    /// The same genre under other names (abbreviations, and Apple's localized genre names).
    private static let aliases: [String: String] = [
        "alt. rock": "alternative rock", "alt rock": "alternative rock",
        "alternativa e indie": "alternative & indie", "alternatif et inde": "alternative & indie",
        "alternativo e indie": "alternative & indie", "alternativ & indie": "alternative & indie",
        "alternativo & indie": "alternative & indie", "alternative/indie": "alternative & indie",
        "alternativa": "alternative", "alternatif": "alternative", "alternativo": "alternative",
        "hip hop/rap": "hip hop/rap", "rap/hip hop": "hip hop/rap",
        "r&b": "r&b", "rnb": "r&b", "rhythm & blues": "r&b",
        "musica classica": "classical", "musique classique": "classical", "klassik": "classical", "clasica": "classical",
        "bande originale": "soundtrack", "colonna sonora": "soundtrack", "banda sonora": "soundtrack",
        "bandes originales de films": "soundtrack", "bande originale de film": "soundtrack", "soundtracks": "soundtrack",
        "electronique": "electronic", "elettronica": "electronic", "electronica": "electronic",
    ]

    /// Display names for genres merged from several names, so a group never shows up under a translation.
    private static let canonical: [String: String] = [
        "alternative & indie": "Alternative & Indie", "alternative rock": "Alternative Rock", "alternative": "Alternative",
        "hip hop/rap": "Hip-Hop/Rap", "r&b": "R&B", "classical": "Classical", "soundtrack": "Soundtrack", "electronic": "Electronic",
    ]

    /// ID3v1 genre numbers (plus the common Winamp extensions).
    private static let id3: [String] = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal", "New Age", "Oldies",
        "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska", "Death Metal", "Pranks",
        "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental",
        "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise", "Alternative Rock", "Bass", "Soul", "Punk", "Space", "Meditative",
        "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk",
        "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk", "Jungle",
        "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal", "Acid Punk",
        "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock", "Folk", "Folk-Rock", "National Folk", "Swing",
        "Fast Fusion", "Bebop", "Latin", "Revival", "Celtic", "Bluegrass", "Avantgarde", "Gothic Rock", "Progressive Rock",
        "Psychedelic Rock", "Symphonic Rock", "Slow Rock", "Big Band", "Chorus", "Easy Listening", "Acoustic", "Humour", "Speech",
        "Chanson", "Opera", "Chamber Music", "Sonata", "Symphony", "Booty Bass", "Primus", "Porn Groove", "Satire", "Slow Jam",
        "Club", "Tango", "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle", "Duet", "Punk Rock",
        "Drum Solo", "A Cappella", "Euro-House", "Dance Hall", "Goa", "Drum & Bass", "Club-House", "Hardcore", "Terror", "Indie",
        "BritPop", "Punk", "Polsk Punk", "Beat", "Christian Gangsta Rap", "Heavy Metal", "Black Metal", "Crossover",
        "Contemporary Christian", "Christian Rock", "Merengue", "Salsa", "Thrash Metal", "Anime", "JPop", "Synthpop",
    ]

    public static func keys(_ raw: String?) -> Set<String> { Set(split(raw).map(key)) }

    /// One entry per genre across the albums, named by its most common spelling, alphabetical.
    public static func summarize(_ albums: [Album]) -> [GenreSummary] {
        var spellings: [String: [String: Int]] = [:]
        var members: [String: [Album]] = [:]
        for album in albums {
            for name in split(album.genre) {
                let k = key(name)
                spellings[k, default: [:]][name, default: 0] += 1
                members[k, default: []].append(album)
            }
        }
        return members.map { k, list in
            let name = canonical[k] ?? spellings[k]?.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? k
            let covers = list.compactMap(\.artworkKey).reduce(into: [String]()) { if $0.count < 4, !$0.contains($1) { $0.append($1) } }
            return GenreSummary(key: k, name: name, albumCount: list.count, artworkKeys: covers)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// "1970s" for 1977.
    public static func decade(_ year: Int?) -> Int? { year.flatMap { $0 > 1000 ? $0 / 10 * 10 : nil } }
}
