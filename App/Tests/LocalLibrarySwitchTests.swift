//
// Vespertine: the Settings › Library switch for the local library, on by default. Off, the music in folders, on drives and on
// shares is in no list and no queue, and nothing scans it or adds to it; nothing is deleted, and on brings it all back.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import GRDB
import Testing
import VespertineAudio
import VespertineLibrary
@testable import Vespertine

@Suite("Local Library settings switch", .serialized) @MainActor
struct LocalLibrarySwitchTests {
    private struct Scratch {
        let root: URL
        let defaults: UserDefaults
        let suite: String
        let settings: AppSettings
        let library: LibraryStore
        let shares: NetworkShareManager
        let player: PlayerController
        let analysis: AnalysisQueue
    }

    private func scratch(automatic: Bool = false, prepare: (URL) throws -> Void = { _ in }) throws -> Scratch {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-app-locallibrary-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try prepare(root)
        let suite = root.appendingPathComponent("defaults.plist").path
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let library = try LibraryStore(dataDirectory: root, automaticScanning: { automatic }, showsFiles: settings.localLibrary)
        library.launchScanDelay = .milliseconds(50)
        let shares = NetworkShareManager(library: library, settings: settings, dataDirectory: root)
        let player = PlayerController(library: library, settings: settings, shares: shares)
        return Scratch(root: root, defaults: defaults, suite: suite, settings: settings, library: library, shares: shares, player: player,
                       analysis: AnalysisQueue(library: library, settings: settings, shares: shares))
    }

    private func clean(_ scratch: Scratch) {
        scratch.player.stop()
        scratch.defaults.removePersistentDomain(forName: scratch.suite)
        try? FileManager.default.removeItem(at: scratch.root)
    }

    private func apply(_ on: Bool, _ scratch: Scratch) {
        LocalLibrarySwitch.apply(on, to: scratch.settings, library: scratch.library, player: scratch.player, analysis: scratch.analysis,
                                 shares: scratch.shares)
    }

    private func until(_ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(90)
        while !condition() {
            if Date() > end { return condition() }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// A folder in the library with three songs of one album. Their files don't exist: nothing opens or plays on a real output.
    @discardableResult
    private func addAlbum(to library: LibraryStore) throws -> [Track] {
        let source = try library.database.addSource(LibrarySource(path: "/Volumes/QA/Music", mode: .reference))
        return try library.database.writer.write { db in
            try (1...3).map { n -> Track in
                var track = Track.transient(location: "/Volumes/QA/Music/Night Ferry/0\(n) Song \(n).flac", title: "Song \(n)",
                                            artist: "Harbour Lights", album: "Night Ferry", duration: 200)
                track.sourceId = source.id
                track.filePath = track.location
                track.codec = "FLAC"
                track.isLossless = true
                track.sampleRate = 44_100
                track.bitDepth = 16
                track.albumArtist = "Harbour Lights"
                track.trackNumber = n
                try track.insert(db)
                return track
            }
        }
    }

    private func rows(_ library: LibraryStore, _ table: String) throws -> Int {
        try library.database.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? 0 }
    }

    /// A song on a music server, as the queue holds one.
    private func serverSong() -> Track {
        var track = Track.transient(location: StreamLocation.Ref(provider: "counting", account: "home", id: "s1").location, title: "From The Server",
                                    artist: "Server Artist", album: "Server Album", duration: 200)
        track.id = 9_001
        return track
    }

    @Test("The switch has a plain title and one line that says what off means and that nothing is deleted")
    func switchExists() {
        #expect(LocalLibrarySwitch.title == "Local Library")
        let line = LocalLibrarySwitch.explanation
        #expect(!line.isEmpty && !line.contains("\n"))
        #expect(line.localizedCaseInsensitiveContains("off"), "it says what off means")
        #expect(line.localizedCaseInsensitiveContains("deleted"))
        #expect(!LocalLibrarySwitch.emptyExplanation.isEmpty)
    }

    @Test("On, Settings lists the folders, importing and analysis; off, only the switch, its line, music servers and the data folder")
    func rowsFollowTheSwitch() {
        #expect(LocalLibrarySwitch.rows(on: true) == [.toggle, .explanation, .sources, .servers, .importing, .analysis, .data])
        #expect(LocalLibrarySwitch.rows(on: false) == [.toggle, .explanation, .servers, .data])
    }

    @Test("A new install and an upgrade start with it on, nothing is stored until it is touched, and off is found at the next launch")
    func onByDefault() throws {
        let scratch = try scratch()
        defer { clean(scratch) }
        #expect(scratch.settings.localLibrary)
        #expect(scratch.library.filesOn)
        #expect(scratch.library.database.showsFiles)
        #expect(scratch.defaults.persistentDomain(forName: scratch.suite)?[LocalLibrarySwitch.key] == nil)

        apply(false, scratch)
        #expect(scratch.defaults.object(forKey: LocalLibrarySwitch.key) as? Bool == false, "stored: the default it replaces is on")
        #expect(!AppSettings(defaults: scratch.defaults, dataDirectory: scratch.root).localLibrary)
        apply(true, scratch)
        #expect(AppSettings(defaults: scratch.defaults, dataDirectory: scratch.root).localLibrary)
    }

    @Test("Off, the folder and its songs are in no list at once and at the next launch; nothing is deleted, and on brings them back")
    func offHidesEveryFile() async throws {
        let scratch = try scratch()
        defer { clean(scratch) }
        let album = try addAlbum(to: scratch.library)
        #expect(await until { scratch.library.sources.count == 1 && scratch.library.albums.count == 1 && scratch.library.stats.tracks == 3 })
        #expect(scratch.library.allTracks().count == 3)

        apply(false, scratch)
        #expect(!scratch.library.filesOn)
        #expect(scratch.library.sources.isEmpty, "at once: the sidebar and Settings list no folder")
        #expect(scratch.library.stats.tracks == 0)
        #expect(scratch.library.libraryStats.tracks == 0)
        #expect(scratch.library.allTracks().isEmpty)
        #expect(scratch.library.search("Song").isEmpty)
        #expect(scratch.library.tracks(ids: album.compactMap(\.id)).isEmpty)
        #expect(scratch.shares.sources.isEmpty, "no share is connected to or checked")
        #expect(await until { scratch.library.albums.isEmpty && scratch.library.artists.isEmpty })
        #expect(try rows(scratch.library, "track") == 3, "nothing was deleted")
        #expect(try rows(scratch.library, "source") == 1)

        // The next launch with the switch off: the first read already leaves the files out.
        let relaunched = try LibraryStore(dataDirectory: scratch.root, automaticScanning: { false },
                                          showsFiles: AppSettings(defaults: scratch.defaults, dataDirectory: scratch.root).localLibrary)
        #expect(!relaunched.filesOn)
        #expect(relaunched.sources.isEmpty)
        #expect(relaunched.stats.tracks == 0)
        #expect(relaunched.allTracks().isEmpty)
        try await Task.sleep(for: .milliseconds(200))   // the observations' first values change nothing
        #expect(relaunched.sources.isEmpty && relaunched.albums.isEmpty)

        apply(true, scratch)
        #expect(scratch.library.sources.count == 1)
        #expect(scratch.library.stats.tracks == 3)
        #expect(scratch.library.allTracks().count == 3)
        #expect(await until { scratch.library.albums.count == 1 })
    }

    @Test("Off, a file that is playing stops and the files leave the queue; a music server's song stays and is next")
    func offEmptiesTheQueueOfFiles() async throws {
        let scratch = try scratch()
        defer { clean(scratch) }
        let album = try addAlbum(to: scratch.library)
        let server = serverSong()
        scratch.player.play([album[0], album[1], server, album[2]])
        #expect(scratch.player.queue.count == 4)
        #expect(scratch.player.current?.track.location == album[0].location)

        apply(false, scratch)
        #expect(scratch.player.queue.map(\.track.location) == [server.location])
        #expect(scratch.player.current?.track.location == server.location, "Play starts the song that is left")
        #expect(!scratch.player.isPlaying)

        // Only files in the queue: nothing is left, and nothing is current.
        apply(true, scratch)
        scratch.player.play(album, startAt: 1)
        apply(false, scratch)
        #expect(scratch.player.queue.isEmpty)
        #expect(scratch.player.current == nil)
    }

    @Test("Off, nothing scans the folders or adds to them, by itself or when asked; turned on, the scan that was due runs")
    func offScansAndAddsNothing() async throws {
        // A reference folder with one song the library has not read yet, automatic scanning on, and the switch stored off.
        let scratch = try scratch(automatic: true) { root in
            let music = root.appendingPathComponent("Music", isDirectory: true)
            try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
            let file = try AVAudioFile(forWriting: music.appendingPathComponent("song.wav"), settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
            // Stereo CD rate and past 45 s: not taken for a voice recording or a short clip, which the scan leaves out.
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44100 * 50)!
            buffer.frameLength = 44100 * 50
            try file.write(from: buffer)
            let database = try LibraryDatabase(url: root.appendingPathComponent("Library.sqlite"))
            _ = try database.addSource(LibrarySource(path: music.standardizedFileURL.path, mode: .reference))
            let suite = root.appendingPathComponent("defaults.plist").path
            try #require(UserDefaults(suiteName: suite)).set(false, forKey: LocalLibrarySwitch.key)
        }
        defer { clean(scratch) }
        #expect(!scratch.settings.localLibrary && !scratch.library.filesOn)

        // Many times the launch delay (50 ms), and long enough for the observations to have delivered.
        try await Task.sleep(for: .seconds(2))
        #expect(try rows(scratch.library, "track") == 0 && scratch.library.scanProgress == nil)
        await scratch.library.rescanAll()
        let other = scratch.root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        await scratch.library.addFolders([other], mode: .reference, managedRoot: scratch.root.appendingPathComponent("Managed"))
        #expect(await scratch.library.add(found: [scratch.root.appendingPathComponent("Music/song.wav")], mode: .reference,
                                          managedRoot: scratch.root.appendingPathComponent("Managed")).isEmpty)
        scratch.analysis.analyzeLibrary(includeNetwork: true)
        #expect(try rows(scratch.library, "track") == 0)
        #expect(try rows(scratch.library, "source") == 1, "no folder was added")
        #expect(!FileManager.default.fileExists(atPath: scratch.root.appendingPathComponent("Managed").path))
        #expect(scratch.library.scanProgress == nil && !scratch.analysis.isRunning)

        apply(true, scratch)
        #expect(await until { scratch.library.stats.tracks == 1 }, "the look for new music that launch would have made")
        #expect(scratch.library.sources.count == 1)
    }
}
