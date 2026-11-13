import Foundation
import VespertineLibrary
import Testing
@testable import Vespertine

/// The TIDAL master switch (decision 209): off, the store shows the library exactly as one that never had a TIDAL account, from the
/// first frame; switching it on and off again re-reads every list without a restart, and deletes nothing.
@Suite("TIDAL switch") @MainActor
struct TidalSwitchTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-tidal-switch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func seed(_ root: URL) throws {
        let database = try LibraryDatabase(url: root.appendingPathComponent("Library.sqlite"))
        let local = try database.addSource(LibrarySource(path: "/Volumes/QA/Music", mode: .reference))
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO track (sourceId, location, filePath, fileSize, modifiedAt, addedAt, codec, isLossless, isDSD,
                                   sampleRate, bitDepth, channels, duration, title, artist, album, trackNumber)
                VALUES (?, '/Volumes/QA/Music/a.flac', '/Volumes/QA/Music/a.flac', 1, '2023-11-14 22:13:20.000',
                        '2026-10-14 12:00:00.000', 'FLAC', 1, 0, 96000, 24, 2, 180, 'A', 'Artist', 'Album', 1)
                """, arguments: [local.id])
        }
        let tidal = try #require(try database.tidalSource(userId: 1).id)
        try database.upsertTidalTracks([TidalTrackInput(tidalId: 1, title: "Streamed", artist: "Other", album: "Streamed Album", albumArtist: "Other")],
                                       sourceId: tidal)
    }

    @Test("Off by default: the store reads like a library without TIDAL, and the TIDAL source is not in `sources`")
    func hiddenAtLaunch() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try seed(root)
        let library = try LibraryStore(dataDirectory: root)
        #expect(library.stats.tracks == 1 && library.stats.albums == 1)
        #expect(library.sources.map(\.path) == ["/Volumes/QA/Music"])
        #expect(library.tidalSource == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(library.albums.map(\.title) == ["Album"] && library.artists.map(\.name) == ["Artist"])
        #expect(library.stats.tracks == 1)
    }

    @Test("Switching on shows the TIDAL rows and the source apart from the folders; off hides them again, deleting nothing")
    func switching() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try seed(root)
        let library = try LibraryStore(dataDirectory: root)
        library.setIncludeTidal(true)
        #expect(library.stats.tracks == 2 && library.stats.albums == 2)
        #expect(library.sources.map(\.path) == ["/Volumes/QA/Music"], "TIDAL is no folder or share")
        #expect(library.tidalSource?.isTidal == true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(library.albums.map(\.title).sorted() == ["Album", "Streamed Album"])
        #expect(library.artists.count == 2)
        library.setIncludeTidal(false)
        #expect(library.stats.tracks == 1 && library.tidalSource == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(library.albums.map(\.title) == ["Album"] && library.artists.count == 1)
        let rows = try await library.database.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM track") }
        #expect(rows == 2, "nothing was deleted")
    }

    @Test("A library that starts with the switch on shows TIDAL from the first frame")
    func onAtLaunch() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try seed(root)
        let library = try LibraryStore(dataDirectory: root, includeTidal: true)
        #expect(library.stats.tracks == 2 && library.tidalSource != nil)
    }
}
