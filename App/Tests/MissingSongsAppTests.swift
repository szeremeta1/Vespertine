import AVFAudio
import Foundation
import GRDB
import VespertineLibrary
import Testing
@testable import Vespertine

/// What the library does about songs whose files are gone, and when it looks for new music by itself:
/// turning "Scan for new music automatically" on catches up at once, playing a gone file with it off only hides the
/// song (no rescan), and "Remove Missing Songs…" takes the hidden rows out without touching a file.
@Suite("Missing songs and the automatic scan switch", .serialized) @MainActor
struct MissingSongsAppTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-missing-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Music"), withIntermediateDirectories: true)
        return root
    }

    /// Stereo CD rate and past 45 s: not taken for a voice recording or a short clip, which the scan leaves out.
    private func addSong(_ name: String, in root: URL) throws {
        let file = try AVAudioFile(forWriting: root.appendingPathComponent("Music/\(name).wav"), settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44100 * 50)!
        buffer.frameLength = 44100 * 50
        try file.write(from: buffer)
    }

    /// A library with one reference folder holding `songs`, none of them read yet.
    private func library(in root: URL, songs: [String], automatic: Bool) throws -> LibraryStore {
        for song in songs { try addSong(song, in: root) }
        let database = try LibraryDatabase(url: root.appendingPathComponent("Library.sqlite"))
        _ = try database.addSource(LibrarySource(path: root.appendingPathComponent("Music").standardizedFileURL.path, mode: .reference))
        let library = try LibraryStore(dataDirectory: root, automaticScanning: { automatic })
        library.launchScanDelay = .milliseconds(50)
        return library
    }

    private func settle(_ seconds: Double = 2) async throws { try await Task.sleep(for: .seconds(seconds)) }

    private func songsInLibrary(_ library: LibraryStore) throws -> Int {
        try library.database.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM track") ?? 0 }
    }

    @Test("Turning automatic scanning on looks for the music added while it was off, at once; turning it off scans nothing")
    func turningOnCatchesUp() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try library(in: root, songs: ["song"], automatic: false)
        try await settle()
        #expect(try songsInLibrary(library) == 0 && library.scanProgress == nil)

        library.automaticScanningChanged()   // still off: the switch was turned off (or never on)
        try await settle()
        #expect(try songsInLibrary(library) == 0, "off scans nothing")

        library.automaticScanning = { true }
        library.automaticScanningChanged()
        for _ in 0..<200 where library.stats.tracks == 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(library.stats.tracks == 1, "the catch-up scan found the song")
    }

    @Test("With scanning off, a song whose file is gone is hidden and no source is rescanned; a new song stays unread")
    func goneFileWithScanOffOnlyHides() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try library(in: root, songs: ["song"], automatic: false)
        await library.rescanAll()
        let track = try #require(try library.database.allTracks().first)
        try FileManager.default.removeItem(atPath: track.filePath)
        try addSong("newer", in: root)

        #expect(library.rescanForMissingFile(track) == false, "nothing was started")
        try await settle()
        #expect(library.scanProgress == nil)
        #expect(try songsInLibrary(library) == 1, "the new song was not read: no rescan")
        #expect(try library.database.allTracks().isEmpty && library.database.missingSongsSummary().songs == 1, "the gone song is hidden")
        for _ in 0..<100 where library.stats.tracks != 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(library.stats.tracks == 0, "the lists follow")
    }

    @Test("With scanning on, a song whose file is gone still starts a rescan of its source, which finds the new song")
    func goneFileWithScanOnRescans() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try library(in: root, songs: ["song"], automatic: true)
        await library.rescanAll()
        let track = try #require(try library.database.allTracks().first)
        try FileManager.default.removeItem(atPath: track.filePath)
        try addSong("newer", in: root)

        #expect(library.rescanForMissingFile(track) == true)
        for _ in 0..<200 where try songsInLibrary(library) < 2 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try songsInLibrary(library) == 2)
        // The scan saves what it read before it marks what's gone: wait for its last step too, not just the new song.
        for _ in 0..<200 where try library.database.allTracks().count != 1 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try library.database.allTracks().count == 1, "the old one is marked missing by that scan")
    }

    @Test("Remove Missing Songs takes the hidden rows out, reports what it removed, and leaves every file on disk")
    func removeMissingSongs() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let library = try library(in: root, songs: ["keep", "gone"], automatic: false)
        await library.rescanAll()
        let gone = try #require(try library.database.allTracks().first { $0.filePath.hasSuffix("gone.wav") })
        let keep = try #require(try library.database.allTracks().first { $0.filePath.hasSuffix("keep.wav") })
        try library.database.setFavorite(true, trackIDs: [gone.id!])
        try FileManager.default.removeItem(atPath: gone.filePath)
        library.rescanForMissingFile(gone)

        let summary = await library.missingSongsSummary()
        #expect(summary == MissingSongsSummary(songs: 1, favorites: 1, played: 0))
        let before = library.revision
        #expect(await library.removeMissingSongs() == 1)
        #expect(library.revision > before, "the views refresh")
        #expect(try songsInLibrary(library) == 1)
        #expect(FileManager.default.fileExists(atPath: keep.filePath), "files are never deleted")
        #expect(await library.missingSongsSummary().songs == 0)
    }

    @Test("A share never scanned is indexed once when it connects, scanning on or off; a known one is only rechecked with it on")
    func neverScannedShareIsIndexedOnce() {
        let now = Date()
        let old = now.addingTimeInterval(-NetworkShareManager.rescanInterval - 60)
        let recent = now.addingTimeInterval(-60)
        for automatic in [false, true] {
            #expect(NetworkShareManager.needsScanOnConnect(lastScannedAt: nil, automatic: automatic, now: now), "never scanned, automatic \(automatic)")
            #expect(!NetworkShareManager.needsScanOnConnect(lastScannedAt: recent, automatic: automatic, now: now), "scanned a minute ago")
        }
        #expect(!NetworkShareManager.needsScanOnConnect(lastScannedAt: old, automatic: false, now: now), "known and stale, scanning off: left to Rescan")
        #expect(NetworkShareManager.needsScanOnConnect(lastScannedAt: old, automatic: true, now: now))
    }
}
