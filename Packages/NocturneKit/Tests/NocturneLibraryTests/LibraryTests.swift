//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFAudio
import Foundation
import GRDB
import NocturneAudio
import Testing
@testable import NocturneLibrary

func makeWAV(_ url: URL, rate: Double = 48_000, bits: Int = 24, seconds: Double = 0.5) throws {
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                   AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let n = AVAudioFrameCount(rate * seconds)
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n)!
    buf.frameLength = n
    for c in 0..<2 { for i in 0..<Int(n) { buf.floatChannelData![c][i] = Float(sin(Double(i) * 0.02)) * 0.3 } }
    try file.write(from: buf)
}

func tempDir() throws -> URL {
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
        await scanner.setSkipsNonMusic(false)
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
        await scanner.setSkipsNonMusic(false)
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
        await scanner.setSkipsNonMusic(false)
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


@Suite("Finding and enriching music")
struct FindAndEnrichTests {
    @Test("File names are parsed into tags", arguments: [
        ("american poetry club - we are beautiful, even when we are broken! - 01 forklift.wav",
         "american poetry club", "we are beautiful, even when we are broken!", 1, "forklift"),
        ("Wilbur Soot - Maybe I Was Boring - 04 It's All Futile! It's All Pointless!.wav",
         "Wilbur Soot", "Maybe I Was Boring", 4, "It's All Futile! It's All Pointless!"),
        ("Childish_Gambino_-_Do_Ya_Like_ft_Adele_Enhanced_24bit_48kHz.flac", "Childish Gambino", nil, nil, "Do Ya Like ft Adele"),
        ("04-Under My Thumb.flac", nil, nil, 4, "Under My Thumb"),
        ("13. Otto Klemperer Feat. Lucia Popp - Die Zauberflöte.flac", "Otto Klemperer Feat. Lucia Popp", nil, 13, "Die Zauberflöte"),
        ("Yarin Primak - Special Vibe [nDZIyPILowE].wav", "Yarin Primak", nil, nil, "Special Vibe"),
    ] as [(String, String?, String?, Int?, String)])
    func parse(name: String, artist: String?, album: String?, number: Int?, title: String) {
        let t = FilenameParser.parse(URL(fileURLWithPath: "/tmp/" + name))
        #expect(t.artist == artist)
        #expect(t.album == album)
        #expect(t.trackNumber == number)
        #expect(t.title == title)
    }

    @Test("Voice recordings and short clips are not music")
    func classification() {
        #expect(MusicFinder.kind(sampleRate: 8_000, channels: 1, duration: 300, isDSD: false) == .recording)
        #expect(MusicFinder.kind(sampleRate: 16_000, channels: 2, duration: 300, isDSD: false) == .recording)
        #expect(MusicFinder.kind(sampleRate: 22_050, channels: 1, duration: 300, isDSD: false) == .recording)
        #expect(MusicFinder.kind(sampleRate: 44_100, channels: 2, duration: 12, isDSD: false) == .clip)
        #expect(MusicFinder.kind(sampleRate: 44_100, channels: 1, duration: 200, isDSD: false) == .music)
        #expect(MusicFinder.kind(sampleRate: 96_000, channels: 2, duration: 200, isDSD: false) == .music)
        #expect(MusicFinder.kind(sampleRate: 2_822_400, channels: 2, duration: 200, isDSD: true) == .music)
    }

    @Test("Finder groups music by folder, flags hi-res, and leaves out recordings")
    func finder() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let album = dir.appendingPathComponent("Album"); try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try makeWAV(album.appendingPathComponent("01 One.wav"), rate: 96_000, bits: 24, seconds: 50)
        try makeWAV(album.appendingPathComponent("02 Two.wav"), rate: 44_100, bits: 16, seconds: 50)
        try makeWAV(album.appendingPathComponent("prompt.wav"), rate: 44_100, bits: 16, seconds: 3)
        let folders = await MusicFinder.find(roots: [dir])
        let found = try #require(folders.first)
        #expect(found.music.count == 2)
        #expect(found.hiRes.count == 1)
        #expect(found.excludedCount == 1)
    }

    @Test("Import clones files into an organized tree and tags the copies from their names; originals untouched")
    func importTagsCopies() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src"); try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let a = src.appendingPathComponent("Test Artist - Test Album - 01 First Song.wav")
        try makeWAV(a, rate: 48_000, bits: 24, seconds: 50)
        try makeWAV(src.appendingPathComponent("Test Artist - Test Album - 02 Second Song.wav"), rate: 48_000, bits: 24, seconds: 50)
        try makeWAV(src.appendingPathComponent("voicemail.wav"), rate: 8_000, bits: 16, seconds: 60)
        let before = try Data(contentsOf: a)

        let root = dir.appendingPathComponent("Managed")
        let written = try Importer.copyAndOrganize([src], into: root) {
            (try? SourceInspector.inspectWithDuration($0)).map { MusicFinder.kind(sampleRate: $0.format.sampleRate, channels: $0.format.channels, duration: $0.duration, isDSD: false) == .music } ?? false
        }
        #expect(written.map { $0.path.replacingOccurrences(of: root.path, with: "") }.sorted()
                == ["/Test Artist/Test Album/01 First Song.wav", "/Test Artist/Test Album/02 Second Song.wav"])

        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        try await scanner.scan(try db.addSource(LibrarySource(path: root.path, mode: .managed)))
        let tracks = try db.allTracks().sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
        #expect(tracks.map(\.title) == ["First Song", "Second Song"])
        #expect(tracks.allSatisfy { $0.artist == "Test Artist" && $0.album == "Test Album" && $0.albumArtist == "Test Artist" })
        #expect(try Data(contentsOf: a) == before)
    }

    @Test("Enrichment fills tags of referenced files from their names")
    func enrichFromNames() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeWAV(dir.appendingPathComponent("Test Artist - Test Album - 01 First Song.wav"), rate: 48_000, bits: 24, seconds: 50)
        try makeWAV(dir.appendingPathComponent("Test Artist - Test Album - 02 Second Song.wav"), rate: 48_000, bits: 24, seconds: 50)
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        try await scanner.scan(try db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        let tracks = try db.allTracks()
        #expect(MetadataEnricher.needsEnrichment(tracks))

        let proposal = try #require(await MetadataEnricher(database: db).propose(albumKey: tracks[0].albumKey, tracks: tracks, lookUpOnline: false))
        #expect(proposal.sources == [.fileNames])
        #expect(proposal.isHighConfidence)
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: dir.appendingPathComponent(".bak"))
        _ = try await writer.apply(proposal, tracks: tracks)
        let enriched = try db.allTracks().sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
        #expect(enriched.map(\.title) == ["First Song", "Second Song"])
        #expect(enriched.allSatisfy { $0.artist == "Test Artist" && $0.album == "Test Album" && $0.albumArtist == "Test Artist" })
        #expect(enriched.map(\.trackNumber) == [1, 2])
    }
}
