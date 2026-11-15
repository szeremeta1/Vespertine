//
// Vespertine: a big library must open, and answer the first questions the window asks, without work that grows with
// the number of songs where the window waits for it. Timings are compared as ratios between library sizes (best of
// several runs), never against a clock; the totals are compared by the work counted, not by time.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
@testable import VespertineLibrary

@Suite("Library at scale")
struct LibraryScaleTests {
    /// A library file of `songs` FLAC tracks (12 to an album, 10 albums to an artist), made in one statement.
    private func makeLibrary(songs: Int, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("Library-\(songs).sqlite")
        let db = try LibraryDatabase(url: url)
        let source = try db.addSource(LibrarySource(path: "/m", mode: .reference))
        try db.writer.write { db in
            try db.execute(sql: """
                WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < \(songs - 1))
                INSERT INTO track (sourceId, location, filePath, fileSize, modifiedAt, addedAt, codec, isLossless, isDSD, sampleRate,
                                   channels, duration, title, artist, album, trackNumber)
                SELECT \(source.id!), '/m/a' || (i / 12) || '/' || i || '.flac', '/m/a' || (i / 12) || '/' || i || '.flac', 1000 + i,
                       '2023-11-14 00:00:00.000', '2023-11-14 00:00:00.000', 'FLAC', 1, 0, 96000, 2, 180, 'Song ' || i,
                       'Artist ' || (i / 120), 'Album ' || (i / 12), i % 12 + 1 FROM n
                """)
        }
        return url
    }

    private func best(of runs: Int = 5, _ work: () throws -> Void) rethrows -> Duration {
        var fastest = Duration.seconds(3600)
        for _ in 0..<runs {
            let start = ContinuousClock.now
            try work()
            fastest = min(fastest, ContinuousClock.now - start)
        }
        return fastest
    }

    @Test("Opening a library doesn't read its songs: 100 times the songs is nowhere near 100 times the time")
    func openDoesNotScaleWithSongs() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let small = try makeLibrary(songs: 1_000, in: dir)
        let large = try makeLibrary(songs: 100_000, in: dir)
        let smallTime = try best { _ = try LibraryDatabase(url: small) }
        let largeTime = try best { _ = try LibraryDatabase(url: large) }
        let opened = try LibraryDatabase(url: large)
        #expect(try opened.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM track") } == 100_000)
        #expect(largeTime.seconds < smallTime.seconds * 10 + 0.001, "open: \(smallTime) for 1,000 songs, \(largeTime) for 100,000")
    }

    /// How many steps SQLite's virtual machine takes for `work` on the library at `url`: the work itself, counted, so a
    /// machine that is busy with other things counts the same as one that is not.
    private func steps(_ url: URL, _ work: (LibraryDatabase) throws -> Void) throws -> Int {
        final class Counter { var steps = 0 }
        let queue = try DatabaseQueue(path: url.path, configuration: LibraryDatabase.queueConfiguration())
        let library = try LibraryDatabase(writer: queue)
        let counter = Counter()
        try queue.writeWithoutTransaction { db in
            sqlite3_progress_handler(db.sqliteConnection, 1, { context in
                Unmanaged<Counter>.fromOpaque(context!).takeUnretainedValue().steps += 1
                return 0
            }, Unmanaged.passUnretained(counter).toOpaque())
        }
        defer { try? queue.writeWithoutTransaction { db in sqlite3_progress_handler(db.sqliteConnection, 0, nil, nil) } }
        try work(library)
        return counter.steps
    }

    @Test("The sidebar's totals grow in step with the library, not faster")
    func statsAreLinear() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let medium = try makeLibrary(songs: 10_000, in: dir)
        let large = try makeLibrary(songs: 100_000, in: dir)
        // The work is counted, not timed: ten times the songs may cost ten times the steps and the sorting that goes with
        // them, never the hundred times of a query that looks at every song for every song.
        let mediumSteps = try steps(medium) { _ = try $0.stats() }
        let largeSteps = try steps(large) { #expect(try $0.stats().tracks == 100_000) }
        #expect(mediumSteps > 10_000, "the count sees the query's work: \(mediumSteps) steps for 10,000 songs")
        #expect(largeSteps < mediumSteps * 20, "stats: \(mediumSteps) steps for 10,000 songs, \(largeSteps) for 100,000")
    }

    @Test("Searching finds songs through the index: a hundred thousand songs cost a few times what ten thousand do")
    func searchIsIndexed() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let medium = try LibraryDatabase(url: try makeLibrary(songs: 10_000, in: dir))
        let large = try LibraryDatabase(url: try makeLibrary(songs: 100_000, in: dir))
        // Few songs match, so the cost is the index lookup, not the size of the table.
        let mediumTime = try best { _ = try medium.search("song 4242") }
        let largeTime = try best { _ = try large.search("song 4242") }
        #expect(try medium.search("song 4242").count == 1)
        #expect(try large.search("song 4242").count == 23, "song 4242 and 42420 to 42429 (every word is a prefix) and the 12 songs of Album 4242")
        #expect(largeTime.seconds < mediumTime.seconds * 30 + 0.002, "search: \(mediumTime) for 10,000 songs, \(largeTime) for 100,000")
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
