import AVFAudio
import CVespertineTags
import Foundation
import GRDB
import SFBAudioEngine
import Testing
@testable import VespertineLibrary

private func fixture() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-audit-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
private func audio(_ url: URL) throws {
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 44100.0, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 88200))
    buffer.frameLength = 88200
    for c in 0..<2 { for i in 0..<88200 { buffer.floatChannelData![c][i] = 0 } }
    try file.write(from: buffer)
}
private func cue(_ title: String = "Second", at url: URL) throws {
    try """
    TITLE "Album"
    FILE "set.wav" WAVE
      TRACK 01 AUDIO
        INDEX 01 00:00:00
      TRACK 02 AUDIO
        TITLE "\(title)"
        INDEX 01 00:01:00
    """.write(to: url, atomically: true, encoding: .utf8)
}
@Suite("Audit regressions") struct AuditRegressionTests {
    @Test func cueOnlyChangeIsRescanned() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try audio(dir.appendingPathComponent("set.wav")); let c = dir.appendingPathComponent("set.cue"); try cue(at: c)
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference))
        try await scanner.scan(source); try cue("Corrected", at: c); try await scanner.scan(source)
        #expect(try db.allTracks().contains { $0.title == "Corrected" })
    }
    @Test func folderFilterHonorsBoundariesAndLiteralWildcards() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["Album", "Album-extra", "100%", "100x"] {
            let folder = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try audio(folder.appendingPathComponent("\(name).wav"))
        }
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        try await scanner.scan(db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        #expect(try db.albums(underPath: dir.appendingPathComponent("Album").path).reduce(0) { $0 + $1.trackCount } == 1)
        #expect(try db.albums(underPath: dir.appendingPathComponent("100%").path).reduce(0) { $0 + $1.trackCount } == 1)
    }
    @Test func importKeepsCueReferencesValid() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src"), dst = dir.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let file = src.appendingPathComponent("set.wav"); try audio(file); try cue(at: src.appendingPathComponent("set.cue"))
        let tagged = try AudioFile(readingPropertiesAndMetadataFrom: file)
        tagged.metadata.title = "Renamed by tags"; try tagged.writeMetadata()
        let folders = try Importer.copyAndOrganize([src], into: dst)
        let enumerated = LibraryScanner.enumerate(try #require(folders.first))
        #expect(LibraryScanner.cueSheets(enumerated.cue).count == 1)
    }
    @Test func tagUndoRestoresCustomTagsAndExactFile() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("song.wav"); try audio(url)
        let tagged = try AudioFile(readingPropertiesAndMetadataFrom: url)
        tagged.metadata.title = "Original"; tagged.metadata.additionalMetadata = ["TEST_CUSTOM": "Original value"]
        try tagged.writeMetadata()
        let original = try Data(contentsOf: url)
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        try await scanner.scan(db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        let track = try #require(try db.allTracks().first)
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: dir.appendingPathComponent(".backups"))
        let result = try await writer.apply(TagEdit(fields: [.title: "Edited"], custom: ["TEST_CUSTOM": "Changed"]), to: [track])
        #expect(result.written == 1)
        #expect(try await writer.revertLastEdit(trackID: track.id!))
        #expect(try Data(contentsOf: url) == original)
    }
    @Test("A read-only file is edited in the library only: no backup, the file untouched, and a rescan keeps the edit")
    func readOnlyFileEditsStayInLibrary() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("song.wav"); try audio(url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let original = try Data(contentsOf: url)
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference))
        try await scanner.scan(source)
        let track = try #require(try db.allTracks().first)
        let backups = dir.appendingPathComponent(".backups")
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: backups)
        let result = try await writer.apply(TagEdit(fields: [.title: "Edited", .album: "Library Only"]), to: [track])
        #expect(result.databaseOnly == 1 && result.written == 0 && result.failures.isEmpty)
        #expect(try Data(contentsOf: url) == original)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: backups.path))?.isEmpty ?? true)
        // Make the next scan read the file again (as if it had changed on the share).
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        try await scanner.scan(source)
        let rescanned = try #require(try db.allTracks().first)
        #expect(rescanned.title == "Edited" && rescanned.album == "Library Only")
        #expect(try await writer.revertLastEdit(trackID: track.id!))
        #expect(try db.allTracks().first?.title == track.title)
    }

    @Test func failedBackupDoesNotModifyOriginal() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("song.wav"); try audio(url)
        let original = try Data(contentsOf: url)
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        try await scanner.scan(db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        let blocker = dir.appendingPathComponent("blocker"); try Data().write(to: blocker)
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: blocker)
        let result = try await writer.apply(TagEdit(fields: [.title: "Edited"]), to: db.allTracks())
        #expect(result.written == 0); #expect(result.failures.count == 1)
        #expect(try Data(contentsOf: url) == original)
    }
    @Test func tagRefreshPreservesAnalysis() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try audio(dir.appendingPathComponent("song.wav"))
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        try await scanner.scan(db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        let track = try #require(try db.allTracks().first)
        try db.saveAnalysis(trackID: track.id!, effectiveBitDepth: 16, bandwidthHz: 20000, verdict: "genuine")
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: dir.appendingPathComponent(".backups"))
        _ = try await writer.apply(TagEdit(fields: [.title: "Edited"]), to: [track])
        #expect(try db.tracks(ids: [track.id!]).first?.effectiveBitDepth == 16)
    }
    @Test func albumDoesNotOfferMissingCueTracks() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try audio(dir.appendingPathComponent("set.wav")); try cue(at: dir.appendingPathComponent("set.cue"))
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference)); try await scanner.scan(source)
        let tracks = try db.allTracks(); let key = try #require(tracks.first?.albumKey)
        try await db.writer.write { db in try db.execute(sql: "UPDATE track SET isMissing = 1 WHERE id = ?", arguments: [tracks.first!.id]) }
        #expect(try db.tracks(albumKey: key).count == 1)
        try await scanner.scan(source)
        #expect(try db.allTracks().count == 2)
    }
    @Test func malformedCueTimesAreRejected() {
        #expect(CueSheet.cdFrames("-1:00:00") == nil)
        #expect(CueSheet.cdFrames("00:60:00") == nil)
        #expect(CueSheet.cdFrames("00:00:75") == nil)
        #expect(CueSheet.cdFrames("1:x:2:3") == nil)
    }
    @Test func cueEditsPersistThroughRescanAndUndo() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("set.wav"); try audio(url)
        let c = dir.appendingPathComponent("set.cue"); try cue(at: c)
        let original = try Data(contentsOf: url)
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference)); try await scanner.scan(source)
        let track = try #require(try db.allTracks().first)
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: dir.appendingPathComponent(".backups"))
        let result = try await writer.apply(TagEdit(fields: [.lyrics: "Words", .title: "Edited CUE"], custom: ["TEST": "Value"]), to: [track])
        #expect(result.databaseOnly == 1)
        try cue("New CUE data", at: c); try await scanner.scan(source)
        let refreshed = try #require(try db.tracks(ids: [track.id!]).first)
        #expect(refreshed.title == "Edited CUE"); #expect(refreshed.lyrics == "Words"); #expect(refreshed.extraTags["TEST"] == "Value")
        #expect(try await writer.revertLastEdit(trackID: track.id!))
        #expect(try db.tracks(ids: [track.id!]).first?.title == track.title)
        #expect(try Data(contentsOf: url) == original)
    }
    @Test func individualFileReferenceOnlyScansSelectedFile() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let selected = dir.appendingPathComponent("selected.wav"); try audio(selected)
        try audio(dir.appendingPathComponent("unselected.wav"))
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        let source = try db.addSource(LibrarySource(path: selected.path, mode: .reference))
        async let first = scanner.scan(source)
        async let second = scanner.scan(source)
        _ = try await (first, second)
        #expect(try db.allTracks().map(\.title) == ["selected"])
    }
    @Test func symlinkBackUpTheTreeIsListedOnce() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let album = dir.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try audio(album.appendingPathComponent("one.wav"))
        try FileManager.default.createSymbolicLink(atPath: album.appendingPathComponent("Up").path, withDestinationPath: "..")
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        let source = try db.addSource(LibrarySource(path: dir.path, mode: .reference))
        try await scanner.scan(source)
        #expect(try db.allTracks().map(\.title) == ["one"])
    }
    @Test func richFLACUndoRestoresArtworkAndCustomTags() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("source.wav"); try audio(wav)
        let url = dir.appendingPathComponent("song.flac"); try SFBAudioEngine.AudioConverter.convert(wav, to: url)
        try FileManager.default.removeItem(at: wav)
        let f = try AudioFile(readingPropertiesAndMetadataFrom: url)
        f.metadata.additionalMetadata = ["TEST_CUSTOM": "original"]
        let picture = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZe8AAAAASUVORK5CYII=")!
        f.metadata.attachPicture(AttachedPicture(imageData: picture, type: .frontCover)); try f.writeMetadata()
        let original = try Data(contentsOf: url)
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        try await scanner.scan(db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        let track = try #require(try db.allTracks().first)
        #expect(track.extraTags["TEST_CUSTOM"] == "original")
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: dir.appendingPathComponent(".backups"))
        _ = try await writer.apply(TagEdit(custom: ["TEST_CUSTOM": "changed"], artwork: .remove), to: [track])
        #expect(try await writer.revertLastEdit(trackID: track.id!))
        #expect(try Data(contentsOf: url) == original)
    }
    @Test func editingSomeFieldsKeepsEveryValueOfTheOthers() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("source.wav"); try audio(wav)
        let url = dir.appendingPathComponent("song.flac"); try SFBAudioEngine.AudioConverter.convert(wav, to: url)
        try FileManager.default.removeItem(at: wav)
        func set(_ key: String, _ values: [String]) {
            let copies = values.compactMap { strdup($0) }
            defer { copies.forEach { free($0) } }
            let status = copies.map { UnsafePointer($0) }.withUnsafeBufferPointer { nvt_property_set(url.path, key, $0.baseAddress, Int32(values.count)) }
            #expect(status == 0)
        }
        func values(_ key: String) -> [String] {
            var buffer = [CChar](repeating: 0, count: 4096)
            let count = nvt_property_get(url.path, key, &buffer, Int32(buffer.count))
            return count > 0 ? String(cString: buffer).components(separatedBy: "\n") : []
        }
        let ids = ["5d3b3f2c-0000-4000-8000-000000000001", "5d3b3f2c-0000-4000-8000-000000000002"]
        set("ARTIST", ["Simon", "Garfunkel"]); set("GENRE", ["Folk", "Rock"]); set("MUSICBRAINZ_ARTISTID", ids); set("TEST_GONE", ["x"])
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        try await scanner.scan(db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        let track = try #require(try db.allTracks().first)
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: dir.appendingPathComponent(".backups"))
        let result = try await writer.apply(TagEdit(fields: [.title: "Edited", .genre: "Pop"], custom: ["TEST_GONE": nil]), to: [track])
        #expect(result.written == 1 && result.failures.isEmpty)
        #expect(values("ARTIST") == ["Simon", "Garfunkel"])     // untouched: every value kept
        #expect(values("MUSICBRAINZ_ARTISTID") == ids)
        #expect(values("GENRE") == ["Pop"])                     // edited: as edited
        #expect(values("TITLE") == ["Edited"])
        #expect(values("TEST_GONE").isEmpty)                    // a deleted custom tag leaves the file
    }
    @Test func numericCueOverflowIsRejected() {
        #expect(CueSheet.cdFrames("9223372036854775807:59:74") == nil)
        #expect(CueSheet.sampleFrame(cdFrames: Int.max, sampleRate: .infinity) == 0)
    }

    @Test func overlappingSourcesCannotStealTrackOwnership() throws {
        let db = try LibraryDatabase.inMemory()
        let child = try db.addSource(LibrarySource(path: "/audit-music/album", mode: .reference))
        #expect(try db.addSource(LibrarySource(path: "/audit-music/album/song.wav", mode: .reference)).id == child.id)
        #expect(throws: (any Error).self) { try db.addSource(LibrarySource(path: "/audit-music", mode: .reference)) }
        #expect(try db.sources().count == 1)
    }
    @Test func cueStatisticsCountPhysicalFileOnce() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("set.wav"); try audio(url); try cue(at: dir.appendingPathComponent("set.cue"))
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        try await scanner.scan(db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        #expect(try db.stats().bytes == Int64(Data(contentsOf: url).count))
    }
    @Test func managedFolderIsNotRecursivelyReimported() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try audio(dir.appendingPathComponent("song.wav"))
        #expect(try Importer.copyAndOrganize([dir], into: dir).isEmpty)
        #expect(LibraryScanner.enumerate(dir).audio.count == 1)
    }

    @Test func undoRefusesToOverwriteExternalChanges() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("song.wav"); try audio(url)
        let db = try LibraryDatabase.inMemory()
        let scanner = LibraryScanner(database: db, artwork: ArtworkStore(directory: dir.appendingPathComponent(".art")))
        await scanner.setSkipsNonMusic(false) // fixtures are short clips
        try await scanner.scan(db.addSource(LibrarySource(path: dir.path, mode: .reference)))
        let track = try #require(try db.allTracks().first)
        let writer = TagWriter(database: db, scanner: scanner, backupDirectory: dir.appendingPathComponent(".backups"))
        await #expect(throws: (any Error).self) {
            try await writer.apply(TagEdit(fields: [.trackNumber: "not a number"]), to: [track])
        }
        _ = try await writer.apply(TagEdit(fields: [.title: "Edited"]), to: [track])
        var external = try Data(contentsOf: url); external.append(contentsOf: [1,2,3,4]); try external.write(to: url)
        await #expect(throws: (any Error).self) { try await writer.revertLastEdit(trackID: track.id!) }
        #expect(try Data(contentsOf: url) == external)
    }

}
