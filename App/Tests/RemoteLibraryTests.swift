import AVFAudio
import Foundation
import GRDB
import Testing
import VespertineLibrary
import VespertineRemoteProtocol
@testable import Vespertine

/// The remote's commands that read and change the library (the song list, the grouped search, adding to a playlist and
/// making one), against a real library of a few scanned files. The web remote and the phone app both send these.
@Suite("The remote's library commands", .serialized) @MainActor
struct RemoteLibraryTests {
    /// Stereo CD rate and past 45 s: not taken for a voice recording or a short clip, which the scan leaves out.
    private func addSong(_ name: String, in root: URL) throws {
        let url = root.appendingPathComponent("Music/\(name).wav")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44100 * 50)!
        buffer.frameLength = 44100 * 50
        try file.write(from: buffer)
    }

    /// A scanned library holding `songs` (untagged files: each one's title is its file name).
    private func library(songs: [String]) async throws -> (LibraryStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-remote-library-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Music"), withIntermediateDirectories: true)
        for song in songs { try addSong(song, in: root) }
        let database = try LibraryDatabase(url: root.appendingPathComponent("Library.sqlite"))
        _ = try database.addSource(LibrarySource(path: root.appendingPathComponent("Music").standardizedFileURL.path, mode: .reference))
        let library = try LibraryStore(dataDirectory: root, automaticScanning: { false })
        await library.rescanAll()
        for _ in 0..<200 where library.stats.tracks != songs.count { try await Task.sleep(for: .milliseconds(50)) }
        return (library, root)
    }

    private func summary(_ track: Track) -> TrackSummary {
        TrackSummary(id: track.id, title: track.title, artist: track.displayArtist, album: track.displayAlbum, albumKey: track.albumKey,
                     duration: track.duration, trackNumber: track.trackNumber, discNumber: track.discNumber, format: "", artworkKey: nil, favorite: false)
    }

    private func album(_ album: Album) -> AlbumSummary {
        AlbumSummary(key: album.key, title: album.title, artist: album.artist, year: album.year, trackCount: album.trackCount, duration: album.duration,
                     format: "", artworkKey: album.artworkKey, hiRes: false, dsd: false, multichannel: false)
    }

    @Test("Songs are listed by title the way a person sorts them, and the list follows the library")
    func songsByTitle() async throws {
        let (library, root) = try await library(songs: ["Zebra Crossing", "apple 10", "Apple 2", "Éclair"])
        defer { try? FileManager.default.removeItem(at: root) }
        let songs = RemoteBridge.songs(of: library)
        #expect(songs.map(\.title) == ["Apple 2", "apple 10", "Éclair", "Zebra Crossing"])
        #expect(RemoteBridge.songs(of: library).map(\.id) == songs.map(\.id))

        // A song added to the library is in the next list: the kept one isn't served stale.
        try addSong("Mango", in: root)
        await library.rescanAll()
        for _ in 0..<200 where library.stats.tracks != 5 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(RemoteBridge.songs(of: library).map(\.title) == ["Apple 2", "apple 10", "Éclair", "Mango", "Zebra Crossing"])
    }

    @Test("A search answers in groups, and only with what matches every word")
    func findsInGroups() async throws {
        let (library, root) = try await library(songs: ["Night Train", "Night Owl", "Morning"])
        defer { try? FileManager.default.removeItem(at: root) }
        _ = library.createPlaylist(name: "Late Night", trackIDs: [])
        _ = library.createPlaylist(name: "Sunday")
        func find(_ text: String, limit: Int = 50) -> SearchResults {
            RemoteBridge.find(text, limit: limit, in: library, track: summary, album: album, artworkKey: { $0.artworkKey })
        }
        // The store's own list of playlists follows the database a moment later.
        for _ in 0..<100 where !library.playlists.contains(where: { $0.name == "Sunday" }) { try await Task.sleep(for: .milliseconds(50)) }

        let night = find("night")
        #expect(Set(night.tracks.map(\.title)) == ["Night Train", "Night Owl"])
        #expect(night.playlists.map(\.name) == ["Late Night"])
        #expect(find("NIGHT tra").tracks.map(\.title) == ["Night Train"])
        #expect(find("night", limit: 1).tracks.count == 1)
        #expect(find("  ") == SearchResults(tracks: [], albums: [], artists: [], playlists: []))
        #expect(find("zzzz") == SearchResults(tracks: [], albums: [], artists: [], playlists: []))
        // Untagged files share the library's "unknown" album and artist: a search for a song's name doesn't claim them.
        #expect(night.albums.isEmpty && night.artists.isEmpty)
    }

    @Test("Songs are added to a playlist in the order sent, a new playlist is listed at once, and bad requests are refused")
    func playlists() async throws {
        let (library, root) = try await library(songs: ["One", "Two", "Three"])
        defer { try? FileManager.default.removeItem(at: root) }
        let songs = RemoteBridge.songs(of: library)
        let ids = try #require(songs.map(\.id) as? [Int64])
        let cover: (Track) -> String? = { _ in nil }
        // A new library starts with its own smart playlists.
        let before = try library.database.playlists().count

        // Making one: named as typed (trimmed), with its songs, and in the answer without waiting for the store.
        guard case .playlists(let made) = RemoteBridge.createPlaylist(named: "  Road Trip ", ids: [ids[2], ids[0]], in: library, artworkKey: cover) else {
            Issue.record("the playlist wasn't made"); return
        }
        let road = try #require(made.first { $0.name == "Road Trip" })
        #expect(road.trackCount == 2 && road.smart == false && road.artworkKeys == [])
        let stored = try #require(try library.database.playlists().first { $0.id == road.id })
        #expect(library.tracks(in: stored).map(\.id) == [ids[2], ids[0]])

        // Adding: at the end, in the order sent; songs that aren't in the library are left out.
        #expect(RemoteBridge.addToPlaylist(road.id, ids: [ids[1], 999_999], in: library) == .ok)
        #expect(library.tracks(in: stored).map(\.id) == [ids[2], ids[0], ids[1]])
        #expect(RemoteBridge.playlistSummary(stored, in: library, artworkKey: cover)?.trackCount == 3)

        // Refused: no name, no such playlist, no such songs, and a smart playlist (its rules choose its songs).
        if case .failed = RemoteBridge.createPlaylist(named: " \n", ids: ids, in: library, artworkKey: cover) {} else { Issue.record("an empty name was taken") }
        if case .failed = RemoteBridge.addToPlaylist(424_242, ids: ids, in: library) {} else { Issue.record("a missing playlist was taken") }
        if case .failed = RemoteBridge.addToPlaylist(road.id, ids: [999_999], in: library) {} else { Issue.record("missing songs were taken") }
        let smart = try #require(library.createPlaylist(name: "Everything", rules: SmartRules(rules: [])))
        if case .failed = RemoteBridge.addToPlaylist(try #require(smart.id), ids: ids, in: library) {} else { Issue.record("a smart playlist took songs") }
        #expect(library.tracks(in: stored).count == 3)
        #expect(try library.database.playlists().count == before + 2)

        // A very long name is cut, not refused.
        guard case .playlists(let long) = RemoteBridge.createPlaylist(named: String(repeating: "a", count: 500), ids: [], in: library, artworkKey: cover) else {
            Issue.record("a long name was refused"); return
        }
        #expect(long.contains { $0.name.count == 200 && $0.trackCount == 0 })
    }

    // MARK: Sections of the library, and songs in several copies

    /// Sets columns of the scanned songs whose path contains `folder` (tags and formats the test files don't have),
    /// and waits for the library to have read the change.
    private func set(_ columns: String, whereIn folder: String, of library: LibraryStore) async throws {
        let revision = library.revision
        try await library.database.writer.write { db in
            try db.execute(sql: "UPDATE track SET \(columns) WHERE filePath LIKE ?", arguments: ["%\(folder)%"])
        }
        for _ in 0..<200 where library.revision == revision { try await Task.sleep(for: .milliseconds(25)) }
    }

    @Test("A song with an ALAC and a Dolby Atmos copy is one favorite, shown as the copy the output plays, with both copies beside it")
    func favoritesListASongOnce() async throws {
        // One album in two folders, as a hi-res download and its Atmos mix sit in a library, and a song in one copy.
        let (library, root) = try await library(songs: ["Evening (2021) [ALAC 24-96]/Harbor", "Evening (2021) [Dolby Atmos]/Harbor",
                                                        "Evening (2021) [ALAC 24-96]/Lanterns"])
        defer { try? FileManager.default.removeItem(at: root) }
        try await set("album = 'Evening', albumArtist = 'The Vesper Quartet', codec = 'ALAC', isLossless = 1, bitDepth = 24, sampleRate = 96000",
                      whereIn: "[ALAC 24-96]", of: library)
        try await set("album = 'Evening', albumArtist = 'The Vesper Quartet', codec = 'Dolby Atmos', isLossless = 0, bitDepth = NULL, bitrate = 768, channels = 6, sampleRate = 48000",
                      whereIn: "[Dolby Atmos]", of: library)
        let all = library.allTracks()
        let alac = try #require(all.first { $0.title == "Harbor" && $0.codec == "ALAC" })
        let atmos = try #require(all.first { $0.title == "Harbor" && $0.codec == "Dolby Atmos" })
        let single = try #require(all.first { $0.title == "Lanterns" })
        #expect(alac.albumKey == atmos.albumKey)

        // Both copies are favorites (what the heart does where an album's copies are bundled), and so is the other song.
        library.setFavorite(true, trackIDs: [try #require(alac.id), try #require(atmos.id), try #require(single.id)])
        #expect(library.favoriteTracks().count == 3)
        // The store's own set of favorites (the hearts) follows the database a moment later.
        for _ in 0..<200 where library.favoriteIDs.count != 3 { try await Task.sleep(for: .milliseconds(25)) }
        func favorites(multichannel: Bool) -> [RemoteBridge.ListedSong] {
            RemoteBridge.favoriteSongs(in: library) { TrackVersions.choose($0, multichannel: multichannel) ?? $0[0] }
        }

        // Once each: two songs, not three rows.
        let onSpeakers = favorites(multichannel: true)
        #expect(Set(onSpeakers.map(\.shown.title)) == ["Harbor", "Lanterns"])
        #expect(onSpeakers.count == 2)
        // The copy shown is the one the output plays: Atmos where it can be heard, the ALAC file on a stereo output.
        #expect(onSpeakers.first { $0.shown.title == "Harbor" }?.shown.id == atmos.id)
        let onHeadphones = favorites(multichannel: false)
        #expect(onHeadphones.first { $0.shown.title == "Harbor" }?.shown.id == alac.id)

        // Its copies are beside it, each with its format as the Mac's list of copies names it; a song in one copy has none.
        let harbor = try #require(onHeadphones.first { $0.shown.title == "Harbor" })
        let copies = try #require(RemoteBridge.copies(of: harbor, in: library))
        #expect(copies.count == 2)
        let alacCopy = try #require(copies.first { $0.id == alac.id })
        let atmosCopy = try #require(copies.first { $0.id == atmos.id })
        #expect(alacCopy.format == "ALAC · 24/96" && alacCopy.hiRes)
        #expect(atmosCopy.format.hasPrefix("Dolby Atmos") && !atmosCopy.hiRes)
        #expect(alacCopy.favorite && atmosCopy.favorite)
        let lanterns = try #require(onHeadphones.first { $0.shown.title == "Lanterns" })
        #expect(RemoteBridge.copies(of: lanterns, in: library) == nil)

        // With only one copy hearted, the song is still one favorite, shown as that copy, and the other is a tap away.
        library.setFavorite(false, trackIDs: [try #require(atmos.id)])
        for _ in 0..<200 where library.favoriteIDs.count != 2 { try await Task.sleep(for: .milliseconds(25)) }
        let one = try #require(favorites(multichannel: true).first { $0.shown.title == "Harbor" })
        #expect(one.shown.id == alac.id)
        let other = try #require(RemoteBridge.copies(of: one, in: library)?.first { $0.id == atmos.id })
        #expect(!other.favorite)
    }

    @Test("Genres, Recently Added and Sources list what the Mac's own pages list")
    func sections() async throws {
        let (library, root) = try await library(songs: ["Low Tide/One", "Low Tide/Two", "Glass Orchard/Three", "Fieldwork/Four"])
        defer { try? FileManager.default.removeItem(at: root) }
        try await set("album = 'Low Tide', albumArtist = 'Marisol Vance', genre = 'Folk; Jazz', addedAt = '2026-01-01 10:00:00.000'", whereIn: "/Low Tide/", of: library)
        try await set("album = 'Glass Orchard', albumArtist = 'The Quiet Engines', genre = 'jazz', addedAt = '2026-03-01 10:00:00.000'", whereIn: "/Glass Orchard/", of: library)
        try await set("album = 'Fieldwork', albumArtist = 'Theo Lindqvist', addedAt = '2026-02-01 10:00:00.000'", whereIn: "/Fieldwork/", of: library)
        for _ in 0..<200 where library.albums.count != 3 || library.genres.count != 2 { try await Task.sleep(for: .milliseconds(25)) }

        // Genres as the Genres page has them: one per genre whatever its case, an album under each of its genres.
        let genres = RemoteBridge.genres(of: library)
        #expect(genres.map(\.name) == ["Folk", "Jazz"])
        #expect(genres.map(\.albumCount) == [1, 2])
        let jazz = try #require(genres.first { $0.name == "Jazz" })
        #expect(Set(library.albums(genre: jazz.key).map(\.title)) == ["Low Tide", "Glass Orchard"])

        // Recently Added: the newest first, and no more than asked for.
        #expect(library.recentlyAddedAlbums(limit: 150).map(\.title) == ["Glass Orchard", "Fieldwork", "Low Tide"])
        #expect(library.recentlyAddedAlbums(limit: 2).map(\.title) == ["Glass Orchard", "Fieldwork"])

        // Sources: the folder the library reads, with how many albums it holds and the status its page shows.
        let overview = RemoteBridge.overview(of: library)
        #expect(overview.albums == 3 && overview.songs == 4 && overview.genres == 2)
        let source = try #require(overview.sources.first)
        #expect(overview.sources.count == 1)
        #expect(source.name == "Music" && source.kind == .folder && source.online && source.albumCount == 3)
        #expect(source.detail.hasPrefix("REFERENCED IN PLACE · ONLINE"))
        #expect(Set(library.albums(inSource: source.id).map(\.title)) == ["Low Tide", "Glass Orchard", "Fieldwork"])
        #expect(library.albums(inSource: source.id + 1).isEmpty)
    }
}
