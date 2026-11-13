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
        let file = try AVAudioFile(forWriting: root.appendingPathComponent("Music/\(name).wav"), settings: [
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
}
