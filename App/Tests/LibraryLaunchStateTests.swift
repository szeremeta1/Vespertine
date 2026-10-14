import Foundation
import VespertineLibrary
import Testing
@testable import Vespertine

/// Issue #54: the sidebar's rows (playlists, sources) and the library-or-empty-screen choice must be in place before
/// the first frame. Left to the database observations, they arrived a moment after the window was up, in separate
/// updates of the sidebar's outline view, and AppKit logged "reentrant operation in its NSTableView delegate".
@Suite("Library launch state") @MainActor
struct LibraryLaunchStateTests {
    @Test("A library opens with its sources, playlists and counts already read")
    func sidebarStateIsReadBeforeTheFirstFrame() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-launch-state-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let database = try LibraryDatabase(url: root.appendingPathComponent("Library.sqlite"))
            let source = try database.addSource(LibrarySource(path: "/Volumes/QA/Music", mode: .reference))
            _ = try database.createPlaylist(name: "Evening")
            try await database.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO track (sourceId, location, filePath, fileSize, modifiedAt, addedAt, codec, isLossless, isDSD,
                                       sampleRate, bitDepth, channels, duration, title, artist, album, trackNumber)
                    VALUES (?, '/Volumes/QA/Music/a.flac', '/Volumes/QA/Music/a.flac', 1, '2023-11-14 22:13:20.000',
                            '2026-10-14 12:00:00.000', 'FLAC', 1, 0, 96000, 24, 2, 180, 'A', 'Artist', 'Album', 1)
                    """, arguments: [source.id])
            }
        }

        let library = try LibraryStore(dataDirectory: root)
        // No suspension point since init: nothing the observations deliver has run yet.
        #expect(library.sources.map(\.path) == ["/Volumes/QA/Music"])
        #expect(library.playlists.map(\.name).last == "Evening")   // after the built-in smart playlists
        #expect(library.stats.tracks == 1 && library.stats.albums == 1)

        // Once the observations deliver their first values, the sidebar's data is unchanged.
        let sources = library.sources, playlists = library.playlists, stats = library.stats
        try await Task.sleep(for: .milliseconds(300))
        #expect(library.sources == sources && library.playlists == playlists && library.stats == stats)
    }
}
