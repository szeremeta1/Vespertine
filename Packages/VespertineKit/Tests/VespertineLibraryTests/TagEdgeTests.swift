//
// Vespertine: tag edits with awkward values (emoji, CJK, line breaks, a megabyte of text) round-trip and revert to the
// original bytes; a file that can't be written is edited in the library only, and its bytes stay as they were.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import CryptoKit
import Foundation
import GRDB
import Testing
@testable import VespertineLibrary

@Suite("Tag edits, awkward values")
struct TagEdgeTests {
    private func library() async throws -> (db: LibraryDatabase, writer: TagWriter, track: Track, dir: URL) {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("song.aiff")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4410)!
            buf.frameLength = 4410
            for i in 0..<4410 { buf.floatChannelData![0][i] = Float(sin(Double(i) * 0.05)) * 0.2 }
            try file.write(from: buf)
        }
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference))
        try await scanner.scan(source)
        let track = try #require(try db.allTracks().first)
        return (db, TagWriter(database: db, scanner: scanner, backupDirectory: dir.appendingPathComponent(".bak")), track, dir)
    }

    private func sha(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    @Test("Emoji, CJK, line breaks and a megabyte of comment are written, read back and reverted to the original bytes")
    func awkwardValues() async throws {
        let (db, writer, track, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = try sha(track.fileURL)
        let big = String(repeating: "ありがとう 🎵 thank you\n", count: 40_000)
        #expect(big.utf8.count > 1_000_000)
        let result = try await writer.apply(TagEdit(fields: [
            .title: "😀 東京の夜 \u{301}e\u{301}",
            .artist: "Line one\nLine two",
            .comment: big,
        ]), to: [track])
        #expect(result.written == 1 && result.failures.isEmpty)
        let edited = try #require(try db.tracks(ids: [track.id!]).first)
        #expect(edited.title == "😀 東京の夜 \u{301}e\u{301}")
        #expect(edited.artist == "Line one\nLine two")
        #expect(edited.comment == big.trimmingCharacters(in: .whitespacesAndNewlines), "the library keeps the text without its closing line break")
        #expect(try sha(track.fileURL) != original)

        #expect(try await writer.revertLastEdit(trackID: track.id!))
        #expect(try sha(track.fileURL) == original, "the file is back byte for byte")
        #expect(try db.tracks(ids: [track.id!]).first?.title == "song")
    }

    @Test("A file that can't be written is edited in the library only, with no backup copied and its bytes untouched")
    func readOnlyFile() async throws {
        let (db, writer, track, dir) = try await library()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: track.fileURL.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let original = try sha(track.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: track.fileURL.path)
        let result = try await writer.apply(TagEdit(fields: [.title: "Kept in the library"]), to: [track])
        #expect(result.written == 0 && result.databaseOnly == 1 && result.failures.isEmpty)
        #expect(try sha(track.fileURL) == original)
        #expect(try db.tracks(ids: [track.id!]).first?.title == "Kept in the library")
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(".bak").path)) ?? []
        #expect(backups.isEmpty)
    }

    @Test("A bad number is refused before anything is written")
    func badNumber() async throws {
        let (db, writer, track, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = try sha(track.fileURL)
        await #expect(throws: (any Error).self) { _ = try await writer.apply(TagEdit(fields: [.trackNumber: "three"]), to: [track]) }
        await #expect(throws: (any Error).self) { _ = try await writer.apply(TagEdit(fields: [.bpm: "-4"]), to: [track]) }
        #expect(try sha(track.fileURL) == original)
        #expect(try db.tracks(ids: [track.id!]).first?.trackNumber == nil)
    }
}
