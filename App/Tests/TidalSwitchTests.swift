import AVFAudio
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

    // MARK: Switching off takes TIDAL out of the queue and the navigation

    private func makePlayer(_ root: URL) throws -> (PlayerController, [Track]) {
        let url = root.appendingPathComponent("sample.wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 480))
            buffer.frameLength = 480
            for c in 0..<2 { for i in 0..<480 { buffer.floatChannelData![c][i] = 0 } }
            try file.write(from: buffer)
        }
        let original = try MetadataReader.read(url: url, artwork: nil)
        try FileManager.default.removeItem(at: url)
        // L1, T2, L3, T4, L5: T are TIDAL songs.
        let tracks = (1...5).map { i -> Track in
            var t = original; t.id = Int64(i); t.title = (i % 2 == 0 ? "T" : "L") + "\(i)"
            t.location = i % 2 == 0 ? "tidal://track/\(9000 + i)" : "/nowhere/L\(i).wav"
            t.filePath = i % 2 == 0 ? "" : t.location
            return t
        }
        let defaults = try #require(UserDefaults(suiteName: root.appendingPathComponent("defaults.plist").path))
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let library = try LibraryStore(dataDirectory: root.appendingPathComponent("library"), automaticScanning: { false })
        let shares = NetworkShareManager(library: library, settings: settings, dataDirectory: root)
        return (PlayerController(library: library, settings: settings, shares: shares), tracks)
    }

    @Test("Switching off removes TIDAL songs from the queue and leaves a local song that is playing alone")
    func queueLosesTidalSongs() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (player, tracks) = try makePlayer(root)
        defer { player.stop() }
        player.play(tracks)
        let playing = try #require(player.current?.id)
        #expect(player.queue.map(\.track.title) == ["L1", "T2", "L3", "T4", "L5"])
        player.dropTidalTracks()
        #expect(player.queue.map(\.track.title) == ["L1", "L3", "L5"])
        #expect(player.current?.id == playing && player.current?.track.title == "L1")
        #expect(player.upcoming.map(\.track.title) == ["L3", "L5"])
    }

    @Test("Switching off while a TIDAL song plays stops it and clears TIDAL from the queue, without moving on")
    func playingTidalSongStops() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (player, tracks) = try makePlayer(root)
        defer { player.stop() }
        player.play(tracks, startAt: 1)
        #expect(player.current?.track.title == "T2")
        player.dropTidalTracks()
        #expect(player.current == nil)
        #expect(player.queue.map(\.track.title) == ["L1", "L3", "L5"])
    }

    @Test("A queue with no TIDAL songs is left exactly as it is")
    func nothingToDrop() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (player, tracks) = try makePlayer(root)
        defer { player.stop() }
        player.play(tracks.filter { !$0.isTidalTrack })
        let before = player.queue
        player.dropTidalTracks()
        #expect(player.queue == before && player.current?.track.title == "L1")
    }

    @Test("Switching off sends a sidebar selection or page about TIDAL content back to Albums")
    func navigationLeavesTidal() {
        func go(_ sidebar: SidebarItem, _ path: [DetailRoute]) -> (SidebarItem, [DetailRoute]) {
            AppModel.navigation(afterTidalOff: sidebar, path: path, sourceIDs: [1], playlistIDs: [10], albumExists: { $0 == "kept" },
                                artistExists: { $0 == "Kept Artist" })
        }
        #expect(go(.songs, []) == (.songs, []))
        #expect(go(.source(1), []) == (.source(1), []))
        #expect(go(.source(7), [.album("kept")]) == (.albums, []), "the TIDAL source is gone")
        #expect(go(.playlist(10), []) == (.playlist(10), []))
        #expect(go(.playlist(11), []) == (.albums, []), "a TIDAL playlist is hidden")
        #expect(go(.albums, [.album("kept"), .artist("Kept Artist")]) == (.albums, [.album("kept"), .artist("Kept Artist")]))
        #expect(go(.albums, [.album("kept"), .album("tidal only")]) == (.albums, []))
        #expect(go(.songs, [.artist("Gone")]) == (.songs, []), "the page goes, the section stays")
        #expect(go(.songs, [.albumFamily("tidal only")]) == (.songs, []))
        #expect(go(.genres, [.genre("Jazz")]) == (.genres, [.genre("Jazz")]))
    }
}
