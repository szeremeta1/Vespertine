// Vespertine: tests for the order a track table's sort gives, and for its rows keeping their places.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import VespertineLibrary
@testable import Vespertine

@Suite("Track table sort order") @MainActor
struct TrackSortTests {
    private static let orders: [(String, [KeyPathComparator<TrackRow>])] = [
        ("number", [KeyPathComparator(\TrackRow.index)]),
        ("number, descending", [KeyPathComparator(\TrackRow.index, order: .reverse)]),
        ("title", [KeyPathComparator(\TrackRow.track.title)]),
        ("title, descending", [KeyPathComparator(\TrackRow.track.title, order: .reverse)]),
        ("artist", [KeyPathComparator(\TrackRow.track.displayArtist)]),
        ("artist, descending", [KeyPathComparator(\TrackRow.track.displayArtist, order: .reverse)]),
        ("album", [KeyPathComparator(\TrackRow.track.displayAlbum)]),
        ("album, descending", [KeyPathComparator(\TrackRow.track.displayAlbum, order: .reverse)]),
        ("format", [KeyPathComparator(\TrackRow.track.sampleRate)]),
        ("format, descending", [KeyPathComparator(\TrackRow.track.sampleRate, order: .reverse)]),
        ("time", [KeyPathComparator(\TrackRow.track.duration)]),
        ("time, descending", [KeyPathComparator(\TrackRow.track.duration, order: .reverse)]),
        ("artist descending, then time", [KeyPathComparator(\TrackRow.track.displayArtist, order: .reverse), KeyPathComparator(\TrackRow.track.duration)]),
        ("format, then title descending, then number", [KeyPathComparator(\TrackRow.track.sampleRate), KeyPathComparator(\TrackRow.track.title, order: .reverse), KeyPathComparator(\TrackRow.index)]),
    ]

    /// Songs whose names sort differently by code point than as a person reads them, with ties in every column.
    private func awkward() throws -> [Track] {
        var tracks = try SortFixture.library(240)
        let titles = ["Track 10", "Track 9", "track 2", "Élan", "Eclipse", "eclipse", "Zebra", "Ábaco", "10,000 Days", "9 to 5", "", "Track 9"]
        for i in tracks.indices where i % 3 == 0 { tracks[i].title = titles[(i / 3) % titles.count] }
        for i in tracks.indices where i % 7 == 0 { tracks[i].artist = nil; tracks[i].albumArtist = i % 14 == 0 ? nil : "The Vesper Quartet" }
        for i in tracks.indices where i % 5 == 0 { tracks[i].album = nil }
        return tracks
    }

    /// The order SwiftUI's own sort gives the rows: what the table did before, a whole song moved per comparison.
    private func reference(_ tracks: [Track], positions: [Int]?, order: [KeyPathComparator<TrackRow>]) -> [Int64?] {
        SortedRows().content(tracks: tracks, positions: positions, order: []).rows.sorted(using: order).map(\.trackID)
    }

    @Test("Every column sorts as the table's own comparison does, ties in the list's order", arguments: 0..<14)
    func sameOrder(_ which: Int) throws {
        let (name, order) = Self.orders[which]
        let tracks = try awkward()
        let positions = tracks.indices.map { $0 * 2 + 1 }
        for positions in [nil, positions] {
            let sorted = SortedRows().content(tracks: tracks, positions: positions, order: order)
            #expect(sorted.rows.map(\.trackID) == reference(tracks, positions: positions, order: order), "\(name)")
            #expect(sorted.rows.map(\.id) == tracks.indices.map { Int64($0) }, "rows are numbered as shown")
        }
    }

    @Test("A sort changes what the rows show, not the rows")
    func rowsKeepTheirPlaces() throws {
        let tracks = try awkward()
        let rows = SortedRows()
        let unsorted = rows.content(tracks: tracks, positions: nil, order: [])
        let first = unsorted.rows.map(\.trackID)
        let sorted = rows.content(tracks: tracks, positions: nil, order: [KeyPathComparator(\TrackRow.track.title)])
        #expect(sorted.rows == unsorted.rows, "the same rows: nothing for the table to move, insert or remove")
        #expect(sorted.rows.map(\.trackID) != first)
        #expect(sorted.list == unsorted.list, "the same list")
        #expect(sorted.arrangement != unsorted.arrangement, "in another arrangement")
        let fewer = rows.content(tracks: Array(tracks.prefix(100)), positions: nil, order: [KeyPathComparator(\TrackRow.track.title)])
        #expect(fewer.rows == Array(unsorted.rows.prefix(100)), "a shorter list keeps the rows it still has")
        #expect(fewer.list != sorted.list)
    }

    @Test("A long list is sorted off the main thread: the table shows what it had until the order is ready")
    func longListsSortInTheBackground() async throws {
        let tracks = try SortFixture.library(SortedRows.immediateLimit * 4)
        let order = [KeyPathComparator(\TrackRow.track.title, order: .reverse)]
        let rows = SortedRows()
        let unsorted = rows.content(tracks: tracks, positions: nil, order: [])
        let listed = unsorted.rows.map(\.trackID)
        let waiting = rows.content(tracks: tracks, positions: nil, order: order)
        #expect(rows.isSorting)
        #expect(waiting.arrangement == unsorted.arrangement && waiting.rows.map(\.trackID) == listed, "still the list's order")
        // Asking again while it sorts starts nothing over.
        _ = rows.content(tracks: tracks, positions: nil, order: order)
        for _ in 0..<600 where rows.isSorting { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(!rows.isSorting)
        let sorted = rows.content(tracks: tracks, positions: nil, order: order)
        #expect(sorted.rows == unsorted.rows)
        #expect(sorted.rows.map(\.trackID) == reference(tracks, positions: nil, order: order))

        // A sort that is no longer wanted is dropped: back to the list's order at once, and it stays.
        _ = rows.content(tracks: tracks, positions: nil, order: [KeyPathComparator(\TrackRow.track.displayAlbum)])
        #expect(rows.isSorting)
        let back = rows.content(tracks: tracks, positions: nil, order: order)
        #expect(!rows.isSorting && back.arrangement == sorted.arrangement)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(rows.content(tracks: tracks, positions: nil, order: order).arrangement == sorted.arrangement)
    }
}
