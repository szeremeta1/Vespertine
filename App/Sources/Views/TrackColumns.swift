//
// Vespertine: the columns of track tables: which ones a page shows (chosen from the header's menu, as in Music), the
// order a page is sorted in, and both kept for the next launch, each kind of page its own.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import SwiftUI
import VespertineLibrary

/// Each kind of page keeps its own columns: what suits Songs (Plays, Date Added) needn't crowd an album.
enum TrackTableKind: String, CaseIterable, Sendable {
    case songs, favorites, playlist, album, search

    /// Pages whose sort is kept for the next launch: the long lists, which are a sort to find things in (most played,
    /// recently added). An album or a playlist opens in its own order.
    var keepsSort: Bool { self == .songs || self == .favorites }
}

/// A column a track table can show. The raw value names it in the saved layout: never change one.
nonisolated enum TrackColumn: String, CaseIterable, Sendable {
    case number, title, artist, album, albumArtist, composer, genre, year, trackNumber, discNumber, format, source, favorite,
         time, plays, lastPlayed, dateAdded, rating, bpm, size, skips, lastSkipped

    /// The comparator the table sorts this column with. nil: a column that isn't sorted (the heart, the source).
    func comparator(forward: Bool = true) -> KeyPathComparator<TrackRow>? {
        let order: SortOrder = forward ? .forward : .reverse
        return switch self {
        case .number: KeyPathComparator(\TrackRow.index, order: order)
        case .title: KeyPathComparator(\TrackRow.track.title, order: order)
        case .artist: KeyPathComparator(\TrackRow.track.displayArtist, order: order)
        case .album: KeyPathComparator(\TrackRow.track.displayAlbum, order: order)
        case .albumArtist: KeyPathComparator(\TrackRow.track.displayAlbumArtist, order: order)
        case .composer: KeyPathComparator(\TrackRow.track.composerOrEmpty, order: order)
        case .genre: KeyPathComparator(\TrackRow.track.genreOrEmpty, order: order)
        case .year: KeyPathComparator(\TrackRow.track.yearOrNone, order: order)
        case .trackNumber: KeyPathComparator(\TrackRow.track.trackNumberOrNone, order: order)
        case .discNumber: KeyPathComparator(\TrackRow.track.discNumberOrNone, order: order)
        case .format: KeyPathComparator(\TrackRow.track.sampleRate, order: order)
        case .time: KeyPathComparator(\TrackRow.track.duration, order: order)
        case .plays: KeyPathComparator(\TrackRow.track.playCount, order: order)
        case .lastPlayed: KeyPathComparator(\TrackRow.track.lastPlayedOrNever, order: order)
        case .dateAdded: KeyPathComparator(\TrackRow.track.addedAt, order: order)
        case .rating: KeyPathComparator(\TrackRow.track.ratingOrNone, order: order)
        case .bpm: KeyPathComparator(\TrackRow.track.bpmOrNone, order: order)
        case .size: KeyPathComparator(\TrackRow.track.fileSize, order: order)
        case .skips: KeyPathComparator(\TrackRow.track.skipsOrNone, order: order)
        case .lastSkipped: KeyPathComparator(\TrackRow.track.lastSkippedOrNever, order: order)
        case .source, .favorite: nil
        }
    }

    /// The column a comparator of the table sorts.
    static func of(_ comparator: KeyPathComparator<TrackRow>) -> TrackColumn? {
        allCases.first { $0.comparator()?.keyPath == comparator.keyPath }
    }

    /// The column's value in every row of `tracks`, for `TrackSort`.
    @MainActor func values(_ tracks: [Track], positions: [Int]?) -> TrackSort.Column.Values? {
        switch self {
        case .number: .numbers(tracks.indices.map { Double(positions?[$0] ?? $0) })
        case .title: .text(tracks.map(\.title))
        case .artist: .text(tracks.map(\.displayArtist))
        case .album: .text(tracks.map(\.displayAlbum))
        case .albumArtist: .text(tracks.map(\.displayAlbumArtist))
        case .composer: .text(tracks.map(\.composerOrEmpty))
        case .genre: .text(tracks.map(\.genreOrEmpty))
        case .year: .numbers(tracks.map { Double($0.yearOrNone) })
        case .trackNumber: .numbers(tracks.map { Double($0.trackNumberOrNone) })
        case .discNumber: .numbers(tracks.map { Double($0.discNumberOrNone) })
        case .format: .numbers(tracks.map(\.sampleRate))
        case .time: .numbers(tracks.map(\.duration))
        case .plays: .numbers(tracks.map { Double($0.playCount) })
        case .lastPlayed: .numbers(tracks.map(\.lastPlayedOrNever))
        case .dateAdded: .numbers(tracks.map { $0.addedAt.timeIntervalSinceReferenceDate })
        case .rating: .numbers(tracks.map { Double($0.ratingOrNone) })
        case .bpm: .numbers(tracks.map { Double($0.bpmOrNone) })
        case .size: .numbers(tracks.map { Double($0.fileSize) })
        case .skips: .numbers(tracks.map { Double($0.skipsOrNone) })
        case .lastSkipped: .numbers(tracks.map(\.lastSkippedOrNever))
        case .source, .favorite: nil
        }
    }
}

/// Values the table sorts by where a field can be empty: an empty one sorts before every other (after them, reversed).
nonisolated extension Track {
    var composerOrEmpty: String { composer ?? "" }
    var genreOrEmpty: String { genre ?? "" }
    var yearOrNone: Int { year ?? -1 }
    var trackNumberOrNone: Int { trackNumber ?? -1 }
    var discNumberOrNone: Int { discNumber ?? -1 }
    var ratingOrNone: Int { rating ?? -1 }
    var bpmOrNone: Int { bpm ?? -1 }
    /// A song never played sorts as played before any that was.
    var lastPlayedOrNever: Double { lastPlayedAt?.timeIntervalSinceReferenceDate ?? -.greatestFiniteMagnitude }
    /// Skips: a library from before they were counted has none (0).
    var skipsOrNone: Int { skipCount ?? 0 }
    var lastSkippedOrNever: Double { lastSkippedAt?.timeIntervalSinceReferenceDate ?? -.greatestFiniteMagnitude }

    /// The rating as stars: a 0–5 rating as it is, a 0–100 one (as most taggers write RATING) in fifths, a 0–255 one
    /// (ID3's POPM) the same way. Empty when there is none.
    var ratingStars: String {
        guard let rating, rating > 0 else { return "" }
        let stars = rating <= 5 ? rating : rating <= 100 ? Int((Double(rating) / 20).rounded()) : Int((Double(rating) / 51).rounded())
        return String(repeating: "★", count: max(1, min(5, stars)))
    }
}

/// The columns each kind of track table shows, their widths and order, and the sort of the pages that keep one, saved in
/// the app's settings.
@MainActor
@Observable
final class TrackTableLayouts {
    static let shared = TrackTableLayouts()

    @ObservationIgnored private let defaults: UserDefaults
    private var columns: [TrackTableKind: TableColumnCustomization<TrackRow>] = [:]
    private var sorts: [TrackTableKind: [KeyPathComparator<TrackRow>]] = [:]

    /// A sorted column as it is saved.
    struct SavedSort: Codable, Equatable {
        var column: String
        var forward: Bool
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for kind in TrackTableKind.allCases {
            if let data = defaults.data(forKey: Self.columnsKey(kind)),
               let saved = try? JSONDecoder().decode(TableColumnCustomization<TrackRow>.self, from: data) {
                columns[kind] = saved
            }
            if kind.keepsSort, let data = defaults.data(forKey: Self.sortKey(kind)),
               let saved = try? JSONDecoder().decode([SavedSort].self, from: data) {
                sorts[kind] = Self.comparators(saved)
            }
        }
    }

    static func columnsKey(_ kind: TrackTableKind) -> String { "TrackTableColumns.\(kind.rawValue)" }
    static func sortKey(_ kind: TrackTableKind) -> String { "TrackTableSort.\(kind.rawValue)" }

    func columns(_ kind: TrackTableKind) -> TableColumnCustomization<TrackRow> { columns[kind] ?? TableColumnCustomization() }

    func setColumns(_ value: TableColumnCustomization<TrackRow>, for kind: TrackTableKind) {
        guard columns[kind] != value else { return }
        columns[kind] = value
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.columnsKey(kind)) }
    }

    func sortOrder(_ kind: TrackTableKind) -> [KeyPathComparator<TrackRow>] { sorts[kind] ?? [] }

    func setSortOrder(_ order: [KeyPathComparator<TrackRow>], for kind: TrackTableKind) {
        guard kind.keepsSort, sorts[kind] != order else { return }
        sorts[kind] = order
        if let data = try? JSONEncoder().encode(Self.saved(order)) { defaults.set(data, forKey: Self.sortKey(kind)) }
    }

    /// A sort as it is saved: the columns by name, most significant first.
    nonisolated static func saved(_ order: [KeyPathComparator<TrackRow>]) -> [SavedSort] {
        order.compactMap { comparator in
            TrackColumn.of(comparator).map { SavedSort(column: $0.rawValue, forward: comparator.order == .forward) }
        }
    }

    /// A saved sort as the table's comparators. A column this version doesn't know is left out.
    nonisolated static func comparators(_ saved: [SavedSort]) -> [KeyPathComparator<TrackRow>] {
        saved.compactMap { TrackColumn(rawValue: $0.column)?.comparator(forward: $0.forward) }
    }
}

extension FilterScope {
    /// The kind of track table a page with this filter shows.
    var tableKind: TrackTableKind {
        switch self {
        case .sidebar(.songs): .songs
        case .sidebar(.favorites): .favorites
        case .search: .search
        default: .playlist
        }
    }
}
