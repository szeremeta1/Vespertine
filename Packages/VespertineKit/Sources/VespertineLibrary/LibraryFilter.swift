//
// Vespertine — filters for every list in the library. Choices within one facet widen the match ("FLAC or ALAC",
// "Jazz or Blues"); facets narrow it ("FLAC, 24-bit, from the 1970s"). An album matches a facet when any of its
// songs does, so a 5.1 album with a stereo bonus disc is both stereo and multichannel.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio

/// A file format as people pick it.
public enum FormatKind: String, CaseIterable, Sendable, Hashable, Identifiable {
    case flac, alac, wav, aiff, dsd, wavPack, ape, otherLossless, dolby, dts, mp3, aac, otherLossy
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .flac: "FLAC"
        case .alac: "ALAC"
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .dsd: "DSD"
        case .wavPack: "WavPack"
        case .ape: "Monkey’s Audio"
        case .otherLossless: "Other lossless"
        case .dolby: "Dolby"
        case .dts: "DTS"
        case .mp3: "MP3"
        case .aac: "AAC"
        case .otherLossy: "Other lossy"
        }
    }

    public static func of(codec: String, lossless: Bool, dsd: Bool) -> FormatKind {
        if dsd { return .dsd }
        switch codec {
        case "FLAC": return .flac
        case "ALAC": return .alac
        case "WAV": return .wav
        case "AIFF": return .aiff
        case "WavPack": return .wavPack
        case "APE": return .ape
        case "MP3": return .mp3
        case "AAC": return .aac
        default:
            if codec.hasPrefix("Dolby") { return .dolby }
            if codec.hasPrefix("DTS") { return .dts }
            return lossless ? .otherLossless : .otherLossy
        }
    }
}

/// On/off conditions that sit beside the facets as chips.
public enum FilterFlag: String, CaseIterable, Sendable, Hashable, Identifiable {
    case bits24, rate88, multichannel, favorite
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .bits24: "≥ 24-bit"
        case .rate88: "≥ 88.2 kHz"
        case .multichannel: "Multichannel"
        case .favorite: "Favorites"
        }
    }
}

/// A dimension you can pick values in.
public enum Facet: String, CaseIterable, Sendable, Hashable, Identifiable {
    case genre, decade, artist, format, sampleRate, bitDepth, channels, analysis, source
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .genre: "Genre"
        case .decade: "Year"
        case .artist: "Artist"
        case .format: "Format"
        case .sampleRate: "Sample Rate"
        case .bitDepth: "Bit Depth"
        case .channels: "Channels"
        case .analysis: "Analysis"
        case .source: "Source"
        }
    }

    /// The fixed names of a value; genres, artists and sources are named by the library.
    public func name(of key: String) -> String {
        switch self {
        case .decade: return "\(key)s"
        case .format: return FormatKind(rawValue: key)?.label ?? key
        case .sampleRate:
            guard let hz = Int(key) else { return key }
            if hz >= 2_822_400 { return "DSD\(Int((Double(hz) / 44_100).rounded()))" }
            return "\(SampleRate.format(Double(hz))) kHz"
        case .bitDepth: return key == "1" ? "1-bit (DSD)" : "\(key)-bit"
        case .channels:
            guard let n = Int(key) else { return key }
            return n == 1 ? "Mono" : n == 2 ? "Stereo" : ChannelLayouts.name(channels: n)
        case .analysis: return FilterFacts.verdictNames[key] ?? key
        case .genre, .artist, .source: return key
        }
    }

    /// The order values are listed in (numbers ascending, decades newest first, verdicts as analysis ranks them).
    public func sorted(_ keys: some Sequence<String>) -> [String] {
        switch self {
        case .sampleRate, .bitDepth, .channels: return keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        case .decade: return keys.sorted { (Int($0) ?? 0) > (Int($1) ?? 0) }
        case .format:
            func rank(_ key: String) -> Int { FormatKind.allCases.firstIndex { $0.rawValue == key } ?? 99 }
            return keys.sorted { rank($0) < rank($1) }
        case .analysis: return keys.sorted { (FilterFacts.verdictOrder.firstIndex(of: $0) ?? 99) < (FilterFacts.verdictOrder.firstIndex(of: $1) ?? 99) }
        case .genre, .artist, .source: return keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }
}

/// What a filter looks at in an album or a song: every value it has in each facet.
public struct FilterFacts: Sendable, Hashable {
    public var formats: Set<FormatKind> = []
    /// Hertz, rounded (DSD at its bit rate: 2822400 for DSD64).
    public var sampleRates: Set<Int> = []
    /// 1 for DSD; lossy files have none.
    public var bitDepths: Set<Int> = []
    public var channels: Set<Int> = []
    /// Analysis verdicts; "none" for lossless PCM not analyzed yet.
    public var verdicts: Set<String> = []
    public var sources: Set<Int64> = []
    /// Genre keys (see `Genres.key`).
    public var genres: Set<String> = []
    public var decade: Int?
    /// Lowercased album artist, as the Artists page groups them.
    public var artist = ""

    public init() {}

    static let verdictOrder = ["genuine", "possibleLossyOrigin", "bandwidthExtended", "upsampled", "paddedBitDepth", "none"]
    static let verdictNames = [
        "genuine": "Genuine", "possibleLossyOrigin": "Lossy origin", "bandwidthExtended": "Synthetic high frequencies",
        "upsampled": "Upsampled", "paddedBitDepth": "Padded bit depth", "none": "Not analyzed",
    ]

    /// A song's facts. Songs without a genre or year of their own take their album's.
    public init(track t: Track, albumGenre: String? = nil, albumYear: Int? = nil, genreKeys: (String?) -> Set<String> = Genres.keys) {
        formats = [FormatKind.of(codec: t.codec, lossless: t.isLossless, dsd: t.isDSD)]
        sampleRates = [Int(t.sampleRate.rounded())]
        if let bits = t.bitDepth ?? (t.isDSD ? 1 : nil) { bitDepths = [bits] }
        channels = [t.channels]
        if let verdict = t.analysisVerdict ?? (t.isLossless && !t.isDSD ? "none" : nil) { verdicts = [verdict] }
        if let source = t.sourceId { sources = [source] }
        genres = genreKeys(t.genre?.isEmpty == false ? t.genre : albumGenre)
        decade = Genres.decade(t.year ?? albumYear)
        artist = t.displayAlbumArtist.lowercased()
    }

    /// Facts for many songs at once (genre names are read once each).
    public static func of(_ tracks: [Track], albums: [String: Album] = [:]) -> [FilterFacts] {
        var cache: [String: Set<String>] = [:]
        func keys(_ raw: String?) -> Set<String> {
            guard let raw, !raw.isEmpty else { return [] }
            if let hit = cache[raw] { return hit }
            let k = Genres.keys(raw)
            cache[raw] = k
            return k
        }
        return tracks.map { t in
            let album = albums[t.albumKey]
            return FilterFacts(track: t, albumGenre: album?.genre, albumYear: album?.year, genreKeys: keys)
        }
    }

    /// The values in one facet, as filter keys.
    public func keys(_ facet: Facet) -> [String] {
        switch facet {
        case .genre: Array(genres)
        case .decade: decade.map { [String($0)] } ?? []
        case .artist: artist.isEmpty ? [] : [artist]
        case .format: formats.map(\.rawValue)
        case .sampleRate: sampleRates.map(String.init)
        case .bitDepth: bitDepths.map(String.init)
        case .channels: channels.map(String.init)
        case .analysis: Array(verdicts)
        case .source: sources.map(String.init)
        }
    }

    func has(any wanted: Set<String>, in facet: Facet) -> Bool {
        switch facet {
        case .genre: !genres.isDisjoint(with: wanted)
        case .decade: decade.map { wanted.contains(String($0)) } ?? false
        case .artist: wanted.contains(artist)
        case .format: formats.contains { wanted.contains($0.rawValue) }
        case .sampleRate: sampleRates.contains { wanted.contains(String($0)) }
        case .bitDepth: bitDepths.contains { wanted.contains(String($0)) }
        case .channels: channels.contains { wanted.contains(String($0)) }
        case .analysis: !verdicts.isDisjoint(with: wanted)
        case .source: sources.contains { wanted.contains(String($0)) }
        }
    }

    /// Whether a flag holds (favorites are library state, passed in).
    public func has(_ flag: FilterFlag, favorite: Bool) -> Bool {
        switch flag {
        // DSD counts as high resolution on both counts, as it always has on these chips.
        case .bits24: bitDepths.contains { $0 >= 24 } || formats.contains(.dsd)
        case .rate88: sampleRates.contains { $0 >= 88_200 }
        case .multichannel: channels.contains { $0 > 2 }
        case .favorite: favorite
        }
    }
}

/// The filter of one page.
public struct LibraryFilter: Sendable, Hashable {
    /// Chosen values per facet (keys as `FilterFacts.keys` gives them). An empty or missing set doesn't filter.
    public var selections: [Facet: Set<String>] = [:]
    public var flags: Set<FilterFlag> = []

    public init(selections: [Facet: Set<String>] = [:], flags: Set<FilterFlag> = []) {
        self.selections = selections.filter { !$0.value.isEmpty }
        self.flags = flags
    }

    public var isEmpty: Bool { flags.isEmpty && selections.values.allSatisfy(\.isEmpty) }
    /// Facets with something chosen.
    public var activeFacets: [Facet] { Facet.allCases.filter { !(selections[$0]?.isEmpty ?? true) } }

    public subscript(facet: Facet) -> Set<String> {
        get { selections[facet] ?? [] }
        set { selections[facet] = newValue.isEmpty ? nil : newValue }
    }

    public mutating func toggle(_ key: String, in facet: Facet) {
        if self[facet].contains(key) { self[facet].remove(key) } else { self[facet].insert(key) }
    }

    public mutating func toggle(_ flag: FilterFlag) {
        if flags.contains(flag) { flags.remove(flag) } else { flags.insert(flag) }
    }

    /// The same filter without some facets (a page about one artist has no use for an artist filter).
    public func removing(_ facets: Set<Facet>) -> LibraryFilter {
        var copy = self
        for f in facets { copy.selections[f] = nil }
        return copy
    }

    public func matches(_ facts: FilterFacts, favorite: Bool = false, ignoring ignored: Set<Facet> = []) -> Bool {
        for flag in flags where !facts.has(flag, favorite: favorite) { return false }
        for (facet, wanted) in selections where !wanted.isEmpty && !ignored.contains(facet) {
            if !facts.has(any: wanted, in: facet) { return false }
        }
        return true
    }

    /// For each value of `facet` among the items, how many items would match with that value chosen, everything
    /// else as it is (the usual way of counting choices: picking a value never shows a count it can't keep).
    public func counts(of facet: Facet, in items: some Collection<FilterFacts>, favorite: (Int) -> Bool = { _ in false }) -> [String: Int] {
        var others = self
        others.selections[facet] = nil
        var counts: [String: Int] = [:]
        for (i, facts) in items.enumerated() where others.matches(facts, favorite: favorite(i)) {
            for key in facts.keys(facet) { counts[key, default: 0] += 1 }
        }
        return counts
    }

    /// Every value of `facet` the items have (whatever else is chosen), with the ones chosen.
    public func values(of facet: Facet, in items: some Collection<FilterFacts>) -> [String] {
        var keys = self[facet]
        for facts in items { keys.formUnion(facts.keys(facet)) }
        return facet.sorted(keys)
    }
}

/// Saved as `{"facets": {"genre": ["jazz"]}, "flags": ["bits24"]}`. Facets and flags a later version doesn't know
/// are skipped, so an older filter file never stops the app from reading the rest.
extension LibraryFilter: Codable {
    private enum CodingKeys: String, CodingKey { case facets, flags }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let facets = try c.decodeIfPresent([String: [String]].self, forKey: .facets) ?? [:]
        let flags = try c.decodeIfPresent([String].self, forKey: .flags) ?? []
        self.init(selections: Dictionary(uniqueKeysWithValues: facets.compactMap { k, v in Facet(rawValue: k).map { ($0, Set(v)) } }),
                  flags: Set(flags.compactMap(FilterFlag.init(rawValue:))))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Dictionary(uniqueKeysWithValues: selections.filter { !$0.value.isEmpty }.map { ($0.key.rawValue, $0.value.sorted()) }), forKey: .facets)
        try c.encode(flags.map(\.rawValue).sorted(), forKey: .flags)
    }
}
