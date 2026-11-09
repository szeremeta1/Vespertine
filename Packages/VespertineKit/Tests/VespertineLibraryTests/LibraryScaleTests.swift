//
// Vespertine: a big library must open, and answer the first questions the window asks, without work that grows with
// the number of songs where the window waits for it. Timings are compared as ratios between library sizes (best of
// several runs), never against a clock.
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

    @Test("The sidebar's totals grow in step with the library, not faster")
    func statsAreLinear() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let medium = try LibraryDatabase(url: try makeLibrary(songs: 10_000, in: dir))
        let large = try LibraryDatabase(url: try makeLibrary(songs: 100_000, in: dir))
        let mediumTime = try best { _ = try medium.stats() }
        let largeTime = try best { _ = try large.stats() }
        let stats = try large.stats()
        #expect(stats.tracks == 100_000)
        #expect(largeTime.seconds < mediumTime.seconds * 40, "stats: \(mediumTime) for 10,000 songs, \(largeTime) for 100,000")
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
