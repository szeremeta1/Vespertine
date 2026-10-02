//
// Vespertine — importing analysis results a share's server published in `.vespertine/analysis.jsonl`.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineAudio
@testable import VespertineLibrary
import Testing

@Suite("Server analysis import")
struct ServerAnalysisTests {
    func line(path: String, size: Int64, mtime: Double, verdict: FileAnalysis.Verdict) throws -> String {
        var a = FileAnalysis(claimedBitDepth: 24, effectiveBitDepth: 24, sampleRate: 96_000, bandwidthHz: 22_000, peakDBFS: -1,
                             clippedSamples: 0, verdict: verdict, summary: "from the server", spectrum: [-60, -70],
                             version: FileAnalysis.currentVersion, confidence: 0.9)
        a.peakDBFS = -1
        let record: [String: Any] = ["path": path, "size": size, "mtime": mtime,
                                     "analysis": try JSONSerialization.jsonObject(with: JSONEncoder().encode(a))]
        return String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self) + "\n"
    }

    /// As an analyzer from before version 3 stored a genuine 32 kHz master: called lossy, with its measurements.
    static func olderResult() -> FileAnalysis {
        let f = SpectralForensics(cliffHz: 15_200, cliffDropDB: 30, cliffConsistency: 1, belowDB: -80, aboveDB: -120, floorDB: -140,
                                  extensionHz: 0, extensionSlope: 0, holeRatio: 0, contentHz: 15_000, framesAnalyzed: 400)
        return FileAnalysis(claimedBitDepth: 24, effectiveBitDepth: 24, sampleRate: 32_000, bandwidthHz: 15_200, peakDBFS: -1,
                            clippedSamples: 0, verdict: .possibleLossyOrigin, summary: "Made from an MP3, AAC or Opus file.",
                            spectrum: [-60, -70], secondsAnalyzed: 300, forensics: f, version: 2, confidence: 1)
    }

    @Test("Stored results from an older analyzer are judged anew, not queued to be read again")
    func olderResultsAreRejudged() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeWAV(dir.appendingPathComponent("a.wav"), rate: 96_000)
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        try await scanner.scan(db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        let track = try #require(try db.allTracks().first)
        try db.saveAnalysis(Self.olderResult(), filePath: track.filePath)
        #expect(try db.storedAnalysis(for: track)?.isCurrent == false)
        #expect(try db.rejudgeStoredAnalyses() == 1)
        let stored = try #require(try db.storedAnalysis(for: track))
        #expect(stored.isCurrent && stored.analysis.verdict == .genuine)
        #expect(try db.tracksNeedingAnalysis().isEmpty)
        #expect(try db.allTracks().first?.analysisVerdict == "genuine")
        #expect(try db.rejudgeStoredAnalyses() == 0)
    }

    @Test("A server still on an older analyzer has its results judged anew on import")
    func olderServerRecordsAreRejudged() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeWAV(dir.appendingPathComponent("a.wav"), rate: 96_000)
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        var share = LibrarySource(path: dir.path, mode: .reference)
        share.remoteURL = "smb://server/music"
        let source = try db.addSource(share)
        try await scanner.scan(source)
        let track = try #require(try db.allTracks().first)
        // An index from before the rename, written by an analyzer older than this app's.
        let index = dir.appendingPathComponent(".nocturne")
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        let record: [String: Any] = ["path": "a.wav", "size": track.fileSize, "mtime": track.modifiedAt.timeIntervalSince1970,
                                     "analysis": try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.olderResult()))]
        try (String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self) + "\n")
            .write(to: index.appendingPathComponent("analysis.jsonl"), atomically: true, encoding: .utf8)
        #expect(try ServerAnalysisImporter().importNew(for: source, into: db) == 1)
        let stored = try #require(try db.storedAnalysis(for: track))
        #expect(stored.isCurrent && stored.analysis.verdict == .genuine && stored.analysis.version == FileAnalysis.currentVersion)
    }

    @Test("Matching records are imported (paths compared as NFC), mismatched sizes are not, and later lines are read incrementally")
    func importsIncrementally() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let album = dir.appendingPathComponent("Album")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let decomposed = "Cafe\u{0301}.wav"                 // written NFD, recorded NFC by the server
        try makeWAV(album.appendingPathComponent(decomposed), rate: 96_000)
        try makeWAV(album.appendingPathComponent("b.wav"), rate: 96_000)

        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        var share = LibrarySource(path: dir.path, mode: .reference)
        share.remoteURL = "smb://server/music"
        let source = try db.addSource(share)
        try await scanner.scan(source)
        let tracks = try db.allTracks()
        #expect(tracks.count == 2)
        let cafe = try #require(tracks.first { !$0.filePath.hasSuffix("b.wav") })
        let b = try #require(tracks.first { $0.filePath.hasSuffix("b.wav") })

        let index = dir.appendingPathComponent(".vespertine")
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        let file = index.appendingPathComponent("analysis.jsonl")
        var text = try line(path: "Album/Caf\u{00E9}.wav", size: cafe.fileSize, mtime: cafe.modifiedAt.timeIntervalSince1970, verdict: .upsampled)
        text += try line(path: "Album/b.wav", size: b.fileSize + 1, mtime: b.modifiedAt.timeIntervalSince1970, verdict: .genuine)
        try text.write(to: file, atomically: true, encoding: .utf8)

        #expect(ServerAnalysisImporter.indexRoot(for: source)?.standardizedFileURL.path == dir.standardizedFileURL.path)
        let importer = ServerAnalysisImporter()
        #expect(try importer.importNew(for: source, into: db) == 1)
        #expect(try db.storedAnalysis(for: cafe)?.analysis.verdict == .upsampled)
        #expect(try db.storedAnalysis(for: cafe)?.isCurrent == true)
        #expect(try db.storedAnalysis(for: b) == nil)
        #expect(try importer.importNew(for: source, into: db) == 0)

        // The server appends a corrected record: only the new line is read, and it's imported.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(try line(path: "Album/b.wav", size: b.fileSize, mtime: b.modifiedAt.timeIntervalSince1970, verdict: .genuine).utf8))
        try handle.close()
        #expect(try importer.importNew(for: source, into: db) == 1)
        #expect(try db.storedAnalysis(for: b)?.analysis.summary == "from the server")

        // The server compacts: the file is rewritten (sorted) and, here, not smaller than what was read.
        // It must be read in full, not from the old offset.
        var compacted = try line(path: "Album/b.wav", size: b.fileSize, mtime: b.modifiedAt.timeIntervalSince1970, verdict: .paddedBitDepth)
        compacted += try line(path: "Album/Caf\u{00E9}.wav", size: cafe.fileSize, mtime: cafe.modifiedAt.timeIntervalSince1970, verdict: .genuine)
        compacted += String(repeating: " ", count: 20_000) + "\n"   // bigger than what was read before
        try compacted.write(to: file, atomically: true, encoding: .utf8)
        try await db.writer.write { try $0.execute(sql: "DELETE FROM analysis") }
        #expect(try importer.importNew(for: source, into: db) == 2)
        #expect(try db.storedAnalysis(for: b)?.analysis.verdict == .paddedBitDepth)
    }

    @Test("A folder SMB shows under a mangled name is matched by size and date")
    func mangledFolderNames() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mangled = dir.appendingPathComponent("_3018I~A")      // the server's "Morning Glory? (30th Anniversary)"
        try FileManager.default.createDirectory(at: mangled, withIntermediateDirectories: true)
        try makeWAV(mangled.appendingPathComponent("01 Hello.wav"), rate: 96_000, seconds: 0.7)
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        var share = LibrarySource(path: dir.path, mode: .reference)
        share.remoteURL = "smb://server/music"
        let source = try db.addSource(share)
        try await scanner.scan(source)
        let track = try #require(try db.allTracks().first)
        let index = dir.appendingPathComponent(".vespertine")
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        let text = try line(path: "Oasis/Morning Glory? (30th Anniversary)/01 Hello.wav", size: track.fileSize,
                            mtime: track.modifiedAt.timeIntervalSince1970 + 0.0004, verdict: .genuine)
            + line(path: "Oasis/Other/02 Roll With It.wav", size: track.fileSize, mtime: track.modifiedAt.timeIntervalSince1970 + 60, verdict: .upsampled)
        try text.write(to: index.appendingPathComponent("analysis.jsonl"), atomically: true, encoding: .utf8)
        #expect(try ServerAnalysisImporter().importNew(for: source, into: db) == 1)
        #expect(try db.storedAnalysis(for: track)?.analysis.verdict == .genuine)
    }

    @Test("Servers set up before the rename keep working: .nocturne/ is read when .vespertine/ is absent")
    func legacyIndexFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-index-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent(".nocturne")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data().write(to: legacy.appendingPathComponent("analysis.jsonl"))
        #expect(ServerAnalysisImporter.indexFile("analysis.jsonl", in: dir).path.contains("/.nocturne/"))
        #expect(ServerAnalysisImporter.indexRoot(for: LibrarySource(path: dir.path, mode: .reference))?.standardizedFileURL.path
                == dir.standardizedFileURL.path)
        let current = dir.appendingPathComponent(".vespertine")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data().write(to: current.appendingPathComponent("analysis.jsonl"))
        #expect(ServerAnalysisImporter.indexFile("analysis.jsonl", in: dir).path.contains("/.vespertine/"))
    }
}
