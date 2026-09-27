//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import GRDB
import Testing
@testable import NocturneLibrary

private func makeWAV(_ url: URL, rate: Double = 48_000, bits: Int = 24, seconds: Double = 0.5) throws {
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                   AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let n = AVAudioFrameCount(rate * seconds)
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n)!
    buf.frameLength = n
    for c in 0..<2 { for i in 0..<Int(n) { buf.floatChannelData![c][i] = Float(sin(Double(i) * 0.02)) * 0.3 } }
    try file.write(from: buf)
}

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nocturne-lib-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("CUE sheets")
struct CueTests {
    @Test("Parses album and per-track fields")
    func parse() {
        let text = """
        REM GENRE "Jazz"
        REM DATE 1999
        PERFORMER "The Band"
        TITLE "Live Set"
        FILE "Live Set.flac" WAVE
          TRACK 01 AUDIO
            TITLE "Opening"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Second"
            PERFORMER "Guest"
            INDEX 00 03:59:70
            INDEX 01 04:00:00
        """
        let sheet = CueSheet.parse(text)
        #expect(sheet.title == "Live Set")
        #expect(sheet.performer == "The Band")
        #expect(sheet.genre == "Jazz")
        #expect(sheet.files.first?.name == "Live Set.flac")
        #expect(sheet.files.first?.tracks.count == 2)
        #expect(sheet.files.first?.tracks[1].performer == "Guest")
        #expect(sheet.files.first?.tracks[1].startCDFrames == 240 * 75)
        #expect(CueSheet.sampleFrame(cdFrames: 240 * 75, sampleRate: 44_100) == 240 * 44_100)
    }
}

@Suite("Library database")
struct DatabaseTests {
    @Test("Scanning indexes files, groups albums, and splits CUE sheets")
    func scan() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeWAV(dir.appendingPathComponent("a.wav"), rate: 96_000)
        try makeWAV(dir.appendingPathComponent("b.wav"), rate: 44_100, bits: 16)
        let albumDir = dir.appendingPathComponent("Live")
        try FileManager.default.createDirectory(at: albumDir, withIntermediateDirectories: true)
        try makeWAV(albumDir.appendingPathComponent("set.wav"), rate: 44_100, bits: 16, seconds: 3)
        try """
        PERFORMER "The Band"
        TITLE "Live Set"
        FILE "set.wav" WAVE
          TRACK 01 AUDIO
            TITLE "One"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Two"
            INDEX 01 00:01:00
        """.write(to: albumDir.appendingPathComponent("set.cue"), atomically: true, encoding: .utf8)

        let db = try LibraryDatabase.inMemory()
        let art = ArtworkStore(directory: dir.appendingPathComponent(".art"))
        let scanner = LibraryScanner(database: db, artwork: art)
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference))
        let summary = try await scanner.scan(source)
        #expect(summary.added == 4)

        let tracks = try db.allTracks()
        let hires = tracks.first { $0.filePath.hasSuffix("a.wav") }
        #expect(hires?.sampleRate == 96_000)
        #expect(hires?.bitDepth == 24)
        #expect(hires?.isHiRes == true)

        let cue = tracks.filter { $0.cueStartFrame != nil }.sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
        #expect(cue.map(\.title) == ["One", "Two"])
        #expect(cue[1].cueStartFrame == 44_100)
        #expect(abs(cue[0].duration - 1) < 0.01)
        #expect(abs(cue[1].duration - 2) < 0.01)
        #expect(try db.albums().contains { $0.title == "Live Set" && $0.trackCount == 2 })

        // Second scan: nothing changed.
        let again = try await scanner.scan(source)
        #expect(again.added == 0 && again.updated == 0)

        // Deleting a file flags it missing rather than losing it.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("b.wav"))
        let third = try await scanner.scan(source)
        #expect(third.missing == 1)
        #expect(try db.allTracks().count == 3)
    }

    @Test("Smart playlists and full-text search")
    func smartAndSearch() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeWAV(dir.appendingPathComponent("Étude in Blue.wav"), rate: 192_000)
        try makeWAV(dir.appendingPathComponent("Plain.wav"), rate: 44_100, bits: 16)
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference))
        try await scanner.scan(source)

        let hiRes = try db.playlists().first { $0.name.hasPrefix("Hi-Res") }!
        #expect(try db.tracks(in: hiRes).map(\.title) == ["Étude in Blue"])
        #expect(try db.search("etude").count == 1, "diacritics are folded")
        #expect(try db.search("blu").count == 1, "prefix match")

        let manual = try db.createPlaylist(name: "Mine")
        let ids = try db.allTracks().compactMap(\.id)
        try db.append(trackIDs: ids.reversed(), to: manual.id!)
        #expect(try db.tracks(in: manual).map(\.id) == ids.reversed())
    }

    @Test("Tag edits are written to the file and can be reverted")
    func tagWriteAndRevert() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // FLAC via the exporter would be ideal; AIFF carries ID3 tags and is written by AVAudioFile.
        let url = dir.appendingPathComponent("song.aiff")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4410)!
            buf.frameLength = 4410
            try file.write(from: buf)
        }
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference))
        try await scanner.scan(source)
        let track = try #require(try db.allTracks().first)

        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: dir.appendingPathComponent(".bak"))
        let result = try await writer.apply(TagEdit(fields: [.title: "New Title", .artist: "Someone", .trackNumber: "3"]), to: [track])
        #expect(result.written == 1)
        let edited = try #require(try db.tracks(ids: [track.id!]).first)
        #expect(edited.title == "New Title")
        #expect(edited.artist == "Someone")
        #expect(edited.trackNumber == 3)

        #expect(try await writer.revertLastEdit(trackID: track.id!))
        let reverted = try #require(try db.tracks(ids: [track.id!]).first)
        #expect(reverted.title == "song")
        #expect(reverted.artist == nil)
    }
}
