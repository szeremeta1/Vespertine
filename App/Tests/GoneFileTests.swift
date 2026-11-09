import AVFAudio
import Foundation
import Testing
import VespertineLibrary
@testable import Vespertine

/// A song that fails to play is taken for gone (and hidden as missing) only when its file answers "no such file" while the
/// folder of its source still lists. A share that timed out or dropped, or a file the app may not read, is not a deleted song.
@Suite("A failed song is missing only when its file is really gone", .serialized) @MainActor
struct GoneFileTests {
    // MARK: The rule, with the file system answers given

    @Test("No such file, and the source's folder lists: gone")
    func noSuchFile() {
        #expect(LibraryStore.fileIsGone("/Volumes/Music Share/a.flac", sourceRoot: "/Volumes/Music Share",
                                        stat: { _ in ENOENT }, list: { _ in ["b.flac"] }))
        #expect(LibraryStore.fileIsGone("/Volumes/Music Share/a/b.flac", sourceRoot: "/Volumes/Music Share",
                                        stat: { _ in ENOTDIR }, list: { _ in ["a"] }))
    }

    @Test("A timeout, an I/O error or a refused read is not gone, whatever the folder says", arguments: [ETIMEDOUT, EIO, EACCES, ENOTCONN, EPERM])
    func otherErrors(_ code: Int32) {
        #expect(!LibraryStore.fileIsGone("/Volumes/Music Share/a.flac", sourceRoot: "/Volumes/Music Share",
                                         stat: { _ in code }, list: { _ in ["b.flac"] }))
    }

    @Test("No such file under a source folder that no longer lists, or lists empty (a dropped mount): not gone")
    func droppedMount() {
        #expect(!LibraryStore.fileIsGone("/Volumes/Music Share/a.flac", sourceRoot: "/Volumes/Music Share",
                                         stat: { _ in ENOENT }, list: { _ in nil }))
        #expect(!LibraryStore.fileIsGone("/Volumes/Music Share/a.flac", sourceRoot: "/Volumes/Music Share",
                                         stat: { _ in ENOENT }, list: { _ in [] }))
        #expect(!LibraryStore.fileIsGone("/Volumes/Music Share/a.flac", sourceRoot: nil, stat: { _ in ENOENT }, list: { _ in ["a"] }))
    }

    @Test("A file that is there is not gone")
    func present() {
        #expect(!LibraryStore.fileIsGone("/Volumes/Music Share/a.flac", sourceRoot: "/Volumes/Music Share",
                                         stat: { _ in 0 }, list: { _ in ["a.flac"] }))
    }

    // MARK: The player, on real files

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-gone-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Music/Album"), withIntermediateDirectories: true)
        return root
    }

    /// Stereo CD rate and past 45 s: the scan takes it for a song.
    private func addSong(_ name: String, in folder: URL) throws {
        let file = try AVAudioFile(forWriting: folder.appendingPathComponent("\(name).wav"), settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44100 * 50)!
        buffer.frameLength = 44100 * 50
        try file.write(from: buffer)
    }

    /// A player over a library of one reference folder holding `Album/song.wav` and `kept.wav` (both read), automatic scanning off.
    private func player(in root: URL) async throws -> (PlayerController, LibraryStore) {
        try addSong("song", in: root.appendingPathComponent("Music/Album"))
        try addSong("kept", in: root.appendingPathComponent("Music"))
        let database = try LibraryDatabase(url: root.appendingPathComponent("Library.sqlite"))
        _ = try database.addSource(LibrarySource(path: root.appendingPathComponent("Music").standardizedFileURL.path, mode: .reference))
        let library = try LibraryStore(dataDirectory: root, automaticScanning: { false })
        await library.rescanAll()
        let defaults = try #require(UserDefaults(suiteName: root.appendingPathComponent("defaults.plist").path))
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        let shares = NetworkShareManager(library: library, settings: settings, dataDirectory: root)
        return (PlayerController(library: library, settings: settings, shares: shares), library)
    }

    /// The song fails (its file can't be opened, so nothing is ever sent to an output): how many songs end up hidden as missing.
    private func missingAfterFailing(_ player: PlayerController, _ library: LibraryStore, _ track: Track) async throws -> Int {
        player.play([track])
        let item = try #require(player.current?.item)
        player.engine.eventHandler?(.failed(item, "The file couldn’t be opened."))
        // Patience for the check, which runs off the main thread: the base commit marked the song at once.
        for _ in 0..<40 where try library.database.missingSongsSummary().songs == 0 { try await Task.sleep(for: .milliseconds(50)) }
        player.stop()
        return try library.database.missingSongsSummary().songs
    }

    @Test("A song whose folder the app may not read is not marked missing")
    func unreadableFolder() async throws {
        let root = try scratch()
        let album = root.appendingPathComponent("Music/Album")
        defer { chmod(album.path, 0o755); try? FileManager.default.removeItem(at: root) }
        let (player, library) = try await player(in: root)
        let track = try #require(try library.database.allTracks().first { $0.filePath.hasSuffix("song.wav") })
        #expect(chmod(album.path, 0) == 0)
        #expect(try await missingAfterFailing(player, library, track) == 0)
    }

    @Test("A song on a source whose folder is gone (a dropped mount) is not marked missing")
    func droppedSource() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let (player, library) = try await player(in: root)
        let track = try #require(try library.database.allTracks().first { $0.filePath.hasSuffix("song.wav") })
        try FileManager.default.moveItem(at: root.appendingPathComponent("Music"), to: root.appendingPathComponent("Unmounted"))
        #expect(try await missingAfterFailing(player, library, track) == 0)
    }

    @Test("A song whose file was deleted while its folder still lists is marked missing")
    func reallyGone() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let (player, library) = try await player(in: root)
        let track = try #require(try library.database.allTracks().first { $0.filePath.hasSuffix("song.wav") })
        try FileManager.default.removeItem(atPath: track.filePath)
        #expect(try await missingAfterFailing(player, library, track) == 1)
    }
}
