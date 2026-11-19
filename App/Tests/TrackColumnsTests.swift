// Vespertine: the columns of track tables: every sortable column sorts as the table would, empty fields sort first,
// and the chosen columns and sort of each kind of page are kept, and read back, by name.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftUI
import Testing
import VespertineLibrary
@testable import Vespertine

@Suite("Track table columns") @MainActor
struct TrackColumnsTests {
    private func defaults() -> UserDefaults {
        let name = "TrackColumnsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Five songs with plays, last plays, years and ratings in no particular order, one of them never played.
    private func songs() throws -> [Track] {
        var tracks = try SortFixture.library(5)
        let plays = [3, 41, 0, 7, 41], years: [Int?] = [1977, nil, 1959, 2024, 1959], ratings: [Int?] = [60, nil, 100, 20, 80]
        for i in tracks.indices {
            tracks[i].playCount = plays[i]
            tracks[i].lastPlayedAt = plays[i] == 0 ? nil : Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 3600)
            tracks[i].year = years[i]
            tracks[i].rating = ratings[i]
            tracks[i].addedAt = Date(timeIntervalSince1970: 1_600_000_000 - Double(i) * 86_400)
        }
        return tracks
    }

    /// The list's order sorted by `column`, as track IDs.
    private func sorted(_ tracks: [Track], by column: TrackColumn, forward: Bool) throws -> [Int64] {
        let comparator = try #require(column.comparator(forward: forward))
        let columns = try #require(TrackSort.columns([comparator], tracks: tracks, positions: nil))
        return TrackSort.order(columns, count: tracks.count).compactMap { tracks[$0].id }
    }

    @Test("Most played first, ties in the list's order; a song never played is last by Last Played")
    func mostPlayed() throws {
        let tracks = try songs()
        #expect(try sorted(tracks, by: .plays, forward: false) == [2, 5, 4, 1, 3])
        #expect(try sorted(tracks, by: .lastPlayed, forward: false) == [5, 4, 2, 1, 3])
        #expect(try sorted(tracks, by: .dateAdded, forward: false) == [1, 2, 3, 4, 5])
    }

    @Test("A song without a year or a rating sorts before the others, and after them reversed")
    func emptyFieldsFirst() throws {
        let tracks = try songs()
        #expect(try sorted(tracks, by: .year, forward: true) == [2, 3, 5, 1, 4])
        #expect(try sorted(tracks, by: .rating, forward: false) == [3, 5, 1, 4, 2])
    }

    @Test("Every sortable column has values for the fast sort, and is found again from its comparator")
    func everyColumnSorts() throws {
        let tracks = try songs()
        for column in TrackColumn.allCases {
            guard let comparator = column.comparator() else {
                #expect(column == .source || column == .favorite)
                continue
            }
            #expect(TrackColumn.of(comparator) == column)
            #expect(column.values(tracks, positions: nil) != nil, "\(column)")
        }
    }

    @Test("Songs and Favorites keep their sort and columns, each its own; an album never keeps a sort")
    func kept() throws {
        let defaults = defaults()
        let layouts = TrackTableLayouts(defaults: defaults)
        let mostPlayed = try #require(TrackColumn.plays.comparator(forward: false))
        let byTitle = try #require(TrackColumn.title.comparator(forward: true))
        layouts.setSortOrder([mostPlayed, byTitle], for: .songs)
        layouts.setSortOrder([byTitle], for: .album)
        var columns = TableColumnCustomization<TrackRow>()
        columns[visibility: TrackColumn.plays.rawValue] = .visible
        layouts.setColumns(columns, for: .favorites)

        let again = TrackTableLayouts(defaults: defaults)
        #expect(again.sortOrder(.songs) == [mostPlayed, byTitle])
        #expect(again.sortOrder(.favorites).isEmpty)
        #expect(again.sortOrder(.album).isEmpty)
        #expect(again.columns(.favorites)[visibility: TrackColumn.plays.rawValue] == .visible)
        #expect(again.columns(.songs) == TableColumnCustomization<TrackRow>())
    }

    @Test("A saved column this version doesn't know is left out of the sort, not the whole sort")
    func unknownColumn() {
        let saved = [TrackTableLayouts.SavedSort(column: "moodRing", forward: true), .init(column: "plays", forward: false)]
        #expect(TrackTableLayouts.comparators(saved) == [TrackColumn.plays.comparator(forward: false)!])
    }

    @Test("Ratings show as up to five stars whatever scale the tag uses")
    func stars() throws {
        var t = try #require(try SortFixture.library(1).first)
        for (rating, stars) in [(nil, ""), (0, ""), (3, "★★★"), (80, "★★★★"), (100, "★★★★★"), (255, "★★★★★"), (1, "★")] as [(Int?, String)] {
            t.rating = rating
            #expect(t.ratingStars == stars, "\(String(describing: rating))")
        }
    }
}
