//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
@testable import VespertineLibrary

@Suite("Favorites")
struct FavoritesTests {
    /// A library of three scanned files: a.wav, b.wav, c.wav.
    private func library() async throws -> (LibraryDatabase, LibraryScanner, LibrarySource, URL) {
        let dir = try tempDir()
        for name in ["a", "b", "c"] { try makeWAV(dir.appendingPathComponent("\(name).wav")) }
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference))
        try await scanner.scan(source)
        return (db, scanner, source, dir)
    }

    private func id(_ db: LibraryDatabase, _ name: String) throws -> Int64 {
        try #require(try db.allTracks().first { $0.filePath.hasSuffix("/\(name).wav") }?.id)
    }

    @Test("Newest favorite first; favoriting again keeps the first date; removing works")
    func addRemoveOrder() async throws {
        let (db, _, _, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try id(db, "a"), b = try id(db, "b"), c = try id(db, "c")
        let start = Date(timeIntervalSince1970: 1_000_000)
        try db.setFavorite(true, trackIDs: [a], at: start)
        try db.setFavorite(true, trackIDs: [c], at: start.addingTimeInterval(60))
        try db.setFavorite(true, trackIDs: [a], at: start.addingTimeInterval(120))   // already a favorite
        #expect(try db.favoriteTracks().map(\.id) == [c, a])

        try db.setFavorite(false, trackIDs: [c, b])   // b never was one
        #expect(try db.favoriteTracks().map(\.id) == [a])
        try db.setFavorite(true, trackIDs: [999_999])   // no such track: ignored
        #expect(try db.favoriteTracks().map(\.id) == [a])
    }

    @Test("Missing files are hidden, and deleted tracks take their favorite with them")
    func missingAndDeleted() async throws {
        let (db, scanner, source, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try id(db, "a"), b = try id(db, "b")
        try db.setFavorite(true, trackIDs: [a, b])
        try FileManager.default.removeItem(at: dir.appendingPathComponent("b.wav"))
        try await scanner.scan(source)
        #expect(try db.favoriteTracks().map(\.id) == [a])

        try db.removeSource(try #require(source.id))
        let rows = try await db.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM favorite") }
        #expect(rows == 0)
    }

    @Test("A moved file stays a favorite")
    func movedFile() async throws {
        let (db, scanner, source, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try id(db, "a")
        let date = Date(timeIntervalSince1970: 2_000_000)
        try db.setFavorite(true, trackIDs: [a], at: date)

        let moved = dir.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: dir.appendingPathComponent("a.wav"), to: moved.appendingPathComponent("a.wav"))
        try await scanner.scan(source)

        let favorites = try db.favoriteTracks()
        #expect(favorites.count == 1)
        #expect(favorites.first?.filePath.hasSuffix("/Moved/a.wav") == true)
        #expect(favorites.first?.id != a)
        let kept = try await db.writer.read { db in try Date.fetchOne(db, sql: "SELECT favoritedAt FROM favorite") }
        #expect(kept == date)
    }

    @Test("Smart playlists can match favorites")
    func smartRule() async throws {
        let (db, _, _, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let b = try id(db, "b")
        try db.setFavorite(true, trackIDs: [b])
        let on = try db.createPlaylist(name: "Loved", rules: SmartRules(rules: [SmartRule(field: .isFavorite, op: .isTrue)]))
        let off = try db.createPlaylist(name: "Not yet", rules: SmartRules(rules: [SmartRule(field: .isFavorite, op: .isFalse)]))
        #expect(try db.tracks(in: on).map(\.id) == [b])
        #expect(try db.tracks(in: off).count == 2)
        #expect(SmartRule.Field.isFavorite.operators == [.isTrue, .isFalse])
    }

    @Test("A favorite is the copy hearted; bundled copies are favorites together; a song counts once")
    func versionsTogether() throws {
        let db = try LibraryDatabase.inMemory()
        let source = try db.addSource(LibrarySource(path: "/m", mode: .reference))
        func track(_ folder: String, _ n: Int, _ title: String, channels: Int) -> Track {
            var t = Track.stub(path: "/m/Dire Straits/BIA/\(folder)/\(n).dsf")
            t.sourceId = source.id
            t.album = "Brothers In Arms"; t.albumArtist = "Dire Straits"; t.trackNumber = n; t.title = title
            t.channels = channels; t.isDSD = true; t.sampleRate = 2_822_400; t.bitDepth = nil
            return t
        }
        let tracks = [track("Multichannel", 1, "So Far Away", channels: 6), track("Stereo", 1, "So Far Away", channels: 2),
                      track("Multichannel", 2, "Money For Nothing", channels: 6), track("Stereo", 2, "Money For Nothing", channels: 2)]
        let ids = try db.writer.write { db in try tracks.map { t -> Int64 in var t = t; try t.insert(db); return t.id! } }
        #expect(try db.favoriteEveryVersion() == 0)

        // Favorited on headphones: only the stereo copy was hearted, and only it is a favorite while the album's copies
        // are separate (the default: hearting one copy never makes the other one a favorite).
        let date = Date(timeIntervalSince1970: 3_000_000)
        try db.setFavorite(true, trackIDs: [ids[1]], at: date)
        #expect(try db.favoriteEveryVersion() == 1)
        #expect(Set(try db.favoriteTracks().compactMap(\.id)) == [ids[1]])

        // Bundled, the song is one favorite whichever copy plays: the 5.1 copy joins, from the day the song was.
        try db.setCopyChoice(.bundled, albumKey: tracks[0].albumKey)
        #expect(try db.favoriteEveryVersion() == 1)
        #expect(Set(try db.favoriteTracks().compactMap(\.id)) == [ids[0], ids[1]])
        let dates = try db.writer.read { db in try Date.fetchAll(db, sql: "SELECT favoritedAt FROM favorite") }
        #expect(dates == [date, date], "the 5.1 version is a favorite from the day the song was")

        #expect(try db.favoriteEveryVersion() == 1, "nothing more to add")
        #expect(try db.favoriteTracks().count == 2)

        // Bundling only reads the hearts: switching back to separate copies leaves exactly the copy that was hearted.
        try db.setCopyChoice(.automatic, albumKey: tracks[0].albumKey)
        #expect(try db.favoriteEveryVersion() == 1)
        #expect(Set(try db.favoriteTracks().compactMap(\.id)) == [ids[1]], "the 5.1 copy's heart was only borrowed")

        // No choice for the album: copies are separate, unless bundling is the app's default.
        #expect(try db.favoriteEveryVersion(bundledByDefault: true) == 1 && db.favoriteTracks().count == 2)
        #expect(try db.favoriteEveryVersion() == 1 && Set(try db.favoriteTracks().compactMap(\.id)) == [ids[1]])
    }

    @Test("A copy hearted on its own stays a favorite when bundling ends; unhearting the real favorite takes the borrowed ones")
    func borrowedHeartsFollowTheRealOne() throws {
        let db = try LibraryDatabase.inMemory()
        let source = try db.addSource(LibrarySource(path: "/m", mode: .reference))
        func track(_ folder: String) -> Track {
            var t = Track.stub(path: "/m/A/B/\(folder)/1.flac")
            t.sourceId = source.id
            t.album = "B"; t.albumArtist = "A"; t.trackNumber = 1; t.title = "One"
            t.channels = folder == "Multichannel" ? 6 : 2
            return t
        }
        let tracks = [track("Multichannel"), track("Stereo")]
        let ids = try db.writer.write { db in try tracks.map { t -> Int64 in var t = t; try t.insert(db); return t.id! } }
        let album = tracks[0].albumKey
        try db.setFavorite(true, trackIDs: [ids[1]])
        try db.setCopyChoice(.bundled, albumKey: album)
        try db.favoriteEveryVersion()
        #expect(Set(try db.favoriteTracks().compactMap(\.id)) == [ids[0], ids[1]])

        // Hearting the borrowed copy for real makes it a favorite of its own.
        try db.setFavorite(true, trackIDs: [ids[0]])
        try db.setFavorite(false, trackIDs: [ids[1]])
        try db.setCopyChoice(.automatic, albumKey: album)
        #expect(try db.favoriteEveryVersion() == 1)
        #expect(Set(try db.favoriteTracks().compactMap(\.id)) == [ids[0]])

        // Bundled again, then the only real favorite goes: nothing borrowed stays behind.
        try db.setCopyChoice(.bundled, albumKey: album)
        try db.favoriteEveryVersion()
        #expect(Set(try db.favoriteTracks().compactMap(\.id)) == [ids[0], ids[1]])
        try db.setFavorite(false, trackIDs: [ids[0]])
        #expect(try db.favoriteEveryVersion() == 0)
        #expect(try db.favoriteTracks().isEmpty)
    }
}
