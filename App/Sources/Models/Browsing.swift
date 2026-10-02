//
// Vespertine — what each page lists and plays through its filter: albums, artists, genres, sources, songs,
// playlists and search.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineLibrary

/// The page a filter belongs to.
enum FilterScope: Hashable {
    case sidebar(SidebarItem)
    case route(DetailRoute)
    case search

    /// Facets the page itself fixes (an artist's page is one artist), which its filter doesn't offer.
    var fixedFacets: Set<Facet> {
        switch self {
        case .sidebar(.artists), .route(.artist): [.artist]
        case .sidebar(.genres), .route(.genre): [.genre]
        case .sidebar(.source): [.source]
        default: []
        }
    }

    /// Pages of songs; the others list albums (or artists and genres, made of albums).
    var listsSongs: Bool {
        switch self {
        case .sidebar(.songs), .sidebar(.favorites), .sidebar(.playlist), .search: true
        default: false
        }
    }

    var offersFavorites: Bool { self != .sidebar(.favorites) }
}

extension FilterScope {
    /// The name a page's filter is saved under. Only the sidebar's pages keep theirs across launches: a search
    /// starts afresh, and artist and genre pages take the filter of the page they're opened from.
    var storageKey: String? {
        guard case .sidebar(let item) = self else { return nil }
        return switch item {
        case .albums: "albums"
        case .artists: "artists"
        case .songs: "songs"
        case .genres: "genres"
        case .recentlyAdded: "recentlyAdded"
        case .favorites: "favorites"
        case .playlist(let id): "playlist:\(id)"
        case .source(let id): "source:\(id)"
        }
    }

    init?(storageKey key: String) {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count > 1 ? Int64(parts[1]) : nil) {
        case ("albums", _): self = .sidebar(.albums)
        case ("artists", _): self = .sidebar(.artists)
        case ("songs", _): self = .sidebar(.songs)
        case ("genres", _): self = .sidebar(.genres)
        case ("recentlyAdded", _): self = .sidebar(.recentlyAdded)
        case ("favorites", _): self = .sidebar(.favorites)
        case ("playlist", let id?): self = .sidebar(.playlist(id))
        case ("source", let id?): self = .sidebar(.source(id))
        default: return nil
        }
    }
}

/// Page filters kept with the library they belong to (they name its playlists, sources and genres), in
/// `<data directory>/Page Filters.json`.
enum FilterStore {
    static func url(in dataDirectory: URL) -> URL { dataDirectory.appendingPathComponent("Page Filters.json") }

    static func load(from url: URL) -> [FilterScope: LibraryFilter] {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([String: LibraryFilter].self, from: data) else { return [:] }
        var filters: [FilterScope: LibraryFilter] = [:]
        for (key, filter) in saved where !filter.isEmpty {
            if let scope = FilterScope(storageKey: key) { filters[scope] = filter }
        }
        return filters
    }

    static func save(_ filters: [FilterScope: LibraryFilter], to url: URL) {
        var saved: [String: LibraryFilter] = [:]
        for (scope, filter) in filters where !filter.isEmpty {
            if let key = scope.storageKey { saved[key] = filter }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if saved.isEmpty { try? FileManager.default.removeItem(at: url); return }
        if let data = try? encoder.encode(saved) { try? data.write(to: url, options: .atomic) }
    }
}

struct FilterPanelRequest: Equatable {
    let scope: FilterScope
    let facet: Facet?
}

/// The chips under a page's title: formats at a glance, and conditions you switch on and off. They combine:
/// formats with each other as "or", conditions with everything as "and" ("FLAC or ALAC, 24-bit, 88.2 kHz and up").
enum QuickChip: String, CaseIterable, Identifiable {
    // Raw values are the old single-choice chips' (QA hook -VespertineFormatFilter).
    case all, flac, pcm, alac, dsd, surround, lossy, bits24, rate96, multichannel, favorite
    var id: String { rawValue }

    static let formats: [QuickChip] = [.flac, .pcm, .alac, .dsd, .surround, .lossy]
    static let conditions: [QuickChip] = [.bits24, .rate96, .multichannel]
    /// Formats no chip stands for (chosen in the Filters panel, so they show as a token).
    static let unchipped: Set<FormatKind> = Set(FormatKind.allCases).subtracting(formats.flatMap(\.kinds))

    var label: String {
        switch self {
        case .all: "All formats"
        case .flac: "FLAC"
        case .pcm: "WAV / AIFF"
        case .alac: "ALAC"
        case .dsd: "DSD"
        case .surround: "Dolby & DTS"
        case .lossy: "Lossy"
        default: flag?.label ?? ""
        }
    }

    var symbol: String? { self == .favorite ? "heart.fill" : nil }

    var kinds: Set<FormatKind> {
        switch self {
        case .flac: [.flac]
        case .pcm: [.wav, .aiff]
        case .alac: [.alac]
        case .dsd: [.dsd]
        case .surround: [.dolby, .dts]
        case .lossy: [.mp3, .aac, .otherLossy]
        default: []
        }
    }

    var flag: FilterFlag? {
        switch self {
        case .bits24: .bits24
        case .rate96: .rate88
        case .multichannel: .multichannel
        case .favorite: .favorite
        default: nil
        }
    }

    private static let formatFlags: Set<FilterFlag> = [.bits24, .rate88, .multichannel]

    func isOn(_ f: LibraryFilter) -> Bool {
        if self == .all { return f[.format].isEmpty && f.flags.isDisjoint(with: Self.formatFlags) }
        if let flag { return f.flags.contains(flag) }
        return kinds.contains { f[.format].contains($0.rawValue) }
    }

    func toggle(_ f: inout LibraryFilter) {
        if self == .all {
            f[.format] = []
            f.flags.subtract(Self.formatFlags)
        } else if let flag {
            f.toggle(flag)
        } else {
            let keys = Set(kinds.map(\.rawValue))
            if isOn(f) { f[.format].subtract(keys) } else { f[.format].formUnion(keys) }
        }
    }
}

/// The formats and conditions a page's items have at all, so chips with nothing behind them stay out of the way.
struct FilterAvailability {
    var formats: Set<FormatKind> = []
    var flags: Set<FilterFlag> = []

    init(_ facts: [FilterFacts], favorite: (Int) -> Bool) {
        for (i, f) in facts.enumerated() {
            formats.formUnion(f.formats)
            for flag in FilterFlag.allCases where !flags.contains(flag) && f.has(flag, favorite: favorite(i)) { flags.insert(flag) }
        }
    }

    func union(_ other: FilterAvailability) -> FilterAvailability {
        var both = self
        both.formats.formUnion(other.formats)
        both.flags.formUnion(other.flags)
        return both
    }

    func offers(_ chip: QuickChip, in filter: LibraryFilter) -> Bool {
        if chip == .all || chip.isOn(filter) { return true }
        if let flag = chip.flag { return flags.contains(flag) }
        return !formats.isDisjoint(with: chip.kinds)
    }
}

extension AppModel {
    func filter(_ scope: FilterScope) -> LibraryFilter { filters[scope] ?? LibraryFilter() }

    func setFilter(_ filter: LibraryFilter, for scope: FilterScope) {
        let value: LibraryFilter? = filter.isEmpty ? nil : filter
        if filters[scope] != value { filters[scope] = value }
    }

    func updateFilter(_ scope: FilterScope, _ change: (inout LibraryFilter) -> Void) {
        var f = filter(scope)
        change(&f)
        setFilter(f, for: scope)
    }

    /// The page on screen.
    var visibleScope: FilterScope {
        if let route = path.last { return .route(route) }
        return searchText.trimmingCharacters(in: .whitespaces).isEmpty ? .sidebar(sidebar) : .search
    }

    /// A page opened from a filtered one starts with that filter: "Jazz" picked on Artists, an artist's page shows
    /// their jazz albums (with the filter in view, to clear). Album pages carry nothing further.
    func carryFilter(from old: [DetailRoute]) {
        guard path.count == old.count + 1, Array(path.dropLast()) == old, let route = path.last else { return }
        if case .album = route { return }
        let searching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        let parent: FilterScope = old.last.map { .route($0) } ?? (searching ? .search : .sidebar(sidebar))
        let scope = FilterScope.route(route)
        setFilter(filter(parent).removing(scope.fixedFacets), for: scope)
    }

    func isFavorite(_ album: Album) -> Bool { library.favoriteAlbumKeys.contains(album.key) }

    // MARK: Albums

    /// The albums a page lists before its filter, in its order.
    func baseAlbums(_ scope: FilterScope) -> [Album] {
        let albums = library.albums
        switch scope {
        case .sidebar(.recentlyAdded):
            return Array(albums.sorted { $0.addedAt > $1.addedAt }.prefix(60))
        case .sidebar(.genres):
            return albums.filter { !$0.facts.genres.isEmpty }
        case .sidebar(.artists):
            let order = Dictionary(library.artists.enumerated().map { ($1.name.lowercased(), $0) }, uniquingKeysWith: min)
            return albums.sorted { a, b in
                let (x, y) = (order[a.facts.artist] ?? .max, order[b.facts.artist] ?? .max)
                return x != y ? x < y : (a.year ?? 0) < (b.year ?? 0)
            }
        case .sidebar(.source(let id)):
            return albums.filter { $0.facts.sources.contains(id) }
        case .route(.artist(let name)):
            let key = name.lowercased()
            return albums.filter { $0.facts.artist == key }.sorted { a, b in
                (a.year ?? 0) != (b.year ?? 0) ? (a.year ?? 0) > (b.year ?? 0) : a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        case .route(.genre(let key)):
            return albums.filter { $0.facts.genres.contains(key) }
        default:
            return albums
        }
    }

    func filtered(_ albums: [Album], by filter: LibraryFilter) -> [Album] {
        filter.isEmpty ? albums : albums.filter { filter.matches($0.facts, favorite: isFavorite($0)) }
    }

    /// The albums a page shows.
    func shownAlbums(_ scope: FilterScope) -> [Album] { filtered(baseAlbums(scope), by: filter(scope)) }

    /// Artists with albums through the filter, counted by those albums.
    func artists(_ filter: LibraryFilter) -> [LibraryDatabase.ArtistSummary] {
        guard !filter.isEmpty else { return library.artists }
        let groups = Dictionary(grouping: filtered(library.albums, by: filter), by: \.facts.artist)
        return library.artists.compactMap { a in
            guard let albums = groups[a.name.lowercased()] else { return nil }
            return .init(name: a.name, albumCount: albums.count, trackCount: albums.reduce(0) { $0 + $1.trackCount },
                         artworkKey: albums.first { $0.artworkKey != nil }?.artworkKey ?? a.artworkKey)
        }
    }

    /// Genres of the albums through the filter, counted by those albums.
    func genres(_ filter: LibraryFilter) -> [GenreSummary] {
        filter.isEmpty ? library.genres : Genres.summarize(filtered(library.albums, by: filter))
    }

    // MARK: Songs

    func trackFacts(_ tracks: [Track]) -> [FilterFacts] { FilterFacts.of(tracks, albums: library.albumsByKey) }

    /// Facets an album page judges per album: an album is Jazz, or from 1973, as a whole, and all of its songs play.
    static let albumFacets: Set<Facet> = [.genre, .decade, .artist]

    /// Whether a song passes a filter; nil when there's no filter. On album pages (`perAlbum`) genre, year and
    /// artist were decided by the album; formats, layouts, verdicts, sources and Favorites still apply per song.
    func allowing(_ filter: LibraryFilter, perAlbum: Bool) -> ((Track) -> Bool)? {
        guard !filter.isEmpty else { return nil }
        let albums = library.albumsByKey, favorites = library.favoriteIDs
        let ignored = perAlbum ? Self.albumFacets : []
        let noGenres: (String?) -> Set<String> = { _ in [] }
        return { t in
            let album = albums[t.albumKey]
            let facts = perAlbum ? FilterFacts(track: t, genreKeys: noGenres)
                                 : FilterFacts(track: t, albumGenre: album?.genre, albumYear: album?.year)
            return filter.matches(facts, favorite: favorites.contains(t.id ?? -1), ignoring: ignored)
        }
    }

    /// The songs of `albums`, album by album, that a page's filter lets through.
    func songs(of albums: [Album], filter: LibraryFilter) -> [Track] {
        let tracks = library.tracks(albumKeys: albums.map(\.key))
        guard let allowing = allowing(filter, perAlbum: true) else { return tracks }
        return tracks.filter(allowing)
    }

    /// The songs a page of songs lists before its filter; nil for pages of albums.
    func baseTracks(_ scope: FilterScope) -> [Track]? {
        switch scope {
        case .sidebar(.songs): library.allTracks()
        case .sidebar(.favorites): library.favoriteTracks()
        case .sidebar(.playlist(let id)): library.playlists.first { $0.id == id }.map(library.tracks(in:)) ?? []
        case .search: library.search(searchText)
        default: nil
        }
    }

    /// Songs through a filter, in their order.
    func filtered(_ tracks: [Track], facts: [FilterFacts], by filter: LibraryFilter) -> [Track] {
        guard !filter.isEmpty else { return tracks }
        let favorites = library.favoriteIDs
        return zip(tracks, facts).filter { filter.matches($1, favorite: favorites.contains($0.id ?? -1)) }.map(\.0)
    }

    /// Everything a page plays: its songs, or its albums' songs, through its filter.
    func playableTracks(_ scope: FilterScope) -> [Track] {
        let filter = filter(scope)
        if let tracks = baseTracks(scope) { return filtered(tracks, facts: filter.isEmpty ? [] : trackFacts(tracks), by: filter) }
        return songs(of: shownAlbums(scope), filter: filter)
    }

    // MARK: Playing

    /// Plays a page in order (`shuffled` false, as a Play button does) or shuffled from a random song.
    func play(_ scope: FilterScope, shuffled: Bool) {
        player.play(playableTracks(scope), shuffled: shuffled, allowing: allowing(filter(scope), perAlbum: !scope.listsSongs))
    }

    /// Plays albums through a filter (an artist's or a genre's albums from its tile).
    func play(albums: [Album], filter: LibraryFilter, shuffled: Bool) {
        player.play(songs(of: albums, filter: filter), shuffled: shuffled, allowing: allowing(filter, perAlbum: true))
    }

    func enqueue(albums: [Album], filter: LibraryFilter, next: Bool) {
        let tracks = songs(of: albums, filter: filter), allowing = allowing(filter, perAlbum: true)
        if next { player.playNext(tracks, allowing: allowing) } else { player.addToQueue(tracks, allowing: allowing) }
    }

    // MARK: Names

    /// Display names of a facet's values: genres as the library spells them, artists as tagged, sources as in the
    /// sidebar; the fixed ones (rates, depths…) from the facet.
    func facetNames(_ facet: Facet) -> [String: String] {
        switch facet {
        case .genre: Dictionary(library.genres.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        case .artist: Dictionary(library.artists.map { ($0.name.lowercased(), $0.name) }, uniquingKeysWith: { a, _ in a })
        case .source: Dictionary(library.sources.compactMap { s in s.id.map { (String($0), s.displayName) } }, uniquingKeysWith: { a, _ in a })
        default: [:]
        }
    }
}
