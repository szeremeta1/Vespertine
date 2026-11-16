//
// Vespertine: the library with its files left out (the app's Local Library switch, off). Every query answers as if the folders,
// drives and shares had never been added; a music server's songs are still answered; nothing is deleted.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
@testable import VespertineLibrary
@testable import VespertineStreaming

@Suite("Library with the files left out")
struct LocalLibraryHiddenTests {
    /// The folder's three songs, and one server account with two songs: one on an album the folder has too, one of its own.
    private func library() throws -> (database: LibraryDatabase, fileIDs: [Int64]) {
        let (database, ids) = try TestLibrary.files()
        try database.addStreamedSource(provider: "fake", account: "home", name: "Home server")
        try database.writeStreamedSongs([
            TestLibrary.song("s1", title: "Lamplight", artist: "The Night Shift", album: "Quiet Hours", number: 1),
            TestLibrary.song("s2", title: "Far Shore", artist: "Mira Vale", album: "Tidewater", number: 1, genre: "Ambient"),
        ], provider: "fake", account: "home")
        return (database, ids)
    }

    @Test("A database nobody switched shows its files")
    func shownByDefault() throws {
        let (database, ids) = try library()
        #expect(database.showsFiles)
        #expect(try database.allTracks().count == 5)
        #expect(try database.tracks(ids: ids).count == 3)
    }

    @Test("With the files left out and no server shown, every query answers as an empty library does, and nothing is deleted")
    func filesOutNothingLeft() async throws {
        let (database, ids) = try library()
        let all = try LibraryAnswers(database)
        database.shownProviders = []
        let filesOnly = try LibraryAnswers(database)
        #expect(filesOnly.tracks.count == 3)

        database.showsFiles = false
        let off = try LibraryAnswers(database)
        #expect(off.albums.isEmpty)
        #expect(off.albumsByTitle.isEmpty)
        #expect(off.albumsOfArtist.isEmpty)
        #expect(off.albumTracks.isEmpty)
        #expect(off.tracks.isEmpty)
        #expect(off.tracksByID.isEmpty)
        #expect(off.artists.isEmpty)
        #expect(off.genres.isEmpty)
        #expect(off.playlistTracks.allSatisfy(\.isEmpty), "the listener's playlists stay, without the songs that are left out")
        #expect(off.playlists.map(\.name) == filesOnly.playlists.map(\.name))
        #expect(off.search.isEmpty)
        #expect(off.searchSubstring.isEmpty)
        #expect(off.history.isEmpty)
        #expect(off.favorites.isEmpty)
        #expect(off.favoriteIDs.isEmpty)
        #expect(off.stats.tracks == 0)
        #expect(off.stats.albums == 0)
        #expect(off.accounts.isEmpty)
        #expect(try database.tracks(ids: ids).isEmpty)
        #expect(try database.writer.read { db in try database.visibleTracksClause(db) } == "0")

        // Nothing was deleted: the rows are where they were, and every answer comes back with the switches.
        let rows = try await database.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM track") }
        #expect(rows == 5)
        #expect(try database.sources().count == 1, "the folder is still a source of the library")
        database.showsFiles = true
        #expect(try LibraryAnswers(database) == filesOnly)
        database.shownProviders = ["fake"]
        #expect(try LibraryAnswers(database) == all)
    }

    @Test("With the files left out, a server that is shown is the whole library: its songs, albums, artists, search and counts")
    func filesOutServerLeft() throws {
        let (database, ids) = try library()
        database.shownProviders = ["fake"]
        let both = try LibraryAnswers(database)
        #expect(both.tracks.count == 5)
        #expect(both.albums.count == 3, "the album both have is one album")

        database.showsFiles = false
        let servers = try LibraryAnswers(database)
        #expect(servers.tracks.count == 2)
        #expect(servers.tracks.allSatisfy(\.isStreamed))
        #expect(Set(servers.albums.map(\.title)) == ["Quiet Hours", "Tidewater"])
        #expect(servers.albums.first { $0.title == "Quiet Hours" }?.trackCount == 1, "only the server's copy of the shared album")
        #expect(Set(servers.artists.map(\.name)) == ["The Night Shift", "Mira Vale"])
        #expect(servers.stats.tracks == 2)
        #expect(servers.stats.albums == 2)
        #expect(servers.accounts.count == 1)
        #expect(try database.tracks(ids: ids).isEmpty)
        #expect(try database.search("Slipway").isEmpty, "a song only the folder has")
        #expect(try database.search("Far Shore").count == 1)
        #expect(try database.stats(filesOnly: true).tracks == 0)

        // A file's row without a source (a song opened by itself, before sources were kept) is a file's too.
        try database.writer.write { db in
            var loose = TestLibrary.file("/Users/test/Desktop/Loose.flac", title: "Loose", artist: "Nobody", album: "Singles", number: 1, sourceID: nil)
            try loose.insert(db)
        }
        #expect(try database.allTracks().count == 2)
        #expect(try database.search("Loose").isEmpty)

        database.showsFiles = true
        #expect(try database.allTracks().count == 6)
    }
}
