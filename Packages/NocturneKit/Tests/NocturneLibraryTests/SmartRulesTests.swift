//
// Nocturne — smart playlist rules match what people type.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import NocturneAudio
@testable import NocturneLibrary

@Suite("Smart playlist rules")
struct SmartRulesTests {
    /// A library with 48 kHz/24-bit, 44.1 kHz/16-bit and 96 kHz/24-bit files.
    func library() async throws -> (LibraryDatabase, URL) {
        let dir = try tempDir()
        try makeWAV(dir.appendingPathComponent("a48.wav"), rate: 48_000, bits: 24)
        try makeWAV(dir.appendingPathComponent("b441.wav"), rate: 44_100, bits: 16)
        try makeWAV(dir.appendingPathComponent("c96.wav"), rate: 96_000, bits: 24)
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        try await scanner.scan(try db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        return (db, dir)
    }

    func names(_ db: LibraryDatabase, _ rules: SmartRules) throws -> [String] {
        try db.tracks(in: Playlist(name: "t", smartRules: rules)).map { ($0.filePath as NSString).lastPathComponent }.sorted()
    }

    @Test("Sample rates are kHz as shown everywhere (48, 44.1, 48 kHz), and old rules in Hz still work")
    func sampleRates() async throws {
        let (db, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }
        func rate(_ op: SmartRule.Operator, _ v: String) throws -> [String] { try names(db, SmartRules(rules: [SmartRule(field: .sampleRate, op: op, value: v)])) }
        #expect(try rate(.equals, "48") == ["a48.wav"])
        #expect(try rate(.equals, "44.1") == ["b441.wav"])
        #expect(try rate(.equals, "48 kHz") == ["a48.wav"])
        #expect(try rate(.equals, "48k") == ["a48.wav"])
        #expect(try rate(.equals, "48000") == ["a48.wav"])
        #expect(try rate(.greaterOrEqual, "88.2") == ["c96.wav"])
        #expect(try rate(.greaterOrEqual, "88200") == ["c96.wav"])      // the built-in Hi-Res playlist's saved rule
        #expect(try rate(.notEquals, "48") == ["b441.wav", "c96.wav"])
        // The rule from the bug report: 24-bit and 48 kHz.
        let airpods = SmartRules(match: .all, rules: [SmartRule(field: .bitDepth, op: .equals, value: "24"),
                                                      SmartRule(field: .sampleRate, op: .equals, value: "48")])
        #expect(try names(db, airpods) == ["a48.wav"])
    }

    @Test("A rule that can't be understood matches nothing instead of being dropped")
    func invalidRules() async throws {
        let (db, dir) = try await library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = SmartRules(match: .all, rules: [SmartRule(field: .sampleRate, op: .contains, value: "48")])
        #expect(try names(db, bad).isEmpty)
        let empty = SmartRules(match: .all, rules: [SmartRule(field: .bitDepth, op: .equals, value: "")])
        #expect(try names(db, empty).isEmpty)
        #expect(SmartRule.Field.sampleRate.operators == [.equals, .notEquals, .greaterOrEqual, .lessOrEqual])
        #expect(SmartRule.Field.isDSD.operators == [.isTrue, .isFalse])
        #expect(SmartRule.number("24-bit") == 24 && SmartRule.number("1,000") == 1000)
    }

    @Test("Files deleted from a source disappear from playlists after a rescan, and come back if restored")
    func deletions() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeWAV(dir.appendingPathComponent("keep.wav"))
        try makeWAV(dir.appendingPathComponent("gone.wav"))
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference))
        try await scanner.scan(source)
        let playlist = try db.createPlaylist(name: "Mix")
        try db.append(trackIDs: try db.allTracks().compactMap(\.id), to: try #require(playlist.id))
        #expect(try db.tracks(in: playlist).count == 2)

        let aside = dir.deletingLastPathComponent().appendingPathComponent("aside-\(UUID()).wav")
        try FileManager.default.moveItem(at: dir.appendingPathComponent("gone.wav"), to: aside)
        let summary = try await scanner.scan(source)
        #expect(summary.missing == 1)
        #expect(try db.tracks(in: playlist).map { ($0.filePath as NSString).lastPathComponent } == ["keep.wav"])
        #expect(try db.allTracks().count == 1)

        try FileManager.default.moveItem(at: aside, to: dir.appendingPathComponent("gone.wav"))
        try await scanner.scan(source)
        #expect(try db.tracks(in: playlist).count == 2)
    }

    @Test("Moved or renamed files keep their playlists, plays, rating, date added and analysis")
    func moves() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldFolder = dir.appendingPathComponent("Artist - Album (1973) [FLAC]")
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try makeWAV(oldFolder.appendingPathComponent("01 Song.wav"))
        try makeWAV(oldFolder.appendingPathComponent("02 Other.wav"))     // same size and length as 01
        try makeWAV(oldFolder.appendingPathComponent("03 Deleted.wav"))
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference))
        try await scanner.scan(source)
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: dir.appendingPathComponent(".bak"))
        for (n, title) in [(1, "Song"), (2, "Other")] {
            let t = try #require(try db.allTracks().first { $0.filePath.hasSuffix("0\(n) \(title).wav") })
            _ = try await writer.apply(TagEdit(fields: [.title: title, .artist: "Artist", .trackNumber: "\(n)"]), to: [t])
        }
        let before = try db.allTracks()
        let song = try #require(before.first { $0.title == "Song" })
        let songID = try #require(song.id)
        let playlist = try db.createPlaylist(name: "Mix")
        try db.append(trackIDs: before.compactMap(\.id), to: try #require(playlist.id))
        try db.markPlayed(songID)
        try db.setRating(4, trackIDs: [songID])
        let reread = try #require(try db.tracks(ids: [songID]).first)
        let analysis = try FileAnalyzer.analyze(url: URL(fileURLWithPath: reread.filePath))
        try db.saveAnalysis(analysis, filePath: reread.filePath)

        // A library manager reorganizes everything: Artist/Album (1973)/CD 01/Artist - Album - 01 - Song.wav,
        // and one file is deleted outright.
        let newFolder = dir.appendingPathComponent("Artist/Album (1973)/CD 01")
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        for name in ["01 Song", "02 Other"] {
            try FileManager.default.moveItem(at: oldFolder.appendingPathComponent("\(name).wav"),
                                             to: newFolder.appendingPathComponent("Artist - Album - \(name).wav"))
        }
        try FileManager.default.removeItem(at: oldFolder.appendingPathComponent("03 Deleted.wav"))
        let summary = try await scanner.scan(source)
        #expect(summary.moved == 2)
        #expect(summary.missing == 1)

        let listed = try db.tracks(in: playlist)
        #expect(listed.map(\.title) == ["Song", "Other"])
        #expect(listed.allSatisfy { $0.filePath.contains("/CD 01/") })
        let moved = try #require(listed.first)
        #expect(moved.playCount == 1 && moved.rating == 4)
        #expect(moved.addedAt == song.addedAt)
        #expect(moved.analysisVerdict == analysis.verdict.rawValue)
        #expect(try db.tracksNeedingAnalysis().allSatisfy { $0.id != moved.id })   // the analysis still counts
        #expect(try db.allTracks().count == 2)                                  // no duplicates left behind
    }

    @Test("Re-reading an unchanged file keeps its analysis verdict")
    func rereadKeepsAnalysis() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeWAV(dir.appendingPathComponent("a.wav"))
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false)
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference))
        try await scanner.scan(source)
        let track = try #require(try db.allTracks().first)
        let analysis = try FileAnalyzer.analyze(url: track.fileURL)
        try db.saveAnalysis(analysis, filePath: track.filePath)
        try await db.writer.write { try $0.execute(sql: "UPDATE track SET modifiedAt = '1970-01-01 00:00:00.000'") }
        let summary = try await scanner.scan(source)
        #expect(summary.updated == 1)
        let reread = try #require(try db.allTracks().first)
        #expect(reread.analysisVerdict == analysis.verdict.rawValue)
        #expect(try db.tracksNeedingAnalysis().isEmpty)
    }
}

@Suite struct AlbumOrderTests {
    @Test("An album spread over several folders still plays in track order")
    func spreadAlbumKeepsTrackOrder() throws {
        let db = try LibraryDatabase.inMemory()
        let source = try db.addSource(LibrarySource(path: "/m", mode: .reference))
        try db.writer.write { db in
            for (folder, n) in [("Vinyl 01", 1), ("Vinyl 01", 12), ("Vinyl 02", 7), ("Extras", 6), ("Vinyl 01", 2)] {
                var t = Track.stub(path: "/m/Fleetwood Mac/Rumours/\(folder)/\(n).flac")
                t.sourceId = source.id; t.album = "Rumours"; t.albumArtist = "Fleetwood Mac"; t.trackNumber = n; t.discNumber = 1
                try t.insert(db)
            }
        }
        let key = try db.allTracks()[0].albumKey
        #expect(try db.tracks(albumKey: key).compactMap(\.trackNumber) == [1, 2, 6, 7, 12])
    }

    @Test("Two folders of one album with the same disc number list one after the other, not interleaved")
    func layersListInTurn() throws {
        let db = try LibraryDatabase.inMemory()
        let source = try db.addSource(LibrarySource(path: "/m", mode: .reference))
        func track(_ folder: String, _ n: Int) -> Track {
            var t = Track.stub(path: "/m/Pink Floyd/DSOTM/\(folder)/\(n).dsf")
            t.sourceId = source.id; t.album = "DSOTM"; t.albumArtist = "Pink Floyd"; t.trackNumber = n; t.discNumber = 1
            return t
        }
        try db.writer.write { db in
            for var t in [track("Stereo", 1), track("Multichannel 5.1", 2), track("Stereo", 2), track("Multichannel 5.1", 1)] { try t.insert(db) }
        }
        let key = try db.allTracks()[0].albumKey
        #expect(try db.tracks(albumKey: key).map { "\(($0.filePath as NSString).deletingLastPathComponent.split(separator: "/").last!) \($0.trackNumber!)" }
                == ["Multichannel 5.1 1", "Multichannel 5.1 2", "Stereo 1", "Stereo 2"])
    }
}
