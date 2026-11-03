//
// Vespertine — transition profiles in the library: stored per file like analyses, made stale by a changed file or
// analyzer, imported from a server's index; and a playlist's own transitions.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import VespertineAudio
@testable import VespertineLibrary
import Testing

@Suite("Transition profiles in the library")
struct TransitionProfileStoreTests {
    static let profile = TransitionProfile(
        seconds: 1, head: .init(silence: 0.1, loudness: -14, edgeLoudness: -15, type: .cold),
        tail: .init(silence: 0, fade: 6, fadeConfidence: 0.9, loudness: -12, edgeLoudness: -40, type: .fade), integratedLUFS: -13)

    func scanned(_ files: [String], remote: Bool = false) async throws -> (LibraryDatabase, LibrarySource, URL) {
        let dir = try tempDir()
        for name in files { try makeWAV(dir.appendingPathComponent(name), rate: 48_000) }
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        var source = LibrarySource(path: dir.path, mode: .reference)
        if remote { source.remoteURL = "smb://server/music" }
        let added = try db.addSource(source)
        try await scanner.scan(added)
        return (db, added, dir)
    }

    @Test("Saved and read back; stale once the file changes or the analyzer is newer")
    func storeAndInvalidate() async throws {
        let (db, _, dir) = try await scanned(["a.wav"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let track = try #require(try db.allTracks().first)
        #expect(try db.transitionProfile(for: track) == nil)
        try db.saveTransitionProfiles([(Self.profile, track.filePath)])
        #expect(try db.transitionProfile(for: track) == Self.profile)
        #expect(try db.transitionProfile(trackID: track.id!) == Self.profile)
        // Another file at the same path: the profile no longer applies.
        var changed = track
        changed.fileSize += 1
        #expect(try db.transitionProfile(for: changed) == nil)
        changed = track
        changed.modifiedAt = track.modifiedAt.addingTimeInterval(5)
        #expect(try db.transitionProfile(for: changed) == nil)
        // Made by an older analyzer.
        var old = Self.profile
        old.version = TransitionProfile.currentVersion - 1
        try db.saveTransitionProfiles([(old, track.filePath)])
        #expect(try db.transitionProfile(for: track) == nil)
        #expect(try db.transitionProfile(trackID: track.id!) == nil)
        // Removing the track removes its profile.
        try await db.writer.write { db in try db.execute(sql: "DELETE FROM track") }
        let left = try await db.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transitionProfile") }
        #expect(left == 0)
    }

    @Test("A CUE sheet's tracks don't get the file's profile (their ends aren't the file's)")
    func cueTracksSkipped() async throws {
        let (db, _, dir) = try await scanned(["a.wav"])
        defer { try? FileManager.default.removeItem(at: dir) }
        var track = try #require(try db.allTracks().first)
        try await db.writer.write { db in try db.execute(sql: "UPDATE track SET cueStartFrame = 0, cueFrameLength = 100") }
        track = try #require(try db.allTracks().first)
        try db.saveTransitionProfiles([(Self.profile, track.filePath)])
        #expect(try db.transitionProfile(for: track) == nil)
    }

    @Test("A server's record carries the profile into the library; older records without one still import")
    func serverImport() async throws {
        let (db, source, dir) = try await scanned(["a.wav", "b.wav"], remote: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracks = try db.allTracks()
        let a = try #require(tracks.first { $0.filePath.hasSuffix("a.wav") })
        let b = try #require(tracks.first { $0.filePath.hasSuffix("b.wav") })
        let analysis = FileAnalysis(claimedBitDepth: 24, effectiveBitDepth: 24, sampleRate: 48_000, bandwidthHz: 22_000, peakDBFS: -1,
                                    clippedSamples: 0, verdict: .genuine, summary: "", spectrum: [], version: FileAnalysis.currentVersion,
                                    confidence: 0.9)
        func line(_ name: String, _ t: Track, profile: TransitionProfile?) throws -> String {
            var record: [String: Any] = ["path": name, "size": t.fileSize, "mtime": t.modifiedAt.timeIntervalSince1970,
                                         "analysis": try JSONSerialization.jsonObject(with: JSONEncoder().encode(analysis))]
            if let profile { record["transition"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) }
            return String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self) + "\n"
        }
        let index = dir.appendingPathComponent(".vespertine")
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        try (try line("a.wav", a, profile: Self.profile) + line("b.wav", b, profile: nil))
            .write(to: index.appendingPathComponent("analysis.jsonl"), atomically: true, encoding: .utf8)
        #expect(try ServerAnalysisImporter().importNew(for: source, into: db) == 2)
        #expect(try db.transitionProfile(for: a) == Self.profile)
        #expect(try db.transitionProfile(for: b) == nil)
    }

    @Test("A playlist keeps its own transitions; nil follows the app; deleting the playlist forgets them")
    func playlistOverride() throws {
        let db = try LibraryDatabase.inMemory()
        var playlist = Playlist(name: "Party")
        try db.writer.write { db in try playlist.insert(db) }
        let id = try #require(playlist.id)
        #expect(try db.transitionStyle(forPlaylist: id) == nil)
        try db.setTransitionStyle(TransitionOverride.crossfade(seconds: 4).storedValue, forPlaylist: id)
        #expect(TransitionOverride(storedValue: try db.transitionStyle(forPlaylist: id)) == .crossfade(seconds: 4))
        try db.setTransitionStyle(TransitionOverride.off.storedValue, forPlaylist: id)
        #expect(try db.playlistTransitionStyles() == [id: "off"])
        try db.setTransitionStyle(nil, forPlaylist: id)
        #expect(try db.transitionStyle(forPlaylist: id) == nil)
        try db.setTransitionStyle("smartMix", forPlaylist: id)
        try db.writer.write { db in _ = try Playlist.deleteOne(db, key: id) }
        #expect(try db.playlistTransitionStyles().isEmpty)
    }
}
