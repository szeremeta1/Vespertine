//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import Testing
@testable import NocturneLibrary

@Suite("Release dates in ID3v2 formats")
struct TagDateTests {
    @Test("Year and full dates survive a round trip through WAV and AIFF tags", arguments: ["wav", "aiff"])
    func roundTrip(ext: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nocturne-date-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("song.\(ext)")
        var settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false]
        if ext == "aiff" { settings[AVLinearPCMIsBigEndianKey] = true }
        do {
            let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 4800)!
            b.frameLength = 4800
            try f.write(from: b)
        }
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        try await scanner.scan(try db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: dir.appendingPathComponent(".bak"))

        // WAV/AIFF are saved as ID3v2.3, which keeps the year only; the year must be exact.
        for (written, year) in [("2012", 2012), ("2018-08-27", 2018), ("1999-12-31", 1999), ("2001-01-01", 2001)] {
            let track = try #require(try db.allTracks().first)
            _ = try await writer.apply(TagEdit(fields: [.releaseDate: written]), to: [track])
            let reread = try #require(try db.allTracks().first)
            #expect(reread.year == year)
            #expect(reread.releaseDate?.hasPrefix(String(year)) == true)
        }
    }

    @Test("An unrelated edit (title, cover) doesn't erase the year of an ID3v2 file", arguments: ["wav", "aiff"])
    func laterEditsKeepYear(ext: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nocturne-date2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("song.\(ext)")
        var settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false]
        if ext == "aiff" { settings[AVLinearPCMIsBigEndianKey] = true }
        do {
            let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 4800)!
            b.frameLength = 4800
            try f.write(from: b)
        }
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        try await scanner.scan(try db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: dir.appendingPathComponent(".bak"))
        _ = try await writer.apply(TagEdit(fields: [.releaseDate: "2012"]), to: [try #require(try db.allTracks().first)])
        _ = try await writer.apply(TagEdit(fields: [.title: "Renamed"]), to: [try #require(try db.allTracks().first)])
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        _ = try await writer.apply(TagEdit(artwork: .replace(png)), to: [try #require(try db.allTracks().first)])
        let t = try #require(try db.allTracks().first)
        #expect(t.title == "Renamed")
        #expect(t.year == 2012)
    }

    @Test("ID3 timestamps are normalised both ways")
    func formatting() {
        #expect(TagWriter.id3Timestamp("2012") == "2012-01-01T12:00:00Z")
        #expect(TagWriter.id3Timestamp("2018-08") == "2018-08-01T12:00:00Z")
        #expect(TagWriter.id3Timestamp("2018-08-27") == "2018-08-27T12:00:00Z")
        #expect(MetadataReader.displayDate("2018-08-27T12:00:00Z") == "2018-08-27")
        #expect(MetadataReader.year(from: "0001-01-01") == nil)
    }
}
