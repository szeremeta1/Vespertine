import AVFAudio
import Foundation
import VespertineLibrary
import Testing
@testable import Vespertine

/// Scanning for new music and analyzing it by itself are opt-in: both off on a fresh install and, once, on every
/// install that had them on before; a choice made afterwards stands.
@Suite("Automatic scanning and analysis are opt-in", .serialized) @MainActor
struct AutomaticWorkTests {
    private func scratch() throws -> (root: URL, defaults: UserDefaults, suite: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-auto-work-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = root.appendingPathComponent("defaults.plist").path
        return (root, try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test("A fresh install scans and analyzes only when asked")
    func defaultsAreOff() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(!settings.watchFolders && !settings.autoAnalyze)
        #expect(!settings.analyzeNetworkShares)
    }

    @Test("An install that had both on, or on by default, is put to off once; its later choice stands")
    func existingInstallsMigrateToOff() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        // What rc4 left behind: Watch Folders stored on, and analysis switched on in setup.
        defaults.set(true, forKey: "watchFolders")
        defaults.set(true, forKey: "autoAnalyze")
        defaults.set(true, forKey: "analyzeNetworkShares")
        let migrated = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(!migrated.watchFolders && !migrated.autoAnalyze)
        #expect(migrated.analyzeNetworkShares, "only the two automatic switches are reset; the share option stays as it was")
        #expect(!defaults.bool(forKey: "watchFolders") && !defaults.bool(forKey: "autoAnalyze"))

        // The user turns them on: that is kept at the next launch.
        migrated.watchFolders = true
        migrated.autoAnalyze = true
        let relaunched = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(relaunched.watchFolders && relaunched.autoAnalyze)
    }

    @Test("An install with nothing stored for them (watching was on by default) ends up off")
    func implicitOnMigratesToOff() throws {
        let (root, defaults, suite) = try scratch()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set(true, forKey: "exclusiveMode")   // an existing install: other settings stored, these two not
        let settings = AppSettings(defaults: defaults, dataDirectory: root)
        #expect(!settings.watchFolders && !settings.autoAnalyze && settings.exclusiveMode)
        #expect(defaults.bool(forKey: AppSettings.automaticWorkOptInKey))
    }

    /// A reference folder with one song in it that the library has not read yet.
    private func libraryWithUnscannedSong(in root: URL, automatic: Bool) throws -> LibraryStore {
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
        let library = try LibraryStore(dataDirectory: root, automaticScanning: { automatic })
        library.launchScanDelay = .milliseconds(50)   // before anything the observations deliver has run
        return library
    }

    @Test("With automatic scanning on, the scan at launch finds the new song")
    func launchScanRunsWhenOn() async throws {
        let (root, _, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try libraryWithUnscannedSong(in: root, automatic: true)
        for _ in 0..<600 where library.stats.tracks == 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(library.stats.tracks == 1)
    }

    @Test("With it off, nothing scans at launch, and Rescan still finds the song")
    func launchScanDoesNotRunWhenOff() async throws {
        let (root, _, _) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try libraryWithUnscannedSong(in: root, automatic: false)
        // Many times the launch delay (50 ms), and long enough for the observations to have delivered.
        try await Task.sleep(for: .seconds(2))
        #expect(library.stats.tracks == 0 && library.scanProgress == nil)
        await library.rescanAll()
        for _ in 0..<200 where library.stats.tracks == 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(library.stats.tracks == 1)
    }
}
