//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import Testing
@testable import VespertineLibrary

@Suite("Playlist import and export")
struct PlaylistInterchangeTests {
    /// A library of three scanned files, a.wav, b.wav and c.wav, tagged "Artist N" / "Song N".
    private func library() async throws -> (LibraryDatabase, URL) {
        let dir = try tempDir()
        for name in ["a", "b", "c"] { try makeWAV(dir.appendingPathComponent("\(name).wav")) }
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference))
        try await scanner.scan(source)
        try await db.writer.write { db in
            for (i, name) in ["a", "b", "c"].enumerated() {
                try db.execute(sql: "UPDATE track SET title = ?, artist = ? WHERE filePath LIKE ?",
                               arguments: ["Song \(i + 1)", "Artist \(i + 1)", "%/\(name).wav"])
            }
        }
        return (db, dir)
    }

    private func id(_ db: LibraryDatabase, _ name: String) throws -> Int64 {
        try #require(try db.allTracks().first { $0.filePath.hasSuffix("/\(name).wav") }?.id)
    }

    @Test("Reads relative and absolute paths, file URLs, Windows separators and #EXTINF, and skips streams")
    func readM3U() {
        let base = URL(fileURLWithPath: "/Music/Lists")
        let text = """
        \u{FEFF}#EXTM3U
        #EXTINF:245,Miles Davis - So What
        ../Jazz/So What.flac
        /Volumes/NAS/a.flac
        file:///Users/me/Music/b%20c.flac
        #EXTINF:-1,Radio
        http://stream.example.com/live
        Sub\\Dir\\d.mp3
        """
        let entries = M3U.entries(text, base: base)
        #expect(entries.map(\.path) == ["/Music/Jazz/So What.flac", "/Volumes/NAS/a.flac", "/Users/me/Music/b c.flac",
                                        "/Music/Lists/Sub/Dir/d.mp3"])
        #expect(entries[0].artist == "Miles Davis" && entries[0].title == "So What" && entries[0].duration == 245)
        #expect(entries[1].title == nil)
    }

    @Test("Export writes an extended M3U that reads back as the same files")
    func writeM3U() async throws {
        let (db, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracks = try db.allTracks().sorted { $0.filePath < $1.filePath }
        let text = M3U.text(tracks)
        #expect(text.hasPrefix("#EXTM3U\n#EXTINF:"))
        #expect(text.contains(",Artist 1 - Song 1\n"))
        let back = M3U.entries(text, base: dir)
        #expect(try db.match(back) == tracks.map(\.id))
    }

    @Test("Matches moved files by title, artist and length, but only when exactly one song fits")
    func matchByName() async throws {
        let (db, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try id(db, "a"), b = try id(db, "b")
        let entries = [
            PlaylistEntry(path: dir.appendingPathComponent("a.wav").path),
            PlaylistEntry(path: "/Elsewhere/b.flac", title: "song 2", artist: "ARTIST 2", duration: 1),
            PlaylistEntry(path: "/Elsewhere/c.flac", title: "Song 3", artist: "Artist 3", duration: 200),   // wrong length
            PlaylistEntry(path: "/Elsewhere/x.flac", title: "Nope", artist: "Nobody"),
        ]
        #expect(try db.match(entries) == [a, b, nil, nil])

        // A second song with the same title and artist makes the name ambiguous.
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE track SET title = 'Song 2', artist = 'Artist 2' WHERE id = ?", arguments: [try trackID(in: db, "c")])
        }
        #expect(try db.match([entries[1]]) == [nil])
    }

    @Test("An imported M3U becomes a playlist of the songs it found")
    func importM3U() async throws {
        let (db, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = "#EXTM3U\nc.wav\nmissing.flac\na.wav\n"
        let (playlist, result) = try #require(try db.importPlaylist(named: "Mix", entries: M3U.entries(text, base: dir)))
        #expect(result.songs == 2 && result.unmatched == 1 && playlist.name == "Mix")
        let ids = try await db.writer.read { db in
            try Int64.fetchAll(db, sql: "SELECT trackId FROM playlistItem WHERE playlistId = ? ORDER BY position", arguments: [playlist.id])
        }
        #expect(ids == [try id(db, "c"), try id(db, "a")])
        #expect(try db.importPlaylist(named: "Empty", entries: [PlaylistEntry(path: "/nowhere.flac")]) == nil)
    }

    @Test("Reads Apple Music's library, and brings in its playlists, loved songs and play counts once")
    func appleMusic() async throws {
        let (db, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }
        func location(_ name: String) -> String { dir.appendingPathComponent("\(name).wav").absoluteString }
        let plist: [String: Any] = [
            "Tracks": [
                "1": ["Track ID": 1, "Name": "Song 1", "Location": location("a"), "Play Count": 7, "Loved": true],
                "2": ["Track ID": 2, "Name": "Song 2", "Artist": "Artist 2", "Total Time": 500, "Play Count": 3],
                "3": ["Track ID": 3, "Name": "Gone", "Location": "file:///Old/gone.m4a", "Favorited": true],
            ],
            "Playlists": [
                ["Name": "Library", "Master": true, "Playlist Items": [["Track ID": 1], ["Track ID": 2]]],
                ["Name": "Music", "Distinguished Kind": 4, "Playlist Items": [["Track ID": 1]]],
                ["Name": "Folder", "Folder": true],
                ["Name": "Road Trip", "Playlist Items": [["Track ID": 2], ["Track ID": 3], ["Track ID": 1]]],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let library = try AppleMusicLibrary(data: data)
        #expect(library.playlists.map(\.name) == ["Road Trip"])
        #expect(library.songs[3]?.loved == true && library.songs[2]?.entry.duration == 0.5)

        let result = try db.importAppleMusic(library)
        #expect(result.playlists == 1 && result.songs == 2 && result.unmatched == 1)
        #expect(result.favorites == 1 && result.playCounts == 2)
        let a = try id(db, "a"), b = try id(db, "b")
        #expect(try db.favoriteTracks().map(\.id) == [a])
        let counts = try await db.writer.read { db in
            try Int.fetchAll(db, sql: "SELECT playCount FROM track WHERE id IN (?, ?) ORDER BY id", arguments: [a, b])
        }
        #expect(counts == [7, 3])

        // Again, without playlists: nothing counts twice.
        let again = try db.importAppleMusic(library, playlists: false)
        #expect(again.playlists == 0 && again.playCounts == 0)
        #expect(throws: AppleMusicLibrary.ReadError.notALibrary) { try AppleMusicLibrary(data: Data("#EXTM3U".utf8)) }
    }
}

private func trackID(in db: Database, _ name: String) throws -> Int64 {
    try #require(try Int64.fetchOne(db, sql: "SELECT id FROM track WHERE filePath LIKE ?", arguments: ["%/\(name).wav"]))
}
